// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { console } from "../dependencies/forge-std-1.9.6/src/console.sol";
import { Actions, Kernel, Keycode } from "../src/Kernel.sol";
import { CallistoMinter } from "../src/modules/MINTR/CallistoMinter.sol";
import { BaseScript } from "./BaseScript.sol";

contract DeployCallistoMinter is BaseScript {
    bytes32 private constant _SALT = keccak256(abi.encode("CallistoMinter_V1"));

    function run() public {
        address kernel = _envAddress("DEPLOYED_KERNEL");
        Kernel DEPLOYED_KERNEL = Kernel(kernel);
        address callToken = _envAddress("DEPLOYED_CALLISTO_TOKEN");

        bytes memory encodedArgs = abi.encode(kernel, callToken);
        bytes memory initCode = abi.encodePacked(type(CallistoMinter).creationCode, encodedArgs);
        string memory name = type(CallistoMinter).name;
        address minter = _deploy(name, "DEPLOYED_CALLISTO_MINTER", _SALT, initCode, true);
        CallistoMinter minterContract = CallistoMinter(minter);
        Keycode keycode = minterContract.KEYCODE();

        if (address(DEPLOYED_KERNEL.getModuleForKeycode(keycode)) == address(0)) {
            vm.startBroadcast(deployer);
            DEPLOYED_KERNEL.executeAction(Actions.InstallModule, minter);
            vm.stopBroadcast();
            console.log("CallistoMinter module installed successfully");
            vm.assertEq(
                address(DEPLOYED_KERNEL.getModuleForKeycode(keycode)), minter, "CallistoMinter module not installed"
            );
        } else {
            console.log("CallistoMinter module already installed, skipping installation");
        }
    }
}
