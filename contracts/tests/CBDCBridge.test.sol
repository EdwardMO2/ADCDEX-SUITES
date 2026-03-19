// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// ============================================================================
// CBDCBridge.test.sol
// Comprehensive test suite for CBDCBridge.sol
// Compatible with Foundry (forge test)
// ============================================================================

import "forge-std/Test.sol";
import "../CBDCBridge.sol";

/// @dev Minimal ERC20 mock with configurable total supply
contract MockERC20 {
    string public symbol;
    uint8  public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory _symbol, uint8 _dec) {
        symbol   = _symbol;
        decimals = _dec;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        return true;
    }
}

contract CBDCBridgeTest is Test {
    CBDCBridge internal bridge;

    MockERC20 internal digitalUSD;
    MockERC20 internal digitalEUR;

    address internal admin       = address(0xDD01);
    address internal timelock    = address(0xDD02);
    address internal centralBank = address(0xDD03); // CENTRAL_BANK_ROLE
    address internal mintAuth    = address(0xDD04);
    address internal burnAuth    = address(0xDD05);
    address internal policyAdmin = address(0xDD06);
    address internal auditor     = address(0xDD07);
    address internal alice       = address(0xDD08);
    address internal bob         = address(0xDD09);

    function setUp() public {
        CBDCBridge impl = new CBDCBridge();
        vm.prank(admin);
        impl.initialize(timelock, admin);
        bridge = impl;

        // Grant roles
        vm.startPrank(admin);
        bridge.grantRole(bridge.CENTRAL_BANK_ROLE(), centralBank);
        bridge.grantRole(bridge.MINT_ROLE(),         mintAuth);
        bridge.grantRole(bridge.BURN_ROLE(),         burnAuth);
        bridge.grantRole(bridge.POLICY_ROLE(),       policyAdmin);
        bridge.grantRole(bridge.AUDITOR_ROLE(),      auditor);
        vm.stopPrank();

        // Deploy mock CBDC tokens
        digitalUSD = new MockERC20("dUSD", 18);
        digitalEUR = new MockERC20("dEUR", 18);

        // Register CBDCs
        vm.startPrank(admin);
        bridge.registerCBDC(
            address(digitalUSD),
            mintAuth,
            burnAuth,
            10_000_000e18, // 10M supply limit
            1e18,          // min 1 dUSD
            1_000_000e18,  // max 1M dUSD per tx
            500_000e18     // 500k daily velocity
        );
        bridge.registerCBDC(
            address(digitalEUR),
            mintAuth,
            burnAuth,
            0,             // unlimited
            1e18,
            1_000_000e18,
            0              // no daily limit
        );
        vm.stopPrank();

        // Activate transfers via policy
        vm.startPrank(policyAdmin);
        bridge.updatePolicy(address(digitalUSD), 1e18, 200, true, true);
        bridge.updatePolicy(address(digitalEUR), 1.08e18, 175, true, true);
        vm.stopPrank();

        // Mint tokens to mint authority so it can transfer them to recipients
        digitalUSD.mint(mintAuth, 5_000_000e18);
        digitalEUR.mint(mintAuth, 5_000_000e18);
        digitalUSD.mint(alice,    1_000_000e18);
        digitalUSD.mint(bob,      1_000_000e18);
    }

    // =========================================================================
    // 1. CBDC Registration
    // =========================================================================

    function test_RegisterCBDC_Success() public view {
        ICBDCBridge.CBDCConfig memory cfg = bridge.getCBDCConfig(address(digitalUSD));
        assertTrue(cfg.active);
        assertEq(cfg.mintAuthority, mintAuth);
        assertEq(cfg.supplyLimit, 10_000_000e18);
        assertEq(cfg.dailyVelocityLimit, 500_000e18);
    }

    function test_RegisterCBDC_Duplicate_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("CBDC already registered");
        bridge.registerCBDC(address(digitalUSD), mintAuth, burnAuth, 0, 1e18, 1_000_000e18, 0);
    }

    function test_RegisterCBDC_NotAdmin_Reverts() public {
        MockERC20 newToken = new MockERC20("NEW", 18);
        vm.prank(alice);
        vm.expectRevert();
        bridge.registerCBDC(address(newToken), mintAuth, burnAuth, 0, 1e18, 0, 0);
    }

    function test_DeregisterCBDC_Success() public {
        vm.prank(admin);
        bridge.deregisterCBDC(address(digitalEUR));
        assertFalse(bridge.getCBDCConfig(address(digitalEUR)).active);
    }

    // =========================================================================
    // 2. Central Bank Policy
    // =========================================================================

    function test_UpdatePolicy_Success() public view {
        ICBDCBridge.CentralBankPolicy memory policy = bridge.getPolicy(address(digitalUSD));
        assertTrue(policy.transfersEnabled);
        assertEq(policy.exchangeRate, 1e18);
        assertEq(policy.interestRateBps, 200);
    }

    function test_UpdatePolicy_NotPolicyRole_Reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        bridge.updatePolicy(address(digitalUSD), 1e18, 300, true, true);
    }

    function test_Policy_TransfersDisabled_BlocksMint() public {
        vm.prank(policyAdmin);
        bridge.updatePolicy(address(digitalUSD), 1e18, 200, false, true); // disable transfers

        vm.startPrank(mintAuth);
        digitalUSD.approve(address(bridge), type(uint256).max);
        vm.expectRevert("Transfers disabled by policy");
        bridge.mintToDEX(address(digitalUSD), alice, 1_000e18);
        vm.stopPrank();
    }

    // =========================================================================
    // 3. Mint / Burn Interactions
    // =========================================================================

    function test_MintToDEX_Success() public {
        uint256 aliceBefore = digitalUSD.balanceOf(alice);

        vm.startPrank(mintAuth);
        digitalUSD.approve(address(bridge), type(uint256).max);
        bridge.mintToDEX(address(digitalUSD), alice, 10_000e18);
        vm.stopPrank();

        assertEq(digitalUSD.balanceOf(alice), aliceBefore + 10_000e18);
    }

    function test_MintToDEX_NotMintAuthority_Reverts() public {
        vm.startPrank(alice);
        digitalUSD.approve(address(bridge), type(uint256).max);
        vm.expectRevert("Not mint authority");
        bridge.mintToDEX(address(digitalUSD), alice, 1_000e18);
        vm.stopPrank();
    }

    function test_MintToDEX_ExceedsVelocity_Reverts() public {
        // 500k daily limit – try to mint 600k in one call
        vm.startPrank(mintAuth);
        digitalUSD.approve(address(bridge), type(uint256).max);
        vm.expectRevert("Daily velocity limit exceeded");
        bridge.mintToDEX(address(digitalUSD), alice, 600_000e18);
        vm.stopPrank();
    }

    function test_MintToDEX_SupplyLimit_Reverts() public {
        // dUSD supply limit is 10M, already 5M minted to mintAuth + 2M to alice+bob
        // Mint to exhaustion then verify next mint fails
        digitalUSD.mint(mintAuth, 10_000_000e18); // ensure mint auth has enough

        // Attempt to mint 1M (within velocity) but totalSupply would exceed 10M
        // Force totalSupply above limit by burning first
        // Instead test a simpler edge: set supplyLimit = current supply then mint 1
        // We test by registering a token with a tiny limit
        MockERC20 tinyToken = new MockERC20("TINY", 18);
        vm.prank(admin);
        bridge.registerCBDC(address(tinyToken), mintAuth, burnAuth, 100e18, 1e18, 200e18, 0);

        vm.prank(policyAdmin);
        bridge.updatePolicy(address(tinyToken), 1e18, 0, true, true);

        // Mint 100e18 to fill the supply limit
        tinyToken.mint(mintAuth, 200e18);

        vm.startPrank(mintAuth);
        tinyToken.approve(address(bridge), type(uint256).max);
        // totalSupply is already 200 but limit is 100 → should revert
        vm.expectRevert("Supply limit exceeded");
        bridge.mintToDEX(address(tinyToken), alice, 1e18);
        vm.stopPrank();
    }

    function test_BurnFromDEX_Success() public {
        // First get alice some tokens through normal transfer
        uint256 burnAmount = 5_000e18;

        vm.startPrank(alice);
        digitalUSD.approve(address(bridge), type(uint256).max);
        uint256 aliceBefore = digitalUSD.balanceOf(alice);
        vm.stopPrank();

        vm.prank(burnAuth);
        bridge.burnFromDEX(address(digitalUSD), alice, burnAmount);

        assertEq(digitalUSD.balanceOf(alice), aliceBefore - burnAmount);
    }

    function test_BurnFromDEX_NotBurnAuthority_Reverts() public {
        vm.startPrank(alice);
        digitalUSD.approve(address(bridge), type(uint256).max);
        vm.expectRevert("Not burn authority");
        bridge.burnFromDEX(address(digitalUSD), alice, 1_000e18);
        vm.stopPrank();
    }

    // =========================================================================
    // 4. CBDC Liquidity Provision
    // =========================================================================

    function test_ProvideLiquidity_Success() public {
        vm.startPrank(alice);
        digitalUSD.approve(address(bridge), type(uint256).max);
        bridge.provideLiquidity(address(digitalUSD), 50_000e18);
        vm.stopPrank();

        ICBDCBridge.LiquidityPosition memory pos = bridge.getLiquidityPosition(alice, address(digitalUSD));
        assertEq(pos.amount, 50_000e18);
        assertEq(pos.cbdcToken, address(digitalUSD));
    }

    function test_WithdrawLiquidity_Success() public {
        vm.startPrank(alice);
        digitalUSD.approve(address(bridge), type(uint256).max);
        bridge.provideLiquidity(address(digitalUSD), 50_000e18);

        uint256 aliceBefore = digitalUSD.balanceOf(alice);
        bridge.withdrawLiquidity(address(digitalUSD), 20_000e18);
        vm.stopPrank();

        assertEq(digitalUSD.balanceOf(alice), aliceBefore + 20_000e18);

        ICBDCBridge.LiquidityPosition memory pos = bridge.getLiquidityPosition(alice, address(digitalUSD));
        assertEq(pos.amount, 30_000e18);
    }

    function test_WithdrawLiquidity_TooMuch_Reverts() public {
        vm.startPrank(alice);
        digitalUSD.approve(address(bridge), type(uint256).max);
        bridge.provideLiquidity(address(digitalUSD), 1_000e18);
        vm.expectRevert("Insufficient liquidity position");
        bridge.withdrawLiquidity(address(digitalUSD), 2_000e18);
        vm.stopPrank();
    }

    // =========================================================================
    // 5. Real-Time Settlement
    // =========================================================================

    function test_SubmitAndExecuteSettlement_Mint() public {
        // Submit a mint settlement request
        vm.prank(mintAuth);
        bytes32 reqId = bridge.submitSettlement(address(digitalUSD), alice, 10_000e18, true);

        ICBDCBridge.SettlementRequest memory req = bridge.getSettlementRequest(reqId);
        assertFalse(req.executed);
        assertTrue(req.isMint);

        // Execute by central bank
        vm.startPrank(mintAuth);
        digitalUSD.approve(address(bridge), type(uint256).max);
        vm.stopPrank();

        uint256 aliceBefore = digitalUSD.balanceOf(alice);

        vm.prank(centralBank);
        bridge.executeSettlement(reqId);

        assertGt(digitalUSD.balanceOf(alice), aliceBefore);
        assertTrue(bridge.getSettlementRequest(reqId).executed);
    }

    function test_ExecuteSettlement_AlreadyExecuted_Reverts() public {
        vm.prank(mintAuth);
        bytes32 reqId = bridge.submitSettlement(address(digitalUSD), alice, 1_000e18, true);

        vm.startPrank(mintAuth);
        digitalUSD.approve(address(bridge), type(uint256).max);
        vm.stopPrank();

        vm.prank(centralBank);
        bridge.executeSettlement(reqId);

        vm.prank(centralBank);
        vm.expectRevert("Already executed");
        bridge.executeSettlement(reqId);
    }

    function test_ExecuteSettlement_NotCentralBank_Reverts() public {
        vm.prank(mintAuth);
        bytes32 reqId = bridge.submitSettlement(address(digitalUSD), alice, 1_000e18, true);

        vm.prank(alice);
        vm.expectRevert();
        bridge.executeSettlement(reqId);
    }

    // =========================================================================
    // 6. Policy Enforcement
    // =========================================================================

    function test_EnforcePolicy_TransfersEnabled_Passes() public view {
        // Should not revert
        bridge.enforcePolicy(alice, address(digitalUSD), 1_000e18);
    }

    function test_EnforcePolicy_TransfersDisabled_Reverts() public {
        vm.prank(policyAdmin);
        bridge.updatePolicy(address(digitalUSD), 1e18, 200, false, true);

        vm.expectRevert("Transfers disabled by central bank policy");
        bridge.enforcePolicy(alice, address(digitalUSD), 1_000e18);
    }

    function test_EnforcePolicy_BelowMin_Reverts() public {
        vm.expectRevert("Below minimum transaction amount");
        bridge.enforcePolicy(alice, address(digitalUSD), 0.5e18);
    }

    // =========================================================================
    // 7. Multi-Chain Compliance Reporting
    // =========================================================================

    function test_GenerateComplianceReport_ByAuditor() public {
        vm.expectEmit(true, false, false, false, address(bridge));
        emit ICBDCBridge.ComplianceReportSent(address(digitalUSD), 0, block.timestamp);
        vm.prank(auditor);
        bridge.generateComplianceReport(address(digitalUSD), 0, block.timestamp);
    }

    function test_GenerateComplianceReport_NotAuditor_Reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        bridge.generateComplianceReport(address(digitalUSD), 0, block.timestamp);
    }

    // =========================================================================
    // 8. Pause / Unpause
    // =========================================================================

    function test_Pause_BlocksMintToDEX() public {
        vm.prank(admin);
        bridge.pause();

        vm.startPrank(mintAuth);
        digitalUSD.approve(address(bridge), type(uint256).max);
        vm.expectRevert();
        bridge.mintToDEX(address(digitalUSD), alice, 1_000e18);
        vm.stopPrank();
    }

    function test_Unpause_AllowsMintToDEX() public {
        vm.prank(admin);
        bridge.pause();

        vm.prank(admin);
        bridge.unpause();

        uint256 aliceBefore = digitalUSD.balanceOf(alice);

        vm.startPrank(mintAuth);
        digitalUSD.approve(address(bridge), type(uint256).max);
        bridge.mintToDEX(address(digitalUSD), alice, 1_000e18);
        vm.stopPrank();

        assertGt(digitalUSD.balanceOf(alice), aliceBefore);
    }
}
