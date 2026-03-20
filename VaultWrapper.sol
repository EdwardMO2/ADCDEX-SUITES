// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract VaultWrapper {
    mapping(address => uint256) public userRewardDebt;
    uint256 public totalDeposits;

    /// @notice Maximum amount that can be deposited in a single call.
    /// @dev    Caps individual deposits to prevent overflow in reward calculations
    ///         even though Solidity 0.8.x already reverts on overflow.
    uint256 public constant MAX_DEPOSIT = type(uint128).max;

    /// @notice Maximum total deposits the vault may hold.
    uint256 public constant MAX_TOTAL_DEPOSITS = type(uint128).max;

    function deposit(uint256 amount) external {
        require(amount > 0, "Cannot deposit zero amount");
        require(amount <= MAX_DEPOSIT, "VaultWrapper: amount exceeds max deposit");
        require(totalDeposits + amount <= MAX_TOTAL_DEPOSITS, "VaultWrapper: total deposits cap exceeded");

        if (totalDeposits == 0) {
            userRewardDebt[msg.sender] = 0;
        } else {
            uint256 rpt = rewardsPerToken();
            // Explicit pre-multiplication guard: while Solidity 0.8.x reverts on
            // overflow automatically, this require makes the intent clear and
            // provides a descriptive error message rather than a generic panic.
            require(rpt == 0 || amount <= type(uint256).max / rpt, "VaultWrapper: reward calculation overflow");
            userRewardDebt[msg.sender] = (amount * rpt) / totalDeposits;
        }
        totalDeposits += amount;
    }

    /// @notice Returns the accumulated reward tokens per staked token.
    /// @dev Override this in a derived contract to implement actual reward logic.
    function rewardsPerToken() public view virtual returns (uint256) {
        return 0;
    }
}