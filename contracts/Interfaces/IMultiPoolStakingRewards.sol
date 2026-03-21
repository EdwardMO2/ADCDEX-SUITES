// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMultiPoolStakingRewards
/// @notice Interface for the MultiPoolStakingRewards contract.
/// @dev Defines all externally callable functions, structs, events, and
///      custom errors used by the multi-pool yield farming system.
interface IMultiPoolStakingRewards {
    // =========================================================================
    //                               STRUCTS
    // =========================================================================

    /// @notice Configuration and state for a single staking pool.
    /// @param stakeToken          ERC-20 token accepted as a deposit.
    /// @param rewardRate          Reward tokens emitted per second for this pool.
    /// @param lockupDuration      Minimum seconds before penalty-free withdrawal.
    /// @param totalStaked         Total stake token balance held by the pool.
    /// @param accRewardPerShare   Accumulated rewards per share (scaled by 1e18).
    /// @param lastUpdateTime      Timestamp of the last reward accrual.
    /// @param earlyUnstakePenalty Penalty fraction for early withdrawal in BPS
    ///                            (e.g. 1000 = 10%).
    /// @param isActive            Whether the pool is currently accepting stakes
    ///                            and accruing rewards.
    struct PoolInfo {
        address stakeToken;
        uint256 rewardRate;
        uint256 lockupDuration;
        uint256 totalStaked;
        uint256 accRewardPerShare;
        uint256 lastUpdateTime;
        uint256 earlyUnstakePenalty;
        bool isActive;
    }

