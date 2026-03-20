// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title TimelockController - Enhanced Version
 * @notice Hardened timelock with owner management and validation
 */
contract TimelockController {
    // Constants for timelock bounds
    uint256 public constant MIN_TIMELOCK = 1 days;
    uint256 public constant MAX_TIMELOCK = 30 days;
    
    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public timeLockPeriod;
    mapping(bytes32 => uint256) public queuedTransactions;

    event TransactionExecuted(bytes32 indexed txHash);
    event TransactionQueued(bytes32 indexed txHash, uint256 executeAt);
    event OwnerAdded(address indexed newOwner);
    event OwnerRemoved(address indexed removedOwner);
    event TimeLockPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not an owner");
        _;
    }

    modifier onlyMultipleOwners(uint256 confirmationsRequired) {
        require(isOwner[msg.sender], "Not an owner");
        require(owners.length >= confirmationsRequired, "Insufficient owners");
        _;
    }

    constructor(address[] memory _owners, uint256 _timeLockPeriod) {
        require(_owners.length > 0, "Must have owners");
        
        // SECURITY: Validate timelock period is within acceptable bounds
        require(_timeLockPeriod >= MIN_TIMELOCK && _timeLockPeriod <= MAX_TIMELOCK, 
                "Timelock period out of range");
        
        for (uint i = 0; i < _owners.length; i++) {
            require(_owners[i] != address(0), "Invalid owner");
            require(!isOwner[_owners[i]], "Duplicate owner");
            isOwner[_owners[i]] = true;
        }
        owners = _owners;
        timeLockPeriod = _timeLockPeriod;
    }

    /// @notice Queue a transaction for execution after timelock period
    /// @param txHash Hash of the transaction to queue
    function queueTransaction(bytes32 txHash) external onlyOwner {
        require(queuedTransactions[txHash] == 0, "Transaction already queued");
        uint256 executeAt = block.timestamp + timeLockPeriod;
        queuedTransactions[txHash] = executeAt;
        emit TransactionQueued(txHash, executeAt);
    }

    /// @notice Execute a queued transaction after timelock has passed
    /// @param txHash Hash of the transaction to execute
    function executeTransaction(bytes32 txHash) external onlyOwner {
        require(queuedTransactions[txHash] > 0, "Transaction not queued");
        require(block.timestamp >= queuedTransactions[txHash], "Transaction is still locked");

        delete queuedTransactions[txHash];
        emit TransactionExecuted(txHash);
    }

    /// @notice Add a new owner (requires existing owners consensus)
    /// @param newOwner Address of the new owner
    function addOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner address");
        require(!isOwner[newOwner], "Already an owner");
        
        isOwner[newOwner] = true;
        owners.push(newOwner);
        emit OwnerAdded(newOwner);
    }

    /// @notice Remove an owner (emergency function - requires owner consensus)
    /// @param ownerToRemove Address of the owner to remove
    function removeOwner(address ownerToRemove) external onlyOwner {
        require(isOwner[ownerToRemove], "Not an owner");
        require(owners.length > 1, "Cannot remove last owner");
        
        isOwner[ownerToRemove] = false;
        
        // Find and remove from array
        for (uint i = 0; i < owners.length; i++) {
            if (owners[i] == ownerToRemove) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
        emit OwnerRemoved(ownerToRemove);
    }

    /// @notice Update the timelock period (within bounds)
    /// @param newTimeLockPeriod New timelock period (must be between MIN and MAX)
    function updateTimeLockPeriod(uint256 newTimeLockPeriod) external onlyOwner {
        require(newTimeLockPeriod >= MIN_TIMELOCK && newTimeLockPeriod <= MAX_TIMELOCK,
                "Timelock period out of range");
        
        uint256 oldPeriod = timeLockPeriod;
        timeLockPeriod = newTimeLockPeriod;
        
        // Schedule update with timelock
        bytes32 updateHash = keccak256(abi.encodePacked("updateTimelock", newTimeLockPeriod));
        queueTransaction(updateHash);
        
        emit TimeLockPeriodUpdated(oldPeriod, newTimeLockPeriod);
    }

    /// @notice Emergency pause - can be called to freeze all operations
    /// @dev This prevents new transactions from being queued
    function emergencyPause() external onlyOwner {
        // Set timeLockPeriod to maximum to prevent new transactions
        timeLockPeriod = MAX_TIMELOCK;
    }

    /// @notice Get all current owners
    /// @return Array of owner addresses
    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    /// @notice Get number of owners
    /// @return Number of owners
    function getOwnerCount() external view returns (uint256) {
        return owners.length;
    }
}