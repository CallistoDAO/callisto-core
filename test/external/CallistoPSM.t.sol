// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import { IAccessControl } from "../../dependencies/@openzeppelin-contracts-5.3.0/access/IAccessControl.sol";
import { IERC20 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";
import { CallistoPSM } from "../../src/external/CallistoPSM.sol";
import { CallistoVaultTestBase } from "../test-common/CallistoVaultTestBase.sol";

contract CallistoPSMTests is CallistoVaultTestBase {
    function test_callistoPSM_transferUnexpectedTokens() external {
        uint256 assets = 50e9;
        ohm.mint(address(psm), assets);

        vm.expectRevert();
        psm.transferUnexpectedTokens(address(ohm), address(this), assets);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(ohm));
        emit IERC20.Transfer(address(psm), address(this), assets);
        psm.transferUnexpectedTokens(address(ohm), address(this), assets);

        assertEq(ohm.balanceOf(address(this)), assets);
        assertEq(ohm.balanceOf(address(psm)), 0);
    }

    function test_callistoPSM_setFee() external {
        uint256 feeIn = 50e16;
        uint256 feeOut = 100e16;

        vm.expectRevert();
        psm.setFee(feeIn, true);

        vm.prank(admin);
        vm.expectRevert(CallistoPSM.InvalidParameter.selector);
        psm.setFee(1e18 + 1, true);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(psm));
        emit CallistoPSM.FeeInSet(feeIn);
        psm.setFee(feeIn, true);
        assertEq(psm.feeIn(), feeIn);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(psm));
        emit CallistoPSM.FeeOutSet(feeOut);
        psm.setFee(feeOut, false);
        assertEq(psm.feeOut(), feeOut);
    }

    function test_callistoPSM_setFeeExempt() external {
        address exemptAddress = makeAddr("exempt");
        bytes32 role = psm.FEE_EXEMPT_ROLE();

        vm.expectRevert();
        psm.setFeeExempt(exemptAddress, true);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(psm));
        emit IAccessControl.RoleGranted(role, exemptAddress, admin);
        psm.setFeeExempt(exemptAddress, true);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CallistoPSM.AlreadyFeeExempt.selector, exemptAddress));
        psm.setFeeExempt(exemptAddress, true);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(psm));
        emit IAccessControl.RoleRevoked(role, exemptAddress, admin);
        psm.setFeeExempt(exemptAddress, false);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CallistoPSM.NotFeeExempt.selector, exemptAddress));
        psm.setFeeExempt(exemptAddress, false);
    }

    function test_callistoPSM_swapInNoFee(uint256 assets) external {
        assets = bound(assets, vault.minDeposit() + 1, MAX_DEPOSIT);

        _depositSusds(assets, address(psm));

        address exemptAddress = makeAddr("exempt");
        bytes32 role = psm.FEE_EXEMPT_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role)
        );
        psm.swapInNoFee(user, assets);

        vm.prank(admin);
        psm.setFeeExempt(exemptAddress, true);

        vm.prank(admin);
        psm.setFee(0.05e18, false); // 5% fee, just check if it works

        vm.startPrank(exemptAddress);
        collar.mintByPSM(address(exemptAddress), assets);
        collar.approve(address(psm), assets);
        vm.expectEmit(true, true, true, true, address(psm));
        emit CallistoPSM.COLLARSold(user, assets, assets, 0);
        psm.swapInNoFee(user, assets);

        assertEq(collar.balanceOf(address(stabilityPool)), assets);
        assertEq(collar.balanceOf(user), 0);
        assertEq(usds.balanceOf(user), assets);
        assertEq(susds.maxWithdraw(address(psm)), 0);
    }

    function test_callistoPSM_swapInWithFee(uint256 assets) external {
        assets = bound(assets, vault.minDeposit() + 1, MAX_DEPOSIT);

        _depositSusds(assets, address(psm));

        vm.prank(admin);
        psm.setFee(0.05e18, false); // 5% fee

        (uint256 collarIn, uint256 fee) = psm.calcCOLLARIn(assets);
        collar.mintByPSM(user, collarIn);

        vm.startPrank(user);
        collar.approve(address(psm), collarIn);
        vm.expectEmit(true, true, true, true, address(psm));
        emit CallistoPSM.COLLARSold(user, collarIn, assets, fee);
        psm.swapIn(user, assets);

        assertEq(collar.balanceOf(address(stabilityPool)), collarIn);
        assertEq(collar.balanceOf(user), 0);
        assertEq(usds.balanceOf(user), assets);
        assertEq(susds.maxWithdraw(address(psm)), 0);
    }

    function test_callistoPSM_swapOutWithFee(uint256 assets) external {
        assets = bound(assets, vault.minDeposit() + 1, MAX_DEPOSIT);
        usds.mint(user, assets);

        vm.prank(admin);
        psm.setFee(0.05e18, true); // 5% fee

        (uint256 collarOut, uint256 fee) = psm.calcCOLLAROut(assets);

        vm.startPrank(user);
        usds.approve(address(psm), assets);
        vm.expectEmit(true, true, true, true, address(psm));
        emit CallistoPSM.COLLARBought(user, collarOut, assets, fee);
        psm.swapOut(user, assets);

        assertEq(collar.balanceOf(user), collarOut);
        assertEq(usds.balanceOf(user), 0);
        assertEq(susds.maxWithdraw(address(psm)), assets);
    }

    function test_callistoPSM_swapOutNoFee(uint256 assets) external {
        assets = bound(assets, vault.minDeposit() + 1, MAX_DEPOSIT);

        address exemptAddress = makeAddr("exempt");
        usds.mint(exemptAddress, assets);
        vm.prank(exemptAddress);
        usds.approve(address(psm), assets);

        bytes32 role = psm.FEE_EXEMPT_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role)
        );
        psm.swapOutNoFee(user, assets);

        vm.prank(admin);
        psm.setFeeExempt(exemptAddress, true);

        vm.prank(admin);
        psm.setFee(0.05e18, true); // 5% fee

        uint256 collarOut = assets;

        vm.prank(exemptAddress);
        vm.expectEmit(true, true, true, true, address(psm));
        emit CallistoPSM.COLLARBought(user, collarOut, assets, 0);
        psm.swapOutNoFee(user, assets);

        assertEq(collar.balanceOf(user), collarOut);
        assertEq(usds.balanceOf(user), 0);
        assertEq(susds.maxWithdraw(address(psm)), assets);
    }

    function test_callistoPSM_calcCOLLAROut() external {
        uint256 assets = 100e9;

        (uint256 collarOut, uint256 fee) = psm.calcCOLLAROut(assets);
        assertEq(collarOut, assets);
        assertEq(fee, 0);

        vm.prank(admin);
        psm.setFee(0.05e18, true); // 5% fee

        (uint256 collarOutWithFee, uint256 newFee) = psm.calcCOLLAROut(assets);
        assertEq(collarOutWithFee, 95e9); // minus 5%
        assertEq(newFee, 5e9);
    }

    function test_callistoPSM_calcCOLLARIn() external {
        uint256 assets = 100e9;

        (uint256 collarIn, uint256 fee) = psm.calcCOLLARIn(assets);
        assertEq(collarIn, assets);
        assertEq(fee, 0);

        vm.prank(admin);
        psm.setFee(0.05e18, false); // 5% fee

        (uint256 collarInWithFee, uint256 newFee) = psm.calcCOLLARIn(assets);
        assertEq(collarInWithFee, 105e9); // plus 5%
        assertEq(newFee, 5e9);
    }

    function test_callistoPSM_setLP_canOnlyBeCalledOnce() external {
        address newLP = makeAddr("newLP");

        // Should revert when trying to set LP again since it's already set in setup
        vm.prank(admin);
        vm.expectRevert(CallistoPSM.AlreadyInitialized.selector);
        psm.setLP(newLP);

        // Verify the original LP is still set
        assertEq(psm.liquidityProvider(), address(vaultStrategy));
    }
}
