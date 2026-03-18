// Updated VaultWrapper contract

pragma solidity ^0.8.0;

contract VaultWrapper {
    mapping(address => uint256) public userRewardDebt; // Mapping to prevent reward double-claiming

    function deposit(uint256 amount) external {
        require(amount > 0, "Cannot deposit zero amount");
        // Fix division by zero
        if (totalDeposits == 0) {
            userRewardDebt[msg.sender] = 0; // No rewards if there are no deposits
        } else {
            userRewardDebt[msg.sender] = (amount * rewardsPerToken()) / totalDeposits;
        }
        totalDeposits += amount;
    }

    // Function to get rewards per token
    function rewardsPerToken() public view returns (uint256) {
        // Reward calculation logic
    }
}