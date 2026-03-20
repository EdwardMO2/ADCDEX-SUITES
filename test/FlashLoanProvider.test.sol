// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
//                           MOCK CONTRACTS
// =============================================================================

/// @dev Minimal ERC-20 used in tests.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8  public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name   = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply    += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

/// @dev Flash loan receiver that correctly repays principal + fee.
contract MockFlashLoanReceiver {
    bytes32 private constant CALLBACK_SUCCESS = keccak256("FlashLoanReceiver.onFlashLoan");

    address public provider;

    constructor(address _provider) {
        provider = _provider;
    }

    function onFlashLoan(
        address, /* initiator */
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata /* data */
    ) external returns (bytes32) {
        // Approve the provider to pull back amount + fee
        MockERC20(token).approve(provider, amount + fee);
        // Transfer the repayment back
        MockERC20(token).transfer(provider, amount + fee);
        return CALLBACK_SUCCESS;
    }
}

/// @dev Flash loan receiver that does NOT repay (returns wrong callback value).
contract MockMaliciousReceiver {
    function onFlashLoan(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes32) {
        return bytes32(0); // wrong return value — does not repay
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

    function assertEq(uint256 a, uint256 b, string memory message) internal pure {
        if (a != b) {
            revert(string(abi.encodePacked(message, ": expected ", _u2s(a), " == ", _u2s(b))));
        }
    }

    function assertGt(uint256 a, uint256 b, string memory message) internal pure {
        require(a > b, message);
    }

    function assertAddrEq(address a, address b, string memory message) internal pure {
        require(a == b, message);
    }

    function _u2s(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp    = v;
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

contract ERC1967Proxy {
    bytes32 private constant _IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address implementation, bytes memory data) payable {
        assembly { sstore(_IMPL_SLOT, implementation) }
        if (data.length > 0) {
            (bool ok, bytes memory reason) = implementation.delegatecall(data);
            if (!ok) { assembly { revert(add(reason, 32), mload(reason)) } }
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
//                        CONTRACT UNDER TEST
// =============================================================================

import {FlashLoanProvider} from "../contracts/FlashLoanProvider.sol";

// =============================================================================
//                            TEST SUITE
// =============================================================================

/// @title FlashLoanProviderTest
/// @notice Comprehensive test suite for FlashLoanProvider.
contract FlashLoanProviderTest {
    using TestAssert for *;

    uint256 constant POOL_LIQUIDITY = 1_000_000 ether;
    uint256 constant LOAN_AMOUNT    = 100_000 ether;

    // -------------------------------------------------------------------------
    //                        DEPLOYMENT HELPERS
    // -------------------------------------------------------------------------

    function _deploy()
        internal
        returns (
            FlashLoanProvider provider,
            MockERC20 token
        )
    {
        token = new MockERC20("USDC", "USDC");

        FlashLoanProvider impl = new FlashLoanProvider();
        bytes memory initData  = abi.encodeCall(
            FlashLoanProvider.initialize,
            (address(this), address(this))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        provider           = FlashLoanProvider(address(proxy));

        // Fund the provider with liquidity
        token.mint(address(provider), POOL_LIQUIDITY);

        // Whitelist the token
        provider.addSupportedToken(address(token));
    }

    // -------------------------------------------------------------------------
    //                       1. INITIALIZATION
    // -------------------------------------------------------------------------

    function testInitialization() public {
        (FlashLoanProvider provider,) = _deploy();

        TestAssert.assertAddrEq(provider.feeCollector(), address(this), "feeCollector");
        TestAssert.assertAddrEq(provider.owner(), address(this), "owner");
        TestAssert.assertEq(provider.FLASH_LOAN_FEE_BPS(), 5, "fee bps");
    }

    // -------------------------------------------------------------------------
    //                       2. TOKEN MANAGEMENT
    // -------------------------------------------------------------------------

    function testAddSupportedToken() public {
        (FlashLoanProvider provider,) = _deploy();
        MockERC20 token2 = new MockERC20("DAI", "DAI");

        provider.addSupportedToken(address(token2));
        TestAssert.assertTrue(provider.supportedTokens(address(token2)), "token2 supported");
    }

    function testRemoveSupportedToken() public {
        (FlashLoanProvider provider, MockERC20 token) = _deploy();

        provider.removeSupportedToken(address(token));
        TestAssert.assertFalse(provider.supportedTokens(address(token)), "token removed");
    }

    // -------------------------------------------------------------------------
    //                       3. FLASH LOAN – SUCCESS
    // -------------------------------------------------------------------------

    function testFlashLoanSuccessful() public {
        (FlashLoanProvider provider, MockERC20 token) = _deploy();

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver(address(provider));
        // Fund receiver so it can repay fee
        token.mint(address(receiver), 1_000 ether);

        uint256 balBefore = token.balanceOf(address(provider));

        provider.initiateFlashLoan(
            address(token),
            LOAN_AMOUNT,
            address(receiver),
            ""
        );

        uint256 expectedFee = (LOAN_AMOUNT * 5) / 10_000;
        uint256 balAfter    = token.balanceOf(address(provider));

        TestAssert.assertEq(balAfter, balBefore + expectedFee, "balance after");
    }

    // -------------------------------------------------------------------------
    //                       4. FEE CALCULATION
    // -------------------------------------------------------------------------

    function testFlashLoanFeeCalculation() public {
        (FlashLoanProvider provider, MockERC20 token) = _deploy();

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver(address(provider));
        token.mint(address(receiver), 1_000 ether);

        provider.initiateFlashLoan(address(token), LOAN_AMOUNT, address(receiver), "");

        uint256 expectedFee = (LOAN_AMOUNT * 5) / 10_000; // 0.05 %
        TestAssert.assertEq(provider.feeAccrued(address(token)), expectedFee, "feeAccrued");
    }

    // -------------------------------------------------------------------------
    //                       5. FAILED REPAYMENT
    // -------------------------------------------------------------------------

    function testFlashLoanFailedRepayment() public {
        (FlashLoanProvider provider, MockERC20 token) = _deploy();
        MockMaliciousReceiver badReceiver = new MockMaliciousReceiver();

        bool reverted;
        try provider.initiateFlashLoan(address(token), LOAN_AMOUNT, address(badReceiver), "") {
            reverted = false;
        } catch {
            reverted = true;
        }
        TestAssert.assertTrue(reverted, "should revert on bad repayment");
    }

    // -------------------------------------------------------------------------
    //                       6. UNSUPPORTED TOKEN
    // -------------------------------------------------------------------------

    function testFlashLoanUnsupportedToken() public {
        (FlashLoanProvider provider,) = _deploy();
        MockERC20 unsupported  = new MockERC20("UNS", "UNS");
        MockFlashLoanReceiver r = new MockFlashLoanReceiver(address(provider));

        bool reverted;
        try provider.initiateFlashLoan(address(unsupported), 100 ether, address(r), "") {
            reverted = false;
        } catch {
            reverted = true;
        }
        TestAssert.assertTrue(reverted, "unsupported token should revert");
    }

    // -------------------------------------------------------------------------
    //                       7. WITHDRAW FEES
    // -------------------------------------------------------------------------

    function testWithdrawFees() public {
        (FlashLoanProvider provider, MockERC20 token) = _deploy();

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver(address(provider));
        token.mint(address(receiver), 1_000 ether);
        provider.initiateFlashLoan(address(token), LOAN_AMOUNT, address(receiver), "");

        uint256 fee          = provider.feeAccrued(address(token));
        uint256 balBefore    = token.balanceOf(address(this));
        provider.withdrawFees(address(token), address(this));
        uint256 balAfter     = token.balanceOf(address(this));

        TestAssert.assertEq(balAfter - balBefore, fee, "fee withdrawn");
        TestAssert.assertEq(provider.feeAccrued(address(token)), 0, "feeAccrued cleared");
    }

    // -------------------------------------------------------------------------
    //                       8. PAUSE / UNPAUSE
    // -------------------------------------------------------------------------

    function testPauseAndUnpause() public {
        (FlashLoanProvider provider,) = _deploy();

        provider.pause();
        TestAssert.assertTrue(provider.paused(), "should be paused");

        provider.unpause();
        TestAssert.assertFalse(provider.paused(), "should be unpaused");
    }

    function testFlashLoanWhenPaused() public {
        (FlashLoanProvider provider, MockERC20 token) = _deploy();
        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver(address(provider));
        token.mint(address(receiver), 1_000 ether);

        provider.pause();

        bool reverted;
        try provider.initiateFlashLoan(address(token), LOAN_AMOUNT, address(receiver), "") {
            reverted = false;
        } catch {
            reverted = true;
        }
        TestAssert.assertTrue(reverted, "paused: should revert");
    }

    // -------------------------------------------------------------------------
    //                         RUN ALL
    // -------------------------------------------------------------------------

    function runAll() external {
        testInitialization();
        testAddSupportedToken();
        testRemoveSupportedToken();
        testFlashLoanSuccessful();
        testFlashLoanFeeCalculation();
        testFlashLoanFailedRepayment();
        testFlashLoanUnsupportedToken();
        testWithdrawFees();
        testPauseAndUnpause();
        testFlashLoanWhenPaused();
    }
}
