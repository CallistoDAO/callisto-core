// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.30;

import { ERC20 } from "../../../dependencies/solmate-6.8.0/src/tokens/ERC20.sol";
import { Module } from "../../Kernel.sol";

/// @notice Treasury holds all other assets under the control of the protocol.
abstract contract TRSRYv1 is Module {
    // =========  EVENTS ========= //

    event IncreaseWithdrawApproval(address indexed withdrawer, ERC20 indexed token, uint256 newAmount);
    event DecreaseWithdrawApproval(address indexed withdrawer, ERC20 indexed token, uint256 newAmount);
    event Withdrawal(address indexed policy_, address indexed withdrawer, ERC20 indexed token, uint256 amount);

    // =========  ERRORS ========= //

    error TRSRY_NotActive();

    // =========  STATE ========= //

    /// @notice Status of the treasury. If false, no withdrawals or debt can be incurred.
    bool public active;

    /// @notice Mapping of who is approved for withdrawal.
    /// @dev    withdrawer -> token -> amount. Infinite approval is max(uint256).
    mapping(address => mapping(ERC20 => uint256)) public withdrawApproval;

    // =========  FUNCTIONS ========= //

    modifier onlyWhileActive() {
        if (!active) revert TRSRY_NotActive();
        _;
    }

    /// @notice Increase approval for specific withdrawer addresses
    function increaseWithdrawApproval(address withdrawer, ERC20 token, uint256 amount) external virtual;

    /// @notice Decrease approval for specific withdrawer addresses
    function decreaseWithdrawApproval(address withdrawer, ERC20 token, uint256 amount) external virtual;

    /// @notice Allow withdrawal of reserve funds from pre-approved addresses.
    function withdrawReserves(address to_, ERC20 token, uint256 amount) external virtual;

    /// @notice Get total balance of assets inside the treasury + any debt taken out against those assets.
    function getReserveBalance(ERC20 token) external view virtual returns (uint256);

    /// @notice Emergency shutdown of withdrawals.
    function deactivate() external virtual;

    /// @notice Re-activate withdrawals after shutdown.
    function activate() external virtual;
}
