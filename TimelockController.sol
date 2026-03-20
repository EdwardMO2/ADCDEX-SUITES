// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract TimelockController {
    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public timeLockPeriod;
    mapping(bytes32 => uint256) public queuedTransactions;

    /// @notice Minimum allowed timelock period (1 hour).
    uint256 public constant MIN_TIMELOCK_PERIOD = 1 hours;
    /// @notice Maximum allowed timelock period (30 days).
    uint256 public constant MAX_TIMELOCK_PERIOD = 30 days;

    event TransactionExecuted(bytes32 indexed txHash, uint256 timestamp);
    event TransactionQueued(bytes32 indexed txHash, uint256 executeAt, uint256 timestamp);
    event TransactionCancelled(bytes32 indexed txHash, address indexed cancelledBy, uint256 timestamp);
    event OwnerAdded(address indexed newOwner, uint256 timestamp);
    event OwnerRemoved(address indexed removedOwner, uint256 timestamp);

    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not an owner");
        _;
    }

    constructor(address[] memory _owners, uint256 _timeLockPeriod) {
        require(_owners.length > 0, "Must have owners");
        require(
            _timeLockPeriod >= MIN_TIMELOCK_PERIOD && _timeLockPeriod <= MAX_TIMELOCK_PERIOD,
            "TimelockController: period out of range"
        );
        for (uint i = 0; i < _owners.length; i++) {
            require(_owners[i] != address(0), "Invalid owner");
            require(!isOwner[_owners[i]], "Duplicate owner");
            isOwner[_owners[i]] = true;
        }
        owners = _owners;
        timeLockPeriod = _timeLockPeriod;
    }

    function queueTransaction(bytes32 txHash) external onlyOwner {
        require(queuedTransactions[txHash] == 0, "Transaction already queued");
        queuedTransactions[txHash] = block.timestamp + timeLockPeriod;
        emit TransactionQueued(txHash, queuedTransactions[txHash], block.timestamp);
    }

    function executeTransaction(bytes32 txHash) external onlyOwner {
        require(queuedTransactions[txHash] > 0, "Transaction not queued");
        require(block.timestamp >= queuedTransactions[txHash], "Transaction is still locked");

        delete queuedTransactions[txHash];
        emit TransactionExecuted(txHash, block.timestamp);
    }

    /// @notice Cancel a queued transaction (emergency escape mechanism).
    /// @param txHash Hash of the transaction to cancel.
    function cancelTransaction(bytes32 txHash) external onlyOwner {
        require(queuedTransactions[txHash] > 0, "Transaction not queued");
        delete queuedTransactions[txHash];
        emit TransactionCancelled(txHash, msg.sender, block.timestamp);
    }

    /// @notice Add a new owner. Callable only by an existing owner.
    /// @param newOwner Address to grant owner status.
    function addOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner address");
        require(!isOwner[newOwner], "Already an owner");
        isOwner[newOwner] = true;
        owners.push(newOwner);
        emit OwnerAdded(newOwner, block.timestamp);
    }

    /// @notice Remove an existing owner. At least one owner must remain.
    /// @param ownerToRemove Address to revoke owner status from.
    function removeOwner(address ownerToRemove) external onlyOwner {
        require(isOwner[ownerToRemove], "Not an owner");
        require(owners.length > 1, "Cannot remove last owner");

        isOwner[ownerToRemove] = false;

        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == ownerToRemove) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
        emit OwnerRemoved(ownerToRemove, block.timestamp);
    }
}
