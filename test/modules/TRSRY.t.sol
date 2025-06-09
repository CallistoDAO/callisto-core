// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.22;

import { MockERC20 } from "../../dependencies/solmate-6.8.0/src/test/utils/mocks/MockERC20.sol";
import { Actions, Kernel, Keycode, Module } from "../../src/Kernel.sol";
import { CallistoTreasury } from "../../src/modules/TRSRY/CallistoTreasury.sol";
import { ModuleTestFixtureGenerator } from "../test-common/lib/ModuleTestFixtureGenerator.sol";
import { Test } from "forge-std/Test.sol";

contract TRSRYTest is Test {
    using ModuleTestFixtureGenerator for CallistoTreasury;

    Kernel internal kernel;
    CallistoTreasury public TRSRY;
    MockERC20 public ngmi;
    address public testUser;
    address public godmode;

    uint256 internal constant INITIAL_TOKEN_AMOUNT = 100e18;

    function setUp() public {
        kernel = new Kernel();
        TRSRY = new CallistoTreasury(kernel);
        ngmi = new MockERC20("not gonna make it", "NGMI", 18);
        kernel.executeAction(Actions.InstallModule, address(TRSRY));

        // Generate test fixture policy addresses with different authorizations
        godmode = TRSRY.generateGodmodeFixture(type(CallistoTreasury).name);
        kernel.executeAction(Actions.ActivatePolicy, godmode);

        testUser = TRSRY.generateFunctionFixture(TRSRY.withdrawReserves.selector);
        kernel.executeAction(Actions.ActivatePolicy, testUser);

        // Give TRSRY some tokens
        ngmi.mint(address(TRSRY), INITIAL_TOKEN_AMOUNT);
    }

    function testCorrectness_KEYCODE() public view {
        assertEq32("TRSRY", Keycode.unwrap(TRSRY.KEYCODE()));
    }

    function testCorrectness_IncreaseWithdrawApproval(uint256 amount_) public {
        vm.prank(godmode);
        TRSRY.increaseWithdrawApproval(testUser, ngmi, amount_);

        assertEq(TRSRY.withdrawApproval(testUser, ngmi), amount_);
    }

    function testCorrectness_DecreaseWithdrawApproval(uint256 amount_) public {
        vm.prank(godmode);
        TRSRY.increaseWithdrawApproval(testUser, ngmi, amount_);

        vm.prank(godmode);
        TRSRY.decreaseWithdrawApproval(testUser, ngmi, amount_);

        assertEq(TRSRY.withdrawApproval(testUser, ngmi), 0);
    }

    function testCorrectness_GetReserveBalance() public view {
        assertEq(TRSRY.getReserveBalance(ngmi), INITIAL_TOKEN_AMOUNT);
    }

    function testCorrectness_ApprovedCanWithdrawToken(uint256 amount_) public {
        vm.assume(amount_ < INITIAL_TOKEN_AMOUNT);

        vm.prank(godmode);
        TRSRY.increaseWithdrawApproval(testUser, ngmi, amount_);

        assertEq(TRSRY.withdrawApproval(testUser, ngmi), amount_);

        vm.prank(testUser);
        TRSRY.withdrawReserves(address(this), ngmi, amount_);

        assertEq(ngmi.balanceOf(address(this)), amount_);
    }

    // TODO test if can withdraw more than allowed amount
    //function testRevert_WithdrawMoreThanApproved(uint256 amount_) public {}

    function testRevert_UnauthorizedCannotWithdrawToken(uint256 amount_) public {
        vm.assume(amount_ < INITIAL_TOKEN_AMOUNT);
        vm.assume(amount_ > 0);

        // Fail when withdrawal using policy without write access
        vm.expectRevert();
        vm.prank(testUser);
        TRSRY.withdrawReserves(address(this), ngmi, amount_);
    }

    function testRevert_AddressWithPermCannotShutdownOrRestart() public {
        // Check status of TRSRY
        assertEq(TRSRY.active(), true);

        // Try to deactivate with non-approved user
        bytes memory err = abi.encodeWithSelector(Module.Module_PolicyNotPermitted.selector, testUser);
        vm.expectRevert(err);
        vm.prank(testUser);
        TRSRY.deactivate();

        assertEq(TRSRY.active(), true);

        // Deactivate with approved user
        vm.prank(godmode);
        TRSRY.deactivate();

        assertEq(TRSRY.active(), false);

        // Call deactivate again and expect nothing to happen since it's already deactivated
        vm.prank(godmode);
        TRSRY.deactivate();

        assertEq(TRSRY.active(), false);

        // Try to reactivate with non-approved user
        vm.expectRevert(err);
        vm.prank(testUser);
        TRSRY.activate();

        assertEq(TRSRY.active(), false);

        // Reactivate with approved user
        vm.prank(godmode);
        TRSRY.activate();

        assertEq(TRSRY.active(), true);

        // Call activate again and expect nothing to happen since it's already activated
        vm.prank(godmode);
        TRSRY.activate();

        assertEq(TRSRY.active(), true);
    }
}
