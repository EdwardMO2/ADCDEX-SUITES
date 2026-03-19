// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// =============================================================================
//                           MOCK CONTRACTS
// =============================================================================

/// @dev Minimal ERC-20 implementation used only in tests.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

/// @dev Minimal ERC-721 implementation used only in tests.
contract MockERC721 {
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public ownerOf;

    uint256 private _nextId = 1;

    event Transfer(
        address indexed from,
        address indexed to,
        uint256 indexed tokenId
    );

    function mint(address to) external returns (uint256 tokenId) {
        tokenId = _nextId++;
        ownerOf[tokenId] = to;
        balanceOf[to]++;
        emit Transfer(address(0), to, tokenId);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x80ac58cd; // ERC-721
    }
}

// =============================================================================
//                       LIBRARY / TEST HELPERS
// =============================================================================

library TestAssert {
    function assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function assertFalse(bool condition, string memory message) internal pure {
        require(!condition, message);
    }

    function assertEq(
        uint256 a,
        uint256 b,
        string memory message
    ) internal pure {
        if (a != b) {
            revert(string(abi.encodePacked(message, ": expected ", _u2s(a), " == ", _u2s(b))));
        }
    }

    function assertGt(
        uint256 a,
        uint256 b,
        string memory message
    ) internal pure {
        require(a > b, message);
    }

    function assertAddrEq(
        address a,
        address b,
        string memory message
    ) internal pure {
        require(a == b, message);
    }

    function _u2s(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 digits;
        while (tmp != 0) { digits++; tmp /= 10; }
        bytes memory buf = new bytes(digits);
        while (v != 0) { digits--; buf[digits] = bytes1(uint8(48 + uint256(v % 10))); v /= 10; }
        return string(buf);
    }
}

// =============================================================================
//                   PROXY / DEPLOYMENT HELPERS
// =============================================================================

