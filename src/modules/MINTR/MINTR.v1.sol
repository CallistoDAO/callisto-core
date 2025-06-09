// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import { Module } from "../../Kernel.sol";
import { CallistoToken } from "../../external/CallistoToken.sol";

/// @notice Wrapper for minting and burning functions of CALL token.
abstract contract MINTRv1 is Module {
    // =========  EVENTS ========= //

    event IncreaseMintApproval(address indexed policy_, uint256 newAmount_);
    event DecreaseMintApproval(address indexed policy_, uint256 newAmount_);
    event Mint(address indexed policy_, address indexed to_, uint256 amount_);
    event Burn(address indexed policy_, address indexed from_, uint256 amount_);

    // ========= ERRORS ========= //

    error MINTR_NotApproved();
    error MINTR_ZeroAmount();
    error MINTR_NotActive();

    // =========  STATE ========= //

    CallistoToken public callToken;

    /// @notice Status of the minter. If false, minting and burning CALL is disabled.
    bool public active;

    /// @notice Mapping of who is approved for minting.
    /// @dev    minter -> amount. Infinite approval is max(uint256).
    mapping(address => uint256) public mintApproval;

    // =========  FUNCTIONS ========= //

    modifier onlyWhileActive() {
        if (!active) revert MINTR_NotActive();
        _;
    }

    /// @notice Mint CALL to an address.
    function mintCALL(address to_, uint256 amount_) external virtual;

    /// @notice Burn CALL from an address. Must have approval.
    function burnCALL(address from_, uint256 amount_) external virtual;

    /// @notice Increase approval for specific withdrawer addresses
    /// @dev    Policies must explicity request how much they want approved before withdrawing.
    function increaseMintApproval(address policy_, uint256 amount_) external virtual;

    /// @notice Decrease approval for specific withdrawer addresses
    function decreaseMintApproval(address policy_, uint256 amount_) external virtual;

    /// @notice Emergency shutdown of minting and burning.
    function deactivate() external virtual;

    /// @notice Re-activate minting and burning after shutdown.
    function activate() external virtual;
}
