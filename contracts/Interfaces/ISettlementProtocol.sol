// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISettlementProtocol
/// @notice Interface for the Global Settlement Protocol
interface ISettlementProtocol {
    // =========================================================================
    // Structs
    // =========================================================================

    struct CurrencyConfig {
        address token;
        string isoCode;  // e.g. "USD", "EUR", "GBP", "CNY", "JPY"
        uint256 sdrWeight; // weight in the SDR basket (1e18 scale)
        bool active;
    }

    struct Settlement {
        bytes32 id;
        address initiator;
        address counterparty;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        uint32  dstChainId;   // 0 = same chain
        SettlementStatus status;
        uint256 createdAt;
        uint256 settledAt;
        bytes   complianceData;
    }

    enum SettlementStatus {
        Pending,
        Completed,
        Disputed,
        Resolved,
        Cancelled
    }

    struct NetPosition {
        address token;
        int256 amount; // positive = owed to us, negative = we owe
    }

    struct SDRBasket {
        address[] tokens;
        uint256[] weights; // must sum to 1e18
        uint256   totalValue; // in USD-equivalent (1e18 scale)
        uint256   lastRebalanced;
    }

    // =========================================================================
    // Events
    // =========================================================================

    event CurrencyRegistered(address indexed token, string isoCode, uint256 sdrWeight);
    event SettlementInitiated(bytes32 indexed id, address indexed initiator, address tokenIn, address tokenOut, uint256 amountIn);
    event SettlementCompleted(bytes32 indexed id, uint256 amountOut, uint256 settledAt);
    event SettlementDisputed(bytes32 indexed id, address indexed disputant, string reason);
    event SettlementResolved(bytes32 indexed id, uint256 resolution);
    event SettlementCancelled(bytes32 indexed id);
    event NetPositionUpdated(address indexed party, address indexed token, int256 newPosition);
    event SDRBasketRebalanced(uint256 totalValue, uint256 timestamp);
    event CrossChainSettlementSent(bytes32 indexed id, uint32 dstChainId);
    event CrossChainSettlementReceived(bytes32 indexed id, uint32 srcChainId);
    event AuditTrailRecorded(bytes32 indexed settlementId, address indexed actor, string action, uint256 timestamp);
    event ComplianceHookCalled(bytes32 indexed settlementId, address indexed hook, bool passed);

    // =========================================================================
    // Currency Management
    // =========================================================================

    /// @notice Register a currency token for settlement
    function registerCurrency(address token, string calldata isoCode, uint256 sdrWeight) external;

    /// @notice Get config for a registered currency
    function getCurrencyConfig(address token) external view returns (CurrencyConfig memory);

    /// @notice List all registered currency tokens
    function getAllCurrencies() external view returns (address[] memory);

    // =========================================================================
    // Settlement Lifecycle
    // =========================================================================

    /// @notice Initiate a new settlement (same-chain or cross-chain)
    function initiateSettlement(
        address counterparty,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint32  dstChainId,
        bytes calldata complianceData
    ) external returns (bytes32 settlementId);

    /// @notice Execute a pending settlement atomically
    function executeSettlement(bytes32 settlementId) external returns (uint256 amountOut);

    /// @notice Cancel an unexecuted settlement
    function cancelSettlement(bytes32 settlementId) external;

    /// @notice Get details of a settlement
    function getSettlement(bytes32 settlementId) external view returns (Settlement memory);

    // =========================================================================
    // Netting Engine
    // =========================================================================

    /// @notice Submit a bilateral position to the netting engine
    function submitNetPosition(address counterparty, address token, int256 amount) external;

    /// @notice Net bilateral positions and settle remaining balance
    function netAndSettle(address counterparty, address[] calldata tokens) external;

    /// @notice Get current net position with a counterparty for a token
    function getNetPosition(address party, address counterparty, address token) external view returns (int256);

    // =========================================================================
    // SDR Basket
    // =========================================================================

    /// @notice Rebalance the SDR basket according to configured weights
    function rebalanceSDR() external;

    /// @notice Get current SDR basket composition
    function getSDRBasket() external view returns (SDRBasket memory);

    /// @notice Get the current USD-equivalent value of the SDR basket
    function getSDRValue() external view returns (uint256);

    // =========================================================================
    // Compliance
    // =========================================================================

    /// @notice Register a compliance hook contract to be called on every settlement
    function addComplianceHook(address hook) external;

    /// @notice Remove a compliance hook
    function removeComplianceHook(address hook) external;

    // =========================================================================
    // Audit Trail
    // =========================================================================

    /// @notice Retrieve the full audit log for a settlement
    function getAuditTrail(bytes32 settlementId) external view returns (string[] memory actions, uint256[] memory timestamps);

    // =========================================================================
    // Dispute Resolution
    // =========================================================================

    /// @notice Raise a dispute for a completed settlement
    function raiseDispute(bytes32 settlementId, string calldata reason) external;

    /// @notice Resolve a disputed settlement (governance/admin)
    function resolveDispute(bytes32 settlementId, uint256 resolution) external;

    // =========================================================================
    // Cross-Chain
    // =========================================================================

    /// @notice LayerZero receive hook for cross-chain settlement messages
    function lzReceive(
        uint16 srcChainId,
        bytes calldata srcAddress,
        uint64 nonce,
        bytes calldata payload
    ) external;
}
