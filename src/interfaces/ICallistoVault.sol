// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IDLGTEv1 } from "../../dependencies/olympus-v3-3.0.0/src/modules/DLGTE/IDLGTE.v1.sol";

interface ICallistoVault {
    /**
     * @dev Allows to apply delegations of gOHM collateral on behalf of the vault in Olympus Cooler Loans V2.
     *
     * This function enables the Callisto CDP market to delegate the vault's gOHM collateral that corresponds to
     * account's cOHM collateral deposit.
     */
    function applyDelegations(IDLGTEv1.DelegationRequest[] calldata requests)
        external
        returns (uint256 totalDelegated, uint256 totalUndelegated, uint256 undelegatedBalance);
}
