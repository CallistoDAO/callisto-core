// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.29;

import { CallistoVault, Kernel } from "../../src/policies/CallistoVault.sol";

contract CallistoVaultTester is CallistoVault {
    constructor(Kernel kernel, InitialParameters memory p) CallistoVault(kernel, p) { }

    function convertOHMToGOHM(uint256 ohmAmount) external view returns (uint256 gOHMAmount) {
        return _convertOHMToGOHM(ohmAmount);
    }
}
