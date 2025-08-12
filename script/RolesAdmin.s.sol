// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { console } from "../dependencies/forge-std-1.9.6/src/console.sol";
import { Actions, Kernel, Policy } from "../src/Kernel.sol";
import { CommonRoles } from "../src/libraries/CommonRoles.sol";
import { RolesAdmin } from "../src/policies/RolesAdmin.sol";
import { BaseScript } from "./BaseScript.sol";

contract DeployCallistoRoles is BaseScript {
    bytes32 private constant _SALT = keccak256(abi.encode("RolesAdmin_V1"));

    function run() public {
        Kernel DEPLOYED_KERNEL = Kernel(_envAddress("DEPLOYED_KERNEL"));
        address roles = _envOr("DEPLOYED_ROLES_ADMIN", address(0));
        if (roles.code.length == 0 || roles == address(0)) {
            vm.startBroadcast(deployer);
            roles = address(new RolesAdmin(DEPLOYED_KERNEL));
            vm.stopBroadcast();
            _printContract("DEPLOYED_ROLES_ADMIN", address(roles), true);
        } else {
            _printContract("DEPLOYED_ROLES_ADMIN", roles, false);
        }

        if (!DEPLOYED_KERNEL.isPolicyActive(Policy(roles))) {
            vm.startBroadcast(deployer);
            DEPLOYED_KERNEL.executeAction(Actions.ActivatePolicy, roles);
            vm.stopBroadcast();
            console.log("RolesAdmin policy activated successfully");
            vm.assertTrue(DEPLOYED_KERNEL.isPolicyActive(Policy(roles)), "RolesAdmin policy is active");
        } else {
            console.log("RolesAdmin policy already active, skipping activation");
        }

        address admin = _envAddress(CALLISTO_ADMIN);
        RolesAdmin rolesAdmin = RolesAdmin(roles);

        if (!rolesAdmin.ROLES().hasRole(admin, CommonRoles.ADMIN)) {
            console.log("Granting admin role to admin", rolesAdmin.admin());
            vm.startBroadcast(deployer);
            rolesAdmin.grantRole(CommonRoles.ADMIN, admin);
            vm.stopBroadcast();
            vm.assertTrue(rolesAdmin.ROLES().hasRole(admin, CommonRoles.ADMIN), "Deployer has admin role");
        } else {
            console.log("Admin already has ADMIN role, skipping grant");
        }
    }
}
