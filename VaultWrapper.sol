// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract VaultWrapper {
    mapping(address => uint256) public userRewardDebt;
    uint256 public totalDeposits;

    function deposit(uint256 amount) external {
        require(amount > 0, "Cannot deposit zero amount");
        if (totalDeposits == 0) {
            userRewardDebt[msg.sender] = 0;
        } else {
            userRewardDebt[msg.sender] = (amount * rewardsPerToken()) / totalDeposits;
        }
        totalDeposits += amount;
    }

    /// @notice Returns the accumulated reward tokens per staked token.
    /// @dev Override this in a derived contract to implement actual reward logic.
    function rewardsPerToken() public view virtual returns (uint256) {
        return 0;
    }
}