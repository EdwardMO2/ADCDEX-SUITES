// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

// Use SafeERC20 for all token transfers in upgradeable contracts
// Remove invalid documentation tags referencing file paths

contract CBDCBridgePatched {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    function mintToDEX(address token, address recipient, uint256 amount) external {
        IERC20Upgradeable(token).safeTransferFrom(msg.sender, recipient, amount);
    }

    function burnFromDEX(address token, address from, uint256 amount) external {
        IERC20Upgradeable(token).safeTransferFrom(from, msg.sender, amount);
    }

    function provideLiquidity(address token, uint256 amount) external {
        IERC20Upgradeable(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdrawLiquidity(address token, uint256 amount) external {
        IERC20Upgradeable(token).safeTransfer(msg.sender, amount);
    }
}

contract BondingMechanismPatched {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    IERC20Upgradeable public adcToken;

    function bondAsset(address token, uint256 amount) external {
        IERC20Upgradeable(token).safeTransferFrom(msg.sender, treasury, amount);
    }

    function claim(uint256 bondId) external {
        adcToken.safeTransfer(msg.sender, claimable);
    }
}

contract MarginTradingPoolPatched {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    IERC20Upgradeable collateralToken;

    function depositCollateral(uint256 amount) external {
        IERC20Upgradeable(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdrawCollateral(uint256 amount) external {
        IERC20Upgradeable(collateralToken).safeTransfer(msg.sender, amount);
    }

    function borrow(uint256 amount) external {
        IERC20Upgradeable(borrowToken).safeTransfer(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        IERC20Upgradeable(borrowToken).safeTransferFrom(msg.sender, address(this), amount);
    }
}