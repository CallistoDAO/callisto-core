// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import { Actions, Kernel } from "../../src/Kernel.sol";
import { CommonRoles } from "../../src/libraries/CommonRoles.sol";
import { CallistoRoles } from "../../src/modules/ROLES/CallistoRoles.sol";
import { CallistoTreasury } from "../../src/modules/TRSRY/CallistoTreasury.sol";
import { RolesAdmin } from "../../src/policies/RolesAdmin.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { CommonUtilities } from "../test-common/lib/CommonUtilities.sol";
import { CallistoVaultTester } from "../testers/CallstoVaultTester.sol";
import { Test } from "forge-std-1.9.6/Test.sol";

abstract contract KernelTestBase is Test {
    address[] accounts;
    address admin;

    Kernel kernel;
    CallistoRoles roles;
    RolesAdmin rolesAdmin;
    CallistoTreasury treasury;

    CallistoVaultTester public vault;
    MockERC20 public ohm;

    constructor() {
        accounts = (new CommonUtilities()).createAccounts(3, "account");
        admin = makeAddr("[ Admin ]");
    }

    function setUpKernel() public virtual {
        // Deploy Kernel and roles.
        kernel = new Kernel();
        roles = new CallistoRoles(kernel);
        rolesAdmin = new RolesAdmin(kernel);
        treasury = new CallistoTreasury(kernel);

        // Set up the kernel.
        kernel.executeAction(Actions.InstallModule, address(roles));
        kernel.executeAction(Actions.InstallModule, address(treasury));
        kernel.executeAction(Actions.ActivatePolicy, address(rolesAdmin));

        // Grant roles and enable the vault policy.
        rolesAdmin.grantRole(CommonRoles.ADMIN, admin);
    }

    function _depositToVault(address user_, uint256 assets) internal returns (uint256 cOHMAmount) {
        vm.startPrank(user_);
        ohm.approve(address(vault), assets);
        cOHMAmount = vault.deposit(assets, user_);
        vm.stopPrank();
    }

    function _depositToVaultExt(address user_, uint256 assets) internal virtual returns (uint256 cOHMAmount);
}
