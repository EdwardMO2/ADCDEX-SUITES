// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISwapPool
/// @notice Minimal pool interface that any pool contract must implement to be
///         usable by the SwapRouter.  StablecoinPools already satisfies this.
interface ISwapPool {
    /// @notice Execute a swap through the pool.
    /// @param poolId       Internal pool identifier.
    /// @param tokenIn      Address of the input token.
    /// @param amountIn     Amount of tokenIn to swap.
    /// @param minAmountOut Minimum acceptable output (slippage guard).
    /// @param recipient    Address that receives the output tokens.
    /// @return amountOut   Actual amount of output tokens delivered.
    function swap(
        bytes32 poolId,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);

    /// @notice Return a quote for a swap without executing it.
    /// @param poolId       Internal pool identifier.
    /// @param tokenIn      Address of the input token.
    /// @param amountIn     Amount of tokenIn.
    /// @return amountOut       Expected output amount.
    /// @return feePaid         Fee deducted by the pool.
    /// @return priceImpactBps  Price impact in basis points.
    function getSwapQuote(
        bytes32 poolId,
        address tokenIn,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 feePaid, uint256 priceImpactBps);
}
