// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStablecoinPools
/// @notice Interface for the stablecoin-optimized multi-chain DEX pool module
interface IStablecoinPools {
    // =========================================================================
    // Structs
    // =========================================================================

    struct StablecoinConfig {
        address token;
        string symbol;
        uint8 decimals;
        bool isSupported;
        uint256 chainId;
    }

    struct PoolInfo {
        address token0;
        address token1;
        uint256 feeBps;          // e.g. 1 = 0.01%, 5 = 0.05%
        bool isStableToStable;
        uint256 reserve0;
        uint256 reserve1;
        uint256 totalLPTokens;
        uint256 concentratedLiquidityMin; // lower price bound (1e18 scale)
        uint256 concentratedLiquidityMax; // upper price bound (1e18 scale)
        bool active;
    }

    struct CrossChainSyncMessage {
        uint32 dstChainId;
        bytes32 poolId;
        uint256 reserve0;
        uint256 reserve1;
        uint256 timestamp;
    }

    // =========================================================================
    // Events
    // =========================================================================

    event StablecoinRegistered(address indexed token, string symbol, uint8 decimals, uint256 chainId);
    event StablecoinDeregistered(address indexed token);
    event PoolCreated(bytes32 indexed poolId, address token0, address token1, uint256 feeBps, bool isStableToStable);
    event LiquidityAdded(bytes32 indexed poolId, address indexed provider, uint256 amount0, uint256 amount1, uint256 lpTokens);
    event LiquidityRemoved(bytes32 indexed poolId, address indexed provider, uint256 amount0, uint256 amount1, uint256 lpTokens);
    event Swapped(bytes32 indexed poolId, address indexed user, address tokenIn, uint256 amountIn, uint256 amountOut, uint256 fee);
    event FeeAdjusted(bytes32 indexed poolId, uint256 oldFeeBps, uint256 newFeeBps, uint256 slippageBps);
    event ConcentratedLiquidityZoneUpdated(bytes32 indexed poolId, uint256 newMin, uint256 newMax);
    event CrossChainSyncSent(bytes32 indexed poolId, uint32 dstChainId, uint256 reserve0, uint256 reserve1);
    event CrossChainSyncReceived(bytes32 indexed poolId, uint32 srcChainId, uint256 reserve0, uint256 reserve1);
    event ReserveAudited(bytes32 indexed poolId, address indexed auditor, uint256 reserve0, uint256 reserve1, uint256 timestamp);

    // =========================================================================
    // Stablecoin Management
    // =========================================================================

    /// @notice Register a supported stablecoin for this chain
    function registerStablecoin(address token, string calldata symbol, uint8 decimals, uint256 chainId) external;

    /// @notice Deregister a stablecoin (emergency/governance)
    function deregisterStablecoin(address token) external;

    /// @notice Check if a token is a registered stablecoin
    function isStablecoin(address token) external view returns (bool);

    /// @notice Get configuration for a registered stablecoin
    function getStablecoinConfig(address token) external view returns (StablecoinConfig memory);

    /// @notice List all registered stablecoin addresses
    function getAllStablecoins() external view returns (address[] memory);

    // =========================================================================
    // Pool Management
    // =========================================================================

    /// @notice Create a new optimized pool for a token pair
    function createPool(
        address token0,
        address token1,
        uint256 feeBps,
        uint256 concentratedLiquidityMin,
        uint256 concentratedLiquidityMax
    ) external returns (bytes32 poolId);

    /// @notice Update the concentrated liquidity zone for a pool
    function updateConcentratedLiquidityZone(bytes32 poolId, uint256 newMin, uint256 newMax) external;

    /// @notice Get pool info
    function getPool(bytes32 poolId) external view returns (PoolInfo memory);

    /// @notice Get pool ID for a token pair
    function getPoolId(address token0, address token1) external pure returns (bytes32);

    // =========================================================================
    // Liquidity
    // =========================================================================

    /// @notice Add liquidity to a pool
    function addLiquidity(bytes32 poolId, uint256 amount0, uint256 amount1, uint256 minLpTokens)
        external
        returns (uint256 lpTokensMinted);

    /// @notice Remove liquidity from a pool
    function removeLiquidity(bytes32 poolId, uint256 lpTokens, uint256 minAmount0, uint256 minAmount1)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Get LP balance for a user in a pool
    function lpBalanceOf(bytes32 poolId, address user) external view returns (uint256);

    // =========================================================================
    // Swapping
    // =========================================================================

    /// @notice Swap tokens in a pool
    function swap(
        bytes32 poolId,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);

    /// @notice Get a quote for a swap without executing it
    function getSwapQuote(bytes32 poolId, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feePaid, uint256 priceImpactBps);

    // =========================================================================
    // Dynamic Fee Adjustment
    // =========================================================================

    /// @notice Trigger dynamic fee recalculation for a pool based on current slippage/volatility
    function adjustFee(bytes32 poolId) external;

    // =========================================================================
    // Reserve Auditing
    // =========================================================================

    /// @notice Emit an audit event recording the current reserves of a pool
    function auditReserves(bytes32 poolId) external;

    // =========================================================================
    // Cross-Chain Sync
    // =========================================================================

    /// @notice Send current pool state to a remote chain via LayerZero
    function syncPoolToChain(bytes32 poolId, uint32 dstChainId, bytes calldata adapterParams)
        external
        payable;

    /// @notice LayerZero receive hook – called by the endpoint on the destination chain
    function lzReceive(
        uint16 srcChainId,
        bytes calldata srcAddress,
        uint64 nonce,
        bytes calldata payload
    ) external;
}
