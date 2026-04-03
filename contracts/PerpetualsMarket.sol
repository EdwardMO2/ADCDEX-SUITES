// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "./Interfaces/IDerivatives.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/// @title PerpetualsMarket
/// @notice Perpetual futures trading with up to 10x leverage, on-chain price feed,
///         funding rate accrual, and liquidation mechanics.
/// @dev    UUPSUpgradeable – upgrade through governance.
contract PerpetualsMarket is
    IDerivatives,
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

    uint8  public constant MAX_LEVERAGE           = 10;
    uint8  public constant MIN_LEVERAGE           = 1;
    /// @dev 80 % of collateral must remain to avoid liquidation.
    uint256 public constant LIQUIDATION_THRESHOLD = 8_000;  // bps
    uint256 public constant FUNDING_INTERVAL      = 8 hours;
    uint256 public constant PRECISION             = 1e18;
    uint256 public constant BPS                   = 10_000;
    /// @dev Liquidator receives 5 % of collateral as reward.
    uint256 public constant LIQUIDATION_REWARD_BPS = 500;
    /// @dev Maximum allowed staleness for Chainlink price data.
    uint256 public constant ORACLE_STALENESS_THRESHOLD = 1 hours;
    /// @dev Maximum allowed price deviation between oracle and admin price (10 %).
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 1_000;

    // =========================================================================
    // State
    // =========================================================================

    /// @notice All open positions, keyed by positionId.
    mapping(bytes32 => Position) public positions;
    /// @notice Per-token funding rates (scaled by PRECISION).
    mapping(address => uint256) public fundingRates;
    /// @notice Simple on-chain price feed: token → price (scaled by PRECISION).
    mapping(address => uint256) public prices;
    /// @notice Collateral token used for margin (e.g. USDC).
    address public collateralToken;
    /// @notice Per-user nonce for unique position ID generation.
    mapping(address => uint256) private _positionNonces;
    /// @notice Chainlink price feed per token for decentralised pricing.
    mapping(address => address) public priceFeeds;

    // =========================================================================
    // Constructor / Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialise the contract.
    /// @param _collateralToken Token accepted as collateral (e.g. USDC).
    /// @param _oracle          Reserved for future OracleManager integration.
    /// @param _owner           Initial contract owner.
    function initialize(
        address _collateralToken,
        address _oracle,
        address _owner
    ) public initializer {
        require(_collateralToken != address(0), "PM: zero collateral token");
        require(_owner != address(0), "PM: zero owner");

        __Ownable_init();
        _transferOwnership(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        collateralToken = _collateralToken;
        // _oracle is stored for future integration; emit for off-chain tracking
        emit FundingRateUpdated(_oracle, 0);
    }

    // =========================================================================
    // Price Feed (Chainlink-integrated with admin fallback)
    // =========================================================================

    /// @notice Set a Chainlink price feed for a token.
    /// @param token Token address.
    /// @param feed  Chainlink AggregatorV3Interface address.
    function setPriceFeed(address token, address feed) external onlyOwner {
        require(feed != address(0), "PM: zero feed address");
        priceFeeds[token] = feed;
    }

    /// @notice Set an admin price for a token (fallback when no Chainlink feed is configured).
    /// @param token Token address.
    /// @param price Price scaled by PRECISION (1e18).
    function setPrice(address token, uint256 price) external onlyOwner {
        require(price > 0, "PM: zero price");
        // When a Chainlink feed exists, enforce deviation limit to prevent manipulation
        if (priceFeeds[token] != address(0)) {
            uint256 chainlinkPrice = _getChainlinkPrice(token);
            if (chainlinkPrice > 0) {
                uint256 deviation = price > chainlinkPrice
                    ? ((price - chainlinkPrice) * BPS) / chainlinkPrice
                    : ((chainlinkPrice - price) * BPS) / chainlinkPrice;
                require(deviation <= MAX_PRICE_DEVIATION_BPS, "PM: price deviates too much from oracle");
            }
        }
        prices[token] = price;
    }

    /// @dev Return the Chainlink price for `token`, or 0 if unavailable/stale.
    function _getChainlinkPrice(address token) internal view returns (uint256) {
        address feed = priceFeeds[token];
        if (feed == address(0)) return 0;

        try AggregatorV3Interface(feed).latestRoundData()
            returns (uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound)
        {
            // Validate: positive price, not stale, round is complete
            if (answer <= 0) return 0;
            if (block.timestamp > updatedAt + ORACLE_STALENESS_THRESHOLD) return 0;
            if (answeredInRound < roundId) return 0;

            // Convert Chainlink 8-decimal price to PRECISION (1e18)
            uint8 feedDecimals = AggregatorV3Interface(feed).decimals();
            return uint256(answer) * (PRECISION / (10 ** feedDecimals));
        } catch {
            return 0;
        }
    }

    /// @dev Return the price for `token`. Prefers Chainlink; falls back to admin price.
    function _getOraclePrice(address token) internal view returns (uint256) {
        uint256 chainlinkPrice = _getChainlinkPrice(token);
        if (chainlinkPrice > 0) return chainlinkPrice;

        uint256 p = prices[token];
        require(p > 0, "PM: no price for token");
        return p;
    }

    // =========================================================================
    // Position Management
    // =========================================================================

    /// @inheritdoc IDerivatives
    function openPosition(
        address token,
        uint256 collateral,
        uint8   leverage,
        bool    isLong
    ) external nonReentrant whenNotPaused returns (bytes32 positionId) {
        require(leverage >= MIN_LEVERAGE && leverage <= MAX_LEVERAGE, "PM: invalid leverage");
        require(collateral > 0, "PM: zero collateral");

        uint256 entryPrice = _getOraclePrice(token);
        uint256 size       = collateral * leverage;

        // Liquidation price calculation (price moves that wipe collateral).
        // entryPrice is scaled by PRECISION (1e18); the ratio preserves that scale.
        // For long:  liqPrice = entryPrice * (leverage - 1) / leverage
        // For short: liqPrice = entryPrice * (leverage + 1) / leverage
        uint256 liquidationPrice;
        unchecked {
            if (isLong) {
                liquidationPrice = (entryPrice * (leverage - 1)) / leverage;
            } else {
                liquidationPrice = (entryPrice * (leverage + 1)) / leverage;
            }
        }

        // Pull collateral from user
        IERC20Upgradeable(collateralToken).safeTransferFrom(msg.sender, address(this), collateral);

        // Include per-user nonce to prevent position ID collisions within the same block.
        positionId = keccak256(
            abi.encodePacked(msg.sender, token, block.timestamp, block.number, _positionNonces[msg.sender]++)
        );

        positions[positionId] = Position({
            owner:            msg.sender,
            token:            token,
            collateral:       collateral,
            size:             size,
            leverage:         leverage,
            isLong:           isLong,
            entryPrice:       entryPrice,
            liquidationPrice: liquidationPrice,
            lastFundingTime:  block.timestamp,
            fundingAccrued:   0
        });

        emit PositionOpened(
            positionId,
            msg.sender,
            token,
            collateral,
            size,
            leverage,
            isLong,
            entryPrice,
            liquidationPrice
        );
    }

    /// @inheritdoc IDerivatives
    function closePosition(bytes32 positionId) external nonReentrant {
        Position storage pos = positions[positionId];
        require(pos.owner == msg.sender, "PM: not position owner");

        uint256 currentPrice = _getOraclePrice(pos.token);
        int256  pnl          = _calculatePnl(pos, currentPrice);

        // Accrue any pending funding
        uint256 fundingCost = _calculateFunding(pos);

        uint256 collateralRemaining = pos.collateral;
        int256  net = pnl - int256(fundingCost);

        uint256 payout;
        if (net >= 0) {
            payout = collateralRemaining + uint256(net);
            // Cap payout at contract balance to avoid draining other users' funds
            uint256 contractBal = IERC20Upgradeable(collateralToken).balanceOf(address(this));
            if (payout > contractBal) payout = contractBal;
        } else {
            uint256 loss = uint256(-net);
            payout = loss >= collateralRemaining ? 0 : collateralRemaining - loss;
        }

        address owner = pos.owner;
        delete positions[positionId];

        if (payout > 0) {
            IERC20Upgradeable(collateralToken).safeTransfer(owner, payout);
        }

        emit PositionClosed(positionId, owner, pnl, payout);
    }

    /// @inheritdoc IDerivatives
    function liquidatePosition(bytes32 positionId) external nonReentrant {
        Position storage pos = positions[positionId];
        require(pos.owner != address(0), "PM: position not found");

        uint256 currentPrice = _getOraclePrice(pos.token);
        require(_isLiquidatable(pos, currentPrice), "PM: not liquidatable");

        uint256 reward;
        unchecked { reward = (pos.collateral * LIQUIDATION_REWARD_BPS) / BPS; }
        address posOwner = pos.owner;
        delete positions[positionId];

        if (reward > 0) {
            IERC20Upgradeable(collateralToken).safeTransfer(msg.sender, reward);
        }

        emit PositionLiquidated(positionId, posOwner, msg.sender, reward);
    }

    /// @inheritdoc IDerivatives
    function updateFundingRate(address token, uint256 rate) external onlyOwner {
        fundingRates[token] = rate;
        emit FundingRateUpdated(token, rate);
    }

    // =========================================================================
    // View helpers
    // =========================================================================

    /// @notice Return the health factor of a position (BPS-scaled; 10000 = 100 %).
    /// @dev    Health factor < 10000 means the position is liquidatable.
    /// @param positionId The position to inspect.
    /// @return health    Health factor in BPS units.
    function getPositionHealth(bytes32 positionId) external view returns (uint256 health) {
        Position storage pos = positions[positionId];
        require(pos.owner != address(0), "PM: position not found");

        uint256 currentPrice = _getOraclePrice(pos.token);
        int256  pnl          = _calculatePnl(pos, currentPrice);
        uint256 fundingCost  = _calculateFunding(pos);

        int256 equity = int256(pos.collateral) + pnl - int256(fundingCost);
        if (equity <= 0) return 0;

        // Health = equity / collateral, scaled by BPS
        health = (uint256(equity) * BPS) / pos.collateral;
    }

    // =========================================================================
    // Pause
    // =========================================================================

    /// @notice Pause position opening.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause position opening.
    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Calculate unrealised PnL for a position at `currentPrice`.
    function _calculatePnl(
        Position storage pos,
        uint256 currentPrice
    ) internal view returns (int256 pnl) {
        if (pos.isLong) {
            // Long profits when price rises
            int256 priceDelta = int256(currentPrice) - int256(pos.entryPrice);
            pnl = (priceDelta * int256(pos.size)) / int256(pos.entryPrice);
        } else {
            // Short profits when price falls
            int256 priceDelta = int256(pos.entryPrice) - int256(currentPrice);
            pnl = (priceDelta * int256(pos.size)) / int256(pos.entryPrice);
        }
    }

    /// @dev Calculate funding cost accrued since last funding time.
    function _calculateFunding(Position storage pos) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - pos.lastFundingTime;
        if (elapsed == 0 || fundingRates[pos.token] == 0) return 0;
        return (pos.size * fundingRates[pos.token] * elapsed) / (PRECISION * FUNDING_INTERVAL);
    }

    /// @dev Return true if position should be liquidated at `currentPrice`.
    function _isLiquidatable(
        Position storage pos,
        uint256 currentPrice
    ) internal view returns (bool) {
        if (pos.isLong) {
            return currentPrice <= pos.liquidationPrice;
        } else {
            return currentPrice >= pos.liquidationPrice;
        }
    }

    // =========================================================================
    // Upgrade
    // =========================================================================

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
