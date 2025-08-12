// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { console } from "../dependencies/forge-std-1.9.6/src/console.sol";
import { Actions, Kernel, Keycode } from "../src/Kernel.sol";
import { CallistoTreasury } from "../src/modules/TRSRY/CallistoTreasury.sol";
import { BaseScript } from "./BaseScript.sol";

contract DeployCallistoTreasury is BaseScript {
    bytes32 private constant _SALT = keccak256(abi.encode("CallistoTreasury_V1"));

    function run() public {
        Kernel DEPLOYED_KERNEL = Kernel(_envAddress("DEPLOYED_KERNEL"));
        bytes memory encodedArgs = abi.encode(DEPLOYED_KERNEL);
        bytes memory initCode = abi.encodePacked(type(CallistoTreasury).creationCode, encodedArgs);
        string memory name = type(CallistoTreasury).name;
        address treasury = _deploy(name, "DEPLOYED_CALLISTO_TREASURY", _SALT, initCode, true);
        CallistoTreasury treasuryContract = CallistoTreasury(treasury);
        Keycode keycode = treasuryContract.KEYCODE();
        if (address(DEPLOYED_KERNEL.getModuleForKeycode(keycode)) == address(0)) {
            vm.startBroadcast(deployer);
            DEPLOYED_KERNEL.executeAction(Actions.InstallModule, treasury);
            vm.stopBroadcast();
            console.log("CallistoTreasury module installed successfully");
            vm.assertEq(
                address(DEPLOYED_KERNEL.getModuleForKeycode(keycode)), treasury, "CallistoTreasury module not installed"
            );
        } else {
            console.log("CallistoTreasury module already installed, skipping installation");
        }
    }
}
