// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import { MockCOLLAR } from "../mocks/MockCOLLAR.sol";
import { MockStabilityPool } from "../mocks/MockStabilityPool.sol";
import { CallistoVaultTestForkBase } from "./CallistoVaultTestForkBase.sol";

abstract contract CallistoVaultTestForkCDP is CallistoVaultTestForkBase {
    MockStabilityPool public stabilityPool;

    function setUp() public virtual {
        // Create collar and stabilityPool
        MockCOLLAR _collar = new MockCOLLAR();

        vm.startPrank(admin);
        stabilityPool = new MockStabilityPool(address(_collar));
        vm.stopPrank();

        // Call parent setUp with the created components
        super.setUpKernel();
        super.setupVault(address(_collar), address(stabilityPool));
    }
}
