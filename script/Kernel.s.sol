// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Kernel } from "../src/Kernel.sol";
import { BaseScript } from "./BaseScript.sol";

contract DeployKernel is BaseScript {
    bytes32 private constant _SALT = keccak256(abi.encode("Kernel_V1"));

    function run() public {
        address kernel = _envOr("DEPLOYED_KERNEL", address(0));
        if (kernel.code.length == 0 || kernel == address(0)) {
            vm.startBroadcast(deployer);
            kernel = address(new Kernel());
            vm.stopBroadcast();
            _printContract("DEPLOYED_KERNEL", address(kernel), true);
        } else {
            _printContract("DEPLOYED_KERNEL", kernel, false);
        }
    }
}