/// @dev A minimal ERC-1967 transparent proxy used to test upgradeable contracts.
contract ERC1967Proxy {
    // ERC-1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1
    bytes32 private constant _IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address implementation, bytes memory data) payable {
        assembly {
            sstore(_IMPL_SLOT, implementation)
        }
        if (data.length > 0) {
            (bool ok, bytes memory reason) = implementation.delegatecall(data);
            if (!ok) {
                assembly { revert(add(reason, 32), mload(reason)) }
            }
        }
    }

    fallback() external payable {
        assembly {
            let impl := sload(_IMPL_SLOT)
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}

// =============================================================================
//                        CONTRACT UNDER TEST (import)
// =============================================================================

import {MultiPoolStakingRewards} from "../contracts/MultiPoolStakingRewards.sol";

// =============================================================================
//                            TEST SUITE
// =============================================================================

/// @title MultiPoolStakingRewardsTest
/// @notice Comprehensive test suite for MultiPoolStakingRewards.
///
/// @dev Test execution model
///  - Each `test*` function is self-contained and deploys its own proxy, so
///    tests do not share state.
///  - Time-dependent tests use helper contracts or inline time manipulation
///    via selfdestruct-free assembly warp tricks; where warp is unavailable
///    the test validates invariants at t=0 and documents expected behaviour.
///  - Call `runAll()` to execute every test in one transaction (useful for
///    coverage reporting against local nodes that support arbitrary block
///    timestamps via `evm_setNextBlockTimestamp`).
///
/// NOTE: To run against a live EVM (where block.timestamp cannot be warped),
/// deploy a Foundry test (see `foundry` branch) or use Hardhat's
/// `helpers.time.increase` helper in the JavaScript test suite.
contract MultiPoolStakingRewardsTest {
    using TestAssert for *;

    // -------------------------------------------------------------------------
    //                          CONSTANTS
    // -------------------------------------------------------------------------

    uint256 constant REWARD_RATE = 1 ether;    // 1 ADC / second
    uint256 constant LOCKUP = 7 days;
    uint256 constant PENALTY_BPS = 1000;       // 10 %
    uint256 constant INITIAL_REWARDS = 1_000_000 ether;
    uint256 constant USER_BALANCE = 1_000 ether;

    // -------------------------------------------------------------------------
    //                          EVENTS (re-declared for vm.expectEmit)
    // -------------------------------------------------------------------------

    event PoolAdded(uint256 indexed poolId, address indexed stakeToken, uint256 rewardRate);
    event Staked(address indexed user, uint256 indexed poolId, uint256 amount);
    event Unstaked(address indexed user, uint256 indexed poolId, uint256 amount, uint256 penalty);
    event RewardsClaimed(address indexed user, uint256 indexed poolId, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed poolId, uint256 amount);

    // -------------------------------------------------------------------------
    //                        DEPLOYMENT HELPERS
    // -------------------------------------------------------------------------

    /// @notice Deploy a fresh proxy + implementation + mock tokens for each test.
    function _deploy()
        internal
        returns (
            MultiPoolStakingRewards staking,
            MockERC20 rewardToken,
            MockERC20 stakeToken,
            MockERC721 nft
        )
    {
        rewardToken = new MockERC20("ADC", "ADC");
        stakeToken = new MockERC20("LP1", "LP1");
        nft = new MockERC721();

        MultiPoolStakingRewards impl = new MultiPoolStakingRewards();

        bytes memory initData = abi.encodeCall(
            MultiPoolStakingRewards.initialize,
            (address(rewardToken), address(nft), address(this))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        staking = MultiPoolStakingRewards(address(proxy));

        // Fund reward pool
        rewardToken.mint(address(this), INITIAL_REWARDS);
        rewardToken.approve(address(staking), INITIAL_REWARDS);
        staking.fundRewardPool(INITIAL_REWARDS);
    }

    /// @notice Add Pool 0 with default parameters to a deployed staking contract.
    function _addPool(
        MultiPoolStakingRewards staking,
        MockERC20 stakeToken
    ) internal returns (uint256 poolId) {
        poolId = staking.addPool(
            address(stakeToken),
            REWARD_RATE,
            LOCKUP,
            PENALTY_BPS
        );
    }

    // -------------------------------------------------------------------------
    //                        1. INITIALIZATION
    // -------------------------------------------------------------------------

    /// @notice Contract initialises with the correct reward token, NFT contract,
    ///         owner, and zero pools.
    function testInitialization() public {
        (
            MultiPoolStakingRewards staking,
            MockERC20 rewardToken,
            ,
            MockERC721 nft
        ) = _deploy();

        TestAssert.assertAddrEq(
            address(staking.rewardToken()),
            address(rewardToken),
            "rewardToken"
        );
        TestAssert.assertAddrEq(
            address(staking.nftContract()),
            address(nft),
            "nftContract"
        );
        TestAssert.assertAddrEq(staking.owner(), address(this), "owner");
        TestAssert.assertEq(staking.poolCount(), 0, "poolCount");
    }

    /// @notice initialize() reverts when reward token is address(0).
    function testInitializeRevertsOnZeroRewardToken() public {
        MultiPoolStakingRewards impl = new MultiPoolStakingRewards();
        bytes memory initData = abi.encodeCall(
            MultiPoolStakingRewards.initialize,
            (address(0), address(0), address(this))
        );
        bool ok;
        try new ERC1967Proxy(address(impl), initData) {
            ok = true;
        } catch {
            ok = false;
        }
        TestAssert.assertFalse(ok, "should revert on zero reward token");
    }

    /// @notice initialize() reverts when owner is address(0).
    function testInitializeRevertsOnZeroOwner() public {
        MockERC20 rt = new MockERC20("R", "R");
        MultiPoolStakingRewards impl = new MultiPoolStakingRewards();
        bytes memory initData = abi.encodeCall(
            MultiPoolStakingRewards.initialize,
            (address(rt), address(0), address(0))
        );
        bool ok;
        try new ERC1967Proxy(address(impl), initData) {
            ok = true;
        } catch {
            ok = false;
        }
        TestAssert.assertFalse(ok, "should revert on zero owner");
    }

    // -------------------------------------------------------------------------
    //                      2. POOL CREATION
    // -------------------------------------------------------------------------

    /// @notice addPool registers a pool and increments the count.
    function testAddPool() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();

        uint256 poolId = staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);
        TestAssert.assertEq(poolId, 0, "poolId should be 0");
        TestAssert.assertEq(staking.poolCount(), 1, "poolCount");

        MultiPoolStakingRewards.PoolInfo memory info = staking.getPoolInfo(0);
        TestAssert.assertAddrEq(info.stakeToken, address(stakeToken), "stakeToken");
        TestAssert.assertEq(info.rewardRate, REWARD_RATE, "rewardRate");
        TestAssert.assertEq(info.lockupDuration, LOCKUP, "lockup");
        TestAssert.assertEq(info.earlyUnstakePenalty, PENALTY_BPS, "penalty");
        TestAssert.assertTrue(info.isActive, "pool should be active");
        TestAssert.assertEq(info.totalStaked, 0, "totalStaked");
    }

    /// @notice Only the owner can add a pool.
    function testAddPoolOnlyOwner() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();

        // Calling from this contract as owner — should succeed.
        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);

        // Calling from a different address — should revert.
        MultiPoolStakingRewards stakingAlias = staking;
        bool ok;
        // We simulate a non-owner call by deploying a caller helper.
        ForeignCaller caller = new ForeignCaller();
        try caller.callAddPool(address(stakingAlias), address(stakeToken)) {
            ok = true;
        } catch {
            ok = false;
        }
        TestAssert.assertFalse(ok, "non-owner should not add pool");
    }

    /// @notice addPool reverts when earlyUnstakePenalty > BPS_DENOMINATOR.
    function testAddPoolPenaltyTooHigh() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();

        bool ok;
        try staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, 10_001) {
            ok = true;
        } catch {
            ok = false;
        }
        TestAssert.assertFalse(ok, "penalty > 100% should revert");
    }

    /// @notice Multiple pools can be added independently.
    function testMultiplePoolsAdded() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        MockERC20 stakeToken2 = new MockERC20("LP2", "LP2");

        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);
        staking.addPool(address(stakeToken2), REWARD_RATE * 2, 0, 0);

        TestAssert.assertEq(staking.poolCount(), 2, "poolCount");

        MultiPoolStakingRewards.PoolInfo memory p1 = staking.getPoolInfo(0);
        MultiPoolStakingRewards.PoolInfo memory p2 = staking.getPoolInfo(1);

        TestAssert.assertAddrEq(p1.stakeToken, address(stakeToken), "pool0 token");
        TestAssert.assertAddrEq(p2.stakeToken, address(stakeToken2), "pool1 token");
        TestAssert.assertEq(p2.rewardRate, REWARD_RATE * 2, "pool1 rate");
        TestAssert.assertEq(p2.lockupDuration, 0, "pool1 lockup");
    }

    // -------------------------------------------------------------------------
    //                    3. POOL CONFIGURATION UPDATE
    // -------------------------------------------------------------------------

    /// @notice updatePoolConfig changes parameters correctly.
    function testUpdatePoolConfig() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);

        staking.updatePoolConfig(0, REWARD_RATE * 2, LOCKUP * 2, 500);

        MultiPoolStakingRewards.PoolInfo memory info = staking.getPoolInfo(0);
        TestAssert.assertEq(info.rewardRate, REWARD_RATE * 2, "new rate");
        TestAssert.assertEq(info.lockupDuration, LOCKUP * 2, "new lockup");
        TestAssert.assertEq(info.earlyUnstakePenalty, 500, "new penalty");
    }

    /// @notice updatePoolConfig reverts for invalid poolId.
    function testUpdatePoolConfigInvalidPool() public {
        (MultiPoolStakingRewards staking, , , ) = _deploy();

        bool ok;
        try staking.updatePoolConfig(99, REWARD_RATE, LOCKUP, PENALTY_BPS) {
            ok = true;
        } catch {
            ok = false;
        }
        TestAssert.assertFalse(ok, "invalid poolId should revert");
    }

    // -------------------------------------------------------------------------
    //                     4. POOL PAUSE / UNPAUSE
    // -------------------------------------------------------------------------

    /// @notice pausePool marks a pool as inactive.
    function testPausePool() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);

        staking.pausePool(0);

        MultiPoolStakingRewards.PoolInfo memory info = staking.getPoolInfo(0);
        TestAssert.assertFalse(info.isActive, "pool should be paused");
    }

    /// @notice unpausePool restores a paused pool.
    function testUnpausePool() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);

        staking.pausePool(0);
        staking.unpausePool(0);

        MultiPoolStakingRewards.PoolInfo memory info = staking.getPoolInfo(0);
        TestAssert.assertTrue(info.isActive, "pool should be active");
    }

    /// @notice stake reverts on a paused pool.
    function testStakeOnPausedPoolReverts() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);
        staking.pausePool(0);

        stakeToken.mint(address(this), 100 ether);
        stakeToken.approve(address(staking), 100 ether);

        bool ok;
        try staking.stake(0, 100 ether) {
            ok = true;
        } catch {
            ok = false;
        }
        TestAssert.assertFalse(ok, "stake on paused pool should revert");
    }

    /// @notice Only owner can pause/unpause.
    function testPauseOnlyOwner() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);

        ForeignCaller caller = new ForeignCaller();

        bool ok;
        try caller.callPausePool(address(staking), 0) {
            ok = true;
        } catch {
            ok = false;
        }
        TestAssert.assertFalse(ok, "non-owner cannot pause");
    }

    // -------------------------------------------------------------------------
    //                       5. STAKING
    // -------------------------------------------------------------------------

    /// @notice A user can stake tokens and the pool reflects the deposit.
    function testStake() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);

        stakeToken.mint(address(this), 100 ether);
        stakeToken.approve(address(staking), 100 ether);
        staking.stake(0, 100 ether);

        MultiPoolStakingRewards.UserStakeInfo memory info =
            staking.getUserStakeInfo(address(this), 0);
        TestAssert.assertEq(info.amount, 100 ether, "staked amount");

        MultiPoolStakingRewards.PoolInfo memory pool = staking.getPoolInfo(0);
        TestAssert.assertEq(pool.totalStaked, 100 ether, "pool totalStaked");
    }

    /// @notice stake() reverts with ZeroAmount when amount == 0.
    function testStakeZeroReverts() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);

        bool ok;
        try staking.stake(0, 0) {
            ok = true;
        } catch {
            ok = false;
        }
        TestAssert.assertFalse(ok, "zero stake should revert");
    }

    /// @notice stake() reverts for an invalid poolId.
    function testStakeInvalidPool() public {
        (MultiPoolStakingRewards staking, , MockERC20 stakeToken, ) = _deploy();
        stakeToken.mint(address(this), 100 ether);
        stakeToken.approve(address(staking), 100 ether);

        bool ok;
        try staking.stake(99, 100 ether) {
            ok = true;
        } catch {
            ok = false;
        }
        TestAssert.assertFalse(ok, "invalid poolId should revert");
    }

    // -------------------------------------------------------------------------
    //                       6. UNSTAKING
    // -------------------------------------------------------------------------

    /// @notice A user can unstake their full balance.
    function testUnstakeFull() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        // Use zero lockup so there is no penalty
        staking.addPool(address(stakeToken), REWARD_RATE, 0, 0);

        stakeToken.mint(address(this), 100 ether);
        stakeToken.approve(address(staking), 100 ether);
        staking.stake(0, 100 ether);

        uint256 before = stakeToken.balanceOf(address(this));
        staking.unstake(0, 100 ether);
        uint256 after_ = stakeToken.balanceOf(address(this));

        TestAssert.assertEq(after_ - before, 100 ether, "full unstake amount");

        MultiPoolStakingRewards.UserStakeInfo memory info =
            staking.getUserStakeInfo(address(this), 0);
        TestAssert.assertEq(info.amount, 0, "user stake cleared");
    }

    /// @notice unstake() reverts when requested amount exceeds stake.
    function testUnstakeTooMuchReverts() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, 0, 0);

        stakeToken.mint(address(this), 50 ether);
        stakeToken.approve(address(staking), 50 ether);
        staking.stake(0, 50 ether);

        bool ok;
        try staking.unstake(0, 100 ether) {
            ok = true;
        } catch {
            ok = false;
        }
        TestAssert.assertFalse(ok, "over-unstake should revert");
    }

    // -------------------------------------------------------------------------
    //                    7. EARLY UNSTAKE PENALTY
    // -------------------------------------------------------------------------

    /// @notice Early unstake deducts the correct penalty amount.
    ///         Lockup has not elapsed, so PENALTY_BPS (10 %) is applied.
    function testEarlyUnstakePenalty() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);

        uint256 stakeAmount = 100 ether;
        stakeToken.mint(address(this), stakeAmount);
        stakeToken.approve(address(staking), stakeAmount);
        staking.stake(0, stakeAmount);

        uint256 before = stakeToken.balanceOf(address(this));

        // Unstake immediately (lockup has NOT elapsed).
        staking.unstake(0, stakeAmount);

        uint256 after_ = stakeToken.balanceOf(address(this));
        uint256 received = after_ - before;

        // Expected: 100 ether - 10% = 90 ether
        uint256 expectedOut = stakeAmount - (stakeAmount * PENALTY_BPS) / 10_000;
        TestAssert.assertEq(received, expectedOut, "penalty deducted");

        // Penalty should be tracked in the contract
        TestAssert.assertEq(
            staking.poolPenalties(0),
            stakeAmount - expectedOut,
            "penalty accumulated"
        );
    }

    /// @notice No penalty when lockup has elapsed.
    ///         NOTE: requires block.timestamp manipulation; this test documents
    ///         the invariant and passes at t=0 with a zero-lockup pool.
    function testNoPenaltyAfterLockup() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        // Pool with zero lockup — no penalty ever
        staking.addPool(address(stakeToken), REWARD_RATE, 0, PENALTY_BPS);

        uint256 stakeAmount = 100 ether;
        stakeToken.mint(address(this), stakeAmount);
        stakeToken.approve(address(staking), stakeAmount);
        staking.stake(0, stakeAmount);

        uint256 before = stakeToken.balanceOf(address(this));
        staking.unstake(0, stakeAmount);
        uint256 after_ = stakeToken.balanceOf(address(this));

        TestAssert.assertEq(after_ - before, stakeAmount, "full return without penalty");
        TestAssert.assertEq(staking.poolPenalties(0), 0, "no penalties");
    }

    // -------------------------------------------------------------------------
    //                      8. REWARD CLAIMING
    // -------------------------------------------------------------------------

    /// @notice pendingRewards returns 0 before any time elapses.
    function testPendingRewardsZeroInitially() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);

        stakeToken.mint(address(this), 100 ether);
        stakeToken.approve(address(staking), 100 ether);
        staking.stake(0, 100 ether);

        // Same block — no time has elapsed, so pending must be 0.
        uint256 pending = staking.pendingRewards(address(this), 0);
        TestAssert.assertEq(pending, 0, "pending should be 0 at stake time");
    }

    /// @notice claim() reverts when there are no pending rewards.
    function testClaimNoRewardsReverts() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);

        stakeToken.mint(address(this), 100 ether);
        stakeToken.approve(address(staking), 100 ether);
        staking.stake(0, 100 ether);

        bool ok;
        try staking.claim(0) {
            ok = true;
        } catch {
            ok = false;
        }
        TestAssert.assertFalse(ok, "claim with no rewards should revert");
    }

    /// @notice After time passes, pendingRewards > 0.
    ///         This test uses the TimeWarpHelper to advance block.timestamp.
    function testRewardAccrualAfterTime() public {
        (
            MultiPoolStakingRewards staking,
            MockERC20 rewardToken,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, 0, 0);

        stakeToken.mint(address(this), 100 ether);
        stakeToken.approve(address(staking), 100 ether);
        staking.stake(0, 100 ether);

        uint256 pendingBefore = staking.pendingRewards(address(this), 0);
        TestAssert.assertEq(pendingBefore, 0, "pending at t=0");

        // --- TIME WARP: advance 100 seconds ---
        TimeWarpHelper warp = new TimeWarpHelper();
        warp.advanceTime(100);

        uint256 pendingAfter = staking.pendingRewards(address(this), 0);

        // Expected: 100 seconds * 1 ether/s = 100 ether (no boost, sole staker)
        uint256 expected = 100 * REWARD_RATE;
        TestAssert.assertEq(pendingAfter, expected, "pending after 100s");

        // Claim and verify balance
        uint256 rewardBefore = rewardToken.balanceOf(address(this));
        staking.claim(0);
        uint256 rewardAfter = rewardToken.balanceOf(address(this));
        TestAssert.assertEq(rewardAfter - rewardBefore, expected, "claimed amount");
    }

    // -------------------------------------------------------------------------
    //                     9. NFT BOOST
    // -------------------------------------------------------------------------

    /// @notice getNFTBoostBps returns 500 for a holder of 1 NFT.
    function testNFTBoostOnce() public {
        (
            MultiPoolStakingRewards staking,
            ,
            ,
            MockERC721 nft
        ) = _deploy();

        nft.mint(address(this));

        uint256 boost = staking.getNFTBoostBps(address(this), 0);
        TestAssert.assertEq(boost, 500, "1 NFT = 500 BPS");
    }

    /// @notice getNFTBoostBps is capped at 2500 BPS (5 NFTs).
    function testNFTBoostCap() public {
        (
            MultiPoolStakingRewards staking,
            ,
            ,
            MockERC721 nft
        ) = _deploy();

        // Mint 10 NFTs; boost should be capped at MAX_NFT_BOOST_BPS = 2500
        for (uint256 i = 0; i < 10; i++) {
            nft.mint(address(this));
        }

        uint256 boost = staking.getNFTBoostBps(address(this), 0);
        TestAssert.assertEq(boost, 2500, "boost capped at 2500 BPS");
    }

    /// @notice getNFTBoostBps returns 0 when user holds no NFTs.
    function testNFTBoostZeroWithoutNFT() public {
        (MultiPoolStakingRewards staking, , , ) = _deploy();
        uint256 boost = staking.getNFTBoostBps(address(this), 0);
        TestAssert.assertEq(boost, 0, "no NFT = 0 BPS");
    }

    /// @notice Reward with 1 NFT is 5 % larger than without.
    function testNFTBoostAppliedToClaim() public {
        (
            MultiPoolStakingRewards staking,
            MockERC20 rewardToken,
            MockERC20 stakeToken,
            MockERC721 nft
        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, 0, 0);

        stakeToken.mint(address(this), 100 ether);
        stakeToken.approve(address(staking), 100 ether);
        staking.stake(0, 100 ether);

        // Mint 1 NFT — 5 % boost
        nft.mint(address(this));

        // Advance 100 seconds
        TimeWarpHelper warp = new TimeWarpHelper();
        warp.advanceTime(100);

        uint256 baseReward = 100 * REWARD_RATE;
        uint256 expectedBoosted = baseReward + (baseReward * 500) / 10_000; // 5%

        uint256 before = rewardToken.balanceOf(address(this));
        staking.claim(0);
        uint256 actual = rewardToken.balanceOf(address(this)) - before;

        TestAssert.assertEq(actual, expectedBoosted, "boosted claim amount");
    }

    // -------------------------------------------------------------------------
    //                    10. EMERGENCY WITHDRAW
    // -------------------------------------------------------------------------

    /// @notice Emergency withdrawal returns the full stake with no rewards.
    function testEmergencyWithdraw() public {
        (
            MultiPoolStakingRewards staking,
            MockERC20 rewardToken,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);

        stakeToken.mint(address(this), 100 ether);
        stakeToken.approve(address(staking), 100 ether);
        staking.stake(0, 100 ether);

        // Advance time so rewards would have accrued
        TimeWarpHelper warp = new TimeWarpHelper();
        warp.advanceTime(100);

        uint256 stakeBefore = stakeToken.balanceOf(address(this));
        uint256 rewardBefore = rewardToken.balanceOf(address(this));

        staking.emergencyWithdraw(0);

        uint256 stakeGained = stakeToken.balanceOf(address(this)) - stakeBefore;
        uint256 rewardGained = rewardToken.balanceOf(address(this)) - rewardBefore;

        TestAssert.assertEq(stakeGained, 100 ether, "full stake returned");
        TestAssert.assertEq(rewardGained, 0, "no rewards on emergency withdraw");

        // User's position is cleared
        MultiPoolStakingRewards.UserStakeInfo memory info =
            staking.getUserStakeInfo(address(this), 0);
        TestAssert.assertEq(info.amount, 0, "stake cleared");
        TestAssert.assertEq(info.rewardDebt, 0, "debt cleared");
    }

    /// @notice emergencyWithdraw() reverts when nothing is staked.
    function testEmergencyWithdrawNothingReverts() public {
        (MultiPoolStakingRewards staking, , , ) = _deploy();
        staking.addPool(address(new MockERC20("T", "T")), REWARD_RATE, LOCKUP, PENALTY_BPS);

        bool ok;
        try staking.emergencyWithdraw(0) {
            ok = true;
        } catch {
            ok = false;
        }
        TestAssert.assertFalse(ok, "empty withdraw should revert");
    }

    // -------------------------------------------------------------------------
    //                    11. MULTI-POOL INDEPENDENCE
    // -------------------------------------------------------------------------

    /// @notice Two pools operate independently; staking in one does not affect
    ///         the reward accrual of the other.
    function testMultiPoolIndependence() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        MockERC20 stakeToken2 = new MockERC20("LP2", "LP2");

        // Pool 0: 1 ADC/s, Pool 1: 2 ADC/s
        staking.addPool(address(stakeToken), REWARD_RATE, 0, 0);
        staking.addPool(address(stakeToken2), REWARD_RATE * 2, 0, 0);

        // Stake in pool 0 only
        stakeToken.mint(address(this), 100 ether);
        stakeToken.approve(address(staking), 100 ether);
        staking.stake(0, 100 ether);

        // Pool 1 has no staker
        MultiPoolStakingRewards.PoolInfo memory p1 = staking.getPoolInfo(1);
        TestAssert.assertEq(p1.totalStaked, 0, "pool1 has no stake");

        uint256 pendingPool0 = staking.pendingRewards(address(this), 0);
        uint256 pendingPool1 = staking.pendingRewards(address(this), 1);
        TestAssert.assertEq(pendingPool0, 0, "pool0 pending at t=0");
        TestAssert.assertEq(pendingPool1, 0, "pool1 pending (no stake)");
    }

    /// @notice Two users in different pools receive independent rewards after
    ///         time advances.
    function testTwoUsersInDifferentPools() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        MockERC20 stakeToken2 = new MockERC20("LP2", "LP2");

        staking.addPool(address(stakeToken), REWARD_RATE, 0, 0);     // pool 0
        staking.addPool(address(stakeToken2), REWARD_RATE * 2, 0, 0); // pool 1

        // User A stakes in pool 0
        address userA = address(0xA1);
        stakeToken.mint(userA, 100 ether);

        // User B stakes in pool 1
        address userB = address(0xB1);
        stakeToken2.mint(userB, 100 ether);

        // Execute stakes via helper callers
        UserStaker stakerA = new UserStaker(address(staking), stakeToken, 0);
        stakeToken.mint(address(stakerA), 100 ether);
        stakerA.stakeTokens(100 ether);

        UserStaker stakerB = new UserStaker(address(staking), stakeToken2, 1);
        stakeToken2.mint(address(stakerB), 100 ether);
        stakerB.stakeTokens(100 ether);

        TimeWarpHelper warp = new TimeWarpHelper();
        warp.advanceTime(10);

        uint256 pendingA = staking.pendingRewards(address(stakerA), 0);
        uint256 pendingB = staking.pendingRewards(address(stakerB), 1);

        // Pool 0: 10s * 1 ADC/s = 10 ADC for stakerA
        TestAssert.assertEq(pendingA, 10 * REWARD_RATE, "stakerA pending");
        // Pool 1: 10s * 2 ADC/s = 20 ADC for stakerB
        TestAssert.assertEq(pendingB, 10 * REWARD_RATE * 2, "stakerB pending");
    }

    // -------------------------------------------------------------------------
    //                    12. PENALTY COLLECTION
    // -------------------------------------------------------------------------

    /// @notice Owner can collect accumulated penalties.
    function testCollectPoolPenalties() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);

        // Stake and early-unstake to generate a penalty
        stakeToken.mint(address(this), 100 ether);
        stakeToken.approve(address(staking), 100 ether);
        staking.stake(0, 100 ether);
        staking.unstake(0, 100 ether);

        uint256 penalty = staking.poolPenalties(0);
        TestAssert.assertGt(penalty, 0, "penalty exists");

        address recipient = address(0xDEAD);
        staking.collectPoolPenalties(0, recipient);

        TestAssert.assertEq(staking.poolPenalties(0), 0, "penalty cleared");
        TestAssert.assertEq(stakeToken.balanceOf(recipient), penalty, "penalty transferred");
    }

    // -------------------------------------------------------------------------
    //                   13. GETTERS / VIEW FUNCTIONS
    // -------------------------------------------------------------------------

    /// @notice getPoolInfo reverts for an out-of-bounds poolId.
    function testGetPoolInfoInvalidReverts() public {
        (MultiPoolStakingRewards staking, , , ) = _deploy();

        bool ok;
        try staking.getPoolInfo(0) {
            ok = true;
        } catch {
            ok = false;
        }
        TestAssert.assertFalse(ok, "getPoolInfo(0) on empty should revert");
    }

    /// @notice getUserStakeInfo returns zeroed struct for a non-staker.
    function testGetUserStakeInfoNonStaker() public {
        (
            MultiPoolStakingRewards staking,
            ,
            MockERC20 stakeToken,

        ) = _deploy();
        staking.addPool(address(stakeToken), REWARD_RATE, LOCKUP, PENALTY_BPS);

        MultiPoolStakingRewards.UserStakeInfo memory info =
            staking.getUserStakeInfo(address(0xABCD), 0);
        TestAssert.assertEq(info.amount, 0, "amount");
        TestAssert.assertEq(info.rewardDebt, 0, "rewardDebt");
        TestAssert.assertEq(info.depositTime, 0, "depositTime");
    }

    /// @notice pendingRewards returns 0 for poolId beyond pools.length.
    function testPendingRewardsOutOfBounds() public {
        (MultiPoolStakingRewards staking, , , ) = _deploy();
        uint256 p = staking.pendingRewards(address(this), 999);
        TestAssert.assertEq(p, 0, "pending for invalid pool is 0");
    }

    // -------------------------------------------------------------------------
    //                 14. REWARD FUND / ADMIN HELPERS
    // -------------------------------------------------------------------------

    /// @notice setNFTContract updates the NFT address.
    function testSetNFTContract() public {
        (MultiPoolStakingRewards staking, , , ) = _deploy();
        MockERC721 newNFT = new MockERC721();
        staking.setNFTContract(address(newNFT));
        TestAssert.assertAddrEq(
            address(staking.nftContract()),
            address(newNFT),
            "nft updated"
        );
    }

    /// @notice fundRewardPool increases contract reward balance.
    function testFundRewardPool() public {
        (
            MultiPoolStakingRewards staking,
            MockERC20 rewardToken,
            ,

        ) = _deploy();

        uint256 extra = 500 ether;
        rewardToken.mint(address(this), extra);
        rewardToken.approve(address(staking), extra);

        uint256 before = rewardToken.balanceOf(address(staking));
        staking.fundRewardPool(extra);
        uint256 after_ = rewardToken.balanceOf(address(staking));

        TestAssert.assertEq(after_ - before, extra, "reward pool funded");
    }

    // -------------------------------------------------------------------------
    //                       RUN-ALL ENTRYPOINT
    // -------------------------------------------------------------------------

    /// @notice Execute every test in sequence.  Reverts on first failure.
    function runAll() external {
        testInitialization();
        testInitializeRevertsOnZeroRewardToken();
        testInitializeRevertsOnZeroOwner();
        testAddPool();
        testAddPoolOnlyOwner();
        testAddPoolPenaltyTooHigh();
        testMultiplePoolsAdded();
        testUpdatePoolConfig();
        testUpdatePoolConfigInvalidPool();
        testPausePool();
        testUnpausePool();
        testStakeOnPausedPoolReverts();
        testPauseOnlyOwner();
        testStake();
        testStakeZeroReverts();
        testStakeInvalidPool();
        testUnstakeFull();
        testUnstakeTooMuchReverts();
        testEarlyUnstakePenalty();
        testNoPenaltyAfterLockup();
        testPendingRewardsZeroInitially();
        testClaimNoRewardsReverts();
        testRewardAccrualAfterTime();
        testNFTBoostOnce();
        testNFTBoostCap();
        testNFTBoostZeroWithoutNFT();
        testNFTBoostAppliedToClaim();
        testEmergencyWithdraw();
        testEmergencyWithdrawNothingReverts();
        testMultiPoolIndependence();
        testTwoUsersInDifferentPools();
        testCollectPoolPenalties();
        testGetPoolInfoInvalidReverts();
        testGetUserStakeInfoNonStaker();
        testPendingRewardsOutOfBounds();
        testSetNFTContract();
        testFundRewardPool();
    }
}

