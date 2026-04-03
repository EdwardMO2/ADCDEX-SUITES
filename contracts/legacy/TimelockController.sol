// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TimelockController (Legacy)
/// @notice Custom multi-owner timelock controller.
/// @dev    This is a legacy root-level contract moved to contracts/legacy/.
///         For production use, prefer OpenZeppelin's TimelockController.
/// @custom:security-note Owner management (addOwner/removeOwner) is also
///         gated through the timelock queue to prevent instant hostile takeovers.
contract TimelockController {
    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public timeLockPeriod;
    mapping(bytes32 => uint256) public queuedTransactions;

    uint256 public constant MIN_TIMELOCK_PERIOD = 1 hours;
    uint256 public constant MAX_TIMELOCK_PERIOD = 30 days;

    event TransactionExecuted(bytes32 indexed txHash, uint256 timestamp);
    event TransactionQueued(bytes32 indexed txHash, uint256 executeAt, uint256 timestamp);
    event TransactionCancelled(bytes32 indexed txHash, address indexed cancelledBy, uint256 timestamp);
    event OwnerAdded(address indexed newOwner, uint256 timestamp);
    event OwnerRemoved(address indexed removedOwner, uint256 timestamp);
    event AddOwnerQueued(address indexed newOwner, bytes32 indexed txHash, uint256 executeAt);
    event RemoveOwnerQueued(address indexed ownerToRemove, bytes32 indexed txHash, uint256 executeAt);

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
        for (uint256 i = 0; i < _owners.length; ) {
            require(_owners[i] != address(0), "Invalid owner");
            require(!isOwner[_owners[i]], "Duplicate owner");
            isOwner[_owners[i]] = true;
            unchecked { ++i; }
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

    function cancelTransaction(bytes32 txHash) external onlyOwner {
        require(queuedTransactions[txHash] > 0, "Transaction not queued");
        delete queuedTransactions[txHash];
        emit TransactionCancelled(txHash, msg.sender, block.timestamp);
    }

    // =========================================================================
    // Timelocked Owner Management
    // =========================================================================

    /// @notice Queue a request to add a new owner. Must be executed after timeLockPeriod.
    /// @param newOwner  Address to grant ownership.
    /// @param salt      Unique salt to differentiate concurrent requests for the same address.
    function queueAddOwner(address newOwner, uint256 salt) external onlyOwner returns (bytes32 txHash) {
        require(newOwner != address(0), "Invalid owner address");
        require(!isOwner[newOwner], "Already an owner");
        txHash = keccak256(abi.encode("addOwner", newOwner, salt));
        require(queuedTransactions[txHash] == 0, "Already queued");
        queuedTransactions[txHash] = block.timestamp + timeLockPeriod;
        emit AddOwnerQueued(newOwner, txHash, queuedTransactions[txHash]);
    }

    /// @notice Execute a previously queued addOwner request after the timelock expires.
    /// @param newOwner Address to grant ownership (must match the queued request).
    /// @param salt     Salt used when queuing (must match the queued request).
    function executeAddOwner(address newOwner, uint256 salt) external onlyOwner {
        bytes32 txHash = keccak256(abi.encode("addOwner", newOwner, salt));
        require(queuedTransactions[txHash] > 0, "Transaction not queued");
        require(block.timestamp >= queuedTransactions[txHash], "Transaction is still locked");
        require(newOwner != address(0), "Invalid owner address");
        require(!isOwner[newOwner], "Already an owner");
        delete queuedTransactions[txHash];
        isOwner[newOwner] = true;
        owners.push(newOwner);
        emit OwnerAdded(newOwner, block.timestamp);
    }

    /// @notice Queue a request to remove an owner. Must be executed after timeLockPeriod.
    /// @param ownerToRemove Address to remove.
    /// @param salt          Unique salt to differentiate concurrent requests.
    function queueRemoveOwner(address ownerToRemove, uint256 salt) external onlyOwner returns (bytes32 txHash) {
        require(isOwner[ownerToRemove], "Not an owner");
        require(owners.length > 1, "Cannot remove last owner");
        txHash = keccak256(abi.encode("removeOwner", ownerToRemove, salt));
        require(queuedTransactions[txHash] == 0, "Already queued");
        queuedTransactions[txHash] = block.timestamp + timeLockPeriod;
        emit RemoveOwnerQueued(ownerToRemove, txHash, queuedTransactions[txHash]);
    }

    /// @notice Execute a previously queued removeOwner request after the timelock expires.
    /// @param ownerToRemove Address to remove (must match the queued request).
    /// @param salt          Salt used when queuing (must match the queued request).
    function executeRemoveOwner(address ownerToRemove, uint256 salt) external onlyOwner {
        bytes32 txHash = keccak256(abi.encode("removeOwner", ownerToRemove, salt));
        require(queuedTransactions[txHash] > 0, "Transaction not queued");
        require(block.timestamp >= queuedTransactions[txHash], "Transaction is still locked");
        require(isOwner[ownerToRemove], "Not an owner");
        require(owners.length > 1, "Cannot remove last owner");
        delete queuedTransactions[txHash];
        isOwner[ownerToRemove] = false;
        uint256 len = owners.length;
        for (uint256 i = 0; i < len; ) {
            if (owners[i] == ownerToRemove) {
                owners[i] = owners[len - 1];
                owners.pop();
                break;
            }
            unchecked { ++i; }
        }
        emit OwnerRemoved(ownerToRemove, block.timestamp);
    }
}
