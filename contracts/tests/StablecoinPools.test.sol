// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================================
// StablecoinPools.test.sol
// Comprehensive test suite for StablecoinPools.sol
// Compatible with Foundry (forge test) or Hardhat (via forge-std shim)
// ============================================================================

import "forge-std/Test.sol";
import "../StablecoinPools.sol";

/// @dev Minimal ERC20 mock for testing
contract MockERC20 {
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory _symbol, uint8 _decimals) {
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Minimal LayerZero endpoint mock
contract MockLZEndpoint {
    event MessageSent(uint16 dstChainId, bytes destination, bytes payload);

    function send(
        uint16 _dstChainId,
        bytes calldata _destination,
        bytes calldata _payload,
        address payable, /* _refundAddress */
        address, /* _zroPaymentAddress */
        bytes calldata /* _adapterParams */
    ) external payable {
        emit MessageSent(_dstChainId, _destination, _payload);
    }
}

contract StablecoinPoolsTest is Test {
    StablecoinPools internal pools;
    MockLZEndpoint internal lzEndpoint;

    MockERC20 internal usdc;
    MockERC20 internal usdt;
    MockERC20 internal dai;
    MockERC20 internal eurs;
    MockERC20 internal gbpx;
    MockERC20 internal busd;
    MockERC20 internal tusd;
    MockERC20 internal adc;

    address internal owner    = address(0xAA01);
    address internal timelock = address(0xAA02);
    address internal alice    = address(0xAA03);
    address internal bob      = address(0xAA04);

    bytes32 internal usdcUsdtPoolId;
    bytes32 internal adcUsdcPoolId;

    function setUp() public {
        // Deploy mocks
        usdc = new MockERC20("USDC", 6);
        usdt = new MockERC20("USDT", 6);
        dai  = new MockERC20("DAI",  18);
        eurs = new MockERC20("EURS", 2);
        gbpx = new MockERC20("GBPX", 18);
        busd = new MockERC20("BUSD", 18);
        tusd = new MockERC20("TUSD", 18);
        adc  = new MockERC20("ADC",  18);

        lzEndpoint = new MockLZEndpoint();

        // Deploy implementation and initialise (no proxy for tests)
        StablecoinPools impl = new StablecoinPools();
        // Call initialize directly (upgradeable pattern, but no proxy in unit tests)
        vm.prank(owner);
        impl.initialize(address(adc), address(lzEndpoint), timelock, owner);
        pools = impl;

        // Register stablecoins
        vm.startPrank(owner);
        pools.registerStablecoin(address(usdc), "USDC", 6, 1);
        pools.registerStablecoin(address(usdt), "USDT", 6, 1);
        pools.registerStablecoin(address(dai),  "DAI",  18, 1);
        pools.registerStablecoin(address(eurs), "EURS", 2,  1);
        pools.registerStablecoin(address(gbpx), "GBPX", 18, 1);
        pools.registerStablecoin(address(busd), "BUSD", 18, 1);
        pools.registerStablecoin(address(tusd), "TUSD", 18, 1);
        vm.stopPrank();

        // Pre-mint tokens to alice and bob
        uint256 large = 1_000_000e18;
        usdc.mint(alice, large);
        usdt.mint(alice, large);
        dai.mint(alice,  large);
        adc.mint(alice,  large);

        usdc.mint(bob, large);
        usdt.mint(bob, large);
    }

    // =========================================================================
    // 1. Stablecoin Registration
    // =========================================================================

    function test_RegisterStablecoin_Success() public view {
        assertTrue(pools.isStablecoin(address(usdc)));
        assertTrue(pools.isStablecoin(address(usdt)));
        assertTrue(pools.isStablecoin(address(dai)));
        assertTrue(pools.isStablecoin(address(eurs)));
        assertTrue(pools.isStablecoin(address(gbpx)));
        assertTrue(pools.isStablecoin(address(busd)));
        assertTrue(pools.isStablecoin(address(tusd)));
    }

    function test_RegisterStablecoin_NotOwner_Reverts() public {
        MockERC20 newToken = new MockERC20("NEW", 18);
        vm.prank(alice);
        vm.expectRevert();
        pools.registerStablecoin(address(newToken), "NEW", 18, 1);
    }

    function test_RegisterStablecoin_Duplicate_Reverts() public {
        vm.prank(owner);
        vm.expectRevert("Already registered");
        pools.registerStablecoin(address(usdc), "USDC", 6, 1);
    }

    function test_DeregisterStablecoin() public {
        vm.prank(owner);
        pools.deregisterStablecoin(address(tusd));
        assertFalse(pools.isStablecoin(address(tusd)));
    }

    function test_GetAllStablecoins_ReturnsAll() public view {
        address[] memory list = pools.getAllStablecoins();
        assertEq(list.length, 7);
    }

    // =========================================================================
    // 2. Pool Creation
    // =========================================================================

    function test_CreatePool_StableToStable_OptimalFee() public {
        vm.prank(alice);
        bytes32 poolId = pools.createPool(
            address(usdc), address(usdt),
            5, // request 0.05% – should be overridden to 0.01% for stable-stable
            0.99e18, 1.01e18
        );

        IStablecoinPools.PoolInfo memory info = pools.getPool(poolId);
        assertTrue(info.active);
        assertTrue(info.isStableToStable);
        assertEq(info.feeBps, StablecoinPools(address(pools)).STABLE_TO_STABLE_FEE_BPS());
        usdcUsdtPoolId = poolId;
    }

    function test_CreatePool_ADCPair_OptimalFee() public {
        vm.prank(alice);
        bytes32 poolId = pools.createPool(
            address(adc), address(usdc),
            10, // override → ADC_PAIR_FEE_BPS
            0.9e18, 1.1e18
        );

        IStablecoinPools.PoolInfo memory info = pools.getPool(poolId);
        assertEq(info.feeBps, StablecoinPools(address(pools)).ADC_PAIR_FEE_BPS());
        adcUsdcPoolId = poolId;
    }

    function test_CreatePool_Duplicate_Reverts() public {
        vm.prank(alice);
        pools.createPool(address(usdc), address(usdt), 1, 0.99e18, 1.01e18);

        vm.prank(alice);
        vm.expectRevert("Pool already exists");
        pools.createPool(address(usdc), address(usdt), 1, 0.99e18, 1.01e18);
    }

    function test_CreatePool_IdenticalTokens_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("Identical tokens");
        pools.createPool(address(usdc), address(usdc), 1, 0.99e18, 1.01e18);
    }

    // =========================================================================
    // 3. Fee Tier Validation
    // =========================================================================

    function test_FeeBps_BelowMin_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("Fee out of range");
        pools.createPool(address(dai), address(eurs), 0, 0.99e18, 1.01e18);
    }

    function test_FeeBps_AboveMax_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("Fee out of range");
        pools.createPool(address(dai), address(eurs), 100, 0.99e18, 1.01e18);
    }

    // =========================================================================
    // 4. Liquidity
    // =========================================================================

    function _setupPoolWithLiquidity() internal returns (bytes32 poolId) {
        vm.prank(alice);
        poolId = pools.createPool(address(usdc), address(usdt), 1, 0.99e18, 1.01e18);

        vm.startPrank(alice);
        usdc.approve(address(pools), type(uint256).max);
        usdt.approve(address(pools), type(uint256).max);
        pools.addLiquidity(poolId, 100_000e18, 100_000e18, 0);
        vm.stopPrank();
    }

    function test_AddLiquidity_FirstDeposit() public {
        bytes32 poolId = _setupPoolWithLiquidity();
        uint256 lpBal = pools.lpBalanceOf(poolId, alice);
        assertGt(lpBal, 0, "LP tokens should be > 0 after first deposit");
    }

    function test_AddLiquidity_SubsequentDeposit() public {
        bytes32 poolId = _setupPoolWithLiquidity();

        vm.startPrank(bob);
        usdc.approve(address(pools), type(uint256).max);
        usdt.approve(address(pools), type(uint256).max);
        uint256 lp = pools.addLiquidity(poolId, 10_000e18, 10_000e18, 0);
        vm.stopPrank();

        assertGt(lp, 0);
        assertEq(pools.lpBalanceOf(poolId, bob), lp);
    }

    function test_RemoveLiquidity_ReturnsFunds() public {
        bytes32 poolId = _setupPoolWithLiquidity();
        uint256 lpBal = pools.lpBalanceOf(poolId, alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        (uint256 a0, uint256 a1) = pools.removeLiquidity(poolId, lpBal, 0, 0);

        assertGt(a0, 0);
        assertGt(a1, 0);
        assertGt(usdc.balanceOf(alice), usdcBefore);
    }

    function test_RemoveLiquidity_InsufficientBalance_Reverts() public {
        bytes32 poolId = _setupPoolWithLiquidity();

        vm.prank(bob);
        vm.expectRevert("Insufficient LP balance");
        pools.removeLiquidity(poolId, 1, 0, 0);
    }

    // =========================================================================
    // 5. Concentrated Liquidity Deployment
    // =========================================================================

    function test_ConcentratedLiquidityZone_SetOnCreate() public {
        vm.prank(alice);
        bytes32 poolId = pools.createPool(address(usdc), address(dai), 1, 0.995e18, 1.005e18);

        IStablecoinPools.PoolInfo memory info = pools.getPool(poolId);
        assertEq(info.concentratedLiquidityMin, 0.995e18);
        assertEq(info.concentratedLiquidityMax, 1.005e18);
    }

    function test_UpdateConcentratedLiquidityZone_OnlyTimelock() public {
        vm.prank(alice);
        bytes32 poolId = pools.createPool(address(usdc), address(dai), 1, 0.995e18, 1.005e18);

        vm.prank(timelock);
        pools.updateConcentratedLiquidityZone(poolId, 0.99e18, 1.01e18);

        IStablecoinPools.PoolInfo memory info = pools.getPool(poolId);
        assertEq(info.concentratedLiquidityMin, 0.99e18);
        assertEq(info.concentratedLiquidityMax, 1.01e18);
    }

    function test_UpdateConcentratedLiquidityZone_NotTimelock_Reverts() public {
        vm.prank(alice);
        bytes32 poolId = pools.createPool(address(usdc), address(dai), 1, 0.995e18, 1.005e18);

        vm.prank(alice);
        vm.expectRevert("Only timelock");
        pools.updateConcentratedLiquidityZone(poolId, 0.99e18, 1.01e18);
    }

    // =========================================================================
    // 6. Swapping & Slippage
    // =========================================================================

    function test_Swap_StablePair_LowSlippage() public {
        bytes32 poolId = _setupPoolWithLiquidity();

        // A $1,000 swap in a $200,000 pool – slippage should be <0.1%
        vm.startPrank(bob);
        usdc.approve(address(pools), type(uint256).max);
        (uint256 out, , uint256 impactBps) = pools.getSwapQuote(poolId, address(usdc), 1_000e18);
        vm.stopPrank();

        assertGt(out, 0);
        assertLt(impactBps, 10, "Price impact should be <0.1%");
    }

    function test_Swap_ExecutesAndUpdatesReserves() public {
        bytes32 poolId = _setupPoolWithLiquidity();

        uint256 balBefore = usdt.balanceOf(bob);

        vm.startPrank(bob);
        usdc.approve(address(pools), type(uint256).max);
        uint256 amountOut = pools.swap(poolId, address(usdc), 1_000e18, 0, bob);
        vm.stopPrank();

        assertGt(amountOut, 0);
        assertEq(usdt.balanceOf(bob), balBefore + amountOut);
    }

    function test_Swap_SlippageTooHigh_Reverts() public {
        bytes32 poolId = _setupPoolWithLiquidity();

        vm.startPrank(bob);
        usdc.approve(address(pools), type(uint256).max);
        vm.expectRevert("Slippage: amountOut too low");
        pools.swap(poolId, address(usdc), 1_000e18, type(uint256).max, bob);
        vm.stopPrank();
    }

    // =========================================================================
    // 7. Dynamic Fee Adjustment
    // =========================================================================

    function test_AdjustFee_StablePool_KeepsMinFee() public {
        bytes32 poolId = _setupPoolWithLiquidity();

        // Balanced pool → fee should stay at STABLE_TO_STABLE_FEE_BPS
        pools.adjustFee(poolId);
        IStablecoinPools.PoolInfo memory info = pools.getPool(poolId);
        assertEq(info.feeBps, StablecoinPools(address(pools)).STABLE_TO_STABLE_FEE_BPS());
    }

    // =========================================================================
    // 8. Reserve Auditing
    // =========================================================================

    function test_AuditReserves_EmitsEvent() public {
        bytes32 poolId = _setupPoolWithLiquidity();

        vm.expectEmit(true, false, false, false, address(pools));
        emit IStablecoinPools.ReserveAudited(poolId, alice, 0, 0, 0);
        vm.prank(alice);
        pools.auditReserves(poolId);
    }

    // =========================================================================
    // 9. Cross-Chain Pool Sync
    // =========================================================================

    function test_SyncPoolToChain_EmitsEvent() public {
        bytes32 poolId = _setupPoolWithLiquidity();

        // Set trusted remote
        vm.prank(owner);
        pools.setTrustedRemote(137, abi.encodePacked(address(pools)));

        vm.expectEmit(true, false, false, false, address(pools));
        emit IStablecoinPools.CrossChainSyncSent(poolId, 137, 0, 0);
        vm.prank(alice);
        pools.syncPoolToChain{value: 0}(poolId, 137, "");
    }

    function test_SyncPool_UntrustedDestination_Reverts() public {
        bytes32 poolId = _setupPoolWithLiquidity();

        vm.prank(alice);
        vm.expectRevert("Untrusted destination");
        pools.syncPoolToChain{value: 0}(poolId, 999, "");
    }

    // =========================================================================
    // 10. Pause / Unpause
    // =========================================================================

    function test_Pause_BlocksSwap() public {
        bytes32 poolId = _setupPoolWithLiquidity();

        vm.prank(owner);
        pools.pause();

        vm.startPrank(bob);
        usdc.approve(address(pools), type(uint256).max);
        vm.expectRevert();
        pools.swap(poolId, address(usdc), 100e18, 0, bob);
        vm.stopPrank();
    }

    function test_Unpause_AllowsSwap() public {
        bytes32 poolId = _setupPoolWithLiquidity();

        vm.prank(owner);
        pools.pause();

        vm.prank(owner);
        pools.unpause();

        vm.startPrank(bob);
        usdc.approve(address(pools), type(uint256).max);
        uint256 out = pools.swap(poolId, address(usdc), 100e18, 0, bob);
        vm.stopPrank();

        assertGt(out, 0);
    }

    // =========================================================================
    // 11. GetPoolId determinism
    // =========================================================================

    function test_GetPoolId_IsDeterministic() public view {
        bytes32 id1 = pools.getPoolId(address(usdc), address(usdt));
        bytes32 id2 = pools.getPoolId(address(usdt), address(usdc));
        assertEq(id1, id2, "Pool ID should be order-independent");
    }
}
