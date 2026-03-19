// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title ICBDCBridge
/// @notice Interface for the Central Bank Digital Currency bridge contract
interface ICBDCBridge {
    // =========================================================================
    // Structs
    // =========================================================================

    struct CBDCConfig {
        address token;           // address of the CBDC / stablecoin
        address mintAuthority;   // address authorised to mint (central bank)
        address burnAuthority;   // address authorised to burn
        uint256 supplyLimit;     // 0 = unlimited
        uint256 minTxAmount;
        uint256 maxTxAmount;
        uint256 dailyVelocityLimit; // max minted/burned per 24 h (0 = unlimited)
        bool    active;
    }

    struct CentralBankPolicy {
        uint256 exchangeRate;       // token value in USD (1e18 scale)
        uint256 interestRateBps;    // annualised base rate in bps
        bool    transfersEnabled;
        bool    liquidityEnabled;
        uint256 updatedAt;
    }

    struct LiquidityPosition {
        address provider;
        address cbdcToken;
        uint256 amount;
        uint256 depositedAt;
    }

    struct SettlementRequest {
        bytes32 id;
        address cbdcToken;
        address counterparty;
        uint256 amount;
        bool    isMint;  // true = mint to DEX, false = burn from DEX
        bool    executed;
        uint256 createdAt;
    }

    // =========================================================================
    // Events
    // =========================================================================

    event CBDCRegistered(address indexed token, address mintAuthority, uint256 supplyLimit);
    event CBDCDeregistered(address indexed token);
    event PolicyUpdated(address indexed token, uint256 exchangeRate, uint256 interestRateBps, bool transfersEnabled);
    event MintedToDEX(address indexed token, address indexed recipient, uint256 amount);
    event BurnedFromDEX(address indexed token, address indexed from, uint256 amount);
    event LiquidityProvided(address indexed provider, address indexed token, uint256 amount);
    event LiquidityWithdrawn(address indexed provider, address indexed token, uint256 amount);
    event RealTimeSettlementExecuted(bytes32 indexed id, address indexed token, uint256 amount, bool isMint);
    event VelocityLimitBreached(address indexed token, uint256 attempted, uint256 limit);
    event PolicyEnforced(address indexed user, address indexed token, string reason);
    event ComplianceReportSent(address indexed token, uint256 fromTimestamp, uint256 toTimestamp);

    // =========================================================================
    // CBDC Configuration
    // =========================================================================

    /// @notice Register a CBDC / programmable stablecoin
    function registerCBDC(
        address token,
        address mintAuthority,
        address burnAuthority,
        uint256 supplyLimit,
        uint256 minTxAmount,
        uint256 maxTxAmount,
        uint256 dailyVelocityLimit
    ) external;

    /// @notice Deregister a CBDC (emergency governance)
    function deregisterCBDC(address token) external;

    /// @notice Get configuration for a registered CBDC
    function getCBDCConfig(address token) external view returns (CBDCConfig memory);

    // =========================================================================
    // Central Bank Policy Interface
    // =========================================================================

    /// @notice Called by the central bank (or its oracle) to update policy
    function updatePolicy(
        address token,
        uint256 exchangeRate,
        uint256 interestRateBps,
        bool transfersEnabled,
        bool liquidityEnabled
    ) external;

    /// @notice Get the current policy for a CBDC
    function getPolicy(address token) external view returns (CentralBankPolicy memory);

    // =========================================================================
    // Mint / Burn (DEX ↔ Central Bank)
    // =========================================================================

    /// @notice Mint CBDC into the DEX liquidity pool (called by mint authority)
    function mintToDEX(address token, address recipient, uint256 amount) external;

    /// @notice Burn CBDC from the DEX liquidity pool (called by burn authority)
    function burnFromDEX(address token, address from, uint256 amount) external;

    // =========================================================================
    // Liquidity Provision
    // =========================================================================

    /// @notice Provide CBDC liquidity to the DEX
    function provideLiquidity(address token, uint256 amount) external;

    /// @notice Withdraw CBDC liquidity from the DEX
    function withdrawLiquidity(address token, uint256 amount) external;

    /// @notice Get the liquidity position for a provider
    function getLiquidityPosition(address provider, address token)
        external
        view
        returns (LiquidityPosition memory);

    // =========================================================================
    // Real-Time Settlement
    // =========================================================================

    /// @notice Submit a settlement request to be executed with the central bank
    function submitSettlement(
        address cbdcToken,
        address counterparty,
        uint256 amount,
        bool isMint
    ) external returns (bytes32 requestId);

    /// @notice Execute a pending settlement request
    function executeSettlement(bytes32 requestId) external;

    /// @notice Get details of a settlement request
    function getSettlementRequest(bytes32 requestId) external view returns (SettlementRequest memory);

    // =========================================================================
    // Policy Enforcement
    // =========================================================================

    /// @notice Check that a transfer complies with current bank policy; reverts if not
    function enforcePolicy(address user, address token, uint256 amount) external view;

    // =========================================================================
    // Reporting
    // =========================================================================

    /// @notice Generate and emit a compliance report for a CBDC over a time range
    function generateComplianceReport(address token, uint256 fromTimestamp, uint256 toTimestamp) external;
}
