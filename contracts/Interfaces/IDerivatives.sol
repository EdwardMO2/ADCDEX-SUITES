// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDerivatives
/// @notice Interface for perpetuals / derivatives market contracts.
interface IDerivatives {
    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Represents an open perpetual position.
    struct Position {
        address owner;
        address token;
        uint256 collateral;
        uint256 size;
        uint8   leverage;
        bool    isLong;
        uint256 entryPrice;
        uint256 liquidationPrice;
        uint256 lastFundingTime;
        uint256 fundingAccrued;
    }

    // =========================================================================
    // Events
    // =========================================================================

    event PositionOpened(
        bytes32 indexed positionId,
        address indexed owner,
        address indexed token,
        uint256 collateral,
        uint256 size,
        uint8   leverage,
        bool    isLong,
        uint256 entryPrice,
        uint256 liquidationPrice
    );

    event PositionClosed(
        bytes32 indexed positionId,
        address indexed owner,
        int256  pnl,
        uint256 collateralReturned
    );

    event PositionLiquidated(
        bytes32 indexed positionId,
        address indexed owner,
        address indexed liquidator,
        uint256 liquidatorReward
    );

    event FundingRateUpdated(
        address indexed token,
        uint256 newRate
    );

    // =========================================================================
    // Functions
    // =========================================================================

    /// @notice Open a perpetual position.
    /// @param token      Underlying asset token address.
    /// @param collateral Amount of collateral token to deposit.
    /// @param leverage   Leverage multiplier (1–10).
    /// @param isLong     True for long, false for short.
    /// @return positionId Unique identifier of the newly created position.
    function openPosition(
        address token,
        uint256 collateral,
        uint8   leverage,
        bool    isLong
    ) external returns (bytes32 positionId);

    /// @notice Close an open position and settle PnL.
    /// @param positionId The position to close.
    function closePosition(bytes32 positionId) external;

    /// @notice Liquidate an under-collateralised position.
    /// @param positionId The position to liquidate.
    function liquidatePosition(bytes32 positionId) external;

    /// @notice Update the funding rate for a token market.
    /// @param token The token whose funding rate is being updated.
    /// @param rate  New funding rate (scaled by PRECISION).
    function updateFundingRate(address token, uint256 rate) external;
}
