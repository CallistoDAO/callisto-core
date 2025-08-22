// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "../../dependencies/@openzeppelin-contracts-5.3.0/access/AccessControl.sol";
import {
    ERC20,
    ERC20Permit,
    Nonces
} from "../../dependencies/@openzeppelin-contracts-5.3.0/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "../../dependencies/@openzeppelin-contracts-5.3.0/token/ERC20/extensions/ERC20Votes.sol";

/// @notice The governance token of the Callisto protocol.
contract CallistoToken is AccessControl, ERC20Permit, ERC20Votes {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    error AdminEqZeroAddress();

    constructor(address defaultAdmin) ERC20("Callisto Token", "CALL") ERC20Permit("Callisto Token") {
        require(defaultAdmin != address(0), AdminEqZeroAddress());
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /**
     * @notice Destroys an `amount` of tokens from `from`, deducting from the caller's allowance.
     *
     * Requirements: the caller should have the `MINTER_ROLE` role and allowance for `from`'s tokens of at least
     * `amount`.
     */
    function burnFrom(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        _spendAllowance(from, _msgSender(), amount);
        _burn(from, amount);
    }

    // The following functions are overrides required by Solidity.

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}