    /// @notice Per-user, per-pool staking position.
    /// @param amount      Tokens currently staked.
    /// @param rewardDebt  Reward debt used to calculate unclaimed base rewards.
    /// @param depositTime Timestamp of the most recent deposit (used for lockup
    ///                    checks).
    struct UserStakeInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 depositTime;
    }

    // =========================================================================
    //                               EVENTS
    // =========================================================================

    /// @notice Emitted when a new pool is registered.
    event PoolAdded(
        uint256 indexed poolId,
        address indexed stakeToken,
        uint256 rewardRate
    );

    /// @notice Emitted when a pool's configuration is updated.
    event PoolUpdated(
        uint256 indexed poolId,
        uint256 rewardRate,
        uint256 earlyUnstakePenalty
    );

    /// @notice Emitted when a pool is paused.
    event PoolPaused(uint256 indexed poolId);

    /// @notice Emitted when a pool is unpaused.
    event PoolUnpaused(uint256 indexed poolId);

    /// @notice Emitted when a user stakes tokens.
    event Staked(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount
    );

    /// @notice Emitted when a user unstakes tokens.
    /// @param penalty The early-withdrawal penalty deducted from the user's
    ///                returned tokens (0 if lockup has elapsed).
    event Unstaked(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount,
        uint256 penalty
    );

    /// @notice Emitted when a user claims accrued rewards.
    event RewardsClaimed(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount
    );

    /// @notice Emitted on emergency withdrawal (rewards forfeited).
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount
    );

    /// @notice Emitted when the reward token address is set.
    event RewardTokenSet(address indexed rewardToken);

    /// @notice Emitted when the NFT boost contract address is set.
    event NFTContractSet(address indexed nftContract);

    // =========================================================================
    //                          CUSTOM ERRORS
    // =========================================================================

    /// @notice Thrown when a pool ID does not refer to an existing pool.
    error InvalidPool(uint256 poolId);

    /// @notice Thrown when an amount of 0 is supplied to a stake/unstake call.
    error ZeroAmount();

    /// @notice Thrown when a user tries to unstake more than their staked balance.
    error InsufficientStake(uint256 requested, uint256 available);

    /// @notice Thrown when an operation requires an active pool but the pool is
    ///         paused.
    error PoolPausedError(uint256 poolId);

    /// @notice Thrown when an early-unstake penalty exceeds 100%.
    error PenaltyTooHigh(uint256 penaltyBps);

    /// @notice Thrown when there are no rewards pending to claim.
    error NoRewardsToClaim();

    /// @notice Thrown when there is nothing staked for an emergency withdrawal.
    error NothingToWithdraw();

    // =========================================================================
    //                         POOL MANAGEMENT
    // =========================================================================

    /// @notice Create a new staking pool.
    /// @dev Can only be called by the contract owner.
    ///      Emits {PoolAdded}.
    /// @param stakeToken          ERC-20 token users will stake.
    /// @param rewardRate          Reward tokens emitted per second.
    /// @param lockupDuration      Seconds the stake must be held before the
    ///                            early-withdrawal penalty is waived.
    /// @param earlyUnstakePenalty Penalty in BPS applied to early withdrawals.
    /// @return poolId             Index of the newly created pool in the pools
    ///                            array.
    function addPool(
        address stakeToken,
        uint256 rewardRate,
        uint256 lockupDuration,
        uint256 earlyUnstakePenalty
    ) external returns (uint256 poolId);

    /// @notice Update an existing pool's configuration.
    /// @dev Can only be called by the contract owner.
    ///      Emits {PoolUpdated}.
    ///      Triggers a pool reward sync before applying the new parameters.
    /// @param poolId              Pool to update.
    /// @param rewardRate          New reward emission rate (tokens per second).
    /// @param lockupDuration      New minimum staking duration.
    /// @param earlyUnstakePenalty New early-withdrawal penalty in BPS.
    function updatePoolConfig(
        uint256 poolId,
        uint256 rewardRate,
        uint256 lockupDuration,
        uint256 earlyUnstakePenalty
    ) external;

    /// @notice Pause a pool, stopping new stakes and reward accrual.
    /// @dev Can only be called by the contract owner.
    ///      Emits {PoolPaused}.
    function pausePool(uint256 poolId) external;

    /// @notice Resume a previously paused pool.
    /// @dev Can only be called by the contract owner.
    ///      Emits {PoolUnpaused}.
    ///      Resets `lastUpdateTime` so no phantom rewards accumulate during the
    ///      paused interval.
    function unpausePool(uint256 poolId) external;

    // =========================================================================
    //                           USER ACTIONS
    // =========================================================================

    /// @notice Stake tokens in a pool.
    /// @dev Emits {Staked}.
    ///      Any accrued rewards are auto-claimed before the stake is recorded.
    ///      The deposit time is reset to `block.timestamp`, restarting the lockup
    ///      window for the entire position.
    /// @param poolId Pool to stake in.
    /// @param amount Amount of stake tokens to deposit.
    function stake(uint256 poolId, uint256 amount) external;

    /// @notice Withdraw staked tokens from a pool.
    /// @dev Emits {Unstaked}.
    ///      Accrued rewards are paid before the stake is reduced.
    ///      A penalty is deducted when the lockup has not elapsed.
    /// @param poolId Pool to withdraw from.
    /// @param amount Amount of stake tokens to withdraw.
    function unstake(uint256 poolId, uint256 amount) external;

    /// @notice Claim all pending rewards for a pool without altering the stake.
    /// @dev Emits {RewardsClaimed}.
    ///      Applies any applicable NFT boost to the base reward before transfer.
    /// @param poolId Pool to claim rewards from.
    function claim(uint256 poolId) external;

    /// @notice Withdraw the entire stake immediately, forfeiting all accrued
    ///         rewards.
    /// @dev Emits {EmergencyWithdraw}.
    ///      No lockup penalty is applied; reward debt is cleared.
    ///      Intended as a last-resort escape hatch.
    /// @param poolId Pool to emergency-withdraw from.
    function emergencyWithdraw(uint256 poolId) external;

    // =========================================================================
    //                            VIEW FUNCTIONS
    // =========================================================================

    /// @notice Calculate the pending reward for a user in a pool.
    /// @dev Simulates a pool update to include rewards accrued since the last
    ///      on-chain interaction.  The NFT boost is applied on top of the base
    ///      pending reward.
    /// @param user   Staker address.
    /// @param poolId Pool to query.
    /// @return Pending reward amount (including NFT boost if applicable).
    function pendingRewards(
        address user,
        uint256 poolId
    ) external view returns (uint256);

    /// @notice Return the full `PoolInfo` struct for a pool.
    function getPoolInfo(
        uint256 poolId
    ) external view returns (PoolInfo memory);

    /// @notice Return the full `UserStakeInfo` struct for a user / pool pair.
    function getUserStakeInfo(
        address user,
        uint256 poolId
    ) external view returns (UserStakeInfo memory);

    /// @notice Return the total number of pools.
    function poolCount() external view returns (uint256);

    /// @notice Return the NFT boost in BPS that would be applied to a user's
    ///         rewards in a given pool.
    /// @dev Returns 0 when no NFT contract is configured or the user holds no
    ///      NFTs.
    function getNFTBoostBps(
        address user,
        uint256 poolId
    ) external view returns (uint256);
}
