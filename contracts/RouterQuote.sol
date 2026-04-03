// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./SwapRouter.sol";
import "./Interfaces/ISwapPool.sol";

/// @title RouterQuote
/// @notice Off-chain-friendly quote engine.  Returns estimated output, price impact,
///         and total fees for SwapRouter Route and SplitRoute definitions without
///         executing any token transfers.  Queries real pool contracts for accurate
///         fee and output estimates.
/// @dev    UUPSUpgradeable – upgrade through governance.
contract RouterQuote is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable
{
    // =========================================================================
    // State
    // =========================================================================

    /// @notice Address of the SwapRouter whose pool registry this contract reads.
    address public swapRouter;

    uint256 public constant BPS = 10_000;

    // =========================================================================
    // Events
    // =========================================================================

    event QuoteGenerated(
        address indexed caller,
        uint256 estimatedOut,
        uint256 priceImpactBps,
        uint256 totalFees
    );

    // =========================================================================
    // Constructor / Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialise the contract.
    /// @param _swapRouter Address of the SwapRouter.
    /// @param _owner      Initial contract owner.
    function initialize(address _swapRouter, address _owner) public initializer {
        require(_swapRouter != address(0), "RouterQuote: zero router");
        require(_owner != address(0), "RouterQuote: zero owner");

        __Ownable_init();
        _transferOwnership(_owner);
        __UUPSUpgradeable_init();

        swapRouter = _swapRouter;
    }

    // =========================================================================
    // Quote Functions
    // =========================================================================

    /// @notice Estimate the output for a single-path route by querying real pool
    ///         contracts registered in the SwapRouter.
    /// @param route          The route to quote.
    /// @return estimatedOut  Estimated output after all hop fees.
    /// @return priceImpactBps Cumulative price impact in BPS across all hops.
    /// @return totalFees     Cumulative fee deducted across all hops.
    function quoteSwapRoute(SwapRouter.Route calldata route)
        external
        returns (
            uint256 estimatedOut,
            uint256 priceImpactBps,
            uint256 totalFees
        )
    {
        uint256 hops = route.path.length;
        require(hops >= 2, "RouterQuote: path too short");
        require(route.poolIds.length == hops - 1, "RouterQuote: poolIds length mismatch");
        require(route.amountIn > 0, "RouterQuote: zero amountIn");

        // Validate all token addresses in path are non-zero
        for (uint256 i = 0; i < hops; ) {
            require(route.path[i] != address(0), "RouterQuote: zero token address in path");
            unchecked { ++i; }
        }

        estimatedOut = route.amountIn;
        uint256 hopCount = hops - 1;
        for (uint256 i = 0; i < hopCount; ) {
            address poolAddr = SwapRouter(swapRouter).pools(route.poolIds[i]);
            require(poolAddr != address(0), "RouterQuote: pool not registered");

            (uint256 hopOut, uint256 hopFee, uint256 hopImpact) =
                ISwapPool(poolAddr).getSwapQuote(route.poolIds[i], route.path[i], estimatedOut);

            totalFees      += hopFee;
            priceImpactBps += hopImpact;
            estimatedOut    = hopOut;

            unchecked { ++i; }
        }

        emit QuoteGenerated(msg.sender, estimatedOut, priceImpactBps, totalFees);
    }

    /// @notice Estimate combined output for a split route.
    /// @param splitRoute     The split route to quote.
    /// @return estimatedOut  Combined estimated output across all sub-routes.
    function quoteSplitRoute(SwapRouter.SplitRoute calldata splitRoute)
        external
        returns (uint256 estimatedOut)
    {
        uint256 numRoutes = splitRoute.routes.length;
        require(numRoutes > 0, "RouterQuote: empty routes");
        require(numRoutes == splitRoute.weights.length, "RouterQuote: weights mismatch");

        uint256 totalWeight;
        for (uint256 i = 0; i < numRoutes; ) {
            totalWeight += splitRoute.weights[i];
            unchecked { ++i; }
        }
        require(totalWeight == BPS, "RouterQuote: weights must sum to BPS");

        uint256 totalIn = splitRoute.routes[0].amountIn;

        for (uint256 i = 0; i < numRoutes; ) {
            SwapRouter.Route calldata r = splitRoute.routes[i];
            uint256 splitAmt = (totalIn * splitRoute.weights[i]) / BPS;

            uint256 hopOut = splitAmt;
            uint256 hops   = r.path.length;
            for (uint256 j = 0; j < hops - 1; ) {
                address poolAddr = SwapRouter(swapRouter).pools(r.poolIds[j]);
                require(poolAddr != address(0), "RouterQuote: pool not registered");

                (uint256 out,,) =
                    ISwapPool(poolAddr).getSwapQuote(r.poolIds[j], r.path[j], hopOut);
                hopOut = out;

                unchecked { ++j; }
            }
            estimatedOut += hopOut;
            unchecked { ++i; }
        }

        emit QuoteGenerated(msg.sender, estimatedOut, 0, 0);
    }

    // =========================================================================
    // Upgrade
    // =========================================================================

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
