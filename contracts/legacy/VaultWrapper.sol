// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title VaultWrapper (Legacy)
/// @notice Basic vault for depositing and withdrawing ERC-20 tokens.
///         Tracks per-user balances and supports an extendable reward debt calculation.
/// @dev    Root-level stub moved to contracts/legacy/ and fixed:
///         - Added token state variable and transferFrom in deposit (was phantom accounting).
///         - Added withdraw function (funds were previously locked indefinitely).
///         - rewardsPerToken() is virtual so subclasses can implement reward logic.
contract VaultWrapper {
    using SafeERC20 for IERC20;

    /// @notice The ERC-20 token managed by this vault.
    IERC20 public immutable token;

    /// @notice Per-user deposited balances.
    mapping(address => uint256) public balances;
    /// @notice Per-user reward debt (used by subclasses for reward calculations).
    mapping(address => uint256) public userRewardDebt;
    /// @notice Total tokens deposited across all users.
    uint256 public totalDeposits;

    uint256 public constant MAX_DEPOSIT = type(uint128).max;
    uint256 public constant MAX_TOTAL_DEPOSITS = type(uint128).max;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    constructor(address _token) {
        require(_token != address(0), "VaultWrapper: zero token");
        token = IERC20(_token);
    }

    /// @notice Deposit tokens into the vault.
    /// @param amount Amount of tokens to deposit.
    function deposit(uint256 amount) external {
        require(amount > 0, "Cannot deposit zero amount");
        require(amount <= MAX_DEPOSIT, "VaultWrapper: amount exceeds max deposit");
        require(totalDeposits + amount <= MAX_TOTAL_DEPOSITS, "VaultWrapper: total deposits cap exceeded");

        if (totalDeposits == 0) {
            userRewardDebt[msg.sender] = 0;
        } else {
            uint256 rpt = rewardsPerToken();
            require(rpt == 0 || amount <= type(uint256).max / rpt, "VaultWrapper: reward calculation overflow");
            userRewardDebt[msg.sender] = (amount * rpt) / totalDeposits;
        }
        balances[msg.sender] += amount;
        totalDeposits += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraw previously deposited tokens from the vault.
    /// @param amount Amount of tokens to withdraw.
    function withdraw(uint256 amount) external {
        require(amount > 0, "VaultWrapper: zero amount");
        require(balances[msg.sender] >= amount, "VaultWrapper: insufficient balance");
        balances[msg.sender] -= amount;
        totalDeposits -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Returns current rewards per deposited token unit.
    ///         Always returns 0 in the base contract; override in subclasses.
    function rewardsPerToken() public view virtual returns (uint256) {
        return 0;
    }
}
