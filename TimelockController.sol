// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract TimelockController {
    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public timeLockPeriod;
    mapping(bytes32 => uint256) public queuedTransactions;

    event TransactionExecuted(bytes32 indexed txHash);
    event TransactionQueued(bytes32 indexed txHash, uint256 executeAt);

    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not an owner");
        _;
    }

    constructor(address[] memory _owners, uint256 _timeLockPeriod) {
        require(_owners.length > 0, "Must have owners");
        for (uint i = 0; i < _owners.length; i++) {
            require(_owners[i] != address(0), "Invalid owner");
            isOwner[_owners[i]] = true;
        }
        owners = _owners;
        timeLockPeriod = _timeLockPeriod;
    }

    function queueTransaction(bytes32 txHash) external onlyOwner {
        require(queuedTransactions[txHash] == 0, "Transaction already queued");
        queuedTransactions[txHash] = block.timestamp + timeLockPeriod;
        emit TransactionQueued(txHash, queuedTransactions[txHash]);
    }

    function executeTransaction(bytes32 txHash) external onlyOwner {
        require(queuedTransactions[txHash] > 0, "Transaction not queued");
        require(block.timestamp >= queuedTransactions[txHash], "Transaction is still locked");

        delete queuedTransactions[txHash];
        emit TransactionExecuted(txHash);
    }
}
