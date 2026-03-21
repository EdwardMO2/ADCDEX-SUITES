// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ADCDEX
/// @notice Abstract base contract defining the ADCDEX DEX interface.
/// @dev    Root-level file moved to contracts/legacy/.
abstract contract ADCDEX {
    mapping(address => bool) public hasVoted;

    function createPool(address baseToken, address quoteToken, uint256 fee)
        external
        virtual
        returns (bytes32 poolId);

    function removeLiquidity(bytes32 poolId, uint256 lpAmount)
        external
        virtual
        returns (uint256 removedAmount);

    function swap(bytes32 poolId, address tokenIn, uint256 amountIn, uint256 minAmountOut)
        external
        virtual
        returns (uint256 swapResult);

    function addLiquidity(
        bytes32 poolId,
        uint256 amount,
        uint256 baseAmount,
        uint256 quoteAmount
    ) external virtual;

    function vote(bytes32 proposalId) external virtual;
}
