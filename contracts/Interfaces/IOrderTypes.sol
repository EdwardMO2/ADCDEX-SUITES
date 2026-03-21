// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IOrderTypes
/// @author ADCDEX
/// @notice Shared types, events, and errors for the advanced order-book system.
interface IOrderTypes {
    // =========================================================================
    //                               ENUMS
    // =========================================================================

    /// @notice Supported order variants.
    enum OrderType {
        LIMIT,
        STOP_LOSS,
        TAKE_PROFIT,
        TRAILING_STOP
    }

    // =========================================================================
    //                              STRUCTS
    // =========================================================================

    /// @notice Represents a single advanced order.
    /// @param orderId      Monotonically increasing identifier.
    /// @param owner        Address that placed the order and owns the escrowed tokens.
    /// @param tokenIn      Token deposited as the order collateral.
    /// @param tokenOut     Token the user wants to receive on execution.
    /// @param amountIn     Amount of `tokenIn` escrowed.
    /// @param triggerPrice Oracle price at which the order activates.
    /// @param limitPrice   Worst acceptable execution price (used by LIMIT orders).
    /// @param orderType    Variant of this order.
    /// @param expiry       Unix timestamp after which the order can no longer execute.
    /// @param active       Whether the order is still open.
    /// @param isLong       Direction flag (true = long / buy, false = short / sell).
    struct Order {
        uint256 orderId;
        address owner;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 triggerPrice;
        uint256 limitPrice;
        OrderType orderType;
        uint256 expiry;
        bool active;
        bool isLong;
    }

    // =========================================================================
    //                               EVENTS
    // =========================================================================

    /// @notice Emitted when a new order is placed.
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed owner,
        OrderType orderType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 triggerPrice,
        uint256 limitPrice,
        uint256 expiry
    );

    /// @notice Emitted when a keeper successfully executes an order.
    event OrderExecuted(
        uint256 indexed orderId,
        address indexed owner,
        uint256 executionPrice
    );

    /// @notice Emitted when the order owner cancels an order.
    event OrderCancelled(uint256 indexed orderId, address indexed owner);

    /// @notice Emitted when an expired order is cleaned up.
    event OrderExpired(uint256 indexed orderId, address indexed owner);

    // =========================================================================
    //                          CUSTOM ERRORS
    // =========================================================================

    /// @notice Order ID does not exist.
    error OrderNotFound(uint256 orderId);

    /// @notice Order's expiry timestamp has passed.
    error OrderExpiredError(uint256 orderId);

    /// @notice Order was already cancelled.
    error OrderAlreadyCancelled(uint256 orderId);

    /// @notice Caller is not authorised to perform the action.
    error Unauthorized(address caller);

    /// @notice Market price does not satisfy the order's trigger condition.
    error TriggerNotMet(uint256 orderId, uint256 currentPrice, uint256 triggerPrice);
}
