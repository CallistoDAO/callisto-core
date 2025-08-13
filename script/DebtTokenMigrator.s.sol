// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { DebtTokenMigrator } from "../src/external/DebtTokenMigrator.sol";
import { BaseScript } from "./BaseScript.sol";

contract DeployDebtTokenMigrator is BaseScript {
    bytes32 private constant _SALT = keccak256(abi.encode("DebtTokenMigrator_V1"));

    function run() public {
        address admin = _envAddress(CALLISTO_ADMIN);
        address timelock = _envAddress("DEPLOYED_TIMELOCK");
        address cooler = _envAddress("OLYMPUS_COOLER");

        bytes memory encodedArgs = abi.encode(admin, timelock, cooler);
        bytes memory initCode = abi.encodePacked(type(DebtTokenMigrator).creationCode, encodedArgs);
        string memory name = type(DebtTokenMigrator).name;
        _deploy(name, "DEPLOYED_DEBT_TOKEN_MIGRATOR", _SALT, initCode, true);
    }
}
