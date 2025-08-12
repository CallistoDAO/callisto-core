// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { console } from "../dependencies/forge-std-1.9.6/src/console.sol";
import { Actions, Kernel, Policy } from "../src/Kernel.sol";
import { VaultStrategy } from "../src/external/VaultStrategy.sol";
import { CommonRoles } from "../src/libraries/CommonRoles.sol";
import { CallistoVault } from "../src/policies/CallistoVault.sol";
import { RolesAdmin } from "../src/policies/RolesAdmin.sol";
import { BaseScript } from "./BaseScript.sol";

contract DeployCallistoVault is BaseScript {
    bytes32 private constant _SALT = keccak256(abi.encode("CallistoVault_V1"));

    function run() public {
        address kernel = _envAddress("DEPLOYED_KERNEL");
        Kernel DEPLOYED_KERNEL = Kernel(kernel);
        address ohm = _envAddress("OHM_TOKEN");
        address staking = _envAddress("OLYMPUS_STAKING");
        address cooler = _envAddress("OLYMPUS_COOLER");
        address vaultStrategy = _envAddress("DEPLOYED_VAULT_STRATEGY");
        address converterToWadDebt = _envAddress("DEPLOYED_CONVERTER_TO_WAD_DEBT");
        uint256 minDeposit = _envOr("MIN_DEPOSIT", 100e9); // 100 OHM default

        CallistoVault.InitialParameters memory params = CallistoVault.InitialParameters({
            asset: ohm,
            olympusStaking: staking,
            olympusCooler: cooler,
            strategy: vaultStrategy,
            debtConverterToWad: converterToWadDebt,
            minDeposit: minDeposit
        });

        bytes memory encodedArgs = abi.encode(kernel, params);
        bytes memory initCode = abi.encodePacked(type(CallistoVault).creationCode, encodedArgs);
        string memory name = type(CallistoVault).name;
        address vault = _deploy(name, "DEPLOYED_CALLISTO_VAULT", _SALT, initCode, true);

        if (!DEPLOYED_KERNEL.isPolicyActive(Policy(vault))) {
            vm.startBroadcast(deployer);
            DEPLOYED_KERNEL.executeAction(Actions.ActivatePolicy, vault);
            vm.stopBroadcast();
            console.log("CallistoVault policy activated successfully");
            vm.assertTrue(DEPLOYED_KERNEL.isPolicyActive(Policy(vault)), "CallistoVault policy is active");
        } else {
            console.log("CallistoVault policy already active, skipping activation");
        }
        address MANAGER_ADDRESS = _envAddress("MANAGER_ADDRESS");
        address roles = _envAddress("DEPLOYED_ROLES_ADMIN");
        RolesAdmin rolesAdmin = RolesAdmin(roles);
        if (!rolesAdmin.ROLES().hasRole(MANAGER_ADDRESS, CommonRoles.MANAGER)) {
            console.log("Granting MANAGER role to MANAGER_ADDRESS via admin", rolesAdmin.admin());
            vm.startBroadcast(deployer);
            rolesAdmin.grantRole(CommonRoles.MANAGER, MANAGER_ADDRESS);
            vm.stopBroadcast();
            vm.assertTrue(
                rolesAdmin.ROLES().hasRole(MANAGER_ADDRESS, CommonRoles.MANAGER), "MANAGER_ADDRESS has MANAGER role"
            );
        } else {
            console.log("MANAGER_ADDRESS already has MANAGER role, skipping grant");
        }
        VaultStrategy strategy = VaultStrategy(vaultStrategy);
        if (strategy.vault() == address(0)) {
            console.log("Setting vault address in strategy");
            vm.startBroadcast(deployer);
            strategy.initVault(vault);
            vm.stopBroadcast();
        } else {
            console.log("Vault address already set in strategy, skipping set");
        }
    }
}
