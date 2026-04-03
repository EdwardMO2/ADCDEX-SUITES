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
    /// @dev Default amplification coefficient for the StableSwap invariant
    uint256 public constant DEFAULT_A_FACTOR = 100;
    /// @dev BPS denominator
    uint256 public constant BPS = 10_000;
    /// @dev TWAP ring buffer size
    uint256 public constant TWAP_BUFFER_SIZE = 24;
    /// @dev Internal precision for decimal normalization (18 decimals)
    uint256 public constant PRECISION = 1e18;
    /// @dev Maximum reserve change ratio per cross-chain sync (200% = 2x)
    uint256 public constant MAX_RESERVE_CHANGE_BPS = 20_000;

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
    /// @dev chainId → last processed nonce for replay protection
    mapping(uint32 => uint64) public lastProcessedNonce;

    /// @dev ADC token address used to detect ADC pairs
    address public adcToken;
    /// @dev Governance timelock – only it may upgrade or change fees
    address public timelock;
    /// @dev Governance-configurable amplification factor for StableSwap
    uint256 public aFactor;
    /// @dev Chainlink oracle for ADC price validation
    address public adcPriceFeed;

    // =========================================================================
    // Fee Accounting (P1-3: separate fees from reserves)
    // =========================================================================

    /// @dev poolId → accumulated fees for token0
    mapping(bytes32 => uint256) public accumulatedFees0;
    /// @dev poolId → accumulated fees for token1
    mapping(bytes32 => uint256) public accumulatedFees1;

    // =========================================================================
    // TWAP Ring Buffer (P1-1)
    // =========================================================================

    struct TWAPObservation {
        uint256 timestamp;
        uint256 price0Cumulative;  // reserve1/reserve0 * PRECISION cumulative
        uint256 price1Cumulative;  // reserve0/reserve1 * PRECISION cumulative
    }

    /// @dev poolId → TWAP observations ring buffer
    mapping(bytes32 => TWAPObservation[TWAP_BUFFER_SIZE]) public twapObservations;
    /// @dev poolId → current write index in TWAP ring buffer
    mapping(bytes32 => uint256) public twapIndex;
    /// @dev poolId → number of observations written (caps at TWAP_BUFFER_SIZE)
    mapping(bytes32 => uint256) public twapCount;

    // =========================================================================
    // Token Pair Index (P2-2)
    // =========================================================================

    /// @dev tokenPairHash → poolId for route discovery
    mapping(bytes32 => bytes32) public pairToPoolId;

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
        aFactor = DEFAULT_A_FACTOR;

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
        // Index pool by token pair for route discovery (P2-2)
        pairToPoolId[poolId] = poolId;

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

        // Decimal normalization: normalize amounts to 18 decimals for calculations
        uint8 decimalsIn = _getTokenDecimals(tokenIn);
        address tokenOut = zeroForOne ? pool.token1 : pool.token0;
        uint8 decimalsOut = _getTokenDecimals(tokenOut);

        uint256 reserveIn = zeroForOne ? pool.reserve0 : pool.reserve1;
        uint256 reserveOut = zeroForOne ? pool.reserve1 : pool.reserve0;

        IERC20Upgradeable(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Normalize to 18 decimals for swap calculation
        uint256 normalizedAmountIn = _normalize(amountIn, decimalsIn);
        uint256 normalizedReserveIn = _normalize(reserveIn, decimalsIn);
        uint256 normalizedReserveOut = _normalize(reserveOut, decimalsOut);

        uint256 normalizedFee;
        uint256 normalizedAmountOut;
        (normalizedAmountOut, normalizedFee) = _calculateSwap(
            pool, normalizedAmountIn, normalizedReserveIn, normalizedReserveOut
        );

        // Denormalize back to native token decimals
        amountOut = _denormalize(normalizedAmountOut, decimalsOut);
        uint256 fee = _denormalize(normalizedFee, decimalsIn);

        // Oracle price validation for ADC pairs (P0-4)
        if (adcPriceFeed != address(0) && (pool.token0 == adcToken || pool.token1 == adcToken)) {
            _validateSwapPrice(amountIn, amountOut, decimalsIn, decimalsOut);
        }

        require(amountOut >= minAmountOut, "Slippage: amountOut too low");
        require(amountOut < reserveOut, "Insufficient liquidity");

        // Separate fee tracking from reserves (P1-3)
        uint256 amountInAfterFee = amountIn - fee;
        if (zeroForOne) {
            pool.reserve0 += amountInAfterFee;
            pool.reserve1 -= amountOut;
            accumulatedFees0[poolId] += fee;
        } else {
            pool.reserve1 += amountInAfterFee;
            pool.reserve0 -= amountOut;
            accumulatedFees1[poolId] += fee;
        }

        // Update TWAP observation (P1-1)
        _updateTWAP(poolId, pool);

        IERC20Upgradeable(tokenOut).safeTransfer(recipient, amountOut);

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
        uint64 nonce,
        bytes calldata payload
    ) external override {
        require(msg.sender == lzEndpoint, "Caller is not LZ endpoint");
        require(
            keccak256(srcAddress) == keccak256(trustedRemotes[uint32(srcChainId)]),
            "Untrusted source"
        );

        // Replay protection: enforce monotonically increasing nonces
        uint32 srcChain = uint32(srcChainId);
        require(nonce > lastProcessedNonce[srcChain], "Stale or replayed message");
        lastProcessedNonce[srcChain] = nonce;

        (bytes32 poolId, uint256 reserve0, uint256 reserve1,) =
            abi.decode(payload, (bytes32, uint256, uint256, uint256));

        // Update reserves from remote if the pool exists (sync only)
        if (_pools[poolId].active) {
            // P0-3: Reserve bounds validation – prevent extreme reserve changes
            uint256 currentReserve0 = _pools[poolId].reserve0;
            uint256 currentReserve1 = _pools[poolId].reserve1;
            if (currentReserve0 > 0 && currentReserve1 > 0) {
                // Ensure new reserves are within MAX_RESERVE_CHANGE_BPS of current
                require(
                    reserve0 <= (currentReserve0 * MAX_RESERVE_CHANGE_BPS) / BPS,
                    "Reserve0 change too large"
                );
                require(
                    reserve1 <= (currentReserve1 * MAX_RESERVE_CHANGE_BPS) / BPS,
                    "Reserve1 change too large"
                );
                // Ensure reserves don't drop to zero if they were non-zero
                require(reserve0 > 0 && reserve1 > 0, "Reserves cannot drop to zero");
            }
            _pools[poolId].reserve0 = reserve0;
            _pools[poolId].reserve1 = reserve1;
            emit CrossChainSyncReceived(poolId, srcChain, reserve0, reserve1);
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

    /// @notice Withdraw accumulated swap fees for a pool (timelock-only, P1-3).
    function withdrawFees(bytes32 poolId, address recipient) external onlyTimelock poolExists(poolId) {
        require(recipient != address(0), "Zero recipient");
        PoolInfo storage pool = _pools[poolId];

        uint256 fees0 = accumulatedFees0[poolId];
        uint256 fees1 = accumulatedFees1[poolId];

        if (fees0 > 0) {
            accumulatedFees0[poolId] = 0;
            IERC20Upgradeable(pool.token0).safeTransfer(recipient, fees0);
        }
        if (fees1 > 0) {
            accumulatedFees1[poolId] = 0;
            IERC20Upgradeable(pool.token1).safeTransfer(recipient, fees1);
        }
    }

    /// @notice Set the A_Factor for StableSwap invariant (governance-configurable, P2-3).
    function setAFactor(uint256 newAFactor) external onlyTimelock {
        require(newAFactor >= 1 && newAFactor <= 10_000, "A factor out of range");
        aFactor = newAFactor;
    }

    /// @notice Set the oracle price feed for ADC price validation (P0-4).
    function setAdcPriceFeed(address _priceFeed) external onlyOwner {
        adcPriceFeed = _priceFeed;
    }

    /// @notice Get the TWAP price for a pool over the observation window (P1-1).
    function getTWAP(bytes32 poolId) external view returns (uint256 price0TWAP, uint256 price1TWAP) {
        uint256 count = twapCount[poolId];
        require(count >= 2, "Insufficient TWAP observations");

        uint256 currentIdx = twapIndex[poolId];
        uint256 oldestIdx = count >= TWAP_BUFFER_SIZE
            ? currentIdx  // ring buffer is full, oldest is at current write position
            : 0;          // ring buffer not yet full, oldest is at 0

        // Get most recent observation (one before current write index)
        uint256 newestIdx = currentIdx == 0 ? (count >= TWAP_BUFFER_SIZE ? TWAP_BUFFER_SIZE - 1 : count - 1) : currentIdx - 1;

        TWAPObservation storage oldest = twapObservations[poolId][oldestIdx];
        TWAPObservation storage newest = twapObservations[poolId][newestIdx];

        uint256 elapsed = newest.timestamp - oldest.timestamp;
        require(elapsed > 0, "Zero TWAP elapsed time");

        price0TWAP = (newest.price0Cumulative - oldest.price0Cumulative) / elapsed;
        price1TWAP = (newest.price1Cumulative - oldest.price1Cumulative) / elapsed;
    }

    /// @notice Lookup poolId by token pair for route discovery (P2-2).
    function getPoolByPair(address token0, address token1) external view returns (bytes32) {
        return pairToPoolId[getPoolId(token0, token1)];
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @dev Compute swap output using StableSwap or constant-product depending on pool type.
    ///      For concentrated liquidity pools, applies virtual reserve adjustment (P2-4).
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

        uint256 effectiveReserveIn = reserveIn;
        uint256 effectiveReserveOut = reserveOut;

        // P2-4: Concentrated liquidity virtual reserve adjustment
        if (pool.concentratedLiquidityMin > 0 && pool.concentratedLiquidityMax > 0) {
            // Compute current price ratio
            uint256 currentPrice = (reserveOut * PRECISION) / reserveIn;
            // Only apply concentration if price is within the liquidity zone
            if (currentPrice >= pool.concentratedLiquidityMin && currentPrice <= pool.concentratedLiquidityMax) {
                // Concentrate liquidity by scaling effective reserves
                uint256 rangeWidth = pool.concentratedLiquidityMax - pool.concentratedLiquidityMin;
                uint256 fullRange = pool.concentratedLiquidityMax; // Simplified: range relative to max
                if (rangeWidth > 0 && fullRange > 0) {
                    // Virtual reserves are amplified within the range
                    uint256 concentration = (fullRange * PRECISION) / rangeWidth;
                    effectiveReserveIn = (reserveIn * concentration) / PRECISION;
                    effectiveReserveOut = (reserveOut * concentration) / PRECISION;
                }
            }
        }

        if (pool.isStableToStable) {
            // StableSwap invariant approximation using configurable A factor
            amountOut = _stableSwapOutput(amountInAfterFee, effectiveReserveIn, effectiveReserveOut);
        } else {
            // Constant-product AMM: x * y = k
            amountOut = (amountInAfterFee * effectiveReserveOut) / (effectiveReserveIn + amountInAfterFee);
        }

        // Scale output back if concentrated liquidity was applied
        if (effectiveReserveOut != reserveOut && effectiveReserveOut > 0) {
            amountOut = (amountOut * reserveOut) / effectiveReserveOut;
        }
    }

    /// @dev Simplified StableSwap output (Newton's method on D invariant with configurable A factor).
    ///      Callers must ensure x > 0 and y > 0 (enforced by _calculateSwap).
    ///      Reserves are capped at 1e36 to prevent b*b overflow (Solidity 0.8 reverts
    ///      on overflow, but capping gives a meaningful error on very large inputs).
    function _stableSwapOutput(
        uint256 dx,
        uint256 x,
        uint256 y
    ) internal view returns (uint256 dy) {
        require(x > 0 && y > 0, "StableSwap: zero reserve");
        // Cap reserves at 1e36 to keep b*b within uint256 bounds
        require(x <= 1e36 && y <= 1e36 && dx <= 1e36, "StableSwap: reserve too large");

        uint256 _aFactor = aFactor;
        // Invariant: A*(x+y) + D = A*D + D^3/(4*x*y)
        // Simplified two-asset approximation used here for gas efficiency
        uint256 D = x + y + (x * y * 2) / (_aFactor * (x + y));
        uint256 newX = x + dx;
        // Solve for newY using the two-asset stable curve
        uint256 b = newX + D / _aFactor;
        uint256 c = (D * D * D) / (4 * _aFactor * newX);
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

    // =========================================================================
    // Decimal Normalization (P0-1)
    // =========================================================================

    /// @dev Get decimals for a token. Defaults to 18 if not registered as stablecoin.
    function _getTokenDecimals(address token) internal view returns (uint8) {
        StablecoinConfig storage config = _stablecoins[token];
        if (config.isSupported && config.decimals > 0) {
            return config.decimals;
        }
        return 18; // Default to 18 decimals for ADC and unknown tokens
    }

    /// @dev Normalize an amount from token-native decimals to 18 decimals.
    function _normalize(uint256 amount, uint8 tokenDecimals) internal pure returns (uint256) {
        if (tokenDecimals == 18) return amount;
        if (tokenDecimals < 18) {
            return amount * (10 ** (18 - tokenDecimals));
        }
        return amount / (10 ** (tokenDecimals - 18));
    }

    /// @dev Denormalize an amount from 18 decimals back to token-native decimals.
    function _denormalize(uint256 amount, uint8 tokenDecimals) internal pure returns (uint256) {
        if (tokenDecimals == 18) return amount;
        if (tokenDecimals < 18) {
            return amount / (10 ** (18 - tokenDecimals));
        }
        return amount * (10 ** (tokenDecimals - 18));
    }

    // =========================================================================
    // TWAP Ring Buffer (P1-1)
    // =========================================================================

    /// @dev Update TWAP observation for a pool after a swap.
    function _updateTWAP(bytes32 poolId, PoolInfo storage pool) internal {
        if (pool.reserve0 == 0 || pool.reserve1 == 0) return;

        uint256 idx = twapIndex[poolId];
        uint256 count = twapCount[poolId];

        uint256 price0 = (pool.reserve1 * PRECISION) / pool.reserve0;
        uint256 price1 = (pool.reserve0 * PRECISION) / pool.reserve1;

        uint256 prevCum0;
        uint256 prevCum1;
        uint256 prevTimestamp;
        if (count > 0) {
            uint256 prevIdx = idx == 0 ? (count >= TWAP_BUFFER_SIZE ? TWAP_BUFFER_SIZE - 1 : count - 1) : idx - 1;
            TWAPObservation storage prev = twapObservations[poolId][prevIdx];
            prevCum0 = prev.price0Cumulative;
            prevCum1 = prev.price1Cumulative;
            prevTimestamp = prev.timestamp;
        }

        uint256 elapsed = block.timestamp - prevTimestamp;
        twapObservations[poolId][idx] = TWAPObservation({
            timestamp: block.timestamp,
            price0Cumulative: prevCum0 + price0 * elapsed,
            price1Cumulative: prevCum1 + price1 * elapsed
        });

        // Advance ring buffer index
        twapIndex[poolId] = (idx + 1) % TWAP_BUFFER_SIZE;
        if (count < TWAP_BUFFER_SIZE) {
            twapCount[poolId] = count + 1;
        }
    }

    // =========================================================================
    // Oracle Price Validation (P0-4)
    // =========================================================================

    /// @dev Validate swap price against oracle price for ADC pairs.
    ///      Reverts if the effective swap rate deviates more than 10% from oracle.
    function _validateSwapPrice(
        uint256 amountIn,
        uint256 amountOut,
        uint8 decimalsIn,
        uint8 decimalsOut
    ) internal view {
        // Only validate if oracle is configured
        if (adcPriceFeed == address(0)) return;

        try IAggregatorV3(adcPriceFeed).latestRoundData()
            returns (uint80, int256 price, uint256, uint256 updatedAt, uint80)
        {
            if (price <= 0 || block.timestamp > updatedAt + 1 hours) return; // Skip if oracle is stale

            // Normalize amounts to compare
            uint256 normalizedIn = _normalize(amountIn, decimalsIn);
            uint256 normalizedOut = _normalize(amountOut, decimalsOut);

            // Effective swap rate = normalizedOut / normalizedIn
            uint256 swapRate = (normalizedOut * PRECISION) / normalizedIn;
            uint256 oracleRate = uint256(price) * PRECISION / 1e8; // Chainlink 8 decimal price

            // Allow 10% deviation
            uint256 maxRate = (oracleRate * 11000) / BPS;
            uint256 minRate = (oracleRate * 9000) / BPS;

            require(swapRate >= minRate && swapRate <= maxRate, "Swap price deviates from oracle");
        } catch {
            // Oracle call failed – allow swap to proceed
        }
    }
}

/// @dev Minimal Chainlink Aggregator interface for price validation
interface IAggregatorV3 {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
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
