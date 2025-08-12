// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { CallistoToken } from "../src/external/CallistoToken.sol";
import { BaseScript } from "./BaseScript.sol";

contract DeployCallistoToken is BaseScript {
    bytes32 private constant _SALT = keccak256(abi.encode("CallistoToken_V1"));

    function run() public {
        address dahliaOwner = _envAddress(CALLISTO_ADMIN);
        bytes memory encodedArgs = abi.encode(dahliaOwner);
        bytes memory initCode = abi.encodePacked(type(CallistoToken).creationCode, encodedArgs);
        string memory name = type(CallistoToken).name;
        _deploy(name, "DEPLOYED_CALLISTO_TOKEN", _SALT, initCode, true);
    }
}
