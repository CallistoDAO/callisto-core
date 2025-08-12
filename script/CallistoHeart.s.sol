// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { console } from "../dependencies/forge-std-1.9.6/src/console.sol";
import { Actions, Kernel, Policy } from "../src/Kernel.sol";
import { CallistoHeart } from "../src/policies/CallistoHeart.sol";
import { CallistoVault } from "../src/policies/CallistoVault.sol";
import { RolesAdmin } from "../src/policies/RolesAdmin.sol";
import { BaseScript } from "./BaseScript.sol";

contract DeployCallistoHeart is BaseScript {
    bytes32 private constant _SALT = keccak256(abi.encode("CallistoHeart_V1"));

    function run() public {
        address kernel = _envAddress("DEPLOYED_KERNEL");
        Kernel DEPLOYED_KERNEL = Kernel(kernel);
        address callistoVault = _envAddress("DEPLOYED_CALLISTO_VAULT");
        address psmStrategy = _envAddress("DEPLOYED_CALLISTO_PSM");

        // Heart configuration parameters
        uint48 frequency = uint48(_envUint("HEART_FREQUENCY")); // 24 hours default
        uint48 auctionDuration = uint48(_envUint("HEART_AUCTION_DURATION")); // 1 hour default
        uint256 maxReward = _envOr("HEART_MAX_REWARD", 1e18); // 1 token default

        bytes memory encodedArgs = abi.encode(kernel, callistoVault, psmStrategy, frequency, auctionDuration, maxReward);
        bytes memory initCode = abi.encodePacked(type(CallistoHeart).creationCode, encodedArgs);
        string memory name = type(CallistoHeart).name;
        address heart = _deploy(name, "DEPLOYED_CALLISTO_HEART", _SALT, initCode, true);
        CallistoHeart callistoHeart = CallistoHeart(heart);

        if (!DEPLOYED_KERNEL.isPolicyActive(Policy(heart))) {
            vm.startBroadcast(deployer);
            DEPLOYED_KERNEL.executeAction(Actions.ActivatePolicy, heart);
            vm.stopBroadcast();
            console.log("CallistoHeart policy activated successfully");
            vm.assertTrue(DEPLOYED_KERNEL.isPolicyActive(Policy(heart)), "CallistoHeart policy is active");
        } else {
            console.log("CallistoHeart policy already active, skipping activation");
        }

        address admin = _envAddress(CALLISTO_ADMIN);
        address roles = _envAddress("DEPLOYED_ROLES_ADMIN");
        RolesAdmin rolesAdmin = RolesAdmin(roles);
        bytes32 HEART_ADMIN_ROLE = callistoHeart.HEART_ADMIN_ROLE();

        if (!rolesAdmin.ROLES().hasRole(admin, HEART_ADMIN_ROLE)) {
            console.log("Granting HEART_ADMIN_ROLE to admin via admin", rolesAdmin.admin());
            vm.startBroadcast(deployer);
            rolesAdmin.grantRole(HEART_ADMIN_ROLE, admin);
            vm.stopBroadcast();
            vm.assertTrue(rolesAdmin.ROLES().hasRole(admin, HEART_ADMIN_ROLE), "Admin has HEART_ADMIN_ROLE");
        } else {
            console.log("Admin already has HEART_ADMIN_ROLE, skipping grant");
        }

        bytes32 HEART_ROLE = CallistoVault(callistoVault).HEART_ROLE();

        if (!rolesAdmin.ROLES().hasRole(heart, HEART_ROLE)) {
            console.log("Granting HEART_ROLE to HEART_ADDRESS via admin", rolesAdmin.admin());
            vm.startBroadcast(deployer);
            rolesAdmin.grantRole(HEART_ROLE, heart);
            vm.stopBroadcast();
            vm.assertTrue(rolesAdmin.ROLES().hasRole(heart, HEART_ROLE), "HEART_ADDRESS has HEART_ROLE");
        } else {
            console.log("HEART_ADDRESS already has HEART_ROLE, skipping grant");
        }
    }
}