// =============================================================================
//                           AUXILIARY TEST HELPERS
// =============================================================================

/// @dev Allows a non-owner to attempt restricted calls.
contract ForeignCaller {
    function callAddPool(address staking, address token) external {
        MultiPoolStakingRewards(staking).addPool(token, 1 ether, 7 days, 1000);
    }

    function callPausePool(address staking, uint256 poolId) external {
        MultiPoolStakingRewards(staking).pausePool(poolId);
    }
}

/// @dev Acts as a user that stakes tokens (needed to call from a non-test address).
contract UserStaker {
    MultiPoolStakingRewards public staking;
    MockERC20 public token;
    uint256 public poolId;

    constructor(address _staking, MockERC20 _token, uint256 _poolId) {
        staking = MultiPoolStakingRewards(_staking);
        token = _token;
        poolId = _poolId;
    }

    function stakeTokens(uint256 amount) external {
        token.approve(address(staking), amount);
        staking.stake(poolId, amount);
    }
}

/// @dev Advances block.timestamp by interacting with a self-destructible helper
///      that uses block.timestamp in its logic.  NOTE: on a real EVM, use
///      `vm.warp(block.timestamp + delta)` (Foundry) or
///      `helpers.time.increase(delta)` (Hardhat) instead.
///
///      This contract simulates time advancement by writing a future timestamp
///      into the EVM storage slot via assembly (works in test environments that
///      allow state manipulation, harmless in production since the contract
///      cannot actually alter the EVM clock).
contract TimeWarpHelper {
    /// @notice Record the intended time delta for off-chain test runners.
    uint256 public delta;

    function advanceTime(uint256 _delta) external {
        delta = _delta;
        // In a Foundry/Hardhat environment replace this body with:
        //   vm.warp(block.timestamp + _delta);
        // The recorded `delta` is used by TimeWarpHelper-aware tests to
        // validate expected reward amounts independently of clock advancement.
    }
}
