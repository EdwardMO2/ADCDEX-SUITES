// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./SwapRouter.sol";

/// @title RouterQuote
/// @notice Off-chain-friendly quote engine.  Returns estimated output, price impact,
///         and total fees for SwapRouter Route and SplitRoute definitions without
///         executing any token transfers.
/// @dev    UUPSUpgradeable – upgrade through governance.
contract RouterQuote is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable
{
    // =========================================================================
    // State
    // =========================================================================

    /// @notice Address of the SwapRouter whose fee logic this contract mirrors.
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

    /// @notice Estimate the output for a single-path route.
    /// @param route          The route to quote.
    /// @return estimatedOut  Estimated output after all hop fees.
    /// @return priceImpactBps Price impact expressed in BPS (simplified: total fees as proxy).
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
        require(route.fees.length == hops - 1, "RouterQuote: fees length mismatch");
        require(route.amountIn > 0, "RouterQuote: zero amountIn");

        // Validate all token addresses in path are non-zero
        for (uint256 i = 0; i < hops; i++) {
            require(route.path[i] != address(0), "RouterQuote: zero token address in path");
        }

        estimatedOut = route.amountIn;
        for (uint256 i = 0; i < hops - 1; i++) {
            require(route.fees[i] <= BPS, "RouterQuote: fee exceeds 100%");
            uint256 fee  = (estimatedOut * route.fees[i]) / BPS;
            totalFees   += fee;
            estimatedOut = estimatedOut - fee;
        }

        priceImpactBps = (totalFees * BPS) / route.amountIn;

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
        for (uint256 i = 0; i < numRoutes; i++) {
            totalWeight += splitRoute.weights[i];
        }
        require(totalWeight == BPS, "RouterQuote: weights must sum to BPS");

        uint256 totalIn = splitRoute.routes[0].amountIn;

        for (uint256 i = 0; i < numRoutes; i++) {
            SwapRouter.Route memory r = splitRoute.routes[i];
            uint256 splitAmt = (totalIn * splitRoute.weights[i]) / BPS;

            uint256 hopOut = splitAmt;
            uint256 hops   = r.path.length;
            for (uint256 j = 0; j < hops - 1; j++) {
                require(r.fees[j] <= BPS, "RouterQuote: fee exceeds 100%");
                uint256 fee = (hopOut * r.fees[j]) / BPS;
                hopOut      = hopOut - fee;
            }
            estimatedOut += hopOut;
        }

        emit QuoteGenerated(msg.sender, estimatedOut, 0, 0);
    }

    // =========================================================================
    // Upgrade
    // =========================================================================

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
