// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/**
 * @title BondingMechanism - Enhanced Version
 * @notice Bonding mechanism with pause functionality and emergency controls
 */
contract BondingMechanism is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    
    IERC20Upgradeable public adcToken;
    address public treasury;

    struct Bond {
        uint256 amountADC;
        uint256 vestingEnd;
        uint256 claimed;
    }

    uint256 public vestingDuration;
    uint256 public discountBps;

    mapping(address => Bond[]) public userBonds;

    event BondCreated(address indexed user, uint256 indexed bondId, uint256 adcAmount, uint256 vestingEnd);
    event BondClaimed(address indexed user, uint256 indexed bondId, uint256 claimedAmount);
    event EmergencyWithdrawal(address indexed recipient, address indexed token, uint256 amount);

    function initialize(
        address _adcToken,
        address _treasury,
        uint256 _vestingDuration,
        uint256 _discountBps,
        address _owner
    ) public initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        __Pausable_init();

        adcToken = IERC20Upgradeable(_adcToken);
        treasury = _treasury;
        vestingDuration = _vestingDuration;
        discountBps = _discountBps;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Bond assets with pause protection
    /// @param token Token to bond
    /// @param amount Amount of tokens to bond
    function bondAsset(address token, uint256 amount) external whenNotPaused {
        require(amount > 0, "Invalid amount");

        IERC20Upgradeable(token).safeTransferFrom(msg.sender, treasury, amount);

        uint256 adcOut = getDiscountedADC(amount, token);

        Bond memory newBond = Bond({
            amountADC: adcOut,
            vestingEnd: block.timestamp + vestingDuration,
            claimed: 0
        });

        userBonds[msg.sender].push(newBond);

        emit BondCreated(msg.sender, userBonds[msg.sender].length - 1, adcOut, newBond.vestingEnd);
    }

    /// @notice Claim bonded tokens with pause protection
    /// @param bondId ID of the bond to claim
    function claim(uint256 bondId) external whenNotPaused {
        Bond storage bond = userBonds[msg.sender][bondId];
        require(block.timestamp >= bond.vestingEnd, "Bond still vesting");
        require(bond.claimed < bond.amountADC, "Already claimed");

        uint256 claimable = bond.amountADC - bond.claimed;
        bond.claimed = bond.amountADC;

        adcToken.safeTransfer(msg.sender, claimable);

        emit BondClaimed(msg.sender, bondId, claimable);
    }

    /// @notice Get discounted ADC amount
    /// @param assetAmount Amount of assets being bonded
    /// @param assetToken Token address (unused in base implementation)
    /// @return adcAmount Amount of ADC to receive
    function getDiscountedADC(uint256 assetAmount, address /* assetToken */) public view returns (uint256) {
        uint256 adcAmount = assetAmount * (10000 + discountBps) / 10000;
        return adcAmount;
    }

    /// @notice Get user's bond count
    /// @param user Address of the user
    /// @return Number of bonds for this user
    function userBondCount(address user) external view returns (uint256) {
        return userBonds[user].length;
    }

    /// @notice Set discount basis points
    /// @param _discountBps New discount in basis points
    function setDiscountBps(uint256 _discountBps) external onlyOwner {
        require(_discountBps <= 2000, "Too high"); // Max 20%
        discountBps = _discountBps;
    }

    /// @notice Set vesting duration
    /// @param _vestingDuration New vesting duration in seconds
    function setVestingDuration(uint256 _vestingDuration) external onlyOwner {
        require(_vestingDuration > 0, "Invalid duration");
        vestingDuration = _vestingDuration;
    }

    /// @notice Emergency pause all bonding operations
    function emergencyPause() external onlyOwner {
        _pause();
    }

    /// @notice Resume bonding operations
    function emergencyUnpause() external onlyOwner {
        _unpause();
    }

    /// @notice Emergency withdrawal of tokens (only owner, when paused)
    /// @param token Token to withdraw
    /// @param recipient Address to receive tokens
    /// @param amount Amount to withdraw
    function emergencyWithdraw(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOwner whenPaused {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
        
        IERC20Upgradeable(token).safeTransfer(recipient, amount);
        emit EmergencyWithdrawal(recipient, token, amount);
    }
}
