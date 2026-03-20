// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================================
// GlobalSettlementProtocol.test.sol
// Comprehensive test suite for GlobalSettlementProtocol.sol
// Compatible with Foundry (forge test)
// ============================================================================

import "forge-std/Test.sol";
import "../GlobalSettlementProtocol.sol";

/// @dev Minimal ERC20 mock
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
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount);
        require(allowance[from][msg.sender] >= amount);
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
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
        address payable,
        address,
        bytes calldata
    ) external payable {
        emit MessageSent(_dstChainId, _destination, _payload);
    }
}

/// @dev A minimal compliance hook that always approves
contract AlwaysApproveHook {
    function screenTransaction(address, uint256, bytes32) external pure returns (bool) {
        return true;
    }
}

/// @dev A compliance hook that always rejects
contract AlwaysRejectHook {
    function screenTransaction(address, uint256, bytes32) external pure returns (bool) {
        revert("Compliance: blocked");
    }
}

contract GlobalSettlementProtocolTest is Test {
    GlobalSettlementProtocol internal gsp;
    MockLZEndpoint             internal lz;

    MockERC20 internal usd;
    MockERC20 internal eur;
    MockERC20 internal gbp;
    MockERC20 internal cny;
    MockERC20 internal jpy;

    address internal owner    = address(0xBB01);
    address internal timelock = address(0xBB02);
    address internal alice    = address(0xBB03);
    address internal bob      = address(0xBB04);
    address internal carol    = address(0xBB05);

    function setUp() public {
        lz = new MockLZEndpoint();

        GlobalSettlementProtocol impl = new GlobalSettlementProtocol();
        vm.prank(owner);
        impl.initialize(address(lz), timelock, owner);
        gsp = impl;

        // Deploy currency mocks
        usd = new MockERC20("USD", 18);
        eur = new MockERC20("EUR", 18);
        gbp = new MockERC20("GBP", 18);
        cny = new MockERC20("CNY", 18);
        jpy = new MockERC20("JPY", 18);

        // Register currencies
        vm.startPrank(owner);
        gsp.registerCurrency(address(usd), "USD", 0.44e18);
        gsp.registerCurrency(address(eur), "EUR", 0.30e18);
        gsp.registerCurrency(address(gbp), "GBP", 0.08e18);
        gsp.registerCurrency(address(cny), "CNY", 0.11e18);
        gsp.registerCurrency(address(jpy), "JPY", 0.07e18);
        vm.stopPrank();

        // Mint tokens
        usd.mint(alice, 1_000_000e18);
        eur.mint(alice, 1_000_000e18);
        usd.mint(bob,   1_000_000e18);
        eur.mint(bob,   1_000_000e18);
        usd.mint(carol, 1_000_000e18);
    }

    // =========================================================================
    // 1. Currency Registration
    // =========================================================================

    function test_RegisterCurrency_Success() public view {
        ISettlementProtocol.CurrencyConfig memory cfg = gsp.getCurrencyConfig(address(usd));
        assertTrue(cfg.active);
        assertEq(cfg.isoCode, "USD");
        assertEq(cfg.sdrWeight, 0.44e18);
    }

    function test_RegisterCurrency_Duplicate_Reverts() public {
        vm.prank(owner);
        vm.expectRevert("Already registered");
        gsp.registerCurrency(address(usd), "USD", 0.44e18);
    }

    function test_GetAllCurrencies_ReturnsAll() public view {
        address[] memory list = gsp.getAllCurrencies();
        assertEq(list.length, 5);
    }

    // =========================================================================
    // 2. Multi-Currency Swaps (Settlement Lifecycle)
    // =========================================================================

    function test_InitiateSettlement_Success() public {
        vm.startPrank(alice);
        usd.approve(address(gsp), type(uint256).max);
        bytes32 id = gsp.initiateSettlement(bob, address(usd), address(eur), 1_000e18, 0, 0, "");
        vm.stopPrank();

        ISettlementProtocol.Settlement memory s = gsp.getSettlement(id);
        assertEq(s.initiator, alice);
        assertEq(s.counterparty, bob);
        assertTrue(s.status == ISettlementProtocol.SettlementStatus.Pending);
    }

    function test_ExecuteSettlement_Success() public {
        vm.startPrank(alice);
        usd.approve(address(gsp), type(uint256).max);
        bytes32 id = gsp.initiateSettlement(bob, address(usd), address(usd), 500e18, 0, 0, "");
        vm.stopPrank();

        uint256 bobBefore = usd.balanceOf(bob);

        vm.prank(bob);
        gsp.executeSettlement(id);

        assertGt(usd.balanceOf(bob), bobBefore);
    }

    function test_CancelSettlement_ByInitiator() public {
        vm.startPrank(alice);
        usd.approve(address(gsp), type(uint256).max);
        bytes32 id = gsp.initiateSettlement(bob, address(usd), address(eur), 200e18, 0, 0, "");

        uint256 balBefore = usd.balanceOf(alice);
        gsp.cancelSettlement(id);
        vm.stopPrank();

        assertGt(usd.balanceOf(alice), balBefore);
        assertTrue(gsp.getSettlement(id).status == ISettlementProtocol.SettlementStatus.Cancelled);
    }

    function test_CancelSettlement_NotInitiator_Reverts() public {
        vm.startPrank(alice);
        usd.approve(address(gsp), type(uint256).max);
        bytes32 id = gsp.initiateSettlement(bob, address(usd), address(eur), 200e18, 0, 0, "");
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert("Only initiator");
        gsp.cancelSettlement(id);
    }

    function test_ExecuteSettlement_CrossChain_Reverts() public {
        vm.prank(owner);
        gsp.setTrustedRemote(137, abi.encodePacked(address(gsp)));

        vm.startPrank(alice);
        usd.approve(address(gsp), type(uint256).max);
        bytes32 id = gsp.initiateSettlement(bob, address(usd), address(usd), 100e18, 0, 137, "");
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert("Cross-chain settlement");
        gsp.executeSettlement(id);
    }

    // =========================================================================
    // 3. Netting Engine
    // =========================================================================

    function test_NetPositionSubmitAndQuery() public {
        vm.prank(alice);
        gsp.submitNetPosition(bob, address(usd), 1_000e18);

        assertEq(gsp.getNetPosition(alice, bob, address(usd)), 1_000e18);
        assertEq(gsp.getNetPosition(bob, alice, address(usd)), -1_000e18);
    }

    function test_NetAndSettle_ReducesPosition() public {
        // alice owes bob 1000 USD
        vm.prank(alice);
        gsp.submitNetPosition(bob, address(usd), -1_000e18);

        uint256 aliceBefore = usd.balanceOf(alice);
        uint256 bobBefore   = usd.balanceOf(bob);

        vm.startPrank(alice);
        usd.approve(address(gsp), type(uint256).max);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usd);
        gsp.netAndSettle(bob, tokens);
        vm.stopPrank();

        assertEq(gsp.getNetPosition(alice, bob, address(usd)), 0);
        assertLt(usd.balanceOf(alice), aliceBefore);
        assertGt(usd.balanceOf(bob), bobBefore);
    }

    // =========================================================================
    // 4. SDR Basket
    // =========================================================================

    function test_ConfigureSDRBasket_Success() public {
        address[] memory tokens  = new address[](5);
        uint256[] memory weights = new uint256[](5);
        tokens[0]  = address(usd); weights[0] = 0.44e18;
        tokens[1]  = address(eur); weights[1] = 0.30e18;
        tokens[2]  = address(gbp); weights[2] = 0.08e18;
        tokens[3]  = address(cny); weights[3] = 0.11e18;
        tokens[4]  = address(jpy); weights[4] = 0.07e18;

        vm.prank(owner);
        gsp.configureSDRBasket(tokens, weights);

        ISettlementProtocol.SDRBasket memory basket = gsp.getSDRBasket();
        assertEq(basket.tokens.length, 5);
    }

    function test_RebalanceSDR_UpdatesValue() public {
        // Configure basket
        address[] memory tokens  = new address[](2);
        uint256[] memory weights = new uint256[](2);
        tokens[0] = address(usd); weights[0] = 0.5e18;
        tokens[1] = address(eur); weights[1] = 0.5e18;

        vm.prank(owner);
        gsp.configureSDRBasket(tokens, weights);

        // Transfer some tokens to the contract so rebalance finds a balance
        usd.mint(address(gsp), 50_000e18);
        eur.mint(address(gsp), 50_000e18);

        gsp.rebalanceSDR();

        assertGt(gsp.getSDRValue(), 0);
    }

    function test_SDRBasket_WeightsMustSumToOne_Reverts() public {
        address[] memory tokens  = new address[](2);
        uint256[] memory weights = new uint256[](2);
        tokens[0] = address(usd); weights[0] = 0.4e18;
        tokens[1] = address(eur); weights[1] = 0.4e18; // sum != 1e18

        vm.prank(owner);
        vm.expectRevert("Weights must sum to 1e18");
        gsp.configureSDRBasket(tokens, weights);
    }

    // =========================================================================
    // 5. Compliance Hook Execution
    // =========================================================================

    function test_ComplianceHook_AlwaysApprove_Passes() public {
        AlwaysApproveHook hook = new AlwaysApproveHook();
        vm.prank(owner);
        gsp.addComplianceHook(address(hook));

        vm.startPrank(alice);
        usd.approve(address(gsp), type(uint256).max);
        bytes32 id = gsp.initiateSettlement(bob, address(usd), address(usd), 100e18, 0, 0, "");
        vm.stopPrank();

        assertTrue(gsp.getSettlement(id).status == ISettlementProtocol.SettlementStatus.Pending);
    }

    function test_ComplianceHook_AlwaysReject_Reverts() public {
        AlwaysRejectHook hook = new AlwaysRejectHook();
        vm.prank(owner);
        gsp.addComplianceHook(address(hook));

        vm.startPrank(alice);
        usd.approve(address(gsp), type(uint256).max);
        vm.expectRevert("Compliance hook rejected");
        gsp.initiateSettlement(bob, address(usd), address(usd), 100e18, 0, 0, "");
        vm.stopPrank();
    }

    function test_RemoveComplianceHook() public {
        AlwaysRejectHook hook = new AlwaysRejectHook();
        vm.startPrank(owner);
        gsp.addComplianceHook(address(hook));
        gsp.removeComplianceHook(address(hook));
        vm.stopPrank();

        // Now the hook is removed, initiation should succeed
        vm.startPrank(alice);
        usd.approve(address(gsp), type(uint256).max);
        bytes32 id = gsp.initiateSettlement(bob, address(usd), address(usd), 100e18, 0, 0, "");
        vm.stopPrank();

        assertTrue(gsp.getSettlement(id).status == ISettlementProtocol.SettlementStatus.Pending);
    }

    // =========================================================================
    // 6. Audit Trail
    // =========================================================================

    function test_AuditTrail_CapturesAllEvents() public {
        vm.startPrank(alice);
        usd.approve(address(gsp), type(uint256).max);
        bytes32 id = gsp.initiateSettlement(bob, address(usd), address(usd), 50e18, 0, 0, "");
        vm.stopPrank();

        vm.prank(bob);
        gsp.executeSettlement(id);

        (string[] memory actions, uint256[] memory timestamps) = gsp.getAuditTrail(id);
        assertEq(actions.length, 2, "Should have Initiated + Executed");
        assertEq(keccak256(bytes(actions[0])), keccak256(bytes("Initiated")));
        assertEq(keccak256(bytes(actions[1])), keccak256(bytes("Executed")));
        assertGt(timestamps[0], 0);
    }

    // =========================================================================
    // 7. Dispute Resolution
    // =========================================================================

    function test_RaiseDispute_ThenResolve() public {
        vm.startPrank(alice);
        usd.approve(address(gsp), type(uint256).max);
        bytes32 id = gsp.initiateSettlement(bob, address(usd), address(usd), 50e18, 0, 0, "");
        vm.stopPrank();

        vm.prank(bob);
        gsp.executeSettlement(id);

        vm.prank(alice);
        gsp.raiseDispute(id, "Amount mismatch");

        assertTrue(gsp.getSettlement(id).status == ISettlementProtocol.SettlementStatus.Disputed);

        vm.prank(timelock);
        gsp.resolveDispute(id, 0);

        assertTrue(gsp.getSettlement(id).status == ISettlementProtocol.SettlementStatus.Resolved);
    }

    function test_ResolveDispute_NotTimelock_Reverts() public {
        vm.startPrank(alice);
        usd.approve(address(gsp), type(uint256).max);
        bytes32 id = gsp.initiateSettlement(bob, address(usd), address(usd), 50e18, 0, 0, "");
        vm.stopPrank();

        vm.prank(alice);
        gsp.raiseDispute(id, "dispute");

        vm.prank(alice);
        vm.expectRevert("Only timelock");
        gsp.resolveDispute(id, 0);
    }

    // =========================================================================
    // 8. Cross-Chain Settlement (LayerZero)
    // =========================================================================

    function test_CrossChainSettlement_SendsLZMessage() public {
        vm.prank(owner);
        gsp.setTrustedRemote(43114, abi.encodePacked(address(gsp)));

        vm.startPrank(alice);
        usd.approve(address(gsp), type(uint256).max);
        vm.expectEmit(true, false, false, false, address(gsp));
        emit ISettlementProtocol.CrossChainSettlementSent(bytes32(0), 43114);
        gsp.initiateSettlement(bob, address(usd), address(usd), 200e18, 0, 43114, "");
        vm.stopPrank();
    }

    // =========================================================================
    // 9. Pause / Unpause
    // =========================================================================

    function test_Pause_BlocksSettlement() public {
        vm.prank(owner);
        gsp.pause();

        vm.startPrank(alice);
        usd.approve(address(gsp), type(uint256).max);
        vm.expectRevert();
        gsp.initiateSettlement(bob, address(usd), address(eur), 100e18, 0, 0, "");
        vm.stopPrank();
    }
}
