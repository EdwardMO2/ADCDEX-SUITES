// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./SwapRouter.sol";

/// @title RouterQuote
/// @notice Off-chain-friendly quote engine with secure input validation
contract RouterQuote is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    address public swapRouter;
    uint256 public constant BPS = 10_000;

    event QuoteGenerated(
        address indexed caller,
        uint256 estimatedOut,
        uint256 priceImpactBps,
        uint256 totalFees
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(address _swapRouter, address _owner) public initializer {
        require(_swapRouter != address(0), "RouterQuote: zero router");
        require(_owner != address(0), "RouterQuote: zero owner");

        __Ownable_init();
        _transferOwnership(_owner);
        __UUPSUpgradeable_init();

        swapRouter = _swapRouter;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Estimate output for a single-path route with fee validation
    /// @param route The route to quote
    /// @return estimatedOut Estimated output after all hop fees
    /// @return priceImpactBps Price impact in BPS
    /// @return totalFees Cumulative fee deducted across all hops
    function quoteSwapRoute(SwapRouter.Route calldata route)
        external
        returns (uint256 estimatedOut, uint256 priceImpactBps, uint256 totalFees)
    {
        uint256 hops = route.path.length;
        require(hops >= 2, "RouterQuote: path too short");
        require(route.fees.length == hops - 1, "RouterQuote: fees length mismatch");
        require(route.amountIn > 0, "RouterQuote: zero amountIn");

        // SECURITY: Validate all token addresses are non-zero
        for (uint256 i = 0; i < hops; i++) {
            require(route.path[i] != address(0), "RouterQuote: zero token address");
        }

        // SECURITY: Validate all fees are within acceptable range (0-100%)
        for (uint256 i = 0; i < route.fees.length; i++) {
            require(route.fees[i] <= BPS, "RouterQuote: fee exceeds 100%");
        }

        estimatedOut = route.amountIn;
        for (uint256 i = 0; i < hops - 1; i++) {
            uint256 fee = (estimatedOut * route.fees[i]) / BPS;
            totalFees += fee;
            estimatedOut = estimatedOut - fee;
        }

        priceImpactBps = (totalFees * BPS) / route.amountIn;

        emit QuoteGenerated(msg.sender, estimatedOut, priceImpactBps, totalFees);
    }

    /// @notice Estimate combined output for a split route
    /// @param splitRoute The split route to quote
    /// @return estimatedOut Combined estimated output across all sub-routes
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
            uint256 hops = r.path.length;
            
            // SECURITY: Validate fees in split routes
            for (uint256 j = 0; j < r.fees.length; j++) {
                require(r.fees[j] <= BPS, "RouterQuote: fee exceeds 100% in split route");
            }
            
            for (uint256 j = 0; j < hops - 1; j++) {
                uint256 fee = (hopOut * r.fees[j]) / BPS;
                hopOut = hopOut - fee;
            }
            estimatedOut += hopOut;
        }
    }
}