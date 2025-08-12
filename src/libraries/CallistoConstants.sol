// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

/**
 * @notice Vault Constants library to keep constant values to use in multiple places without increase contract bytecode.
 */
library CallistoConstants {
    /// @notice Minimum deposit bound
    uint256 internal constant MIN_OHM_DEPOSIT_BOUND = 1e9;
}
