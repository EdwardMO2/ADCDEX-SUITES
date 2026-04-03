// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "./Interfaces/ISwapPool.sol";

/// @title SwapRouter
/// @notice Multi-hop swap routing engine.  Supports sequential single-path routes
///         and weighted split routes across multiple pools.  Each hop is executed
///         through a registered pool contract that implements ISwapPool.
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
        bytes32[] poolIds;       // Pool ID for each hop (length = path.length - 1)
        uint256   amountIn;
        uint256   minAmountOut;
        uint256[] perHopMinOut;  // P1-4: minimum output per hop (optional, length = path.length - 1)
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
    /// @notice All registered pool IDs for iteration.
    bytes32[] public registeredPoolIds;
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
            registeredPoolIds.push(poolId);
        }
        pools[poolId] = poolAddr;
        emit PoolRegistered(poolId, poolAddr);
    }

    // =========================================================================
    // Swap Execution
    // =========================================================================

    /// @notice Execute a multi-hop swap along a single route.
    /// @dev    Each hop is routed through the pool contract registered for the
    ///         corresponding poolId.  The pool's own swap logic (AMM curve, fees,
    ///         slippage) is applied on each hop.  Per-hop slippage protection is
    ///         enforced when perHopMinOut is provided.
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
        require(route.poolIds.length == hops - 1, "SwapRouter: poolIds length mismatch");
        require(route.amountIn > 0, "SwapRouter: zero amountIn");

        // Validate per-hop slippage array if provided
        bool hasPerHopSlippage = route.perHopMinOut.length > 0;
        if (hasPerHopSlippage) {
            require(route.perHopMinOut.length == hops - 1, "SwapRouter: perHopMinOut length mismatch");
        }

        // Pull tokenIn from caller
        IERC20Upgradeable(route.path[0]).safeTransferFrom(
            msg.sender,
            address(this),
            route.amountIn
        );

        amountOut = route.amountIn;
        uint256 hopCount = hops - 1;
        for (uint256 i = 0; i < hopCount; ) {
            address poolAddr = pools[route.poolIds[i]];
            require(poolAddr != address(0), "SwapRouter: pool not registered");

            // Approve the pool to spend the current hop's input token
            IERC20Upgradeable(route.path[i]).forceApprove(poolAddr, amountOut);

            // P1-4: Per-hop slippage protection
            uint256 hopMinOut = hasPerHopSlippage ? route.perHopMinOut[i] : 0;

            // Execute the swap through the pool; output is sent back to this contract
            amountOut = ISwapPool(poolAddr).swap(
                route.poolIds[i],
                route.path[i],
                amountOut,
                hopMinOut,
                address(this)
            );

            unchecked { ++i; }
        }

        require(amountOut >= minAmountOut, "SwapRouter: insufficient output");

        // Transfer final token out to caller
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
    /// @dev    All sub-routes must share the same input token.  The total input
    ///         is split among sub-routes according to their weights.
    /// @param splitRoute  The split route definition.
    /// @return totalAmountOut  Combined output across all sub-routes.
    function executeSplitRoute(
        SplitRoute calldata splitRoute
    ) external nonReentrant whenNotPaused returns (uint256 totalAmountOut) {
        uint256 numRoutes = splitRoute.routes.length;
        require(numRoutes > 0, "SwapRouter: empty routes");
        require(numRoutes == splitRoute.weights.length, "SwapRouter: weights mismatch");

        uint256 totalWeight;
        for (uint256 i = 0; i < numRoutes; ) {
            totalWeight += splitRoute.weights[i];
            unchecked { ++i; }
        }
        require(totalWeight == BPS, "SwapRouter: weights must sum to BPS");

        // All sub-routes must share the same input token
        uint256 totalIn = splitRoute.routes[0].amountIn;
        address tokenIn = splitRoute.routes[0].path[0];

        for (uint256 i = 1; i < numRoutes; ) {
            require(
                splitRoute.routes[i].path[0] == tokenIn,
                "SwapRouter: all sub-routes must share the same input token"
            );
            unchecked { ++i; }
        }

        IERC20Upgradeable(tokenIn).safeTransferFrom(msg.sender, address(this), totalIn);

        for (uint256 i = 0; i < numRoutes; ) {
            Route calldata r = splitRoute.routes[i];
            uint256 splitAmt = (totalIn * splitRoute.weights[i]) / BPS;

            uint256 hopOut = splitAmt;
            uint256 hops   = r.path.length;

            // Execute each hop through its registered pool
            for (uint256 j = 0; j < hops - 1; ) {
                address poolAddr = pools[r.poolIds[j]];
                require(poolAddr != address(0), "SwapRouter: pool not registered");

                IERC20Upgradeable(r.path[j]).forceApprove(poolAddr, hopOut);

                hopOut = ISwapPool(poolAddr).swap(
                    r.poolIds[j],
                    r.path[j],
                    hopOut,
                    0,
                    address(this)
                );

                unchecked { ++j; }
            }

            if (hopOut > 0) {
                IERC20Upgradeable(r.path[hops - 1]).safeTransfer(msg.sender, hopOut);
            }
            totalAmountOut += hopOut;
            unchecked { ++i; }
        }

        emit SplitRouteExecuted(msg.sender, totalAmountOut);
    }

    // =========================================================================
    // Quote / Route Finding
    // =========================================================================

    /// @notice Find the best single-hop route between two tokens by querying all
    ///         registered pools for quotes and returning the one with the highest
    ///         expected output.
    /// @param tokenIn   Input token.
    /// @param tokenOut  Output token.
    /// @param amountIn  Amount of tokenIn.
    /// @return route    The best single-hop route found; reverts if no pool exists
    ///                  for the pair.
    function findBestRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (Route memory route) {
        require(tokenIn != address(0) && tokenOut != address(0), "SwapRouter: zero token address");
        require(amountIn > 0, "SwapRouter: zero amountIn");

        uint256 bestOutput;
        bytes32 bestPoolId;
        uint256 numPools = registeredPoolIds.length;

        for (uint256 i = 0; i < numPools; ) {
            bytes32 pid = registeredPoolIds[i];
            address poolAddr = pools[pid];
            if (poolAddr != address(0)) {
                // Try to get a quote; skip if the pool reverts (pair not supported)
                try ISwapPool(poolAddr).getSwapQuote(pid, tokenIn, amountIn)
                    returns (uint256 out, uint256, uint256)
                {
                    if (out > bestOutput) {
                        bestOutput = out;
                        bestPoolId = pid;
                    }
                } catch {
                    // Pool does not support this pair – skip
                }
            }
            unchecked { ++i; }
        }

        // Also try a deterministic poolId derived from the sorted token pair
        bytes32 derivedId = _computePoolId(tokenIn, tokenOut);
        address derivedPool = pools[derivedId];
        if (derivedPool != address(0)) {
            try ISwapPool(derivedPool).getSwapQuote(derivedId, tokenIn, amountIn)
                returns (uint256 out, uint256, uint256)
            {
                if (out > bestOutput) {
                    bestOutput = out;
                    bestPoolId = derivedId;
                }
            } catch {}
        }

        require(bestOutput > 0, "SwapRouter: no pool found for pair");

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        bytes32[] memory pids = new bytes32[](1);
        pids[0] = bestPoolId;

        uint256[] memory perHopMin = new uint256[](1);
        perHopMin[0] = bestOutput;

        route = Route({
            path:         path,
            poolIds:      pids,
            amountIn:     amountIn,
            minAmountOut: bestOutput,
            perHopMinOut: perHopMin
        });
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @notice Compute a deterministic pool ID from a token pair.
    /// @dev    Sorts the two addresses before hashing, matching the convention
    ///         used by StablecoinPools.getPoolId().
    /// @param token0 First token address.
    /// @param token1 Second token address.
    /// @return Pool ID as keccak256 of the sorted, packed addresses.
    function _computePoolId(address token0, address token1) internal pure returns (bytes32) {
        if (token0 > token1) (token0, token1) = (token1, token0);
        return keccak256(abi.encodePacked(token0, token1));
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
