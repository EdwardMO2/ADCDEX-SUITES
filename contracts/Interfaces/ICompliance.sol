// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title ICompliance
/// @notice Interface for the KYC/AML compliance layer
interface ICompliance {
    // =========================================================================
    // Enums & Structs
    // =========================================================================

    enum KYCStatus {
        NotSubmitted,
        Pending,
        Approved,
        Rejected,
        Expired
    }

    enum RiskLevel {
        Low,
        Medium,
        High,
        Blocked
    }

    struct UserRecord {
        KYCStatus kycStatus;
        RiskLevel riskLevel;
        bool frozen;
        uint256 kycExpiry;
        uint256 dailyVolumeUsed;
        uint256 lastActivityDate;
        string kycProvider;
    }

    struct ComplianceRule {
        bytes32 id;
        string name;
        uint256 maxDailyVolume;    // 0 = no limit
        uint256 maxTxAmount;       // 0 = no limit
        RiskLevel minRiskLevel;    // users above this level are blocked
        bool requiresKYC;
        bool active;
    }

    struct ComplianceReport {
        uint256 fromTimestamp;
        uint256 toTimestamp;
        uint256 totalTransactions;
        uint256 totalVolume;
        uint256 blockedTransactions;
        uint256 frozenAccounts;
        bytes   regulatorData;     // ABI-encoded additional data for regulator
    }

    // =========================================================================
    // Events
    // =========================================================================

    event UserOnboarded(address indexed user, KYCStatus status, string provider);
    event KYCStatusUpdated(address indexed user, KYCStatus oldStatus, KYCStatus newStatus, address indexed officer);
    event RiskLevelUpdated(address indexed user, RiskLevel oldLevel, RiskLevel newLevel, address indexed officer);
    event AccountFrozen(address indexed user, address indexed officer, string reason);
    event AccountUnfrozen(address indexed user, address indexed officer, string reason);
    event TransactionBlocked(address indexed user, bytes32 indexed txRef, string reason);
    event TransactionApproved(address indexed user, bytes32 indexed txRef, uint256 amount);
    event ComplianceRuleAdded(bytes32 indexed ruleId, string name);
    event ComplianceRuleUpdated(bytes32 indexed ruleId);
    event ComplianceRuleRemoved(bytes32 indexed ruleId);
    event RegulatoryReportGenerated(uint256 fromTimestamp, uint256 toTimestamp, address indexed requestedBy);
    event ComplianceEventLogged(address indexed user, string eventType, bytes32 indexed ref, uint256 timestamp);
    event SanctionsListUpdated(address indexed account, bool isSanctioned);

    // =========================================================================
    // User Management
    // =========================================================================

    /// @notice Onboard a new user with initial KYC status
    function onboardUser(address user, KYCStatus initialStatus, string calldata provider, uint256 kycExpiry) external;

    /// @notice Update a user's KYC status
    function updateKYCStatus(address user, KYCStatus newStatus, string calldata provider, uint256 kycExpiry) external;

    /// @notice Update a user's AML risk level
    function updateRiskLevel(address user, RiskLevel newLevel) external;

    /// @notice Get the full compliance record for a user
    function getUserRecord(address user) external view returns (UserRecord memory);

    // =========================================================================
    // Account Controls
    // =========================================================================

    /// @notice Freeze a user account (emergency / AML)
    function freezeAccount(address user, string calldata reason) external;

    /// @notice Unfreeze a previously frozen account
    function unfreezeAccount(address user, string calldata reason) external;

    /// @notice Check if an account is currently frozen
    function isFrozen(address user) external view returns (bool);

    // =========================================================================
    // Transaction Screening
    // =========================================================================

    /// @notice Screen a transaction; reverts or returns false if blocked
    function screenTransaction(address user, uint256 amount, bytes32 txRef)
        external
        returns (bool approved);

    /// @notice Check whether a transaction would pass screening without state changes
    function previewScreen(address user, uint256 amount)
        external
        view
        returns (bool approved, string memory reason);

    // =========================================================================
    // Sanctions
    // =========================================================================

    /// @notice Add or remove an address from the internal sanctions list
    function setSanctioned(address account, bool isSanctioned) external;

    /// @notice Check if an address is on the sanctions list
    function isSanctioned(address account) external view returns (bool);

    // =========================================================================
    // Rules
    // =========================================================================

    /// @notice Add a new compliance rule
    function addRule(ComplianceRule calldata rule) external;

    /// @notice Update an existing compliance rule
    function updateRule(ComplianceRule calldata rule) external;

    /// @notice Remove a compliance rule
    function removeRule(bytes32 ruleId) external;

    // =========================================================================
    // Reporting
    // =========================================================================

    /// @notice Generate a regulatory compliance report for a given time range
    function generateReport(uint256 fromTimestamp, uint256 toTimestamp)
        external
        returns (ComplianceReport memory report);
}
