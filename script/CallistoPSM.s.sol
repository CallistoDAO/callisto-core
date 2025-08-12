// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { console } from "../dependencies/forge-std-1.9.6/src/console.sol";
import { CallistoPSM } from "../src/external/CallistoPSM.sol";
import { BaseScript } from "./BaseScript.sol";

contract DeployCallistoPSM is BaseScript {
    bytes32 private constant _SALT = keccak256(abi.encode("CallistoPSM_V1"));

    function run() public {
        address admin = _envAddress(CALLISTO_ADMIN);
        address usds = _envAddress("USDS_TOKEN");
        address collar = _envAddress("DEPLOYED_DEBT_TOKEN");
        address susds = _envAddress("SUSDS_TOKEN");
        address psmStrategy = _envAddress("DEPLOYED_PSM_STRATEGY");
        address debtTokenMigrator = _envAddress("DEPLOYED_DEBT_TOKEN_MIGRATOR");

        // deployer - default admin
        bytes memory encodedArgs = abi.encode(deployer, usds, collar, susds, psmStrategy, debtTokenMigrator);
        bytes memory initCode = abi.encodePacked(type(CallistoPSM).creationCode, encodedArgs);
        string memory name = type(CallistoPSM).name;
        address psm = _deploy(name, "DEPLOYED_CALLISTO_PSM", _SALT, initCode, true);
        CallistoPSM psmContract = CallistoPSM(psm);

        bytes32 ADMIN_ROLE = psmContract.ADMIN_ROLE();
        if (!psmContract.hasRole(ADMIN_ROLE, admin)) {
            vm.startBroadcast(deployer);
            psmContract.grantRole(ADMIN_ROLE, admin);
            psmContract.grantRole(ADMIN_ROLE, deployer);
            vm.stopBroadcast();
            console.log("CallistoPSM - ADMIN_ROLE granted successfully to admin");
            vm.assertTrue(psmContract.hasRole(ADMIN_ROLE, admin), "admin has ADMIN_ROLE");
        } else {
            console.log("CallistoPSM - Admin already has ADMIN_ROLE, skipping grant");
        }
        // TODO: remove deployer default admin
        // TODO: add call of psmStrategy.finalizeInitialization
    }
}
