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

import {PerpetualsMarket} from "../contracts/PerpetualsMarket.sol";

// =============================================================================
//                            TEST SUITE
// =============================================================================

/// @title PerpetualsMarketTest
/// @notice Comprehensive test suite for PerpetualsMarket.
contract PerpetualsMarketTest {
    using TestAssert for *;

    uint256 constant INITIAL_PRICE  = 1_000e18;  // $1000 per token
    uint256 constant COLLATERAL_AMT = 1_000e18;  // 1000 USDC
    uint8   constant LEVERAGE       = 5;

    // -------------------------------------------------------------------------
    //                        DEPLOYMENT HELPERS
    // -------------------------------------------------------------------------

    function _deploy()
        internal
        returns (
            PerpetualsMarket market,
            MockERC20 collateral,
            MockERC20 underlying
        )
    {
        collateral  = new MockERC20("USDC", "USDC");
        underlying  = new MockERC20("ETH",  "ETH");

        PerpetualsMarket impl = new PerpetualsMarket();
        bytes memory initData = abi.encodeCall(
            PerpetualsMarket.initialize,
            (address(collateral), address(0), address(this))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        market = PerpetualsMarket(address(proxy));

        // Set oracle price
        market.setPrice(address(underlying), INITIAL_PRICE);

        // Fund test contract with collateral and approve market
        collateral.mint(address(this), 10_000_000e18);
        collateral.approve(address(market), type(uint256).max);

        // Fund market with collateral for PnL payouts
        collateral.mint(address(market), 10_000_000e18);
    }

    // -------------------------------------------------------------------------
    //                       1. INITIALIZATION
    // -------------------------------------------------------------------------

    function testInitialization() public {
        (PerpetualsMarket market, MockERC20 collateral,) = _deploy();

        TestAssert.assertAddrEq(market.collateralToken(), address(collateral), "collateralToken");
        TestAssert.assertAddrEq(market.owner(), address(this), "owner");
        TestAssert.assertEq(market.MAX_LEVERAGE(), 10, "MAX_LEVERAGE");
    }

    // -------------------------------------------------------------------------
    //                       2. OPEN LONG POSITION
    // -------------------------------------------------------------------------

    function testOpenLongPosition() public {
        (PerpetualsMarket market,, MockERC20 underlying) = _deploy();

        bytes32 posId = market.openPosition(address(underlying), COLLATERAL_AMT, LEVERAGE, true);

        (
            address owner,
            address token,
            uint256 collateral,
            uint256 size,
            uint8   leverage,
            bool    isLong,
            uint256 entryPrice,
            uint256 liquidationPrice,
            ,
        ) = market.positions(posId);

        TestAssert.assertAddrEq(owner, address(this), "position owner");
        TestAssert.assertAddrEq(token, address(underlying), "position token");
        TestAssert.assertEq(collateral, COLLATERAL_AMT, "collateral");
        TestAssert.assertEq(size, COLLATERAL_AMT * LEVERAGE, "size");
        TestAssert.assertEq(leverage, LEVERAGE, "leverage");
        TestAssert.assertTrue(isLong, "isLong");
        TestAssert.assertEq(entryPrice, INITIAL_PRICE, "entryPrice");
        // liqPrice for long = entryPrice * (leverage - 1) / leverage = 800e18
        uint256 expectedLiqPrice = (INITIAL_PRICE * (LEVERAGE - 1)) / LEVERAGE;
        TestAssert.assertEq(liquidationPrice, expectedLiqPrice, "liquidationPrice");
    }

    // -------------------------------------------------------------------------
    //                       3. OPEN SHORT POSITION
    // -------------------------------------------------------------------------

    function testOpenShortPosition() public {
        (PerpetualsMarket market,, MockERC20 underlying) = _deploy();

        bytes32 posId = market.openPosition(address(underlying), COLLATERAL_AMT, LEVERAGE, false);

        (,,,,,bool isLong,,uint256 liqPrice,,) = market.positions(posId);

        TestAssert.assertFalse(isLong, "isLong false");
        // liqPrice for short = entryPrice * (leverage + 1) / leverage = 1200e18
        uint256 expectedLiqPrice = (INITIAL_PRICE * (LEVERAGE + 1)) / LEVERAGE;
        TestAssert.assertEq(liqPrice, expectedLiqPrice, "short liqPrice");
    }

    // -------------------------------------------------------------------------
    //                       4. CLOSE POSITION
    // -------------------------------------------------------------------------

    function testClosePosition() public {
        (PerpetualsMarket market,MockERC20 collateral, MockERC20 underlying) = _deploy();

        bytes32 posId  = market.openPosition(address(underlying), COLLATERAL_AMT, LEVERAGE, true);
        uint256 before = collateral.balanceOf(address(this));

        // Price unchanged – PnL = 0, should get back collateral
        market.closePosition(posId);

        uint256 returned = collateral.balanceOf(address(this)) - before;
        TestAssert.assertEq(returned, COLLATERAL_AMT, "collateral returned on close");

        // Position should be deleted
        (address owner,,,,,,,,,) = market.positions(posId);
        TestAssert.assertAddrEq(owner, address(0), "position deleted");
    }

    // -------------------------------------------------------------------------
    //                       5. LIQUIDATION
    // -------------------------------------------------------------------------

    function testLiquidation() public {
        (PerpetualsMarket market,, MockERC20 underlying) = _deploy();

        bytes32 posId = market.openPosition(address(underlying), COLLATERAL_AMT, LEVERAGE, true);

        // Drop price below long liquidation price
        uint256 liqPrice = (INITIAL_PRICE * (LEVERAGE - 1)) / LEVERAGE;
        market.setPrice(address(underlying), liqPrice - 1);

        uint256 rewardExpected = (COLLATERAL_AMT * 500) / 10_000; // 5 %
        uint256 balBefore = MockERC20(market.collateralToken()).balanceOf(address(this));

        market.liquidatePosition(posId);

        uint256 balAfter = MockERC20(market.collateralToken()).balanceOf(address(this));
        TestAssert.assertEq(balAfter - balBefore, rewardExpected, "liquidator reward");
    }

    // -------------------------------------------------------------------------
    //                       6. INVALID LEVERAGE
    // -------------------------------------------------------------------------

    function testInvalidLeverage() public {
        (PerpetualsMarket market,, MockERC20 underlying) = _deploy();

        bool reverted;
        try market.openPosition(address(underlying), COLLATERAL_AMT, 11, true) {
            reverted = false;
        } catch {
            reverted = true;
        }
        TestAssert.assertTrue(reverted, "leverage > 10 should revert");

        try market.openPosition(address(underlying), COLLATERAL_AMT, 0, true) {
            reverted = false;
        } catch {
            reverted = true;
        }
        TestAssert.assertTrue(reverted, "leverage 0 should revert");
    }

    // -------------------------------------------------------------------------
    //                       7. FUNDING RATE UPDATE
    // -------------------------------------------------------------------------

    function testFundingRateUpdate() public {
        (PerpetualsMarket market,, MockERC20 underlying) = _deploy();

        uint256 rate = 1e15; // 0.001 per funding interval
        market.updateFundingRate(address(underlying), rate);

        TestAssert.assertEq(market.fundingRates(address(underlying)), rate, "funding rate");
    }

    // -------------------------------------------------------------------------
    //                         RUN ALL
    // -------------------------------------------------------------------------

    function runAll() external {
        testInitialization();
        testOpenLongPosition();
        testOpenShortPosition();
        testClosePosition();
        testLiquidation();
        testInvalidLeverage();
        testFundingRateUpdate();
    }
}
