// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract BondingMechanism is Ownable, Pausable {
    /// @dev Minimum delay before a queued change can be executed.
    uint256 public constant TIMELOCK_DELAY = 2 days;

    struct Timelock {
        address executor;
        uint256 discount;
        uint256 vestingDuration;
        uint256 executions;
        // Two-step discount change fields
        uint256 pendingDiscount;
        uint256 discountExecutableAt;
        // Two-step vesting duration change fields
        uint256 pendingVestingDuration;
        uint256 vestingExecutableAt;
    }

    Timelock public timelock;

    event DiscountChangeRequested(uint256 indexed newDiscount, uint256 executableAt);
    event DiscountChangeExecuted(uint256 indexed newDiscount);
    event VestingDurationChangeRequested(uint256 indexed newDuration, uint256 executableAt);
    event VestingDurationChangeExecuted(uint256 indexed newDuration);

    constructor(address _executor) Ownable() {
        require(_executor != address(0), "BondingMechanism: zero executor");
        timelock.executor = _executor;
    }

    modifier onlyTimelock() {
        require(msg.sender == timelock.executor, "Not allowed");
        _;
    }

    /// @notice Pause the contract. Only the owner may call this.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract. Only the owner may call this.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Request a discount change. The change is not applied immediately;
    ///         it must be executed via executeDiscountChange() after TIMELOCK_DELAY.
    /// @param newDiscount The proposed new discount value.
    function requestDiscountChange(uint256 newDiscount) external onlyTimelock whenNotPaused {
        timelock.pendingDiscount = newDiscount;
        timelock.discountExecutableAt = block.timestamp + TIMELOCK_DELAY;
        emit DiscountChangeRequested(newDiscount, timelock.discountExecutableAt);
    }

    /// @notice Execute a previously requested discount change after the timelock delay.
    function executeDiscountChange() external onlyTimelock whenNotPaused {
        require(timelock.discountExecutableAt > 0, "BondingMechanism: no pending discount change");
        require(block.timestamp >= timelock.discountExecutableAt, "BondingMechanism: timelock not expired");
        timelock.discount = timelock.pendingDiscount;
        timelock.discountExecutableAt = 0;
        timelock.executions += 1;
        emit DiscountChangeExecuted(timelock.discount);
    }

    /// @notice Request a vesting duration change. The change is not applied immediately;
    ///         it must be executed via executeVestingDurationChange() after TIMELOCK_DELAY.
    /// @param newDuration The proposed new vesting duration in seconds.
    function requestVestingDurationChange(uint256 newDuration) external onlyTimelock whenNotPaused {
        timelock.pendingVestingDuration = newDuration;
        timelock.vestingExecutableAt = block.timestamp + TIMELOCK_DELAY;
        emit VestingDurationChangeRequested(newDuration, timelock.vestingExecutableAt);
    }

    /// @notice Execute a previously requested vesting duration change after the timelock delay.
    function executeVestingDurationChange() external onlyTimelock whenNotPaused {
        require(timelock.vestingExecutableAt > 0, "BondingMechanism: no pending vesting change");
        require(block.timestamp >= timelock.vestingExecutableAt, "BondingMechanism: timelock not expired");
        timelock.vestingDuration = timelock.pendingVestingDuration;
        timelock.vestingExecutableAt = 0;
        timelock.executions += 1;
        emit VestingDurationChangeExecuted(timelock.vestingDuration);
    }
}
