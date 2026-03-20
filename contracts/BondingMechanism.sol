// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

contract BondingMechanism is Ownable {
    struct Timelock {
        address executor;
        uint256 discount;
        uint256 vestingDuration;
        uint256 executions;
    }

    Timelock public timelock;

    constructor(address _executor) Ownable() {
        timelock.executor = _executor;
    }

    modifier onlyTimelock() {
        require(msg.sender == timelock.executor, "Not allowed");
        _;
    }

    function requestDiscountChange(uint256 newDiscount) external onlyTimelock {
        timelock.discount = newDiscount;
    }

    function executeDiscountChange() external onlyTimelock {
        // Logic to apply the new discount
    }

    function requestVestingDurationChange(uint256 newDuration) external onlyTimelock {
        timelock.vestingDuration = newDuration;
    }

    function executeVestingDurationChange() external onlyTimelock {
        // Logic to apply the new vesting duration
    }

    // Additional functions and logic
}
