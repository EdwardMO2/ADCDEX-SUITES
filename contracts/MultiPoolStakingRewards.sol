// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IMultiPoolStakingRewards} from "./Interfaces/IMultiPoolStakingRewards.sol";

/// @title MultiPoolStakingRewards
/// @author ADCDEX
/// @notice Upgradeable multi-pool yield farming contract that allows users to
///         stake ERC-20 tokens across independent pools and earn ADC rewards.
///         Each pool has its own reward rate, lockup duration, and early-
///         unstake penalty.  An optional ERC-721 contract provides per-user
///         reward boosts (5 % per NFT held, capped at 25 %).
///
/// @dev Architecture
///  - Per-share accounting (MasterChef pattern) keeps reward calculations O(1).
///  - `accRewardPerShare` is stored scaled by PRECISION (1e18) to avoid
///    truncation on small amounts.
///  - NFT boosts are applied on top of the base pending reward at claim time;
///    they are NOT baked into `rewardDebt`, so the extra tokens are pulled
///    from the reward pool on each claim.
///  - Early-unstake penalties stay in the contract, segregated by pool, and
///    can be recovered by the owner via `collectPoolPenalties`.
///  - UUPS upgrade pattern; upgrades are gated by `onlyOwner`.
///  - `ReentrancyGuard` (OZ v5, namespaced storage) protects all
///    state-changing user entry points.
contract MultiPoolStakingRewards is
    IMultiPoolStakingRewards,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // =========================================================================
    //                             CONSTANTS
    // =========================================================================

    /// @notice NFT boost granted per NFT held (500 BPS = 5 %).
    uint256 public constant NFT_BOOST_PER_TOKEN_BPS = 500;

    /// @notice Maximum NFT boost (2 500 BPS = 25 %, achieved with ≥ 5 NFTs).
    uint256 public constant MAX_NFT_BOOST_BPS = 2500;

    /// @notice Basis-points denominator (10 000 = 100 %).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Scaling factor used for `accRewardPerShare` arithmetic.
    uint256 internal constant PRECISION = 1e18;

    // =========================================================================
    //                              STATE
    // =========================================================================

    /// @notice Token distributed as rewards across all pools (e.g. ADC).
    IERC20 public rewardToken;

    /// @notice Optional ERC-721 contract whose token balance drives NFT boosts.
    ///         Set to `address(0)` to disable NFT boosts globally.
    IERC721 public nftContract;

    /// @notice Ordered list of all registered pools.
    PoolInfo[] public pools;

    /// @notice Per-user, per-pool staking positions.
    /// @dev    user => poolId => UserStakeInfo
    mapping(address => mapping(uint256 => UserStakeInfo)) public userStakes;

    /// @notice Early-withdrawal penalties accumulated per pool (in that pool's
    ///         stake token), claimable by the owner via `collectPoolPenalties`.
    mapping(uint256 => uint256) public poolPenalties;

    // =========================================================================
    //                            INITIALIZER
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract (called once via the proxy).
    /// @param _rewardToken  Address of the ERC-20 reward token (e.g. ADC).
    ///                      Must not be `address(0)`.
    /// @param _nftContract  Address of the ERC-721 boost contract.
    ///                      Pass `address(0)` to disable NFT boosts.
    /// @param _owner        Initial owner / admin of the contract.
    function initialize(
        address _rewardToken,
        address _nftContract,
        address _owner
    ) public initializer {
        require(_rewardToken != address(0), "Invalid reward token");
        require(_owner != address(0), "Invalid owner");

        __Ownable_init(_owner);

        rewardToken = IERC20(_rewardToken);

        if (_nftContract != address(0)) {
            nftContract = IERC721(_nftContract);
            emit NFTContractSet(_nftContract);
        }

        emit RewardTokenSet(_rewardToken);
    }

    // =========================================================================
    //                        UPGRADE AUTHORIZATION
    // =========================================================================

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // =========================================================================
    //                          POOL MANAGEMENT
    // =========================================================================

    /// @inheritdoc IMultiPoolStakingRewards
    function addPool(
        address stakeToken,
        uint256 rewardRate,
        uint256 lockupDuration,
        uint256 earlyUnstakePenalty
    ) external onlyOwner returns (uint256 poolId) {
        require(stakeToken != address(0), "Invalid stake token");
        if (earlyUnstakePenalty > BPS_DENOMINATOR) {
            revert PenaltyTooHigh(earlyUnstakePenalty);
        }

        poolId = pools.length;

        pools.push(
            PoolInfo({
                stakeToken: stakeToken,
                rewardRate: rewardRate,
                lockupDuration: lockupDuration,
                totalStaked: 0,
                accRewardPerShare: 0,
                lastUpdateTime: block.timestamp,
                earlyUnstakePenalty: earlyUnstakePenalty,
                isActive: true
            })
        );

        emit PoolAdded(poolId, stakeToken, rewardRate);
    }

    /// @inheritdoc IMultiPoolStakingRewards
    function updatePoolConfig(
        uint256 poolId,
        uint256 rewardRate,
        uint256 lockupDuration,
        uint256 earlyUnstakePenalty
    ) external onlyOwner {
        if (poolId >= pools.length) revert InvalidPool(poolId);
        if (earlyUnstakePenalty > BPS_DENOMINATOR) {
            revert PenaltyTooHigh(earlyUnstakePenalty);
        }

        _updatePool(poolId);

        PoolInfo storage pool = pools[poolId];
        pool.rewardRate = rewardRate;
        pool.lockupDuration = lockupDuration;
        pool.earlyUnstakePenalty = earlyUnstakePenalty;

        emit PoolUpdated(poolId, rewardRate, earlyUnstakePenalty);
    }

    /// @inheritdoc IMultiPoolStakingRewards
    function pausePool(uint256 poolId) external onlyOwner {
        if (poolId >= pools.length) revert InvalidPool(poolId);
        require(pools[poolId].isActive, "Already paused");

        _updatePool(poolId);
        pools[poolId].isActive = false;

        emit PoolPaused(poolId);
    }

    /// @inheritdoc IMultiPoolStakingRewards
    function unpausePool(uint256 poolId) external onlyOwner {
        if (poolId >= pools.length) revert InvalidPool(poolId);
        require(!pools[poolId].isActive, "Already active");

        pools[poolId].lastUpdateTime = block.timestamp;
        pools[poolId].isActive = true;

        emit PoolUnpaused(poolId);
    }

    // =========================================================================
    //                            USER ACTIONS
    // =========================================================================

    /// @inheritdoc IMultiPoolStakingRewards
    function stake(uint256 poolId, uint256 amount) external nonReentrant {
        if (poolId >= pools.length) revert InvalidPool(poolId);
        if (amount == 0) revert ZeroAmount();

        PoolInfo storage pool = pools[poolId];
        if (!pool.isActive) revert PoolPausedError(poolId);

        _updatePool(poolId);

        UserStakeInfo storage userStake = userStakes[msg.sender][poolId];

        // Auto-claim any accrued rewards before modifying the stake.
        if (userStake.amount > 0) {
            uint256 pending = _calcPendingBase(userStake, pool);
            if (pending > 0) {
                uint256 boosted = _applyNFTBoost(msg.sender, pending);
                _safeRewardTransfer(msg.sender, boosted, poolId);
            }
        }

        IERC20(pool.stakeToken).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        userStake.amount += amount;
        userStake.depositTime = block.timestamp;
        userStake.rewardDebt =
            (userStake.amount * pool.accRewardPerShare) /
            PRECISION;

        pool.totalStaked += amount;

        emit Staked(msg.sender, poolId, amount);
    }

    /// @inheritdoc IMultiPoolStakingRewards
    function unstake(uint256 poolId, uint256 amount) external nonReentrant {
        if (poolId >= pools.length) revert InvalidPool(poolId);
        if (amount == 0) revert ZeroAmount();

        UserStakeInfo storage userStake = userStakes[msg.sender][poolId];
        if (userStake.amount < amount) {
            revert InsufficientStake(amount, userStake.amount);
        }

        _updatePool(poolId);

        PoolInfo storage pool = pools[poolId];

        // Claim accrued rewards before reducing the position.
        uint256 pending = _calcPendingBase(userStake, pool);
        if (pending > 0) {
            uint256 boosted = _applyNFTBoost(msg.sender, pending);
            _safeRewardTransfer(msg.sender, boosted, poolId);
        }

        // Determine early-unstake penalty.
        uint256 penalty = 0;
        if (
            pool.lockupDuration > 0 &&
            pool.earlyUnstakePenalty > 0 &&
            block.timestamp < userStake.depositTime + pool.lockupDuration
        ) {
            penalty = (amount * pool.earlyUnstakePenalty) / BPS_DENOMINATOR;
            poolPenalties[poolId] += penalty;
        }

        uint256 amountOut = amount - penalty;

        pool.totalStaked -= amount;
        userStake.amount -= amount;
        userStake.rewardDebt =
            (userStake.amount * pool.accRewardPerShare) /
            PRECISION;

        IERC20(pool.stakeToken).safeTransfer(msg.sender, amountOut);

        emit Unstaked(msg.sender, poolId, amount, penalty);
    }

    /// @inheritdoc IMultiPoolStakingRewards
    function claim(uint256 poolId) external nonReentrant {
        if (poolId >= pools.length) revert InvalidPool(poolId);

        _updatePool(poolId);

        PoolInfo storage pool = pools[poolId];
        UserStakeInfo storage userStake = userStakes[msg.sender][poolId];

        uint256 pending = _calcPendingBase(userStake, pool);
        if (pending == 0) revert NoRewardsToClaim();

        // Update debt before transfer to follow CEI pattern.
        userStake.rewardDebt =
            (userStake.amount * pool.accRewardPerShare) /
            PRECISION;

        uint256 boosted = _applyNFTBoost(msg.sender, pending);
        _safeRewardTransfer(msg.sender, boosted, poolId);
    }

    /// @inheritdoc IMultiPoolStakingRewards
    function emergencyWithdraw(uint256 poolId) external nonReentrant {
        if (poolId >= pools.length) revert InvalidPool(poolId);

        UserStakeInfo storage userStake = userStakes[msg.sender][poolId];
        if (userStake.amount == 0) revert NothingToWithdraw();

        PoolInfo storage pool = pools[poolId];
        uint256 amount = userStake.amount;

        pool.totalStaked -= amount;
        userStake.amount = 0;
        userStake.rewardDebt = 0;
        userStake.depositTime = 0;

        IERC20(pool.stakeToken).safeTransfer(msg.sender, amount);

        emit EmergencyWithdraw(msg.sender, poolId, amount);
    }

    // =========================================================================
    //                          ADMIN FUNCTIONS
    // =========================================================================

    /// @notice Update the NFT contract used for reward boosts.
    /// @dev    Pass `address(0)` to disable NFT boosts.
    ///         Can only be called by the owner.
    /// @param _nftContract New ERC-721 contract address.
    function setNFTContract(address _nftContract) external onlyOwner {
        nftContract = IERC721(_nftContract);
        emit NFTContractSet(_nftContract);
    }

    /// @notice Deposit reward tokens into the contract for distribution.
    /// @dev    Any address can fund the reward pool.
    /// @param amount Amount of reward tokens to transfer in.
    function fundRewardPool(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Collect accumulated early-unstake penalties for a pool.
    /// @dev    Penalties are denominated in that pool's stake token.
    ///         Can only be called by the owner.
    /// @param poolId    Pool whose penalties should be collected.
    /// @param recipient Address that receives the penalty tokens.
    function collectPoolPenalties(
        uint256 poolId,
        address recipient
    ) external onlyOwner {
        if (poolId >= pools.length) revert InvalidPool(poolId);
        require(recipient != address(0), "Invalid recipient");

        uint256 amount = poolPenalties[poolId];
        require(amount > 0, "No penalties to collect");

        poolPenalties[poolId] = 0;
        IERC20(pools[poolId].stakeToken).safeTransfer(recipient, amount);
    }

    // =========================================================================
    //                           VIEW FUNCTIONS
    // =========================================================================

    /// @inheritdoc IMultiPoolStakingRewards
    function pendingRewards(
        address user,
        uint256 poolId
    ) external view returns (uint256) {
        if (poolId >= pools.length) return 0;

        PoolInfo storage pool = pools[poolId];
        UserStakeInfo storage userStake = userStakes[user][poolId];

        if (userStake.amount == 0) return 0;

        // Simulate the pool update to include time elapsed since last sync.
        uint256 acc = pool.accRewardPerShare;
        if (
            pool.isActive &&
            block.timestamp > pool.lastUpdateTime &&
            pool.totalStaked > 0
        ) {
            uint256 elapsed = block.timestamp - pool.lastUpdateTime;
            acc += (elapsed * pool.rewardRate * PRECISION) / pool.totalStaked;
        }

        uint256 base = (userStake.amount * acc) / PRECISION - userStake.rewardDebt;
        return _applyNFTBoost(user, base);
    }

    /// @inheritdoc IMultiPoolStakingRewards
    function getPoolInfo(
        uint256 poolId
    ) external view returns (PoolInfo memory) {
        if (poolId >= pools.length) revert InvalidPool(poolId);
        return pools[poolId];
    }

    /// @inheritdoc IMultiPoolStakingRewards
    function getUserStakeInfo(
        address user,
        uint256 poolId
    ) external view returns (UserStakeInfo memory) {
        return userStakes[user][poolId];
    }

    /// @inheritdoc IMultiPoolStakingRewards
    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    /// @inheritdoc IMultiPoolStakingRewards
    function getNFTBoostBps(
        address user,
        uint256 /*poolId*/
    ) external view returns (uint256) {
        return _calcNFTBoostBps(user);
    }

    // =========================================================================
    //                        INTERNAL HELPERS
    // =========================================================================

    /// @notice Sync `accRewardPerShare` and `lastUpdateTime` for a pool.
    /// @dev    No-op if the pool is paused, no tokens are staked, or the
    ///         timestamp has not advanced.
    function _updatePool(uint256 poolId) internal {
        PoolInfo storage pool = pools[poolId];

        if (!pool.isActive || block.timestamp <= pool.lastUpdateTime) return;

        if (pool.totalStaked == 0) {
            pool.lastUpdateTime = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - pool.lastUpdateTime;
        pool.accRewardPerShare +=
            (elapsed * pool.rewardRate * PRECISION) /
            pool.totalStaked;
        pool.lastUpdateTime = block.timestamp;
    }

    /// @notice Calculate the base (pre-boost) pending reward for a user.
    /// @param userStake Storage reference to the user's position.
    /// @param pool      Storage reference to the pool.
    /// @return Base pending reward amount.
    function _calcPendingBase(
        UserStakeInfo storage userStake,
        PoolInfo storage pool
    ) internal view returns (uint256) {
        if (userStake.amount == 0) return 0;
        return
            (userStake.amount * pool.accRewardPerShare) /
            PRECISION -
            userStake.rewardDebt;
    }

    /// @notice Apply the NFT boost to a base reward amount.
    /// @param user       Staker whose NFT balance is checked.
    /// @param baseAmount Unadjusted reward amount.
    /// @return Reward amount after boost.
    function _applyNFTBoost(
        address user,
        uint256 baseAmount
    ) internal view returns (uint256) {
        uint256 boostBps = _calcNFTBoostBps(user);
        if (boostBps == 0) return baseAmount;
        return baseAmount + (baseAmount * boostBps) / BPS_DENOMINATOR;
    }

    /// @notice Calculate the NFT boost in BPS for a given user.
    /// @dev    Returns 0 when no NFT contract is configured or balance is zero.
    function _calcNFTBoostBps(address user) internal view returns (uint256) {
        if (address(nftContract) == address(0)) return 0;
        uint256 balance = nftContract.balanceOf(user);
        if (balance == 0) return 0;
        uint256 boost = balance * NFT_BOOST_PER_TOKEN_BPS;
        return boost > MAX_NFT_BOOST_BPS ? MAX_NFT_BOOST_BPS : boost;
    }

    /// @notice Transfer reward tokens to a recipient, capping at available
    ///         balance to avoid hard reverts when the reward pool is exhausted.
    /// @param to     Recipient address.
    /// @param amount Desired transfer amount.
    /// @param poolId Pool the reward originates from (used for event emission).
    function _safeRewardTransfer(
        address to,
        uint256 amount,
        uint256 poolId
    ) internal {
        uint256 available = rewardToken.balanceOf(address(this));
        uint256 actual = amount > available ? available : amount;
        if (actual == 0) return;

        rewardToken.safeTransfer(to, actual);
        emit RewardsClaimed(to, poolId, actual);
    }
}
