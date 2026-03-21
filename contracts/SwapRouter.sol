// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/// @title SwapRouter
/// @notice Multi-hop swap routing engine.  Supports sequential single-path routes
///         and weighted split routes across multiple pools.
/// @dev    UUPSUpgradeable – upgrade through governance.
contract SwapRouter is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 public constant MAX_HOPS = 5;
    uint256 public constant BPS      = 10_000;

    // =========================================================================
    // Structs
    // =========================================================================

    struct Route {
        address[] path;          // Token path: [tokenIn, hop1, ..., tokenOut]
        uint256[] fees;          // Fee for each hop in BPS (length = path.length - 1)
        uint256   amountIn;
        uint256   minAmountOut;
    }

    struct SplitRoute {
        Route[]   routes;        // Individual sub-routes
        uint256[] weights;       // Weight per route in BPS (must sum to BPS)
    }

    // =========================================================================
    // State
    // =========================================================================

    /// @notice Pool registry: poolId → pool address.
    mapping(bytes32 => address) public pools;
    /// @notice All registered pool addresses for iteration.
    address[] public registeredPools;
    /// @notice Address of the StablecoinPools contract (integration point).
    address public stablecoinPools;

    // =========================================================================
    // Events
    // =========================================================================

    event SwapRouteExecuted(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event SplitRouteExecuted(
        address indexed sender,
        uint256 totalAmountOut
    );

    event PoolRegistered(bytes32 indexed poolId, address indexed poolAddr);

    // =========================================================================
    // Constructor / Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialise the router.
    /// @param _stablecoinPools Address of the StablecoinPools integration contract.
    /// @param _owner           Initial contract owner.
    function initialize(address _stablecoinPools, address _owner) public initializer {
        require(_owner != address(0), "SwapRouter: zero owner");

        __Ownable_init();
        _transferOwnership(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        stablecoinPools = _stablecoinPools;
    }

    // =========================================================================
    // Pool Registry
    // =========================================================================

    /// @notice Register or update a pool.
    /// @param poolId   Unique identifier for the pool.
    /// @param poolAddr Pool contract address.
    function registerPool(bytes32 poolId, address poolAddr) external onlyOwner {
        require(poolAddr != address(0), "SwapRouter: zero pool address");
        if (pools[poolId] == address(0)) {
            registeredPools.push(poolAddr);
        }
        pools[poolId] = poolAddr;
        emit PoolRegistered(poolId, poolAddr);
    }

    // =========================================================================
    // Swap Execution
    // =========================================================================
    //
    // ⚠️  SECURITY NOTICE — SIMPLIFIED / TESTNET IMPLEMENTATION
    // The swap functions below are a synthetic approximation: they deduct
    // hop fees mathematically but do NOT call external pool contracts.
    // Output tokens must already be held by this router contract.
    // This design is acceptable for testnet and integration testing, but
    // MUST be replaced with actual pool interactions before mainnet deployment.
    //
    // TODO: Integrate real pool contract calls (e.g. Uniswap v3/v4 style) on
    //       each hop of the route before any production deployment.

    /// @notice Execute a multi-hop swap along a single route.
    /// @dev    Simplified implementation: executes a direct transfer for each hop
    ///         using the pool as a liquidity source.  A production implementation
    ///         would call the pool's swap function on each hop.
    /// @param route        The route to execute.
    /// @param minAmountOut Minimum acceptable output; reverts if not met.
    /// @return amountOut   Actual output amount.
    function executeSwapRoute(
        Route calldata route,
        uint256 minAmountOut
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        uint256 hops = route.path.length;
        require(hops >= 2, "SwapRouter: path too short");
        require(hops - 1 <= MAX_HOPS, "SwapRouter: too many hops");
        require(route.fees.length == hops - 1, "SwapRouter: fees length mismatch");
        require(route.amountIn > 0, "SwapRouter: zero amountIn");

        // Pull tokenIn from caller
        IERC20Upgradeable(route.path[0]).safeTransferFrom(
            msg.sender,
            address(this),
            route.amountIn
        );

        amountOut = route.amountIn;
        for (uint256 i = 0; i < hops - 1; i++) {
            // Deduct hop fee
            uint256 fee = (amountOut * route.fees[i]) / BPS;
            amountOut   = amountOut - fee;
        }

        require(amountOut >= minAmountOut, "SwapRouter: insufficient output");

        // Transfer final token out to caller (requires this contract holds the output token)
        IERC20Upgradeable(route.path[hops - 1]).safeTransfer(msg.sender, amountOut);

        emit SwapRouteExecuted(
            msg.sender,
            route.path[0],
            route.path[hops - 1],
            route.amountIn,
            amountOut
        );
    }

    /// @notice Execute a split swap across multiple weighted sub-routes.
    /// @param splitRoute  The split route definition.
    /// @return totalAmountOut  Combined output across all sub-routes.
    function executeSplitRoute(
        SplitRoute calldata splitRoute
    ) external nonReentrant whenNotPaused returns (uint256 totalAmountOut) {
        uint256 numRoutes = splitRoute.routes.length;
        require(numRoutes > 0, "SwapRouter: empty routes");
        require(numRoutes == splitRoute.weights.length, "SwapRouter: weights mismatch");

        uint256 totalWeight;
        for (uint256 i = 0; i < numRoutes; i++) {
            totalWeight += splitRoute.weights[i];
        }
        require(totalWeight == BPS, "SwapRouter: weights must sum to BPS");

        // Determine total amountIn from first route (all routes share the same input token)
        uint256 totalIn = splitRoute.routes[0].amountIn;
        address tokenIn = splitRoute.routes[0].path[0];

        IERC20Upgradeable(tokenIn).safeTransferFrom(msg.sender, address(this), totalIn);

        for (uint256 i = 0; i < numRoutes; i++) {
            Route memory r = splitRoute.routes[i];
            uint256 splitAmt = (totalIn * splitRoute.weights[i]) / BPS;

            uint256 hopOut = splitAmt;
            uint256 hops   = r.path.length;
            for (uint256 j = 0; j < hops - 1; j++) {
                uint256 fee = (hopOut * r.fees[j]) / BPS;
                hopOut      = hopOut - fee;
            }

            if (hopOut > 0) {
                IERC20Upgradeable(r.path[hops - 1]).safeTransfer(msg.sender, hopOut);
            }
            totalAmountOut += hopOut;
        }

        emit SplitRouteExecuted(msg.sender, totalAmountOut);
    }

    // =========================================================================
    // Quote / Route Finding
    // =========================================================================

    /// @notice Return a simplified 2-token route through any registered pool.
    /// @dev    View function only – returns a best-effort single-hop route.
    /// @param tokenIn   Input token.
    /// @param tokenOut  Output token.
    /// @param amountIn  Amount of tokenIn.
    /// @return route    A single-hop route between tokenIn and tokenOut.
    function findBestRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external pure returns (Route memory route) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256[] memory fees = new uint256[](1);
        fees[0] = 5; // default 0.05 % fee

        route = Route({
            path:         path,
            fees:         fees,
            amountIn:     amountIn,
            minAmountOut: 0
        });
    }

    // =========================================================================
    // Pause
    // =========================================================================

    /// @notice Pause swap execution.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause swap execution.
    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    // Upgrade
    // =========================================================================

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
