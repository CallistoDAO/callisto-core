// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { PSMStrategy } from "../src/external/PSMStrategy.sol";
import { BaseScript } from "./BaseScript.sol";

contract DeployPSMStrategy is BaseScript {
    bytes32 private constant _SALT = keccak256(abi.encode("PSMStrategy_V1"));

    function run() public {
        address defaultAdmin = _envAddress("CALLISTO_ADMIN");
        address stabilityPool = _envAddress("DEPLOYED_STABILITY_POOL");
        address collar = _envAddress("DEPLOYED_DEBT_TOKEN");
        address auctioneer = address(0); // TODO: Change this later to deployed contract
        address treasury = _envAddress("DEPLOYED_CALLISTO_TREASURY");

        bytes memory encodedArgs = abi.encode(defaultAdmin, stabilityPool, collar, auctioneer, treasury);
        bytes memory initCode = abi.encodePacked(type(PSMStrategy).creationCode, encodedArgs);
        string memory name = type(PSMStrategy).name;
        _deploy(name, "DEPLOYED_PSM_STRATEGY", _SALT, initCode, true);
    }
}
