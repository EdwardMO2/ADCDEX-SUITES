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
//                        MOCK POOL (ISwapPool)
// =============================================================================

/// @notice Minimal mock pool that implements ISwapPool for testing.
contract MockPool {
    address public token0;
    address public token1;
    uint256 public feeBps;
    uint256 constant BPS = 10_000;

    constructor(address _token0, address _token1, uint256 _feeBps) {
        token0 = _token0;
        token1 = _token1;
        feeBps = _feeBps;
    }

    function swap(
        bytes32,
        address tokenIn,
        uint256 amountIn,
        uint256,
        address recipient
    ) external returns (uint256 amountOut) {
        require(tokenIn == token0 || tokenIn == token1, "MockPool: invalid tokenIn");
        address tokenOut = tokenIn == token0 ? token1 : token0;

        // Pull input tokens from caller (the router)
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Calculate output (simple constant-sum minus fee)
        uint256 fee = (amountIn * feeBps) / BPS;
        amountOut = amountIn - fee;

        // Send output tokens to recipient
        MockERC20(tokenOut).transfer(recipient, amountOut);
    }

    function getSwapQuote(bytes32, address, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feePaid, uint256 priceImpactBps)
    {
        feePaid        = (amountIn * feeBps) / BPS;
        amountOut      = amountIn - feePaid;
        priceImpactBps = 0;
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

import {SwapRouter} from "../contracts/SwapRouter.sol";

// =============================================================================
//                            TEST SUITE
// =============================================================================

/// @title SwapRouterTest
/// @notice Comprehensive test suite for SwapRouter.
contract SwapRouterTest {
    using TestAssert for *;

    uint256 constant SWAP_AMOUNT = 1_000e18;

    // -------------------------------------------------------------------------
    //                        DEPLOYMENT HELPERS
    // -------------------------------------------------------------------------

    function _computePoolId(address _token0, address _token1) internal pure returns (bytes32) {
        if (_token0 > _token1) (_token0, _token1) = (_token1, _token0);
        return keccak256(abi.encodePacked(_token0, _token1));
    }

    function _deploy()
        internal
        returns (
            SwapRouter router,
            MockERC20 tokenA,
            MockERC20 tokenB,
            MockPool pool
        )
    {
        tokenA = new MockERC20("TokenA", "TKNA");
        tokenB = new MockERC20("TokenB", "TKNB");

        // Deploy MockPool for the tokenA/tokenB pair with 0.05% fee
        pool = new MockPool(address(tokenA), address(tokenB), 5);

        SwapRouter impl      = new SwapRouter();
        bytes memory initData = abi.encodeCall(
            SwapRouter.initialize,
            (address(0), address(this))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = SwapRouter(address(proxy));

        // Register the pool in the router
        bytes32 poolId = _computePoolId(address(tokenA), address(tokenB));
        router.registerPool(poolId, address(pool));

        // Mint to test contract and approve router
        tokenA.mint(address(this), 100_000_000e18);
        tokenB.mint(address(this), 100_000_000e18);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);

        // Fund the pool with tokenB so it can pay out swaps (A → B)
        tokenB.mint(address(pool), 100_000_000e18);
        // Fund the pool with tokenA so it can pay out swaps (B → A)
        tokenA.mint(address(pool), 100_000_000e18);
    }

    function _buildRoute(
        MockERC20 tokenA,
        MockERC20 tokenB,
        uint256 amountIn,
        uint256 minOut
    ) internal pure returns (SwapRouter.Route memory) {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = _computePoolId(address(tokenA), address(tokenB));

        return SwapRouter.Route({
            path:         path,
            poolIds:      poolIds,
            amountIn:     amountIn,
            minAmountOut: minOut
        });
    }

    // -------------------------------------------------------------------------
    //                       1. INITIALIZATION
    // -------------------------------------------------------------------------

    function testInitialization() public {
        (SwapRouter router,,,) = _deploy();

        TestAssert.assertAddrEq(router.owner(), address(this), "owner");
        TestAssert.assertEq(router.MAX_HOPS(), 5, "MAX_HOPS");
    }

    // -------------------------------------------------------------------------
    //                       2. REGISTER POOL
    // -------------------------------------------------------------------------

    function testRegisterPool() public {
        (SwapRouter router,,,) = _deploy();

        bytes32 poolId  = keccak256("pool1");
        address poolAddr = address(0x1234);
        router.registerPool(poolId, poolAddr);

        TestAssert.assertAddrEq(router.pools(poolId), poolAddr, "pool registered");
        TestAssert.assertEq(uint256(router.registeredPoolIds(1)), uint256(poolId), "registeredPoolIds tracked");
    }

    // -------------------------------------------------------------------------
    //                       3. EXECUTE SWAP ROUTE
    // -------------------------------------------------------------------------

    function testExecuteSwapRoute() public {
        (SwapRouter router, MockERC20 tokenA, MockERC20 tokenB,) = _deploy();

        SwapRouter.Route memory route = _buildRoute(tokenA, tokenB, SWAP_AMOUNT, 0);
        uint256 balBefore = tokenB.balanceOf(address(this));

        uint256 amountOut = router.executeSwapRoute(route, 0);

        uint256 received = tokenB.balanceOf(address(this)) - balBefore;
        TestAssert.assertGt(amountOut, 0, "amountOut > 0");
        TestAssert.assertEq(received, amountOut, "received matches return");

        uint256 expectedFee = (SWAP_AMOUNT * 5) / 10_000;
        uint256 expectedOut = SWAP_AMOUNT - expectedFee;
        TestAssert.assertEq(amountOut, expectedOut, "amountOut after fee");
    }

    // -------------------------------------------------------------------------
    //                       4. SPLIT ROUTE
    // -------------------------------------------------------------------------

    function testSplitRoute() public {
        (SwapRouter router, MockERC20 tokenA, MockERC20 tokenB,) = _deploy();

        SwapRouter.Route memory r1 = _buildRoute(tokenA, tokenB, SWAP_AMOUNT, 0);
        SwapRouter.Route memory r2 = _buildRoute(tokenA, tokenB, SWAP_AMOUNT, 0);

        SwapRouter.Route[] memory routes   = new SwapRouter.Route[](2);
        uint256[] memory weights = new uint256[](2);
        routes[0]  = r1;
        routes[1]  = r2;
        weights[0] = 5_000; // 50 %
        weights[1] = 5_000; // 50 %

        SwapRouter.SplitRoute memory splitRoute = SwapRouter.SplitRoute({
            routes:  routes,
            weights: weights
        });

        uint256 balBefore = tokenB.balanceOf(address(this));
        uint256 totalOut  = router.executeSplitRoute(splitRoute);
        uint256 received  = tokenB.balanceOf(address(this)) - balBefore;

        TestAssert.assertGt(totalOut, 0, "totalOut > 0");
        TestAssert.assertEq(received, totalOut, "received matches return");
    }

    // -------------------------------------------------------------------------
    //                       5. FIND BEST ROUTE
    // -------------------------------------------------------------------------

    function testFindBestRoute() public {
        (SwapRouter router, MockERC20 tokenA, MockERC20 tokenB,) = _deploy();

        SwapRouter.Route memory route = router.findBestRoute(
            address(tokenA),
            address(tokenB),
            SWAP_AMOUNT
        );

        TestAssert.assertAddrEq(route.path[0], address(tokenA), "path[0]");
        TestAssert.assertAddrEq(route.path[1], address(tokenB), "path[1]");
        TestAssert.assertEq(route.amountIn, SWAP_AMOUNT, "amountIn");
        TestAssert.assertGt(route.minAmountOut, 0, "minAmountOut from real quote");
    }

    // -------------------------------------------------------------------------
    //                       6. SLIPPAGE PROTECTION
    // -------------------------------------------------------------------------

    function testSlippageProtection() public {
        (SwapRouter router, MockERC20 tokenA, MockERC20 tokenB,) = _deploy();

        // Set minAmountOut higher than what will be returned
        uint256 minAmountOut = SWAP_AMOUNT; // 100 % of input, impossible with any fee
        SwapRouter.Route memory route = _buildRoute(tokenA, tokenB, SWAP_AMOUNT, minAmountOut);

        bool reverted;
        try router.executeSwapRoute(route, minAmountOut) {
            reverted = false;
        } catch {
            reverted = true;
        }
        TestAssert.assertTrue(reverted, "slippage: should revert");
    }

    // -------------------------------------------------------------------------
    //                         RUN ALL
    // -------------------------------------------------------------------------

    function runAll() external {
        testInitialization();
        testRegisterPool();
        testExecuteSwapRoute();
        testSplitRoute();
        testFindBestRoute();
        testSlippageProtection();
    }
}
