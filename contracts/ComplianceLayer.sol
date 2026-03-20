// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "./Interfaces/ICompliance.sol";

/// @title ComplianceLayer
/// @notice KYC/AML compliance module with role-based access control,
///         transaction screening, sanctions list, account freezing,
///         and regulatory reporting. Designed for institutional and
///         government-grade DeFi compliance from day 1.
/// @dev    UUPSUpgradeable – upgrade through Timelock governance.
contract ComplianceLayer is
    ICompliance,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // =========================================================================
    // Roles
    // =========================================================================

    bytes32 public constant ADMIN_ROLE       = keccak256("ADMIN_ROLE");
    bytes32 public constant KYC_OFFICER_ROLE = keccak256("KYC_OFFICER_ROLE");
    bytes32 public constant AML_OFFICER_ROLE = keccak256("AML_OFFICER_ROLE");
    bytes32 public constant AUDITOR_ROLE     = keccak256("AUDITOR_ROLE");
    bytes32 public constant UPGRADER_ROLE    = keccak256("UPGRADER_ROLE");

    // =========================================================================
    // State
    // =========================================================================

    /// @dev user → compliance record
    mapping(address => UserRecord) private _records;

    /// @dev sanctions list
    mapping(address => bool) private _sanctioned;

    /// @dev compliance rules
    mapping(bytes32 => ComplianceRule) private _rules;
    bytes32[] private _ruleIds;

    /// @dev Aggregate counters for reporting
    uint256 private _totalTransactions;
    uint256 private _totalVolume;
    uint256 private _blockedTransactions;
    uint256 private _frozenAccounts;

    /// @dev compliance event log (user → events)
    mapping(address => string[]) private _eventLog;
    mapping(address => uint256[]) private _eventTimestamps;

    address public timelock;

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _timelock, address _admin) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        timelock = _timelock;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _timelock);
    }

    function _authorizeUpgrade(address) internal view override {
        require(hasRole(UPGRADER_ROLE, msg.sender), "Only upgrader");
    }

    // =========================================================================
    // User Management
    // =========================================================================

    /// @inheritdoc ICompliance
    function onboardUser(
        address user,
        KYCStatus initialStatus,
        string calldata provider,
        uint256 kycExpiry
    ) external override onlyRole(KYC_OFFICER_ROLE) {
        require(user != address(0), "Zero address");
        require(_records[user].kycStatus == KYCStatus.NotSubmitted, "Already onboarded");

        _records[user] = UserRecord({
            kycStatus: initialStatus,
            riskLevel: RiskLevel.Low,
            frozen: false,
            kycExpiry: kycExpiry,
            dailyVolumeUsed: 0,
            lastActivityDate: block.timestamp,
            kycProvider: provider
        });

        _logEvent(user, "Onboarded");
        emit UserOnboarded(user, initialStatus, provider);
    }

    /// @inheritdoc ICompliance
    function updateKYCStatus(
        address user,
        KYCStatus newStatus,
        string calldata provider,
        uint256 kycExpiry
    ) external override onlyRole(KYC_OFFICER_ROLE) {
        KYCStatus old = _records[user].kycStatus;
        _records[user].kycStatus = newStatus;
        _records[user].kycProvider = provider;
        _records[user].kycExpiry = kycExpiry;

        _logEvent(user, "KYCUpdated");
        emit KYCStatusUpdated(user, old, newStatus, msg.sender);
    }

    /// @inheritdoc ICompliance
    function updateRiskLevel(address user, RiskLevel newLevel)
        external
        override
        onlyRole(AML_OFFICER_ROLE)
    {
        RiskLevel old = _records[user].riskLevel;
        _records[user].riskLevel = newLevel;

        _logEvent(user, "RiskLevelUpdated");
        emit RiskLevelUpdated(user, old, newLevel, msg.sender);
    }

    /// @inheritdoc ICompliance
    function getUserRecord(address user)
        external
        view
        override
        returns (UserRecord memory)
    {
        return _records[user];
    }

    // =========================================================================
    // Account Controls
    // =========================================================================

    /// @inheritdoc ICompliance
    function freezeAccount(address user, string calldata reason)
        external
        override
        onlyRole(AML_OFFICER_ROLE)
    {
        require(!_records[user].frozen, "Already frozen");
        _records[user].frozen = true;
        _frozenAccounts++;

        _logEvent(user, string(abi.encodePacked("Frozen: ", reason)));
        emit AccountFrozen(user, msg.sender, reason);
    }

    /// @inheritdoc ICompliance
    function unfreezeAccount(address user, string calldata reason)
        external
        override
        onlyRole(AML_OFFICER_ROLE)
    {
        require(_records[user].frozen, "Not frozen");
        _records[user].frozen = false;
        if (_frozenAccounts > 0) _frozenAccounts--;

        _logEvent(user, string(abi.encodePacked("Unfrozen: ", reason)));
        emit AccountUnfrozen(user, msg.sender, reason);
    }

    /// @inheritdoc ICompliance
    function isFrozen(address user) external view override returns (bool) {
        return _records[user].frozen;
    }

    // =========================================================================
    // Transaction Screening
    // =========================================================================

    /// @inheritdoc ICompliance
    function screenTransaction(
        address user,
        uint256 amount,
        bytes32 txRef
    ) external override nonReentrant whenNotPaused returns (bool approved) {
        (approved, ) = _screen(user, amount);

        if (!approved) {
            _blockedTransactions++;
            _logEvent(user, "TxBlocked");
            emit TransactionBlocked(user, txRef, "Compliance check failed");
        } else {
            _totalTransactions++;
            _totalVolume += amount;

            // Reset daily volume if new day
            UserRecord storage rec = _records[user];
            if (block.timestamp / 1 days > rec.lastActivityDate / 1 days) {
                rec.dailyVolumeUsed = 0;
            }
            rec.dailyVolumeUsed += amount;
            rec.lastActivityDate = block.timestamp;

            emit TransactionApproved(user, txRef, amount);
        }
    }

    /// @inheritdoc ICompliance
    function previewScreen(address user, uint256 amount)
        external
        view
        override
        returns (bool approved, string memory reason)
    {
        return _screen(user, amount);
    }

    // =========================================================================
    // Sanctions
    // =========================================================================

    /// @inheritdoc ICompliance
    function setSanctioned(address account, bool sanctioned)
        external
        override
        onlyRole(AML_OFFICER_ROLE)
    {
        _sanctioned[account] = sanctioned;
        emit SanctionsListUpdated(account, sanctioned);
    }

    /// @inheritdoc ICompliance
    function isSanctioned(address account) external view override returns (bool) {
        return _sanctioned[account];
    }

    // =========================================================================
    // Rules
    // =========================================================================

    /// @inheritdoc ICompliance
    function addRule(ComplianceRule calldata rule) external override onlyRole(ADMIN_ROLE) {
        require(!_rules[rule.id].active, "Rule already exists");
        _rules[rule.id] = rule;
        _ruleIds.push(rule.id);
        emit ComplianceRuleAdded(rule.id, rule.name);
    }

    /// @inheritdoc ICompliance
    function updateRule(ComplianceRule calldata rule) external override onlyRole(ADMIN_ROLE) {
        require(_rules[rule.id].active || _ruleExists(rule.id), "Rule not found");
        _rules[rule.id] = rule;
        emit ComplianceRuleUpdated(rule.id);
    }

    /// @inheritdoc ICompliance
    function removeRule(bytes32 ruleId) external override onlyRole(ADMIN_ROLE) {
        require(_ruleExists(ruleId), "Rule not found");
        delete _rules[ruleId];
        for (uint256 i = 0; i < _ruleIds.length; i++) {
            if (_ruleIds[i] == ruleId) {
                _ruleIds[i] = _ruleIds[_ruleIds.length - 1];
                _ruleIds.pop();
                break;
            }
        }
        emit ComplianceRuleRemoved(ruleId);
    }

    // =========================================================================
    // Reporting
    // =========================================================================

    /// @inheritdoc ICompliance
    function generateReport(uint256 fromTimestamp, uint256 toTimestamp)
        external
        override
        onlyRole(AUDITOR_ROLE)
        returns (ComplianceReport memory report)
    {
        report = ComplianceReport({
            fromTimestamp: fromTimestamp,
            toTimestamp: toTimestamp,
            totalTransactions: _totalTransactions,
            totalVolume: _totalVolume,
            blockedTransactions: _blockedTransactions,
            frozenAccounts: _frozenAccounts,
            regulatorData: abi.encode(_totalTransactions, _totalVolume, _blockedTransactions, _frozenAccounts)
        });

        emit RegulatoryReportGenerated(fromTimestamp, toTimestamp, msg.sender);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    function _screen(address user, uint256 amount)
        internal
        view
        returns (bool approved, string memory reason)
    {
        if (_sanctioned[user]) return (false, "Sanctioned address");
        if (_records[user].frozen) return (false, "Account frozen");

        UserRecord storage rec = _records[user];
        if (rec.kycStatus != KYCStatus.Approved) return (false, "KYC not approved");
        if (rec.kycExpiry > 0 && block.timestamp > rec.kycExpiry) return (false, "KYC expired");
        if (rec.riskLevel == RiskLevel.Blocked) return (false, "High-risk account blocked");

        // Check active compliance rules
        for (uint256 i = 0; i < _ruleIds.length; i++) {
            ComplianceRule storage rule = _rules[_ruleIds[i]];
            if (!rule.active) continue;

            if (rule.maxTxAmount > 0 && amount > rule.maxTxAmount)
                return (false, "Exceeds max transaction limit");

            uint256 dailyUsed = rec.dailyVolumeUsed;
            if (block.timestamp / 1 days > rec.lastActivityDate / 1 days) dailyUsed = 0;
            if (rule.maxDailyVolume > 0 && dailyUsed + amount > rule.maxDailyVolume)
                return (false, "Exceeds daily volume limit");

            if (uint8(rec.riskLevel) > uint8(rule.minRiskLevel))
                return (false, "Risk level too high for rule");
        }

        return (true, "");
    }

    function _logEvent(address user, string memory eventType) internal {
        _eventLog[user].push(eventType);
        _eventTimestamps[user].push(block.timestamp);
        emit ComplianceEventLogged(user, eventType, bytes32(0), block.timestamp);
    }

    function _ruleExists(bytes32 ruleId) internal view returns (bool) {
        for (uint256 i = 0; i < _ruleIds.length; i++) {
            if (_ruleIds[i] == ruleId) return true;
        }
        return false;
    }
}
