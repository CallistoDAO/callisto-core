// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import { IERC4626 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";

import { IGOHM } from "../../src/interfaces/IGOHM.sol";
import { IMonoCooler } from "../../src/interfaces/IMonoCooler.sol";
import {
    CallistoVaultLogic,
    CallistoVaultTestForkBase,
    IMonoCoolerExtended,
    SafeCast
} from "../test-common/CallistoVaultTestForkBase.sol";

import { IDLGTEv1 } from "../mocks/MockMonoCooler.sol";

// import { console } from "forge-std/Test.sol";

contract CallistoVaultRestrictedFuncTests is CallistoVaultTestForkBase {
    using SafeCast for *;

    function setUp() public virtual override {
        vm.createSelectFork("mainnet");
        super.setUp();
    }

    function test_callistoVaultFork_depositSimple(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        _ohmMint(user, assets);

        uint256 shares = vault.convertToShares(assets);

        vm.startPrank(user);
        ohm.approve(address(vault), assets);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Deposit(user, user, assets, shares);
        vault.deposit(assets, user);
        vm.stopPrank();

        vm.prank(heart);
        vault.execute();

        assertEq(uint256(cooler.accountCollateral(address(vault))), gohm.balanceTo(assets));
        assertEq(ohm.balanceOf(user), 0);
        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.pendingOHMDeposits(), 0);

        IMonoCoolerExtended.AccountPosition memory position = cooler.accountPosition(address(vault));
        assertEq(
            position.collateral, gohm.balanceTo(assets), "Cooler collateral should match the deposited assets in gOHM"
        );

        assertApproxEqAbs(
            position.currentDebt,
            susds.maxWithdraw(address(psm)),
            2,
            "Cooler debt should match the max withdrawable sUSDS from PSM"
        );
    }

    error DepositLessThanWithdrawal(uint256 depositOHM, uint256 withdrawalOHM);

    function _depositAndWithdrawAtDifferentIntervals(
        uint32[] memory durations,
        uint256 depositAmount,
        uint256 withdrawalAmount
    ) private {
        require(depositAmount >= withdrawalAmount, DepositLessThanWithdrawal(depositAmount, withdrawalAmount));
        uint256 depositShares = vault.convertToShares(depositAmount);
        uint256 withdrawalShares = vault.convertToShares(withdrawalAmount);
        uint256 snapshotID;

        _ohmMint(user, depositAmount);

        uint256 durationNum = durations.length;
        for (uint256 i = 0; i < durationNum; ++i) {
            snapshotID = vm.snapshotState();

            // 1. Preparation: deposit OHM.
            vm.startPrank(user);
            ohm.approve(address(vault), depositAmount);
            vault.deposit(depositAmount, user);
            vm.stopPrank();

            assertEq(vault.balanceOf(user), depositShares);
            assertEq(ohm.balanceOf(user), 0);
            assertEq(ohm.balanceOf(address(vault)), depositAmount);
            assertEq(vault.pendingOHMDeposits(), depositAmount);

            vm.prank(heart);
            vault.execute();

            assertEq(vault.pendingOHMDeposits(), 0);
            assertEq(ohm.balanceOf(address(vault)), 0);
            assertEq(gohm.balanceOf(address(vault)), 0);
            assertEq(usds.balanceOf(address(vault)), 0);
            assertGt(susds.balanceOf(address(psm)), 0);

            // Wait for accumulating sUSDS profits and Olympus Cooler debt.
            if (durations[i] != 0) skip(durations[i]);

            if (depositAmount == withdrawalAmount) {
                // Check that no time skip in this iteration.
                if (durations[i] == 0) {
                    // Add 1 wei of USDS to withdraw the entire gOHM collateral because of sUSDS rounding.
                    // vm.prank(Ethereum.USDS_HOLDER);
                    _usdsMint(user, 1);
                    vm.prank(user);
                    usds.approve(address(vault), 1);
                }

                // 1 wei of gOHM is missing for the last depositor because of rounding in the gOHM contract.
                _gohmMint(address(vault), 1);
            }

            // 2. Withdrawal.
            vm.prank(user);
            vault.withdraw(withdrawalAmount, user, user);

            assertEq(ohm.balanceOf(user), withdrawalAmount);
            assertEq(vault.balanceOf(user), depositShares - withdrawalShares);
            assertEq(usds.balanceOf(user), 0);
            assertEq(ohm.balanceOf(address(vault)), 0);
            assertEq(gohm.balanceOf(address(vault)), 0);
            assertEq(usds.balanceOf(address(vault)), 0);
            assertGe(susds.balanceOf(address(psm)), 0);

            vm.revertToState(snapshotID);
        }
    }

    function test_callistoVaultFork_depositsAndWithdrawsAllOHMAtDifferentIntervals() external {
        uint32[] memory durations = new uint32[](6);
        durations[0] = 0 seconds;
        durations[1] = 1 seconds;
        durations[2] = 7 days;
        durations[3] = 30 days;
        durations[4] = 365 days;
        durations[5] = 365 days * 11;

        uint256 ohmAmount = 100e9; // 100 OHM
        _depositAndWithdrawAtDifferentIntervals({
            durations: durations,
            depositAmount: ohmAmount,
            withdrawalAmount: ohmAmount
        });
    }

    function test_callistoVaultFork_depositsAndWithdrawsHalfOfOHMAtDifferentIntervals() external {
        uint32[] memory durations = new uint32[](6);
        durations[0] = 0 seconds;
        durations[1] = 1 seconds;
        durations[2] = 7 days;
        durations[3] = 30 days;
        durations[4] = 365 days;
        durations[5] = 365 days * 11;

        uint256 ohmAmount = 200e9; // 200 OHM
        _depositAndWithdrawAtDifferentIntervals({
            durations: durations,
            depositAmount: ohmAmount,
            withdrawalAmount: ohmAmount / 2
        });
    }

    // Withdrawal after user deposit without calling processPendingDeposits()
    // 1.1. Full withdrawal should succeed. (without calling processPendingDeposits())
    function test_callistoVaultFork_withdrawFull(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 shares = vault.convertToShares(assets);
        _depositToVaultExt(user, assets);
        _gohmMint(address(vault), 1); // 1 wei of gOHM is missing for the last depositor because of rounding in the gOHM

        vm.warp(block.timestamp + 30 days);

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(user, user, user, assets, shares);
        vault.withdraw(assets, user, user);
        assertEq(ohm.balanceOf(address(user)), assets);
    }

    // Withdrawal after user deposit without calling processPendingDeposits()
    // 1.2. Partial withdrawal should succeed.
    function test_callistoVaultFork_withdrawPartial(uint256 assets, uint256 partialAssets) external {
        assets = bound(assets, MIN_DEPOSIT * 2, MAX_DEPOSIT);
        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets / 2);
        uint256 partialShares = vault.convertToShares(partialAssets);
        _depositToVaultExt(user, assets);

        vm.warp(block.timestamp + 30 days);

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(user, user, user, partialAssets, partialShares);
        vault.withdraw(partialAssets, user, user);
        assertEq(ohm.balanceOf(address(user)), partialAssets);
    }

    // Withdrawal when the vault’s Cooler V2 loan has been liquidated
    //  2.1. If pendingOHM ≥ requested amount → withdrawal should succeed.
    function test_callistoVaultFork_withdrawEnoughPendingValue(uint256 assets, uint256 partialAssets) external {
        assets = bound(assets, MIN_DEPOSIT * 2, MAX_DEPOSIT);
        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets / 2);

        _depositToVaultExt(user, assets);

        _ohmMint(user2, partialAssets);
        _depositToVault(user2, partialAssets);

        assertEq(vault.pendingOHMDeposits(), partialAssets);

        vm.prank(user);
        vault.withdraw(partialAssets, user, user);
        assertEq(ohm.balanceOf(address(user)), partialAssets);
        assertEq(vault.pendingOHMDeposits(), 0);
    }

    // Withdrawal when the vault’s Cooler V2 loan has been liquidated
    // 2.2. If pendingOHM is insufficient:
    function test_callistoVaultFork_withdrawInsufficientPendingOHM(uint256 assets, uint256 partialAssets) external {
        assets = bound(assets, MIN_DEPOSIT * 2, MAX_DEPOSIT);
        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets / 2);
        assets = 200e9; // 200 OHM
        partialAssets = 50e9; // 100 OHM
        _depositToVaultExt(user, assets);

        assertEq(vault.pendingOHMDeposits(), 0);
        assertEq(cooler.accountCollateral(address(vault)), gohm.balanceTo(assets));

        vm.prank(user);
        vault.withdraw(partialAssets, user, user);
        assertEq(ohm.balanceOf(address(user)), partialAssets);
        assertEq(cooler.accountCollateral(address(vault)), gohm.balanceTo(assets - partialAssets));
    }

    /**
     * Final withdrawal edge case due to rounding error in gOHM
     */
    function _prepareWithdrawalEdgeCaseDueToRounding(uint256 assets, uint256 partialAssets) internal {
        _depositToVaultExt(user, assets);

        assertEq(cooler.accountCollateral(address(vault)), gohm.balanceTo(assets));

        vm.mockCall(
            address(cooler),
            abi.encodeWithSelector(IMonoCooler.accountCollateral.selector, address(vault)),
            abi.encode(gohm.balanceTo(assets - partialAssets).toUint128())
        );
    }

    function _convertOHMToGOHM(IGOHM gOHM, uint256 value) private view returns (uint256) {
        uint256 gOHMIndex = gOHM.index();
        uint256 gohmDeciamls = 10 ** gOHM.decimals();
        return (value * gohmDeciamls) / gOHMIndex + SafeCast.toUint(mulmod(value, gohmDeciamls, gOHMIndex) > 0);
    }

    // 3.1. If the available gOHM in Cooler is less than required due to rounding → should revert.
    function test_callistoVaultFork_withdrawalEdgeCaseDueToRoundingErrorInGOHM_revert(
        uint256 assets,
        uint256 partialAssets
    ) external {
        assets = bound(assets, MIN_DEPOSIT * 2, MAX_DEPOSIT);
        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets / 2);
        _prepareWithdrawalEdgeCaseDueToRounding(assets, partialAssets);
        uint256 fakeTotalCollateral = cooler.accountCollateral(address(vault));
        uint256 notEnoughGOHM = _convertOHMToGOHM(gohm, assets) - fakeTotalCollateral;

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(CallistoVaultLogic.NotEnoughGOHM.selector, notEnoughGOHM));
        vault.withdraw(assets, user, user);
    }

    // 3.2. After the protocol sends the missing gOHM directly to the vault → withdrawal should succeed.
    function test_callistoVaultFork_withdrawalEdgeCaseDueToRoundingErrorInGOHM_success(
        uint256 assets,
        uint256 partialAssets
    ) external {
        assets = bound(assets, MIN_DEPOSIT * 2, MAX_DEPOSIT);
        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets / 2);
        uint256 shares = vault.convertToShares(assets);

        _prepareWithdrawalEdgeCaseDueToRounding(assets, partialAssets);

        uint256 fakeTotalCollateral = cooler.accountCollateral(address(vault));
        uint256 notEnoughGOHM = _convertOHMToGOHM(gohm, assets) - fakeTotalCollateral;

        // protocol sends the missing gOHM directly to the vault
        _gohmMint(address(vault), notEnoughGOHM);

        // withdraw must be success
        vm.prank(user);
        uint256 withdrawShares = vault.withdraw(assets, user, user);
        assertEq(withdrawShares, shares);
        assertEq(ohm.balanceOf(address(user)), assets);
    }

    function _prepareInsufficientUsdsInPSM(uint256 assets) internal returns (uint256) {
        _gohmMint(address(vault), 1);
        _depositToVaultExt(user, assets);

        uint256 susdsAmount = susds.balanceOf(address(psm));

        uint256 insufficientUsds = susdsAmount / 5; // example lacks 20% of usds

        _buyUSDSfromPSM(insufficientUsds);
        return insufficientUsds;
    }

    // 4.2. If the user has not approved USDS spend → should revert.
    function test_callistoVaultFork_withdrawPSMhasInsufficientUSDS_revert(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        _prepareInsufficientUsdsInPSM(assets);

        // revert with NotEnoughGOHM on withdraw
        vm.prank(user);
        vm.expectRevert();
        vault.withdraw(assets, user, user);
    }

    // 4.1. If the user has approved USDS spend by the vault → vault pulls remaining USDS and withdrawal should succeed.
    function test_callistoVaultFork_withdrawPSMhasInsufficientUSDS_success(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        uint256 shares = vault.convertToShares(assets);
        // olympus cooler returns grater debt by 2-3 assets after
        uint256 delta = 5;
        uint256 insufficientUsds = _prepareInsufficientUsdsInPSM(assets);

        // mint and approve susds
        _usdsMint(user, insufficientUsds + delta);
        vm.prank(user);
        usds.approve(address(vault), insufficientUsds + delta);

        // withdraw must be success
        vm.prank(user);
        uint256 withdrawShares = vault.withdraw(assets, user, user);
        assertEq(withdrawShares, shares);
        assertEq(ohm.balanceOf(address(user)), assets);
        assertEq(ohm.balanceOf(address(user)), assets);
        assertApproxEqAbs(vault.reimbursementClaims(address(user)), insufficientUsds, delta);
    }

    function _prepareCoolerWithDebt(uint256 assets) internal {
        uint256 partialAssets = assets / 10_000; // 100 OHM
        _depositToVaultExt(user, assets);

        vm.warp(block.timestamp + 60 days);

        uint128 partialOhm = gohm.balanceTo(partialAssets).toUint128();

        vm.prank(address(vault));
        cooler.withdrawCollateral(partialOhm, address(vault), address(vault), new IDLGTEv1.DelegationRequest[](0));

        // hack to make insufficient collateral
        // TODO: remove this hack, remake to realistic scenario
        vm.warp(block.timestamp - 60 days);
    }

    function _getCoolerDebt() internal view returns (uint128 wadDebt) {
        int128 debtDelta = cooler.debtDeltaForMaxOriginationLtv({ account: address(vault), collateralDelta: 0 });
        wadDebt = uint128(-debtDelta);
    }

    function test_callistoVaultFork_repayCoolerDebt_full(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);

        _prepareCoolerWithDebt(assets);
        uint128 wadDebt = _getCoolerDebt();
        assertGt(wadDebt, 0, "Cooler debt should be greater than 0");

        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.CoolerDebtRepaid(address(this), wadDebt);
        vault.repayCoolerDebt(0);

        uint128 wadDebtAfter = _getCoolerDebt();
        assertEq(wadDebtAfter, 0, "Cooler debt should be repaid");
    }

    function test_callistoVaultFork_repayCoolerDebt_partial() external {
        uint256 assets = 100e9; // 100 OHM

        _prepareCoolerWithDebt(assets);
        uint128 wadDebt = _getCoolerDebt();

        assertGt(wadDebt, 0, "Cooler debt should be greater than 0");

        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.CoolerDebtRepaid(address(this), 100);
        vault.repayCoolerDebt(100);

        uint128 wadDebtAfter = _getCoolerDebt();
        assertEq(wadDebtAfter, wadDebt - 100, "Cooler debt should be partially repaid");
    }

    function test_callistoVaultFork_repayCoolerDebt_withUserHelp(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);

        _prepareCoolerWithDebt(assets);
        uint128 wadDebt = _getCoolerDebt();
        assertGt(wadDebt, 0, "Cooler debt should be greater than 0");

        uint256 totalAssetsAvailable = vaultStrategy.totalAssetsAvailable();
        uint256 gap = 10_000; // fr example some small assets available in the vault

        _buyUSDSfromPSM(totalAssetsAvailable - gap);

        // check revert when user has not approved USDS spend
        vm.expectRevert();
        vault.repayCoolerDebt(0);

        // mint and approve USDS
        _usdsMint(address(this), wadDebt);
        usds.approve(address(vault), wadDebt);

        uint256 strategyBalance = vaultStrategy.totalAssetsAvailable();

        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.ReimbursementClaimAdded(address(this), wadDebt - strategyBalance);

        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.CoolerDebtRepaid(address(this), wadDebt);
        vault.repayCoolerDebt(0);

        assertEq(vault.reimbursementClaims(address(this)), wadDebt - strategyBalance);

        uint128 wadDebtAfter = _getCoolerDebt();
        assertEq(wadDebtAfter, 0, "Cooler debt should be repaid");
    }
}
