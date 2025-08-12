// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

library CommonRoles {
    /// @dev Administrative access, e.g. configuration parameters. Typically assigned to on-chain governance.
    bytes32 internal constant ADMIN = "admin";

    /// @dev Managerial access, e.g. managing specific protocol parameters. Typically assigned to a multisig/council.
    bytes32 internal constant MANAGER = "manager";

    /// @notice The `account` is missing a role.
    error Unauthorized(address account);
}
