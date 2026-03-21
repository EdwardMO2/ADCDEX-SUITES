// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/// @title BondingMechanismPatched (Legacy)
/// @notice Patched bonding mechanism with discount calculation.
/// @dev    Root-level file moved to contracts/legacy/.
///         Uses non-upgradeable OZ contracts; for an upgradeable deployment use
///         contracts/BondingMechanism.sol instead.
contract BondingMechanismPatched is Ownable, Pausable {
    mapping(address => uint256) public assetADC;

    constructor() Ownable() {}

    /// @notice Pause the contract. Only the owner may call this.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract. Only the owner may call this.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Returns the discounted ADC amount for a given asset token.
    /// @param assetToken  Token address to look up.
    /// @param discountRate Percentage discount (0–100).
    function getDiscountedADC(address assetToken, uint256 discountRate)
        public
        view
        whenNotPaused
        returns (uint256)
    {
        uint256 baseADC = assetADC[assetToken];
        require(discountRate <= 100, "Discount rate must be between 0 and 100");
        return baseADC * (100 - discountRate) / 100;
    }
}
