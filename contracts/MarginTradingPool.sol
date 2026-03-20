// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/// @title MarginTradingPool
/// @notice Overcollateralised lending pool.  Users deposit collateral, borrow up to
///         a configurable LTV ratio, and accrue per-second interest.  Positions that
///         fall below the liquidation ratio can be liquidated by any caller.
/// @dev    UUPSUpgradeable – upgrade through governance.
contract MarginTradingPool is
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

    /// @dev Minimum collateral ratio to borrow (150 %).
    uint256 public constant COLLATERAL_RATIO       = 15_000;  // bps
    /// @dev Below this ratio the position becomes liquidatable (110 %).
    uint256 public constant LIQUIDATION_RATIO      = 11_000;  // bps
    uint256 public constant PRECISION              = 1e18;
    uint256 public constant BPS                    = 10_000;
    /// @dev ~3 % APY – 0.000001 per second.
    uint256 public constant INTEREST_RATE_PER_SECOND = 1e12;  // 1e12 / 1e18 = 0.000001

    // =========================================================================
    // Structs
    // =========================================================================

    struct UserMarginAccount {
        uint256 collateral;
        uint256 borrowed;
        uint256 lastInterestTime;
        uint256 healthFactor;
    }

    // =========================================================================
    // State
    // =========================================================================

    /// @notice Per-user margin accounts.
    mapping(address => UserMarginAccount) public accounts;
    /// @notice Token deposited as collateral (e.g. USDC).
    address public collateralToken;
    /// @notice Token that users borrow (e.g. USDC or a synthetic).
    address public borrowToken;

    // =========================================================================
    // Events
    // =========================================================================

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(
        address indexed liquidator,
        address indexed user,
        uint256 collateralSeized,
        uint256 debtCleared
    );

    // =========================================================================
    // Constructor / Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialise the contract.
    /// @param _collateralToken Token used as collateral.
    /// @param _borrowToken     Token that users can borrow.
    /// @param _owner           Initial contract owner.
    function initialize(
        address _collateralToken,
        address _borrowToken,
        address _owner
    ) public initializer {
        require(_collateralToken != address(0), "MTP: zero collateral token");
        require(_borrowToken != address(0), "MTP: zero borrow token");
        require(_owner != address(0), "MTP: zero owner");

        __Ownable_init();
        _transferOwnership(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        collateralToken = _collateralToken;
        borrowToken     = _borrowToken;
    }

    // =========================================================================
    // Collateral Management
    // =========================================================================

    /// @notice Deposit collateral into your margin account.
    /// @param amount Amount of collateralToken to deposit.
    function depositCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "MTP: zero amount");
        _accrueInterest(msg.sender);

        IERC20Upgradeable(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        accounts[msg.sender].collateral += amount;

        if (accounts[msg.sender].lastInterestTime == 0) {
            accounts[msg.sender].lastInterestTime = block.timestamp;
        }

        _updateHealthFactor(msg.sender);
        emit CollateralDeposited(msg.sender, amount);
    }

    /// @notice Withdraw collateral from your margin account.
    /// @dev    Reverts if the withdrawal would push health factor below 100 %.
    /// @param amount Amount of collateralToken to withdraw.
    function withdrawCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "MTP: zero amount");
        _accrueInterest(msg.sender);

        UserMarginAccount storage acct = accounts[msg.sender];
        require(acct.collateral >= amount, "MTP: insufficient collateral");

        acct.collateral -= amount;

        // Ensure account remains healthy after withdrawal
        if (acct.borrowed > 0) {
            uint256 hf = _computeHealthFactor(acct.collateral, acct.borrowed);
            require(hf >= BPS, "MTP: health factor too low");
        }

        _updateHealthFactor(msg.sender);
        IERC20Upgradeable(collateralToken).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    // =========================================================================
    // Borrowing
    // =========================================================================

    /// @notice Borrow borrowToken against deposited collateral.
    /// @dev    Collateral must be >= COLLATERAL_RATIO of the total borrowed amount.
    /// @param amount Amount of borrowToken to borrow.
    function borrow(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "MTP: zero amount");
        _accrueInterest(msg.sender);

        UserMarginAccount storage acct = accounts[msg.sender];
        require(acct.collateral > 0, "MTP: no collateral");

        uint256 newBorrowed = acct.borrowed + amount;
        // collateral * BPS >= newBorrowed * COLLATERAL_RATIO
        require(
            acct.collateral * BPS >= newBorrowed * COLLATERAL_RATIO,
            "MTP: borrow exceeds limit"
        );

        acct.borrowed = newBorrowed;
        _updateHealthFactor(msg.sender);

        IERC20Upgradeable(borrowToken).safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    /// @notice Repay borrowed borrowToken.
    /// @param amount Amount of borrowToken to repay.
    function repay(uint256 amount) external nonReentrant {
        require(amount > 0, "MTP: zero amount");
        _accrueInterest(msg.sender);

        UserMarginAccount storage acct = accounts[msg.sender];
        require(acct.borrowed > 0, "MTP: no debt");

        uint256 repayAmount = amount > acct.borrowed ? acct.borrowed : amount;
        acct.borrowed -= repayAmount;

        _updateHealthFactor(msg.sender);
        IERC20Upgradeable(borrowToken).safeTransferFrom(msg.sender, address(this), repayAmount);
        emit Repaid(msg.sender, repayAmount);
    }

    // =========================================================================
    // Liquidation
    // =========================================================================

    /// @notice Liquidate an undercollateralised account.
    /// @dev    Health factor must be < 10000 (below 1.0 / 100 %).
    /// @param user The account to liquidate.
    function liquidate(address user) external nonReentrant {
        _accrueInterest(user);

        UserMarginAccount storage acct = accounts[user];
        require(acct.borrowed > 0, "MTP: no debt to liquidate");

        uint256 hf = _computeHealthFactor(acct.collateral, acct.borrowed);
        require(hf < BPS, "MTP: account is healthy");

        uint256 collateralSeized = acct.collateral;
        uint256 debtCleared      = acct.borrowed;

        acct.collateral       = 0;
        acct.borrowed         = 0;
        acct.healthFactor     = 0;

        // Liquidator repays the debt and receives all collateral
        IERC20Upgradeable(borrowToken).safeTransferFrom(msg.sender, address(this), debtCleared);
        IERC20Upgradeable(collateralToken).safeTransfer(msg.sender, collateralSeized);

        emit Liquidated(msg.sender, user, collateralSeized, debtCleared);
    }

    // =========================================================================
    // View helpers
    // =========================================================================

    /// @notice Return the health factor of an account (BPS-scaled).
    /// @dev    Returns 0 when there is no borrowed balance.  A value >= 10000
    ///         means the account is healthy; < 10000 means it's liquidatable.
    /// @param user Address of the account.
    /// @return     Health factor (10000 = 100 %).
    function getHealthFactor(address user) external view returns (uint256) {
        UserMarginAccount storage acct = accounts[user];
        if (acct.borrowed == 0) return type(uint256).max;
        return _computeHealthFactor(acct.collateral, acct.borrowed);
    }

    // =========================================================================
    // Pause
    // =========================================================================

    /// @notice Pause borrowing.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause borrowing.
    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Accrue per-second interest on the user's borrowed balance.
    function _accrueInterest(address user) internal {
        UserMarginAccount storage acct = accounts[user];
        if (acct.borrowed == 0 || acct.lastInterestTime == 0) {
            acct.lastInterestTime = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - acct.lastInterestTime;
        if (elapsed == 0) return;

        uint256 interest = (acct.borrowed * INTEREST_RATE_PER_SECOND * elapsed) / PRECISION;
        acct.borrowed         += interest;
        acct.lastInterestTime  = block.timestamp;
    }

    /// @dev Compute health factor = (collateral * BPS) / (borrowed * LIQUIDATION_RATIO / BPS).
    ///      Simplifies to: (collateral * BPS * BPS) / (borrowed * LIQUIDATION_RATIO).
    function _computeHealthFactor(
        uint256 collateral,
        uint256 borrowed
    ) internal pure returns (uint256) {
        if (borrowed == 0) return type(uint256).max;
        return (collateral * BPS * BPS) / (borrowed * LIQUIDATION_RATIO);
    }

    /// @dev Store updated health factor on the account struct.
    function _updateHealthFactor(address user) internal {
        UserMarginAccount storage acct = accounts[user];
        if (acct.borrowed == 0) {
            acct.healthFactor = type(uint256).max;
        } else {
            acct.healthFactor = _computeHealthFactor(acct.collateral, acct.borrowed);
        }
    }

    // =========================================================================
    // Upgrade
    // =========================================================================

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
