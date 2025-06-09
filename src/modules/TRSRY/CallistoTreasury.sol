// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.30;

import { ERC20 } from "../../../dependencies/solmate-6.8.0/src/tokens/ERC20.sol";
import { Kernel, Keycode, Module } from "../../Kernel.sol";
import { TransferHelper } from "../../libraries/TransferHelper.sol";
import { TRSRYv1 } from "./TRSRY.v1.sol";

/// @notice Treasury holds all other assets under the control of the protocol.
contract CallistoTreasury is TRSRYv1 {
    using TransferHelper for ERC20;

    //============================================================================================//
    //                                      MODULE SETUP                                          //
    //============================================================================================//

    constructor(Kernel kernel_) Module(kernel_) {
        active = true;
    }

    /// @inheritdoc Module
    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap(0x5452535259); // `toKeycode("TRSRY")`.
    }

    /// @inheritdoc Module
    function VERSION() external pure override returns (uint8, uint8) {
        return (1, 0);
    }

    //============================================================================================//
    //                                       CORE FUNCTIONS                                       //
    //============================================================================================//

    /// @inheritdoc TRSRYv1
    function increaseWithdrawApproval(address withdrawer, ERC20 token, uint256 amount) external override permissioned {
        uint256 approval = withdrawApproval[withdrawer][token];

        uint256 newAmount = type(uint256).max - approval <= amount ? type(uint256).max : approval + amount;
        withdrawApproval[withdrawer][token] = newAmount;

        emit IncreaseWithdrawApproval(withdrawer, token, newAmount);
    }

    /// @inheritdoc TRSRYv1
    function decreaseWithdrawApproval(address withdrawer, ERC20 token, uint256 amount) external override permissioned {
        uint256 approval = withdrawApproval[withdrawer][token];

        uint256 newAmount = approval <= amount ? 0 : approval - amount;
        withdrawApproval[withdrawer][token] = newAmount;

        emit DecreaseWithdrawApproval(withdrawer, token, newAmount);
    }

    /// @inheritdoc TRSRYv1
    function withdrawReserves(address to, ERC20 token, uint256 amount) public override permissioned onlyWhileActive {
        withdrawApproval[msg.sender][token] -= amount;
        token.safeTransfer(to, amount);
        emit Withdrawal(msg.sender, to, token, amount);
    }

    /// @inheritdoc TRSRYv1
    function deactivate() external override permissioned {
        active = false;
    }

    /// @inheritdoc TRSRYv1
    function activate() external override permissioned {
        active = true;
    }

    //============================================================================================//
    //                                       VIEW FUNCTIONS                                       //
    //============================================================================================//

    /// @inheritdoc TRSRYv1
    function getReserveBalance(ERC20 token) external view override returns (uint256) {
        return token.balanceOf(address(this));
    }
}
