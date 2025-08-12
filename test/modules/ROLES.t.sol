// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import { Actions, Kernel, fromKeycode } from "../../src/Kernel.sol";
import { CallistoRoles } from "../../src/modules/ROLES/CallistoRoles.sol";
import { ROLESv1 } from "../../src/modules/ROLES/ROLES.v1.sol";
import { ModuleTestFixtureGenerator } from "../test-common/lib/ModuleTestFixtureGenerator.sol";
import { UserFactory } from "../test-common/lib/UserFactory.sol";
import { Test } from "forge-std-1.9.6/Test.sol";

contract ROLESTest is Test {
    using ModuleTestFixtureGenerator for CallistoRoles;

    Kernel internal kernel;
    CallistoRoles public ROLES;
    address public testUser;
    address public testUser2;
    address public godmode;

    uint256 internal constant INITIAL_TOKEN_AMOUNT = 100e18;

    function setUp() public {
        kernel = new Kernel();
        ROLES = new CallistoRoles(kernel);

        address[] memory users = (new UserFactory()).create(2);
        testUser = users[0];
        testUser2 = users[1];

        kernel.executeAction(Actions.InstallModule, address(ROLES));

        // Generate test policy with all authorizations
        godmode = ROLES.generateGodmodeFixture(type(CallistoRoles).name);
        kernel.executeAction(Actions.ActivatePolicy, godmode);
    }

    function testCorrectness_KEYCODE() public view {
        assertEq32("ROLES", fromKeycode(ROLES.KEYCODE()));
    }

    function testCorrectness_SaveRole() public {
        bytes32 testRole = "test_role";

        // Give role to test user
        vm.prank(godmode);
        ROLES.saveRole(testRole, testUser);

        assertTrue(ROLES.hasRole(testUser, testRole));
    }

    function testCorrectness_RemoveRole() public {
        bytes32 testRole = "test_role";

        // Give then remove role from test user
        vm.startPrank(godmode);
        ROLES.saveRole(testRole, testUser);
        ROLES.removeRole(testRole, testUser);
        vm.stopPrank();

        assertFalse(ROLES.hasRole(testUser, testRole));
    }

    function testCorrectness_EnsureValidRole() public {
        ROLES.ensureValidRole("valid");

        bytes memory err = abi.encodeWithSelector(ROLESv1.ROLES_InvalidRole.selector, bytes32("INVALID_ID"));
        vm.expectRevert(err);
        ROLES.ensureValidRole("INVALID_ID");
    }
}
