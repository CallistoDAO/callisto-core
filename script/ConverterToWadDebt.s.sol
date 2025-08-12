// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ConverterToWadDebt } from "../src/external/ConverterToWadDebt.sol";
import { BaseScript } from "./BaseScript.sol";

contract DeployConverterToWadDebt is BaseScript {
    bytes32 private constant _SALT = keccak256(abi.encode("ConverterToWadDebt_V1"));

    function run() public {
        bytes memory initCode = abi.encodePacked(type(ConverterToWadDebt).creationCode);
        string memory name = type(ConverterToWadDebt).name;
        _deploy(name, "DEPLOYED_CONVERTER_TO_WAD_DEBT", _SALT, initCode, true);
    }
}
