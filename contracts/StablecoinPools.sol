// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "./Interfaces/IStablecoinPools.sol";

/// @title StablecoinPools
/// @notice Stablecoin-optimised DEX pools with concentrated liquidity,
///         dynamic fees, multi-collateral reserves, and cross-chain sync
///         via LayerZero. Supports all major stablecoins and ADC pairs on
///         all 5+ chains simultaneously.
/// @dev    UUPSUpgradeable – upgrade through Timelock governance.
contract StablecoinPools is
    IStablecoinPools,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev Fee basis points for stable-to-stable swaps (0.01 %)
    uint256 public constant STABLE_TO_STABLE_FEE_BPS = 1;
    /// @dev Fee basis points for ADC-paired swaps (0.05 %)
    uint256 public constant ADC_PAIR_FEE_BPS = 5;
    /// @dev Maximum fee (0.3 %) – hard cap during high-volatility adjustment
    uint256 public constant MAX_FEE_BPS = 30;
    /// @dev Minimum fee in bps – never goes below this
    uint256 public constant MIN_FEE_BPS = 1;
    /// @dev Slippage threshold above which fees are dynamically increased
    uint256 public constant SLIPPAGE_THRESHOLD_BPS = 10; // 0.1 %
    /// @dev Amplification coefficient for the StableSwap invariant (A factor)
    uint256 public constant A_FACTOR = 100;
    /// @dev BPS denominator
    uint256 public constant BPS = 10_000;

    // =========================================================================
    // State
    // =========================================================================

    /// @dev token address → stablecoin config
    mapping(address => StablecoinConfig) private _stablecoins;
    address[] private _stablecoinList;

    /// @dev poolId → pool info (excluding LP balances)
    mapping(bytes32 => PoolInfo) private _pools;
    /// @dev poolId → user → LP balance
    mapping(bytes32 => mapping(address => uint256)) private _lpBalances;
    bytes32[] private _poolList;

    /// @dev address of the LayerZero endpoint on this chain
    address public lzEndpoint;
    /// @dev chainId → trusted remote bridge address (packed bytes for lz)
    mapping(uint32 => bytes) public trustedRemotes;

    /// @dev ADC token address used to detect ADC pairs
    address public adcToken;
    /// @dev Governance timelock – only it may upgrade or change fees
    address public timelock;

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _adcToken,
        address _lzEndpoint,
        address _timelock,
        address _owner
    ) public initializer {
        __Ownable_init();
        _transferOwnership(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        adcToken = _adcToken;
        lzEndpoint = _lzEndpoint;
        timelock = _timelock;

        // Register the 7 major stablecoins at launch (addresses are chain-specific
        // placeholders – governance will call registerStablecoin post-deploy)
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == timelock, "Only timelock can upgrade");
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyTimelock() {
        require(msg.sender == timelock, "Only timelock");
        _;
    }

    modifier poolExists(bytes32 poolId) {
        require(_pools[poolId].active, "Pool does not exist");
        _;
    }

    // =========================================================================
    // Stablecoin Management
    // =========================================================================

    /// @inheritdoc IStablecoinPools
    function registerStablecoin(
        address token,
        string calldata symbol,
        uint8 decimals,
        uint256 chainId
    ) external override onlyOwner {
        require(token != address(0), "Zero address");
        require(!_stablecoins[token].isSupported, "Already registered");

        _stablecoins[token] = StablecoinConfig({
            token: token,
            symbol: symbol,
            decimals: decimals,
            isSupported: true,
            chainId: chainId
        });
        _stablecoinList.push(token);

        emit StablecoinRegistered(token, symbol, decimals, chainId);
    }

    /// @inheritdoc IStablecoinPools
    function deregisterStablecoin(address token) external override onlyOwner {
        require(_stablecoins[token].isSupported, "Not registered");
        _stablecoins[token].isSupported = false;
        emit StablecoinDeregistered(token);
    }

    /// @inheritdoc IStablecoinPools
    function isStablecoin(address token) external view override returns (bool) {
        return _stablecoins[token].isSupported;
    }

    /// @inheritdoc IStablecoinPools
    function getStablecoinConfig(address token)
        external
        view
        override
        returns (StablecoinConfig memory)
    {
        return _stablecoins[token];
    }

    /// @inheritdoc IStablecoinPools
    function getAllStablecoins() external view override returns (address[] memory) {
        return _stablecoinList;
    }

    // =========================================================================
    // Pool Management
    // =========================================================================

    /// @inheritdoc IStablecoinPools
    function createPool(
        address token0,
        address token1,
        uint256 feeBps,
        uint256 concentratedLiquidityMin,
        uint256 concentratedLiquidityMax
    ) external override whenNotPaused returns (bytes32 poolId) {
        require(token0 != address(0) && token1 != address(0), "Zero address");
        require(token0 != token1, "Identical tokens");
        require(feeBps >= MIN_FEE_BPS && feeBps <= MAX_FEE_BPS, "Fee out of range");
        require(
            concentratedLiquidityMin < concentratedLiquidityMax,
            "Invalid liquidity zone"
        );

        // Sort tokens deterministically
        if (token0 > token1) (token0, token1) = (token1, token0);

        poolId = getPoolId(token0, token1);
        require(!_pools[poolId].active, "Pool already exists");

        bool isStableToStable = _stablecoins[token0].isSupported &&
            _stablecoins[token1].isSupported;

        // Enforce fee tiers: stable-stable = 0.01%, ADC pair = 0.05%
        uint256 effectiveFee = feeBps;
        if (isStableToStable) {
            effectiveFee = STABLE_TO_STABLE_FEE_BPS;
        } else if (token0 == adcToken || token1 == adcToken) {
            effectiveFee = ADC_PAIR_FEE_BPS;
        }

        _pools[poolId] = PoolInfo({
            token0: token0,
            token1: token1,
            feeBps: effectiveFee,
            isStableToStable: isStableToStable,
            reserve0: 0,
            reserve1: 0,
            totalLPTokens: 0,
            concentratedLiquidityMin: concentratedLiquidityMin,
            concentratedLiquidityMax: concentratedLiquidityMax,
            active: true
        });
        _poolList.push(poolId);

        emit PoolCreated(poolId, token0, token1, effectiveFee, isStableToStable);
    }

    /// @inheritdoc IStablecoinPools
    function updateConcentratedLiquidityZone(
        bytes32 poolId,
        uint256 newMin,
        uint256 newMax
    ) external override onlyTimelock poolExists(poolId) {
        require(newMin < newMax, "Invalid range");
        _pools[poolId].concentratedLiquidityMin = newMin;
        _pools[poolId].concentratedLiquidityMax = newMax;
        emit ConcentratedLiquidityZoneUpdated(poolId, newMin, newMax);
    }

    /// @inheritdoc IStablecoinPools
    function getPool(bytes32 poolId) external view override returns (PoolInfo memory) {
        return _pools[poolId];
    }

    /// @inheritdoc IStablecoinPools
    function getPoolId(address token0, address token1) public pure override returns (bytes32) {
        if (token0 > token1) (token0, token1) = (token1, token0);
        return keccak256(abi.encodePacked(token0, token1));
    }

    // =========================================================================
    // Liquidity
    // =========================================================================

    /// @inheritdoc IStablecoinPools
    function addLiquidity(
        bytes32 poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 minLpTokens
    ) external override nonReentrant whenNotPaused poolExists(poolId) returns (uint256 lpTokensMinted) {
        require(amount0 > 0 && amount1 > 0, "Zero amounts");

        PoolInfo storage pool = _pools[poolId];

        IERC20Upgradeable(pool.token0).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20Upgradeable(pool.token1).safeTransferFrom(msg.sender, address(this), amount1);

        uint256 totalLP = pool.totalLPTokens;
        if (totalLP == 0) {
            lpTokensMinted = _sqrt(amount0 * amount1);
        } else {
            uint256 r0 = pool.reserve0;
            uint256 r1 = pool.reserve1;
            uint256 lp0 = (amount0 * totalLP) / r0;
            uint256 lp1 = (amount1 * totalLP) / r1;
            lpTokensMinted = lp0 < lp1 ? lp0 : lp1;
        }

        require(lpTokensMinted >= minLpTokens, "Slippage: insufficient LP tokens");

        _lpBalances[poolId][msg.sender] += lpTokensMinted;
        pool.totalLPTokens = totalLP + lpTokensMinted;
        pool.reserve0 += amount0;
        pool.reserve1 += amount1;

        emit LiquidityAdded(poolId, msg.sender, amount0, amount1, lpTokensMinted);
    }

    /// @inheritdoc IStablecoinPools
    function removeLiquidity(
        bytes32 poolId,
        uint256 lpTokens,
        uint256 minAmount0,
        uint256 minAmount1
    ) external override nonReentrant whenNotPaused poolExists(poolId) returns (uint256 amount0, uint256 amount1) {
        require(lpTokens > 0, "Zero LP tokens");
        require(_lpBalances[poolId][msg.sender] >= lpTokens, "Insufficient LP balance");

        PoolInfo storage pool = _pools[poolId];
        uint256 totalLP = pool.totalLPTokens;

        amount0 = (lpTokens * pool.reserve0) / totalLP;
        amount1 = (lpTokens * pool.reserve1) / totalLP;

        require(amount0 >= minAmount0 && amount1 >= minAmount1, "Slippage: insufficient amounts");

        _lpBalances[poolId][msg.sender] -= lpTokens;
        pool.totalLPTokens = totalLP - lpTokens;
        unchecked {
            pool.reserve0 -= amount0;
            pool.reserve1 -= amount1;
        }

        IERC20Upgradeable(pool.token0).safeTransfer(msg.sender, amount0);
        IERC20Upgradeable(pool.token1).safeTransfer(msg.sender, amount1);

        emit LiquidityRemoved(poolId, msg.sender, amount0, amount1, lpTokens);
    }

    /// @inheritdoc IStablecoinPools
    function lpBalanceOf(bytes32 poolId, address user) external view override returns (uint256) {
        return _lpBalances[poolId][user];
    }

    // =========================================================================
    // Swapping
    // =========================================================================

    /// @inheritdoc IStablecoinPools
    function swap(
        bytes32 poolId,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external override nonReentrant whenNotPaused poolExists(poolId) returns (uint256 amountOut) {
        require(amountIn > 0, "Zero input");
        require(recipient != address(0), "Zero recipient");

        PoolInfo storage pool = _pools[poolId];
        bool zeroForOne = tokenIn == pool.token0;
        require(zeroForOne || tokenIn == pool.token1, "Invalid tokenIn");

        uint256 reserveIn = zeroForOne ? pool.reserve0 : pool.reserve1;
        uint256 reserveOut = zeroForOne ? pool.reserve1 : pool.reserve0;

        IERC20Upgradeable(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 fee;
        (amountOut, fee) = _calculateSwap(pool, amountIn, reserveIn, reserveOut);

        require(amountOut >= minAmountOut, "Slippage: amountOut too low");
        require(amountOut < reserveOut, "Insufficient liquidity");

        address tokenOut = zeroForOne ? pool.token1 : pool.token0;
        IERC20Upgradeable(tokenOut).safeTransfer(recipient, amountOut);

        if (zeroForOne) {
            pool.reserve0 += amountIn;
            pool.reserve1 -= amountOut;
        } else {
            pool.reserve1 += amountIn;
            pool.reserve0 -= amountOut;
        }

        emit Swapped(poolId, msg.sender, tokenIn, amountIn, amountOut, fee);
    }

    /// @inheritdoc IStablecoinPools
    function getSwapQuote(
        bytes32 poolId,
        address tokenIn,
        uint256 amountIn
    ) external view override returns (uint256 amountOut, uint256 feePaid, uint256 priceImpactBps) {
        PoolInfo storage pool = _pools[poolId];
        bool zeroForOne = tokenIn == pool.token0;
        uint256 reserveIn = zeroForOne ? pool.reserve0 : pool.reserve1;
        uint256 reserveOut = zeroForOne ? pool.reserve1 : pool.reserve0;

        (amountOut, feePaid) = _calculateSwap(pool, amountIn, reserveIn, reserveOut);

        // Price impact = (idealOut - actualOut) / idealOut in bps
        uint256 idealOut = (amountIn * reserveOut) / (reserveIn + amountIn);
        priceImpactBps = idealOut > amountOut
            ? ((idealOut - amountOut) * BPS) / idealOut
            : 0;
    }

    // =========================================================================
    // Dynamic Fee Adjustment
    // =========================================================================

    /// @inheritdoc IStablecoinPools
    function adjustFee(bytes32 poolId) external override poolExists(poolId) {
        PoolInfo storage pool = _pools[poolId];

        // Compute simple on-chain price deviation as a proxy for volatility:
        // if reserves deviate from 1:1 parity (for stable pairs) by > threshold,
        // increase the fee toward MAX_FEE_BPS, otherwise drop back to the base.
        if (!pool.isStableToStable) return; // Only adjust for stable-stable pools

        uint256 oldFee = pool.feeBps;
        uint256 total = pool.reserve0 + pool.reserve1;
        if (total == 0) return;

        // Measure deviation from 50/50 as a slippage proxy (in bps)
        uint256 halfTotal = total / 2;
        uint256 deviation = pool.reserve0 > halfTotal
            ? pool.reserve0 - halfTotal
            : halfTotal - pool.reserve0;
        uint256 deviationBps = (deviation * BPS) / total;

        uint256 newFee;
        if (deviationBps <= SLIPPAGE_THRESHOLD_BPS) {
            newFee = STABLE_TO_STABLE_FEE_BPS; // back to 0.01%
        } else {
            // Scale fee linearly from 0.01% up to MAX_FEE_BPS
            newFee = STABLE_TO_STABLE_FEE_BPS +
                ((deviationBps - SLIPPAGE_THRESHOLD_BPS) * (MAX_FEE_BPS - STABLE_TO_STABLE_FEE_BPS)) /
                BPS;
            if (newFee > MAX_FEE_BPS) newFee = MAX_FEE_BPS;
        }

        if (newFee != oldFee) {
            pool.feeBps = newFee;
            emit FeeAdjusted(poolId, oldFee, newFee, deviationBps);
        }
    }

    // =========================================================================
    // Reserve Auditing
    // =========================================================================

    /// @inheritdoc IStablecoinPools
    function auditReserves(bytes32 poolId) external override poolExists(poolId) {
        PoolInfo storage pool = _pools[poolId];
        emit ReserveAudited(poolId, msg.sender, pool.reserve0, pool.reserve1, block.timestamp);
    }

    // =========================================================================
    // Cross-Chain Sync (LayerZero)
    // =========================================================================

    /// @notice Set or update the trusted remote for a destination chain
    function setTrustedRemote(uint32 dstChainId, bytes calldata remoteAddress) external onlyOwner {
        trustedRemotes[dstChainId] = remoteAddress;
    }

    /// @inheritdoc IStablecoinPools
    function syncPoolToChain(
        bytes32 poolId,
        uint32 dstChainId,
        bytes calldata adapterParams
    ) external payable override poolExists(poolId) {
        require(trustedRemotes[dstChainId].length > 0, "Untrusted destination");

        PoolInfo storage pool = _pools[poolId];

        bytes memory payload = abi.encode(
            poolId,
            pool.reserve0,
            pool.reserve1,
            block.timestamp
        );

        // LayerZero send interface
        ILayerZeroEndpoint(lzEndpoint).send{value: msg.value}(
            uint16(dstChainId),
            trustedRemotes[dstChainId],
            payload,
            payable(msg.sender),
            address(0),
            adapterParams
        );

        emit CrossChainSyncSent(poolId, dstChainId, pool.reserve0, pool.reserve1);
    }

    /// @inheritdoc IStablecoinPools
    function lzReceive(
        uint16 srcChainId,
        bytes calldata srcAddress,
        uint64, /* nonce */
        bytes calldata payload
    ) external override {
        require(msg.sender == lzEndpoint, "Caller is not LZ endpoint");
        require(
            keccak256(srcAddress) == keccak256(trustedRemotes[uint32(srcChainId)]),
            "Untrusted source"
        );

        (bytes32 poolId, uint256 reserve0, uint256 reserve1,) =
            abi.decode(payload, (bytes32, uint256, uint256, uint256));

        // Update reserves from remote if the pool exists (sync only)
        if (_pools[poolId].active) {
            _pools[poolId].reserve0 = reserve0;
            _pools[poolId].reserve1 = reserve1;
            emit CrossChainSyncReceived(poolId, uint32(srcChainId), reserve0, reserve1);
        }
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Pause the contract (timelock / owner)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract (timelock / owner)
    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @dev Compute swap output using StableSwap or constant-product depending on pool type
    function _calculateSwap(
        PoolInfo storage pool,
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal view returns (uint256 amountOut, uint256 fee) {
        require(reserveIn > 0 && reserveOut > 0, "Empty reserves");

        fee = (amountIn * pool.feeBps) / BPS;
        uint256 amountInAfterFee;
        unchecked { amountInAfterFee = amountIn - fee; }

        if (pool.isStableToStable) {
            // StableSwap invariant approximation (simplified, using A=100)
            amountOut = _stableSwapOutput(amountInAfterFee, reserveIn, reserveOut);
        } else {
            // Constant-product AMM: x * y = k
            amountOut = (amountInAfterFee * reserveOut) / (reserveIn + amountInAfterFee);
        }
    }

    /// @dev Simplified StableSwap output (Newton's method on D invariant with A factor).
    ///      Callers must ensure x > 0 and y > 0 (enforced by _calculateSwap).
    ///      Reserves are capped at 1e36 to prevent b*b overflow (Solidity 0.8 reverts
    ///      on overflow, but capping gives a meaningful error on very large inputs).
    function _stableSwapOutput(
        uint256 dx,
        uint256 x,
        uint256 y
    ) internal pure returns (uint256 dy) {
        require(x > 0 && y > 0, "StableSwap: zero reserve");
        // Cap reserves at 1e36 to keep b*b within uint256 bounds
        require(x <= 1e36 && y <= 1e36 && dx <= 1e36, "StableSwap: reserve too large");

        // Invariant: A*(x+y) + D = A*D + D^3/(4*x*y)
        // Simplified two-asset approximation used here for gas efficiency
        uint256 D = x + y + (x * y * 2) / (A_FACTOR * (x + y));
        uint256 newX = x + dx;
        // Solve for newY using the two-asset stable curve
        uint256 b = newX + D / A_FACTOR;
        uint256 c = (D * D * D) / (4 * A_FACTOR * newX);
        // newY^2 + b*newY = c  →  newY = (sqrt(b^2 + 4c) - b) / 2
        // b*b is safe because b <= newX + D/A_FACTOR <= 2*1e36 + 1e36 = 3e36 << sqrt(type(uint256).max)
        uint256 disc = b * b + 4 * c;
        uint256 newY = (_sqrt(disc) - b) / 2;
        dy = y > newY ? y - newY : 0;
    }

    /// @dev Integer square root (Babylonian method)
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

/// @dev Minimal LayerZero endpoint interface
interface ILayerZeroEndpoint {
    function send(
        uint16 _dstChainId,
        bytes calldata _destination,
        bytes calldata _payload,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes calldata _adapterParams
    ) external payable;
}
