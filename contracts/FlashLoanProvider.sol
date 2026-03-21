// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "./Interfaces/IFlashLoanReceiver.sol";

/// @title FlashLoanProvider
/// @notice Provides single-transaction flash loans for supported ERC-20 tokens.
///         A flat fee of FLASH_LOAN_FEE_BPS (0.05 %) is charged on each loan.
///         Fees accumulate in `feeAccrued` and can be withdrawn by the owner.
/// @dev    UUPSUpgradeable – upgrade through governance.
contract FlashLoanProvider is
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

    /// @dev Fee in basis points charged on every flash loan (0.05 %).
    uint256 public constant FLASH_LOAN_FEE_BPS = 5;
    /// @dev Basis-point denominator.
    uint256 public constant BPS = 10_000;
    /// @dev Return value that a compliant receiver must return from onFlashLoan.
    bytes32 public constant CALLBACK_SUCCESS =
        keccak256("FlashLoanReceiver.onFlashLoan");

    // =========================================================================
    // State
    // =========================================================================

    /// @notice Whether a token is eligible for flash loans.
    mapping(address => bool) public supportedTokens;
    /// @notice Address that receives accumulated protocol fees.
    address public feeCollector;
    /// @notice Accumulated fees per token, pending withdrawal.
    mapping(address => uint256) public feeAccrued;

    // =========================================================================
    // Events
    // =========================================================================

    event FlashLoanExecuted(
        address indexed receiver,
        address indexed token,
        uint256 amount,
        uint256 fee,
        address indexed initiator
    );
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);

    // =========================================================================
    // Constructor / Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialise the contract.
    /// @param _feeCollector Address that will receive protocol fees.
    /// @param _owner        Initial contract owner.
    function initialize(address _feeCollector, address _owner) public initializer {
        require(_feeCollector != address(0), "FlashLoanProvider: zero fee collector");
        require(_owner != address(0), "FlashLoanProvider: zero owner");

        __Ownable_init();
        _transferOwnership(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        feeCollector = _feeCollector;
    }

    // =========================================================================
    // Flash Loan
    // =========================================================================

    /// @notice Execute a flash loan.
    /// @dev The receiver must implement IFlashLoanReceiver and repay `amount + fee`
    ///      within the same call, otherwise the transaction reverts.
    /// @param token    ERC-20 token to borrow.
    /// @param amount   Amount to borrow (must be > 0).
    /// @param receiver Contract that will receive the tokens and must repay.
    /// @param data     Arbitrary data forwarded to the receiver callback.
    function initiateFlashLoan(
        address token,
        uint256 amount,
        address receiver,
        bytes calldata data
    ) external nonReentrant whenNotPaused {
        require(supportedTokens[token], "FlashLoanProvider: unsupported token");
        require(amount > 0, "FlashLoanProvider: zero amount");
        require(receiver != address(0), "FlashLoanProvider: zero receiver");

        uint256 fee = (amount * FLASH_LOAN_FEE_BPS) / BPS;
        uint256 balanceBefore = IERC20Upgradeable(token).balanceOf(address(this));

        require(balanceBefore >= amount, "FlashLoanProvider: insufficient liquidity");

        // Transfer principal to receiver
        IERC20Upgradeable(token).safeTransfer(receiver, amount);

        // Invoke receiver callback
        bytes32 result = IFlashLoanReceiver(receiver).onFlashLoan(
            msg.sender,
            token,
            amount,
            fee,
            data
        );
        require(result == CALLBACK_SUCCESS, "FlashLoanProvider: callback failed");

        // Verify repayment
        uint256 balanceAfter = IERC20Upgradeable(token).balanceOf(address(this));
        require(
            balanceAfter >= balanceBefore + fee,
            "FlashLoanProvider: repayment insufficient"
        );

        feeAccrued[token] += fee;

        emit FlashLoanExecuted(receiver, token, amount, fee, msg.sender);
    }

    // =========================================================================
    // Token Management
    // =========================================================================

    /// @notice Add a token to the supported list.
    /// @param token ERC-20 token address to whitelist.
    function addSupportedToken(address token) external onlyOwner {
        require(token != address(0), "FlashLoanProvider: zero token");
        require(!supportedTokens[token], "FlashLoanProvider: already supported");
        supportedTokens[token] = true;
        emit TokenAdded(token);
    }

    /// @notice Remove a token from the supported list.
    /// @param token ERC-20 token address to remove.
    function removeSupportedToken(address token) external onlyOwner {
        require(supportedTokens[token], "FlashLoanProvider: not supported");
        supportedTokens[token] = false;
        emit TokenRemoved(token);
    }

    // =========================================================================
    // Fee Withdrawal
    // =========================================================================

    /// @notice Withdraw accumulated fees for a token to the designated fee collector.
    /// @param token ERC-20 token whose fees are to be withdrawn.
    function withdrawFees(address token) external onlyOwner {
        uint256 amount = feeAccrued[token];
        require(amount > 0, "FlashLoanProvider: no fees");
        feeAccrued[token] = 0;
        IERC20Upgradeable(token).safeTransfer(feeCollector, amount);
        emit FeesWithdrawn(token, feeCollector, amount);
    }

    // =========================================================================
    // Pause
    // =========================================================================

    /// @notice Pause flash loan execution.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause flash loan execution.
    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    // Upgrade
    // =========================================================================

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
