// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFlashLoanReceiver
/// @notice Interface that any flash loan receiver must implement to receive funds from FlashLoanProvider.
interface IFlashLoanReceiver {
    /// @notice Called by FlashLoanProvider after transferring `amount` of `token` to this contract.
    /// @dev The implementor MUST repay `amount + fee` of `token` back to the FlashLoanProvider
    ///      within this call, otherwise the transaction will revert.
    /// @param initiator  The address that initiated the flash loan.
    /// @param token      The ERC-20 token being flash-loaned.
    /// @param amount     The principal amount loaned.
    /// @param fee        The fee that must be repaid on top of `amount`.
    /// @param data       Arbitrary data forwarded from the initiator.
    /// @return           Must return `CALLBACK_SUCCESS = keccak256("FlashLoanReceiver.onFlashLoan")`.
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32);
}
