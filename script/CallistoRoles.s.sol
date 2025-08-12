// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { console } from "../dependencies/forge-std-1.9.6/src/console.sol";
import { Actions, Kernel, Keycode } from "../src/Kernel.sol";
import { CallistoRoles } from "../src/modules/ROLES/CallistoRoles.sol";
import { BaseScript } from "./BaseScript.sol";

contract DeployCallistoRoles is BaseScript {
    bytes32 private constant _SALT = keccak256(abi.encode("CallistoRoles_V1"));

    function run() public {
        Kernel DEPLOYED_KERNEL = Kernel(_envAddress("DEPLOYED_KERNEL"));
        bytes memory encodedArgs = abi.encode(DEPLOYED_KERNEL);
        bytes memory initCode = abi.encodePacked(type(CallistoRoles).creationCode, encodedArgs);
        string memory name = type(CallistoRoles).name;
        address roles = _deploy(name, "DEPLOYED_CALLISTO_ROLES", _SALT, initCode, true);
        CallistoRoles callistoRoles = CallistoRoles(roles);
        Keycode keycode = callistoRoles.KEYCODE();
        if (address(DEPLOYED_KERNEL.getModuleForKeycode(keycode)) == address(0)) {
            vm.startBroadcast(deployer);
            DEPLOYED_KERNEL.executeAction(Actions.InstallModule, roles);
            vm.stopBroadcast();
            console.log("CallistoRoles module installed successfully");
            vm.assertEq(
                address(DEPLOYED_KERNEL.getModuleForKeycode(keycode)), roles, "CallistoRoles module not installed"
            );
        } else {
            console.log("CallistoRoles module already installed, skipping installation");
        }
    }
}
