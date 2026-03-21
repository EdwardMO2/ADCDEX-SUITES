// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
//                           MOCK CONTRACTS
// =============================================================================

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

import {MarginTradingPool} from "../contracts/MarginTradingPool.sol";

// =============================================================================
//                            TEST SUITE
// =============================================================================

/// @title MarginTradingPoolTest
/// @notice Comprehensive test suite for MarginTradingPool.
contract MarginTradingPoolTest {
    using TestAssert for *;

    uint256 constant COLLATERAL_AMT = 15_000e18;  // 150 % of borrow
    uint256 constant BORROW_AMT     = 10_000e18;

    // -------------------------------------------------------------------------
    //                        DEPLOYMENT HELPERS
    // -------------------------------------------------------------------------

    function _deploy()
        internal
        returns (
            MarginTradingPool pool,
            MockERC20 collateralToken,
            MockERC20 borrowToken
        )
    {
        collateralToken = new MockERC20("USDC", "USDC");
        borrowToken     = new MockERC20("DAI",  "DAI");

        MarginTradingPool impl = new MarginTradingPool();
        bytes memory initData  = abi.encodeCall(
            MarginTradingPool.initialize,
            (address(collateralToken), address(borrowToken), address(this))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        pool = MarginTradingPool(address(proxy));

        // Mint tokens to test contract
        collateralToken.mint(address(this), 100_000_000e18);
        borrowToken.mint(address(this), 100_000_000e18);

        // Approve pool
        collateralToken.approve(address(pool), type(uint256).max);
        borrowToken.approve(address(pool), type(uint256).max);

        // Fund pool with borrow token for lending
        borrowToken.mint(address(pool), 100_000_000e18);
    }

    // -------------------------------------------------------------------------
    //                       1. DEPOSIT COLLATERAL
    // -------------------------------------------------------------------------

    function testDepositCollateral() public {
        (MarginTradingPool pool,,) = _deploy();

        pool.depositCollateral(COLLATERAL_AMT);

        (uint256 collateral,,,) = pool.accounts(address(this));
        TestAssert.assertEq(collateral, COLLATERAL_AMT, "collateral deposited");
    }

    // -------------------------------------------------------------------------
    //                       2. BORROW
    // -------------------------------------------------------------------------

    function testBorrow() public {
        (MarginTradingPool pool,, MockERC20 borrowToken) = _deploy();

        pool.depositCollateral(COLLATERAL_AMT);
        uint256 balBefore = borrowToken.balanceOf(address(this));
        pool.borrow(BORROW_AMT);
        uint256 received = borrowToken.balanceOf(address(this)) - balBefore;

        TestAssert.assertEq(received, BORROW_AMT, "borrow received");

        (,uint256 borrowed,,) = pool.accounts(address(this));
        TestAssert.assertEq(borrowed, BORROW_AMT, "borrowed stored");
    }

    // -------------------------------------------------------------------------
    //                       3. REPAY
    // -------------------------------------------------------------------------

    function testRepay() public {
        (MarginTradingPool pool,,) = _deploy();

        pool.depositCollateral(COLLATERAL_AMT);
        pool.borrow(BORROW_AMT);
        pool.repay(BORROW_AMT);

        (,uint256 borrowed,,) = pool.accounts(address(this));
        TestAssert.assertEq(borrowed, 0, "debt cleared");
    }

    // -------------------------------------------------------------------------
    //                       4. WITHDRAW COLLATERAL
    // -------------------------------------------------------------------------

    function testWithdrawCollateral() public {
        (MarginTradingPool pool, MockERC20 collateralToken,) = _deploy();

        pool.depositCollateral(COLLATERAL_AMT);
        uint256 balBefore = collateralToken.balanceOf(address(this));
        pool.withdrawCollateral(COLLATERAL_AMT);
        uint256 returned = collateralToken.balanceOf(address(this)) - balBefore;

        TestAssert.assertEq(returned, COLLATERAL_AMT, "collateral returned");
    }

    // -------------------------------------------------------------------------
    //                       5. HEALTH FACTOR
    // -------------------------------------------------------------------------

    function testHealthFactor() public {
        (MarginTradingPool pool,,) = _deploy();

        // With no debt, health factor should be max
        pool.depositCollateral(COLLATERAL_AMT);
        uint256 hfNoBorrow = pool.getHealthFactor(address(this));
        TestAssert.assertEq(hfNoBorrow, type(uint256).max, "no borrow: max hf");

        // After borrow at exactly 150 % collateral ratio
        // hf = (15000 * 10000 * 10000) / (10000 * 11000) = 136.36... bps → > 10000
        pool.borrow(BORROW_AMT);
        uint256 hf = pool.getHealthFactor(address(this));
        TestAssert.assertGt(hf, 10_000, "hf > 100 % after borrow");
    }

    // -------------------------------------------------------------------------
    //                       6. LIQUIDATION
    // -------------------------------------------------------------------------

    function testLiquidation() public {
        (MarginTradingPool pool, MockERC20 collateralToken, MockERC20 borrowToken) = _deploy();

        // Deposit just enough collateral to pass 150 % borrow check
        pool.depositCollateral(COLLATERAL_AMT);
        pool.borrow(BORROW_AMT);

        // Create a second address scenario using a proxy user contract
        // Since we can't manipulate time here, we test the revert on healthy account
        bool reverted;
        try pool.liquidate(address(this)) {
            reverted = false;
        } catch {
            reverted = true;
        }
        TestAssert.assertTrue(reverted, "healthy account: liquidation should revert");

        // Suppress unused variable warning
        collateralToken;
        borrowToken;
    }

    // -------------------------------------------------------------------------
    //                       7. INTEREST ACCRUAL
    // -------------------------------------------------------------------------

    function testInterestAccrual() public {
        (MarginTradingPool pool,,) = _deploy();

        pool.depositCollateral(COLLATERAL_AMT);
        pool.borrow(BORROW_AMT);

        (,uint256 borrowedBefore,,) = pool.accounts(address(this));

        // Trigger interest accrual via a no-op repay of 0 is not allowed,
        // so deposit 1 wei of collateral to trigger _accrueInterest
        pool.depositCollateral(1);

        (,uint256 borrowedAfter,,) = pool.accounts(address(this));
        // In the same block, interest elapsed = 0, so borrowed should be unchanged
        TestAssert.assertEq(borrowedAfter, borrowedBefore, "same-block interest = 0");
    }

    // -------------------------------------------------------------------------
    //                         RUN ALL
    // -------------------------------------------------------------------------

    function runAll() external {
        testDepositCollateral();
        testBorrow();
        testRepay();
        testWithdrawCollateral();
        testHealthFactor();
        testLiquidation();
        testInterestAccrual();
    }
}
