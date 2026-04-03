// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "./Interfaces/ICBDCBridge.sol";

/// @title CBDCBridge
/// @notice Central Bank Digital Currency bridge enabling programmatic
///         stablecoin mint/burn, real-time central-bank settlement,
///         CBDC-to-DEX liquidity provision, and policy enforcement.
///         Designed for central-bank pilot compatibility from day 1.
/// @dev    UUPSUpgradeable – upgrade through governance timelock.
contract CBDCBridge is
    ICBDCBridge,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // =========================================================================
    // Roles
    // =========================================================================

    bytes32 public constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");
    bytes32 public constant CENTRAL_BANK_ROLE  = keccak256("CENTRAL_BANK_ROLE");
    bytes32 public constant MINT_ROLE          = keccak256("MINT_ROLE");
    bytes32 public constant BURN_ROLE          = keccak256("BURN_ROLE");
    bytes32 public constant POLICY_ROLE        = keccak256("POLICY_ROLE");
    bytes32 public constant UPGRADER_ROLE      = keccak256("UPGRADER_ROLE");
    bytes32 public constant AUDITOR_ROLE       = keccak256("AUDITOR_ROLE");

    // =========================================================================
    // State
    // =========================================================================

    address public timelock;

    /// @dev token → CBDC configuration
    mapping(address => CBDCConfig) private _cbdcConfigs;
    address[] private _cbdcList;

    /// @dev token → central bank policy
    mapping(address => CentralBankPolicy) private _policies;

    /// @dev provider → token → liquidity position
    mapping(address => mapping(address => LiquidityPosition)) private _liquidityPositions;
    /// @dev token → total liquidity supplied by all providers
    mapping(address => uint256) private _totalLiquidity;

    /// @dev settlement request id → settlement request
    mapping(bytes32 => SettlementRequest) private _settlements;
    uint256 private _settlementNonce;

    /// @dev token → cumulative amount minted/burned in the current 24 h window
    mapping(address => uint256) private _dailyMinted;
    mapping(address => uint256) private _dailyMintedDate;

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
    // CBDC Configuration
    // =========================================================================

    /// @inheritdoc ICBDCBridge
    function registerCBDC(
        address token,
        address mintAuthority,
        address burnAuthority,
        uint256 supplyLimit,
        uint256 minTxAmount,
        uint256 maxTxAmount,
        uint256 dailyVelocityLimit
    ) external override onlyRole(ADMIN_ROLE) {
        require(token != address(0), "Zero token address");
        require(mintAuthority != address(0), "Zero mint authority");
        require(burnAuthority != address(0), "Zero burn authority");
        require(!_cbdcConfigs[token].active, "CBDC already registered");

        _cbdcConfigs[token] = CBDCConfig({
            token: token,
            mintAuthority: mintAuthority,
            burnAuthority: burnAuthority,
            supplyLimit: supplyLimit,
            minTxAmount: minTxAmount,
            maxTxAmount: maxTxAmount,
            dailyVelocityLimit: dailyVelocityLimit,
            active: true
        });
        _cbdcList.push(token);

        emit CBDCRegistered(token, mintAuthority, supplyLimit);
    }

    /// @inheritdoc ICBDCBridge
    function deregisterCBDC(address token) external override onlyRole(ADMIN_ROLE) {
        require(_cbdcConfigs[token].active, "CBDC not registered");
        _cbdcConfigs[token].active = false;
        emit CBDCDeregistered(token);
    }

    /// @inheritdoc ICBDCBridge
    function getCBDCConfig(address token)
        external
        view
        override
        returns (CBDCConfig memory)
    {
        return _cbdcConfigs[token];
    }

    // =========================================================================
    // Central Bank Policy Interface
    // =========================================================================

    /// @inheritdoc ICBDCBridge
    function updatePolicy(
        address token,
        uint256 exchangeRate,
        uint256 interestRateBps,
        bool transfersEnabled,
        bool liquidityEnabled
    ) external override onlyRole(POLICY_ROLE) {
        require(_cbdcConfigs[token].active, "CBDC not registered");

        _policies[token] = CentralBankPolicy({
            exchangeRate: exchangeRate,
            interestRateBps: interestRateBps,
            transfersEnabled: transfersEnabled,
            liquidityEnabled: liquidityEnabled,
            updatedAt: block.timestamp
        });

        emit PolicyUpdated(token, exchangeRate, interestRateBps, transfersEnabled);
    }

    /// @inheritdoc ICBDCBridge
    function getPolicy(address token)
        external
        view
        override
        returns (CentralBankPolicy memory)
    {
        return _policies[token];
    }

    // =========================================================================
    // Mint / Burn
    // =========================================================================

    /// @inheritdoc ICBDCBridge
    function mintToDEX(
        address token,
        address recipient,
        uint256 amount
    ) external override nonReentrant whenNotPaused {
        CBDCConfig storage cfg = _cbdcConfigs[token];
        CentralBankPolicy storage policy = _policies[token];
        require(cfg.active, "CBDC not registered");
        require(msg.sender == cfg.mintAuthority, "Not mint authority");
        require(policy.transfersEnabled, "Transfers disabled by policy");
        require(amount >= cfg.minTxAmount, "Below min tx amount");
        require(cfg.maxTxAmount == 0 || amount <= cfg.maxTxAmount, "Exceeds max tx amount");
        require(recipient != address(0), "Zero recipient");

        // Velocity check
        _checkAndUpdateDailyLimit(token, cfg.dailyVelocityLimit, amount);

        // Supply limit check
        if (cfg.supplyLimit > 0) {
            uint256 currentSupply = IERC20Upgradeable(token).totalSupply();
            require(currentSupply + amount <= cfg.supplyLimit, "Supply limit exceeded");
        }

        // Transfer from mint authority to recipient (authority must approve first)
        IERC20Upgradeable(token).safeTransferFrom(msg.sender, recipient, amount);

        emit MintedToDEX(token, recipient, amount);
    }

    /// @inheritdoc ICBDCBridge
    function burnFromDEX(
        address token,
        address from,
        uint256 amount
    ) external override nonReentrant whenNotPaused {
        CBDCConfig storage cfg = _cbdcConfigs[token];
        CentralBankPolicy storage policy = _policies[token];
        require(cfg.active, "CBDC not registered");
        require(msg.sender == cfg.burnAuthority, "Not burn authority");
        require(policy.transfersEnabled, "Transfers disabled by policy");
        require(amount >= cfg.minTxAmount, "Below min tx amount");
        require(cfg.maxTxAmount == 0 || amount <= cfg.maxTxAmount, "Exceeds max tx amount");

        // Transfer from DEX back to burn authority
        IERC20Upgradeable(token).safeTransferFrom(from, msg.sender, amount);

        emit BurnedFromDEX(token, from, amount);
    }

    // =========================================================================
    // Liquidity Provision
    // =========================================================================

    /// @inheritdoc ICBDCBridge
    function provideLiquidity(address token, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
    {
        CBDCConfig storage cfg = _cbdcConfigs[token];
        CentralBankPolicy storage policy = _policies[token];
        require(cfg.active, "CBDC not registered");
        require(policy.liquidityEnabled, "Liquidity disabled by policy");
        require(amount > 0, "Zero amount");

        IERC20Upgradeable(token).safeTransferFrom(msg.sender, address(this), amount);

        LiquidityPosition storage pos = _liquidityPositions[msg.sender][token];
        pos.provider = msg.sender;
        pos.cbdcToken = token;
        pos.amount += amount;
        if (pos.depositedAt == 0) pos.depositedAt = block.timestamp;

        _totalLiquidity[token] += amount;

        emit LiquidityProvided(msg.sender, token, amount);
    }

    /// @inheritdoc ICBDCBridge
    function withdrawLiquidity(address token, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
    {
        LiquidityPosition storage pos = _liquidityPositions[msg.sender][token];
        require(pos.amount >= amount, "Insufficient liquidity position");

        pos.amount -= amount;
        _totalLiquidity[token] -= amount;

        IERC20Upgradeable(token).safeTransfer(msg.sender, amount);

        emit LiquidityWithdrawn(msg.sender, token, amount);
    }

    /// @inheritdoc ICBDCBridge
    function getLiquidityPosition(address provider, address token)
        external
        view
        override
        returns (LiquidityPosition memory)
    {
        return _liquidityPositions[provider][token];
    }

    // =========================================================================
    // Real-Time Settlement
    // =========================================================================

    /// @inheritdoc ICBDCBridge
    function submitSettlement(
        address cbdcToken,
        address counterparty,
        uint256 amount,
        bool isMint
    ) external override nonReentrant whenNotPaused returns (bytes32 requestId) {
        require(_cbdcConfigs[cbdcToken].active, "CBDC not registered");
        require(counterparty != address(0), "Zero counterparty");
        require(amount > 0, "Zero amount");

        requestId = keccak256(
            abi.encodePacked(msg.sender, cbdcToken, counterparty, amount, isMint, ++_settlementNonce)
        );

        _settlements[requestId] = SettlementRequest({
            id: requestId,
            cbdcToken: cbdcToken,
            counterparty: counterparty,
            amount: amount,
            isMint: isMint,
            executed: false,
            createdAt: block.timestamp
        });
    }

    /// @inheritdoc ICBDCBridge
    function executeSettlement(bytes32 requestId)
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(CENTRAL_BANK_ROLE)
    {
        SettlementRequest storage req = _settlements[requestId];
        require(!req.executed, "Already executed");

        CBDCConfig storage cfg = _cbdcConfigs[req.cbdcToken];
        require(cfg.active, "CBDC not registered");

        req.executed = true;

        if (req.isMint) {
            // Mint: transfer from mint authority to counterparty
            IERC20Upgradeable(req.cbdcToken).safeTransferFrom(
                cfg.mintAuthority,
                req.counterparty,
                req.amount
            );
        } else {
            // Burn: transfer from counterparty to burn authority
            IERC20Upgradeable(req.cbdcToken).safeTransferFrom(
                req.counterparty,
                cfg.burnAuthority,
                req.amount
            );
        }

        emit RealTimeSettlementExecuted(requestId, req.cbdcToken, req.amount, req.isMint);
    }

    /// @inheritdoc ICBDCBridge
    function getSettlementRequest(bytes32 requestId)
        external
        view
        override
        returns (SettlementRequest memory)
    {
        return _settlements[requestId];
    }

    // =========================================================================
    // Policy Enforcement
    // =========================================================================

    /// @inheritdoc ICBDCBridge
    function enforcePolicy(address user, address token, uint256 amount)
        external
        view
        override
    {
        CentralBankPolicy storage policy = _policies[token];
        require(policy.transfersEnabled, "Transfers disabled by central bank policy");

        CBDCConfig storage cfg = _cbdcConfigs[token];
        require(cfg.active, "CBDC not registered");
        require(amount >= cfg.minTxAmount, "Below minimum transaction amount");
        require(cfg.maxTxAmount == 0 || amount <= cfg.maxTxAmount, "Exceeds maximum transaction amount");

        // Suppress unused variable warning; the check above constitutes policy enforcement.
        // Events cannot be emitted from view functions, so callers should observe the PolicyEnforced
        // event via the non-view wrapper enforceAndLog if an audit log is required.
        user; // acknowledged
    }

    // =========================================================================
    // Reporting
    // =========================================================================

    /// @inheritdoc ICBDCBridge
    function generateComplianceReport(
        address token,
        uint256 fromTimestamp,
        uint256 toTimestamp
    ) external override onlyRole(AUDITOR_ROLE) {
        require(_cbdcConfigs[token].active, "CBDC not registered");
        emit ComplianceReportSent(token, fromTimestamp, toTimestamp);
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

    function _checkAndUpdateDailyLimit(
        address token,
        uint256 limit,
        uint256 amount
    ) internal {
        if (limit == 0) return; // no limit

        uint256 today = block.timestamp / 1 days;
        if (_dailyMintedDate[token] != today) {
            _dailyMinted[token] = 0;
            _dailyMintedDate[token] = today;
        }

        if (_dailyMinted[token] + amount > limit) {
            emit VelocityLimitBreached(token, amount, limit);
            revert("Daily velocity limit exceeded");
        }

        _dailyMinted[token] += amount;
    }
}
