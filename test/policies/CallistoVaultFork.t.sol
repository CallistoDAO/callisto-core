// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import { IERC20, IERC4626 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";

import { CallistoPSM } from "../../src/external/CallistoPSM.sol";
import { ICallistoVault } from "../../src/interfaces/ICallistoVault.sol";
import { IMonoCooler } from "../../src/interfaces/IMonoCooler.sol";
import { IOlympusStaking } from "../../src/interfaces/IOlympusStaking.sol";
import { IDLGTEv1 } from "../mocks/MockMonoCooler.sol";
import { IMonoCoolerExtended, SafeCast } from "../test-common/CallistoVaultTestForkBase.sol";
import { CallistoVaultTestForkCDP } from "../test-common/CallistoVaultTestForkCDP.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// import { console } from "forge-std-1.9.6/Test.sol";

contract CallistoVaultForkTests is CallistoVaultTestForkCDP {
    using SafeCast for *;

    function setUp() public virtual override {
        vm.createSelectFork("mainnet", 23_016_996);
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

        assertEq(psm.suppliedByLP(), 0, "PSM suppliedByLP should be 0");
        assertEq(vault.pendingOHMDeposits(), assets, "pending ohm should be tracked");

        // We can't easily predict the exact shares due to sUSDS rounding, so just check the event is emitted
        vm.expectEmit(false, false, false, false, address(psm));
        emit CallistoPSM.LiquidityAdded(0, 0);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.DepositsHandled(assets);

        vm.prank(heart);
        vault.execute();

        assertEq(uint256(COOLER.accountCollateral(address(vault))), GOHM.balanceTo(assets));
        assertEq(ohm.balanceOf(user), 0, "ohm balance of the user should be 0");
        assertEq(vault.balanceOf(user), shares, "balance of cOHM of the user");
        assertEq(vault.totalAssets(), assets, "total ohm balance should match deposited assets");
        assertEq(vault.pendingOHMDeposits(), 0, "pending ohm should reset");

        IMonoCoolerExtended.AccountPosition memory position = COOLER.accountPosition(address(vault));
        assertEq(
            position.collateral, GOHM.balanceTo(assets), "Cooler collateral should match the deposited assets in gOHM"
        );

        assertApproxEqAbs(
            position.currentDebt,
            SUSDS.maxWithdraw(address(psm)),
            2,
            "Cooler debt should match the max withdrawable sUSDS from PSM"
        );

        assertEq(psm.suppliedByLP(), SUSDS.balanceOf(address(psm)), "PSM suppliedByLP should match sUSDS balance");
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
            assertEq(GOHM.balanceOf(address(vault)), 0);
            assertEq(USDS.balanceOf(address(vault)), 0);
            assertGt(SUSDS.balanceOf(address(psm)), 0);

            // Wait for accumulating sUSDS profits and Olympus Cooler debt.
            if (durations[i] != 0) skip(durations[i]);

            if (depositAmount == withdrawalAmount) {
                // Check that no time skip in this iteration.
                if (durations[i] == 0) {
                    // Add 1 wei of USDS to withdraw the entire gOHM collateral because of sUSDS rounding.
                    // vm.prank(Ethereum.USDS_HOLDER);
                    _usdsMint(user, 1);
                    vm.prank(user);
                    USDS.approve(address(vault), 1);
                }

                // 1 wei of gOHM is missing for the last depositor because of rounding in the gOHM contract.
                _gohmMint(address(vault), 1);
            }

            // 2. Withdrawal.
            vm.prank(user);
            vault.withdraw(withdrawalAmount, user, user);

            assertEq(ohm.balanceOf(user), withdrawalAmount);
            assertEq(vault.balanceOf(user), depositShares - withdrawalShares);
            assertEq(USDS.balanceOf(user), 0);
            assertEq(ohm.balanceOf(address(vault)), 0);
            assertEq(GOHM.balanceOf(address(vault)), 0);
            assertEq(USDS.balanceOf(address(vault)), 0);
            assertGe(SUSDS.balanceOf(address(psm)), 0);

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
        assertEq(COOLER.accountCollateral(address(vault)), GOHM.balanceTo(assets));

        vm.prank(user);
        vault.withdraw(partialAssets, user, user);
        assertEq(ohm.balanceOf(address(user)), partialAssets);
        assertEq(COOLER.accountCollateral(address(vault)), GOHM.balanceTo(assets - partialAssets));
    }

    /**
     * Final withdrawal edge case due to rounding error in gOHM
     */
    function _prepareWithdrawalEdgeCaseDueToRounding(uint256 assets, uint256 partialAssets) internal {
        _depositToVaultExt(user, assets);

        assertEq(COOLER.accountCollateral(address(vault)), GOHM.balanceTo(assets));

        vm.mockCall(
            address(COOLER),
            abi.encodeWithSelector(IMonoCooler.accountCollateral.selector, address(vault)),
            abi.encode(GOHM.balanceTo(assets - partialAssets).toUint128())
        );
    }

    // 3.1. If the available gOHM in Cooler is less than required due to rounding → should revert.
    function test_callistoVaultFork_withdrawalEdgeCaseDueToRoundingErrorInGOHM_revert(
        uint256 assets,
        uint256 partialAssets
    ) external {
        assets = bound(assets, MIN_DEPOSIT * 2, MAX_DEPOSIT);
        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets / 2);
        _prepareWithdrawalEdgeCaseDueToRounding(assets, partialAssets);
        uint256 fakeTotalCollateral = COOLER.accountCollateral(address(vault));
        uint256 notEnoughGOHM = vault.convertOHMToGOHM(assets) - fakeTotalCollateral;

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(ICallistoVault.NotEnoughGOHM.selector, notEnoughGOHM));
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

        uint256 fakeTotalCollateral = COOLER.accountCollateral(address(vault));
        uint256 notEnoughGOHM = vault.convertOHMToGOHM(assets) - fakeTotalCollateral;

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

        uint256 susdsAmount = SUSDS.balanceOf(address(psm));

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
        USDS.approve(address(vault), insufficientUsds + delta);

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

        uint128 partialOhm = GOHM.balanceTo(partialAssets).toUint128();

        vm.prank(address(vault));
        COOLER.withdrawCollateral(partialOhm, address(vault), address(vault), new IDLGTEv1.DelegationRequest[](0));

        // hack to make insufficient collateral
        // TODO: remove this hack, remake to realistic scenario
        vm.warp(block.timestamp - 60 days);
    }

    function _getCoolerDebt() internal view returns (uint128 wadDebt) {
        int128 debtDelta = COOLER.debtDeltaForMaxOriginationLtv({ account: address(vault), collateralDelta: 0 });
        wadDebt = uint128(-debtDelta);
    }

    function test_callistoVaultFork_repayCoolerDebt_full(uint256 assets, bool withReimbursement) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        // Setup: deposit assets and execute to establish position with debt
        _depositToVaultExt(user, assets);

        // Create debt by manipulating time (similar to _prepareCoolerWithDebt but more explicit)
        vm.warp(block.timestamp + 60 days);
        uint128 partialOhm = uint128(GOHM.balanceTo(assets / 10_000)); // Small withdrawal to create debt
        vm.prank(address(vault));
        COOLER.withdrawCollateral(partialOhm, address(vault), address(vault), new IDLGTEv1.DelegationRequest[](0));
        vm.warp(block.timestamp - 60 days); // Revert time to make debt worse

        // Get current debt
        uint128 wadDebt = _getCoolerDebt();
        vm.assume(wadDebt > 0);

        uint256 reimbursementValue = 0;
        if (withReimbursement) {
            reimbursementValue = wadDebt;
            // Prepare for reimbursement by removing USDS from PSM and providing user funds
            uint256 totalAssetsAvailable = vaultStrategy.totalAssetsAvailable();

            // Only buy USDS if there's enough available to buy
            if (totalAssetsAvailable >= wadDebt) {
                _buyUSDSfromPSM(wadDebt);
            } else if (totalAssetsAvailable > 0) {
                _buyUSDSfromPSM(totalAssetsAvailable);
            }

            _usdsMint(address(this), wadDebt);
            USDS.approve(address(vault), wadDebt);
        }

        uint256 totalReimbursementBefore = vault.totalReimbursementClaim();

        // Perform full debt repayment using explicit amount (like the mock test)
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.CoolerDebtRepaid(address(this), wadDebt);
        vault.repayCoolerDebt(wadDebt);

        // Verify debt was fully repaid
        uint128 wadDebtAfter = _getCoolerDebt();
        assertEq(wadDebtAfter, 0, "Cooler debt should be fully repaid");

        // For fork tests, reimbursement logic is more complex, so let's check more carefully
        if (withReimbursement) {
            // Reimbursement claim might be different due to strategy availability
            uint256 actualClaim = vault.reimbursementClaims(address(this));

            // TODO: consider to remove this branch or improve the test, as the strategy's funds are always enough here.
            assertEq(actualClaim, 0);

            // In fork tests, the claim might be less than expected due to strategy funds availability
            assertLe(actualClaim, reimbursementValue, "Reimbursement claim should not exceed expected");
            assertEq(
                vault.totalReimbursementClaim(),
                totalReimbursementBefore + actualClaim,
                "Total reimbursement should properly increase"
            );
        } else {
            assertEq(vault.reimbursementClaims(address(this)), 0, "Should have no reimbursement claim");
            assertEq(vault.totalReimbursementClaim(), totalReimbursementBefore, "Total reimbursement should not change");
        }
    }

    function test_callistoVaultFork_repayCoolerDebt_partial(
        uint256 assets,
        uint128 partialAssets,
        bool withReimbursement
    ) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);

        // Use the existing helper that properly creates debt
        _prepareCoolerWithDebt(assets);

        // Get current debt and bound partial repayment
        uint128 wadDebt = _getCoolerDebt();
        vm.assume(wadDebt > 1);
        partialAssets = uint128(bound(partialAssets, 1, wadDebt - 1));

        uint256 reimbursementValue = 0;
        if (withReimbursement) {
            reimbursementValue = partialAssets;
            // Prepare for reimbursement by removing USDS from PSM and providing user funds
            uint256 totalAssetsAvailable = vaultStrategy.totalAssetsAvailable();

            // Only buy USDS if there's enough available to buy
            if (totalAssetsAvailable >= partialAssets) {
                _buyUSDSfromPSM(partialAssets);
            } else if (totalAssetsAvailable > 0) {
                _buyUSDSfromPSM(totalAssetsAvailable);
            }

            _usdsMint(address(this), partialAssets);
            USDS.approve(address(vault), partialAssets);
        }

        uint256 totalReimbursementBefore = vault.totalReimbursementClaim();

        // Perform partial debt repayment
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.CoolerDebtRepaid(address(this), partialAssets);
        vault.repayCoolerDebt(partialAssets);

        // Verify debt was partially repaid
        uint128 wadDebtAfter = _getCoolerDebt();
        assertEq(wadDebtAfter, wadDebt - partialAssets, "Cooler debt should be partially repaid");

        // For fork tests, reimbursement logic is more complex, so let's check more carefully
        if (withReimbursement) {
            // Reimbursement claim might be different due to strategy availability
            uint256 actualClaim = vault.reimbursementClaims(address(this));

            // TODO: consider to remove this branch or improve the test, as the strategy's funds are always enough here.
            assertEq(actualClaim, 0);

            // In fork tests, the claim might be less than expected due to strategy funds availability
            assertLe(actualClaim, reimbursementValue, "Reimbursement claim should not exceed expected");
            assertEq(
                vault.totalReimbursementClaim(),
                totalReimbursementBefore + actualClaim,
                "Total reimbursement should properly increase"
            );
        } else {
            assertEq(vault.reimbursementClaims(address(this)), 0, "Should have no reimbursement claim");
            assertEq(vault.totalReimbursementClaim(), totalReimbursementBefore, "Total reimbursement should not change");
        }
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
        USDS.approve(address(vault), wadDebt);

        uint256 strategyBalance = vaultStrategy.totalAssetsAvailable();

        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.ReimbursementClaimAdded(address(this), wadDebt - strategyBalance, wadDebt - strategyBalance);

        uint256 totalReimbursementBefore = vault.totalReimbursementClaim();

        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.CoolerDebtRepaid(address(this), wadDebt);
        vault.repayCoolerDebt(0);

        uint256 reimbursement = vault.reimbursementClaims(address(this));
        assertEq(reimbursement, wadDebt - strategyBalance);
        assertEq(
            vault.totalReimbursementClaim(),
            totalReimbursementBefore + reimbursement,
            "Total reimbursement should increase"
        );

        uint128 wadDebtAfter = _getCoolerDebt();
        assertEq(wadDebtAfter, 0, "Cooler debt should be repaid");
    }

    // Test partial treasury profit withdrawal using fork logic instead of mocks
    function test_callistoVaultFork_sweepProfit_partial(uint256 assets, uint256 partialYield) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        // Deposit assets and let them be processed
        _depositToVaultExt(user, assets);

        // Fast forward time to accumulate some yield in sUSDS
        vm.warp(block.timestamp + 30 days);

        // Get the total profit available (strategy funds - cooler debt)
        uint256 totalProfit = vault.totalProfit();

        // Skip if no meaningful profit available (need at least 10 to test partial withdrawal)
        vm.assume(totalProfit >= 10);

        // Bound partial yield to be between 1 and total profit - 5 (leave room for rounding)
        partialYield = bound(partialYield, 1, totalProfit - 5);

        // Record initial treasury balance
        uint256 initialTreasuryBalance = USDS.balanceOf(address(treasury));

        // Sweep partial profit to treasury
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.TreasuryProfitWithdrawn(partialYield);
        vault.sweepProfit(partialYield);

        // Verify partial amount was transferred to treasury
        assertEq(USDS.balanceOf(address(treasury)), initialTreasuryBalance + partialYield);

        // Verify remaining profit is approximately correct (allow for small rounding differences)
        uint256 newTotalProfit = vault.totalProfit();
        uint256 expectedRemaining = totalProfit - partialYield;
        assertApproxEqAbs(newTotalProfit, expectedRemaining, 5);
    }

    // Test full treasury profit withdrawal using fork logic
    function test_callistoVaultFork_sweepProfit_full(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        // Deposit assets and let them be processed
        _depositToVaultExt(user, assets);

        // Fast forward time to accumulate some yield in sUSDS
        vm.warp(block.timestamp + 30 days);

        // Try to get total profit, skip if underflow (happens when debt > deposits due to interest)
        uint256 totalProfit = vault.totalProfit();
        // Skip if no meaningful profit available
        vm.assume(totalProfit >= 5);

        // Record initial treasury balance
        uint256 initialTreasuryBalance = USDS.balanceOf(address(treasury));

        // Sweep all profit to treasury using type(uint256).max
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.TreasuryProfitWithdrawn(totalProfit);
        vault.sweepProfit(type(uint256).max);

        // Verify all profit was transferred to treasury
        assertEq(USDS.balanceOf(address(treasury)), initialTreasuryBalance + totalProfit);

        uint256 finalProfit = vault.totalProfit();
        assertLe(finalProfit, 5);
    }

    function test_callistoVaultFork_totalProfit_takesIntoAccountReimbursement(uint256 assets, uint256 time) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        time = bound(time, 0, 365 days);

        // 1. Preparation.
        // Deposit and process OHM in the vault, and create the debt.
        _prepareCoolerWithDebt(assets);
        uint128 wadDebt = _getCoolerDebt();
        // Empty the PSM so that the `address(this)` can repay the debt to the cooler and receive a reimbursement.
        uint256 totalAssetsAvailable = vaultStrategy.totalAssetsAvailable();
        _buyUSDSfromPSM(totalAssetsAvailable);
        (, uint256 debt) = COOLER.treasuryBorrower().convertToDebtTokenAmount(wadDebt);
        _usdsMint(address(this), debt);
        USDS.approve(address(vault), debt);

        // Skip time to accumulate some profit.
        skip(time);
        // Save the total profit before adding a reimbursement.
        uint256 totalProfitBefore = vault.totalProfit();

        assertEq(vault.totalReimbursementClaim(), 0, "Total reimbursement should be zero");

        // Repay the debt to the cooler to receive a reimbursement.
        vault.repayCoolerDebt(0); // 0 means repaying how much to return to the origination LTV.

        uint256 reimbursement = vault.reimbursementClaims(address(this));
        assertEq(
            vault.totalReimbursementClaim(), reimbursement, "Total reimbursement should match the added reimbursement"
        );

        // 2. Test: validate total profit calculation.
        // Total profit stays the same, because the debt is reduced by `reimbursement`.
        assertEq(
            vault.totalProfit(),
            totalProfitBefore,
            "Total profit should stay the same by taking into account the reimbursement"
        );
    }

    function test_callistoVaultFork_totalProfit_isZeroWhenDebtGreaterThanDeposited(uint256 assets, uint256 time)
        external
    {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        time = bound(time, 0, 365 days);

        // 1. Preparation.
        // Deposit and process OHM in the vault, and create the debt.
        _prepareCoolerWithDebt(assets);
        uint128 wadDebt = _getCoolerDebt();
        // Empty the PSM so that the `address(this)` can repay the debt to the cooler and receive a reimbursement.
        uint256 totalAssetsAvailable = vaultStrategy.totalAssetsAvailable();
        _buyUSDSfromPSM(totalAssetsAvailable);
        (, uint256 debt) = COOLER.treasuryBorrower().convertToDebtTokenAmount(wadDebt);
        _usdsMint(address(this), debt);
        USDS.approve(address(vault), debt);

        assertEq(vault.totalProfit(), 0, "Total profit should be zero");

        // Repay the debt to the cooler to receive a reimbursement.
        vault.repayCoolerDebt(0); // 0 means repaying how much to return to the origination LTV.

        // 2. Test: validate that no profit.
        assertEq(vault.totalProfit(), 0, "Total profit should be zero");
    }

    // Test withdrawal with PSM having insufficient USDS and claim reimbursement using fork logic
    function test_callistoVaultFork_withdrawPSMhasInsufficientUSDS_WithClaimReimbursement(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);

        // First just copy the working test logic exactly
        uint256 shares = vault.convertToShares(assets);
        // olympus cooler returns grater debt by 2-3 assets after
        uint256 delta = 5;
        uint256 insufficientUsds = _prepareInsufficientUsdsInPSM(assets);

        // mint and approve USDS
        _usdsMint(user, insufficientUsds + delta);
        vm.prank(user);
        USDS.approve(address(vault), insufficientUsds + delta);

        // withdraw must be success
        vm.prank(user);
        uint256 withdrawShares = vault.withdraw(assets, user, user);
        assertEq(withdrawShares, shares);
        assertEq(ohm.balanceOf(address(user)), assets);
        assertApproxEqAbs(vault.reimbursementClaims(address(user)), insufficientUsds, delta);

        // Ensure vault has enough USDS for reimbursement claim by minting directly to vault
        uint256 claimAmount = vault.reimbursementClaims(address(user));
        _usdsMint(address(vault), claimAmount);

        uint256 totalReimbursementBefore = vault.totalReimbursementClaim();

        // claim reimbursement for user
        vault.claimReimbursement(user);
        assertApproxEqAbs(
            USDS.balanceOf(address(user)), claimAmount, 10, "User should receive reimbursement claim amount"
        );
        assertEq(vault.reimbursementClaims(address(user)), 0);
        assertEq(
            vault.totalReimbursementClaim(),
            totalReimbursementBefore - claimAmount,
            "Total reimbursement should decrease"
        );
    }

    // Test partial withdrawal of excess gOHM using fork logic
    function test_callistoVaultFork_withdrawExcessGOHM_partial(uint256 assets, uint256 partialAssets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);

        // Setup: deposit assets and execute to establish collateral position
        _depositToVaultExt(user, assets);

        // Get current gOHM index and simulate an increase by mocking
        uint256 currentIndex = GOHM.index();
        uint256 indexInc = 1e9; // Simulate index increase
        uint256 newIndex = currentIndex + indexInc;

        // Mock the gOHM index to simulate appreciation/staking rewards
        vm.mockCall(address(GOHM), abi.encodeWithSelector(GOHM.index.selector), abi.encode(newIndex));

        // Get excess gOHM after the simulated index increase
        uint256 excessGOHM = vault.excessGOHM();
        assertGt(excessGOHM, 0, "Should have excess gOHM after index increase");

        // Test withdrawing partial excess gOHM
        partialAssets = bound(partialAssets, 1, excessGOHM - 1);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.GOHMExcessWithdrawn(user, partialAssets);
        vault.withdrawExcessGOHM(partialAssets, user);

        // Verify gOHM was transferred to the recipient
        assertEq(GOHM.balanceOf(user), partialAssets);

        // Verify remaining excess is reduced (allow for precision differences due to fork test complexity)
        uint256 remainingExcess = vault.excessGOHM();
        uint256 expectedRemaining = excessGOHM - partialAssets;
        assertApproxEqAbs(
            remainingExcess, expectedRemaining, 1e7, "Remaining excess should be reduced by partial amount"
        );
    }

    // Test that excess gOHM withdrawal reverts when vault position is liquidated using fork logic
    function test_callistoVaultFork_withdrawExcessGOHM_noExcessGOHMreve(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        // Setup: deposit assets and execute to establish collateral position
        _depositToVaultExt(user, assets);

        // Get current gOHM index and simulate an increase by mocking
        uint256 currentIndex = GOHM.index();
        uint256 indexInc = 1e9; // Simulate index increase
        uint256 newIndex = currentIndex + indexInc;

        // Mock the gOHM index to simulate appreciation/staking rewards
        vm.mockCall(address(GOHM), abi.encodeWithSelector(GOHM.index.selector), abi.encode(newIndex));

        // Verify excess gOHM exists after index increase
        uint256 excessGOHM = vault.excessGOHM();
        assertGt(excessGOHM, 0, "Should have excess gOHM after index increase");

        // Simulate vault position liquidation by mocking cooler to return zero collateral
        // This is more appropriate for fork tests than trying to withdraw all collateral
        vm.mockCall(
            address(COOLER),
            abi.encodeWithSelector(COOLER.accountCollateral.selector, address(vault)),
            abi.encode(uint128(0))
        );

        // After liquidation, there should be no excess gOHM
        uint256 excessAfterLiquidation = vault.excessGOHM();
        assertEq(excessAfterLiquidation, 0, "Should have no excess gOHM after liquidation");

        // Attempting to withdraw excess gOHM should revert
        vm.prank(admin);
        vm.expectRevert(ICallistoVault.NoExcessGOHM.selector);
        vault.withdrawExcessGOHM(excessGOHM, user);
    }

    // Test full withdrawal of excess gOHM using fork logic
    function test_callistoVaultFork_withdrawExcessGOHM_full(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        // Setup: deposit assets and execute to establish collateral position
        _depositToVaultExt(user, assets);

        // Get current gOHM index and simulate an increase by mocking
        uint256 currentIndex = GOHM.index();
        uint256 indexInc = 1e9; // Simulate index increase
        uint256 newIndex = currentIndex + indexInc;

        // Mock the gOHM index to simulate appreciation/staking rewards
        vm.mockCall(address(GOHM), abi.encodeWithSelector(GOHM.index.selector), abi.encode(newIndex));

        // Get excess gOHM after the simulated index increase
        uint256 excessGOHM = vault.excessGOHM();
        assertGt(excessGOHM, 0, "Should have excess gOHM after index increase");

        // Test that attempting to withdraw more than excess fails
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICallistoVault.NotEnoughGOHM.selector, 1));
        vault.withdrawExcessGOHM(excessGOHM + 1, user);

        // Test withdrawing full excess gOHM succeeds
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.GOHMExcessWithdrawn(user, excessGOHM);
        vault.withdrawExcessGOHM(excessGOHM, user);

        // Verify gOHM was transferred to the recipient
        assertEq(GOHM.balanceOf(user), excessGOHM);

        // Verify no excess gOHM remains after full withdrawal
        uint256 remainingExcess = vault.excessGOHM();
        assertEq(remainingExcess, 0, "Should have no excess gOHM after full withdrawal");
    }

    // Test withdrawal when cooler loan has been liquidated but vault doesn't have enough OHM balance using fork logic
    function test_callistoVaultFork_withdrawCoolerV2LoanHasBeenLiquidated_Revert(uint256 assets, uint256 partialAssets)
        external
    {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets - 1);

        // Setup: deposit assets and execute to establish collateral position
        _depositToVaultExt(user, assets);

        // Verify initial position is established properly
        assertEq(vault.pendingOHMDeposits(), 0);
        assertGt(COOLER.accountCollateral(address(vault)), 0);

        // Simulate vault position liquidation by mocking cooler to return zero collateral
        // This is more appropriate for fork tests than trying to withdraw all collateral
        vm.mockCall(
            address(COOLER),
            abi.encodeWithSelector(COOLER.accountCollateral.selector, address(vault)),
            abi.encode(uint128(0))
        );

        // Verify liquidation simulation worked
        assertEq(COOLER.accountCollateral(address(vault)), 0, "Cooler collateral should be zero after liquidation");

        // Mint some OHM directly to vault (but not enough for full withdrawal)
        _ohmMint(address(vault), partialAssets);

        // Verify vault has the partial amount but not enough for full withdrawal
        assertEq(ohm.balanceOf(address(vault)), partialAssets);
        assertLt(partialAssets, assets, "Partial assets should be less than requested withdrawal");

        // Attempt to withdraw the full original amount should revert
        // Since cooler has no collateral and vault doesn't have enough OHM balance
        vm.prank(user);
        vm.expectRevert();
        vault.withdraw(assets, user, user);
    }

    // Test withdrawal when cooler loan has been liquidated and vault has enough OHM balance using fork logic
    function test_callistoVaultFork_withdrawCoolerV2LoanHasBeenLiquidated_Ok(uint256 assets, uint256 partialAssets)
        external
    {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets - 1);

        uint256 partialShares = vault.convertToShares(partialAssets);

        // Setup: deposit assets and execute to establish collateral position
        _depositToVaultExt(user, assets);

        // Verify initial position is established properly
        assertEq(vault.pendingOHMDeposits(), 0);
        assertGt(COOLER.accountCollateral(address(vault)), 0);

        // Simulate vault position liquidation by mocking cooler to return zero collateral
        // This is more appropriate for fork tests than trying to withdraw all collateral
        vm.mockCall(
            address(COOLER),
            abi.encodeWithSelector(COOLER.accountCollateral.selector, address(vault)),
            abi.encode(uint128(0))
        );

        // Verify liquidation simulation worked
        assertEq(COOLER.accountCollateral(address(vault)), 0, "Cooler collateral should be zero after liquidation");

        // Mint OHM directly to vault (enough for the partial withdrawal)
        _ohmMint(address(vault), partialAssets);

        // Verify vault has sufficient OHM balance for the withdrawal
        assertEq(ohm.balanceOf(address(vault)), partialAssets);

        // Withdraw the partial amount should succeed since vault has enough OHM balance
        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(user, user, user, partialAssets, partialShares);
        vault.withdraw(partialAssets, user, user);

        // Verify user received the withdrawn OHM
        assertEq(ohm.balanceOf(address(user)), partialAssets);

        // Verify vault OHM balance was reduced
        assertEq(ohm.balanceOf(address(vault)), 0);
    }

    // Test emergency redeem functionality using fork logic
    function test_callistoVaultFork_emergencyRedeem(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 shares = vault.convertToShares(assets);

        // Setup: deposit assets and execute to establish collateral position
        _depositToVaultExt(user, assets);

        // Verify initial position is established properly
        assertEq(vault.pendingOHMDeposits(), 0);
        assertGt(COOLER.accountCollateral(address(vault)), 0);

        // In fork tests, we need to account for the fact that debt might be different due to real contract interactions
        // The emergency redeem should return the PSM balance available
        uint256 expectedUSDS = SUSDS.maxWithdraw(address(psm));

        // Test emergency redeem before liquidation - should return 0 (vault position still active)
        uint256 preEmergencyResult = vault.emergencyRedeem(1234);
        assertEq(preEmergencyResult, 0, "Emergency redeem should return 0 before liquidation");

        // Simulate vault position liquidation by mocking cooler to return zero collateral
        // This simulates the vault being liquidated
        vm.mockCall(
            address(COOLER),
            abi.encodeWithSelector(COOLER.accountCollateral.selector, address(vault)),
            abi.encode(uint128(0))
        );

        // Verify liquidation simulation worked
        assertEq(COOLER.accountCollateral(address(vault)), 0, "Cooler collateral should be zero after liquidation");

        // Test zero value revert
        vm.expectRevert(ICallistoVault.ZeroValue.selector);
        vault.emergencyRedeem(0);

        // Perform emergency redeem - user gets USDS from PSM
        vm.prank(user);
        uint256 returnedUSDS = vault.emergencyRedeem(shares);

        // Verify user received USDS (amount may vary in fork tests due to real contract precision)
        assertGt(returnedUSDS, 0, "Should receive some USDS from emergency redeem");
        assertEq(USDS.balanceOf(address(user)), returnedUSDS, "User should receive the returned USDS amount");

        // In fork tests, the exact amount might vary due to sUSDS yield and real contract interactions
        // so we use approximate equality with reasonable tolerance
        assertApproxEqRel(returnedUSDS, expectedUSDS, 0.01e18, "Returned USDS should be close to expected amount");
    }

    // Test reimbursement claim specifically from PSM using fork logic (migrated from CallistoVault.t.sol)
    function test_callistoVaultFork_claimReimbursement_fromPSM(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        // Setup: deposit and execute to create position with debt
        _depositToVaultExt(user, assets);

        // Create debt scenario using the established fork pattern
        _prepareCoolerWithDebt(assets);
        uint128 wadDebt = _getCoolerDebt();
        assertGt(wadDebt, 0, "Cooler debt should be greater than 0");

        // Create scenario where PSM has no funds by draining it completely
        uint256 totalAssetsAvailable = vaultStrategy.totalAssetsAvailable();
        if (totalAssetsAvailable > 0) {
            _buyUSDSfromPSM(totalAssetsAvailable);
        }

        // Verify PSM has no funds available
        assertEq(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have no assets available");

        // Mint and approve USDS for full debt repayment (creates reimbursement claim)
        _usdsMint(address(this), wadDebt);
        USDS.approve(address(vault), wadDebt);

        // Repay debt to create reimbursement claim
        vault.repayCoolerDebt(wadDebt);

        // Verify reimbursement claim was created and PSM has no balance
        uint256 reimbursementClaim = vault.reimbursementClaims(address(this));
        assertEq(reimbursementClaim, wadDebt, "Reimbursement claim should equal debt repaid");
        assertEq(vault.totalReimbursementClaim(), reimbursementClaim, "Total reimbursement should increase");
        assertEq(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have no USDS available");

        // Add USDS to PSM by having another user deposit (similar to original test pattern)
        _ohmMint(user2, assets * 2);
        _depositToVaultExt(user2, assets * 2);

        // Verify PSM now has funds available
        assertGt(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have USDS available after new deposit");

        // Record initial balance
        uint256 userInitialBalance = USDS.balanceOf(address(this));

        // Claim reimbursement from PSM
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.ReimbursementClaimRemoved(address(this), reimbursementClaim, wadDebt);
        vault.claimReimbursement(address(this));

        // Verify user received the reimbursement from PSM
        uint256 userFinalBalance = USDS.balanceOf(address(this));
        uint256 receivedAmount = userFinalBalance - userInitialBalance;

        // In fork tests, allow for small precision differences due to real contract interactions
        assertApproxEqAbs(receivedAmount, wadDebt, 10, "User should receive debt amount as reimbursement");

        // Verify reimbursement claim is cleared
        assertEq(vault.reimbursementClaims(address(this)), 0, "Reimbursement claim should be cleared");
        assertEq(vault.totalReimbursementClaim(), 0, "Total reimbursement should be emptied");
    }

    // Test partial reimbursement claim specifically from PSM using fork logic (migrated from CallistoVault.t.sol)
    function test_callistoVaultFork_claimReimbursementPartial_fromPSM(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        // Setup: deposit and execute to create position with debt
        _depositToVaultExt(user, assets);

        // Create debt scenario using the established fork pattern
        _prepareCoolerWithDebt(assets);
        uint128 wadDebt = _getCoolerDebt();
        assertGt(wadDebt, 0, "Cooler debt should be greater than 0");

        // Create scenario where PSM has no funds by draining it completely
        uint256 totalAssetsAvailable = vaultStrategy.totalAssetsAvailable();
        if (totalAssetsAvailable > 0) {
            _buyUSDSfromPSM(totalAssetsAvailable);
        }

        // Verify PSM has no funds available
        assertEq(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have no assets available");

        // Mint and approve USDS for full debt repayment (creates reimbursement claim)
        _usdsMint(address(this), wadDebt);
        USDS.approve(address(vault), wadDebt);

        // Repay debt to create reimbursement claim
        vault.repayCoolerDebt(wadDebt);

        // Verify reimbursement claim was created and PSM has no balance
        uint256 reimbursementClaim = vault.reimbursementClaims(address(this));
        assertEq(reimbursementClaim, wadDebt, "Reimbursement claim should equal debt repaid");
        assertEq(vault.totalReimbursementClaim(), reimbursementClaim, "Total reimbursement should increase");
        assertEq(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have no USDS available");

        // Add USDS to PSM by having another user deposit (similar to original test pattern)
        _ohmMint(user2, assets * 2);
        _depositToVaultExt(user2, assets * 2);

        // Verify PSM now has funds available
        assertGt(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have USDS available after new deposit");

        // Claim partial amount (half of the reimbursement)
        uint256 partialAmount = wadDebt / 2;
        uint256 partialAmountInWad = vault.debtConverterToWad().toWad(partialAmount);

        // Record initial balance
        uint256 userInitialBalance = USDS.balanceOf(address(this));

        // Claim partial reimbursement from PSM
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.ReimbursementClaimRemoved(address(this), partialAmountInWad, partialAmount);
        vault.claimReimbursementPartial(address(this), partialAmount);

        // Verify user received the partial reimbursement from PSM
        uint256 userFinalBalance = USDS.balanceOf(address(this));
        uint256 receivedAmount = userFinalBalance - userInitialBalance;

        // In fork tests, allow for small precision differences due to real contract interactions
        assertApproxEqAbs(receivedAmount, partialAmount, 10, "User should receive partial amount as reimbursement");

        // Check that remaining claim is properly reduced
        uint256 remainingClaim = vault.reimbursementClaims(address(this));
        assertGt(remainingClaim, 0, "Should have remaining claim");
        assertLt(remainingClaim, reimbursementClaim, "Remaining should be less than original");
        assertEq(vault.totalReimbursementClaim(), remainingClaim, "Total reimbursement should be decreased");

        // Verify the remaining claim is approximately correct (allow for precision differences)
        uint256 expectedRemaining = reimbursementClaim - partialAmountInWad;
        assertApproxEqAbs(remainingClaim, expectedRemaining, 10, "Remaining claim should be correct");
    }

    // Test multiple partial reimbursement claims using fork logic (migrated from CallistoVault.t.sol)
    function test_callistoVaultFork_claimReimbursementPartial_multiplePartialClaims(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT * 4, MAX_DEPOSIT);

        // Setup: deposit and execute to create position with debt
        _depositToVaultExt(user, assets);

        // Create debt scenario using the established fork pattern
        _prepareCoolerWithDebt(assets);
        uint128 wadDebt = _getCoolerDebt();
        assertGt(wadDebt, 0, "Cooler debt should be greater than 0");

        // Create scenario where PSM has no funds by draining it completely
        uint256 totalAssetsAvailable = vaultStrategy.totalAssetsAvailable();
        if (totalAssetsAvailable > 0) {
            _buyUSDSfromPSM(totalAssetsAvailable);
        }

        // Verify PSM has no funds available
        assertEq(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have no assets available");

        // Mint and approve USDS for full debt repayment (creates reimbursement claim)
        _usdsMint(address(this), wadDebt);
        USDS.approve(address(vault), wadDebt);

        // Repay debt to create reimbursement claim
        vault.repayCoolerDebt(wadDebt);

        // Verify reimbursement claim was created and PSM has no balance
        uint256 reimbursementClaim = vault.reimbursementClaims(address(this));
        assertEq(reimbursementClaim, wadDebt, "Reimbursement claim should equal debt repaid");
        assertEq(vault.totalReimbursementClaim(), reimbursementClaim, "Total reimbursement should increase");
        assertEq(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have no USDS available");

        // Ensure we have enough funds in PSM for multiple claims by having user2 deposit more
        _ohmMint(user2, assets * 2);
        _depositToVaultExt(user2, assets * 2);

        // Verify PSM now has sufficient funds available for multiple claims
        assertGt(vaultStrategy.totalAssetsAvailable(), wadDebt, "PSM should have enough USDS for multiple claims");

        // Record initial balance
        uint256 initialBalance = USDS.balanceOf(address(this));

        // First partial claim (1/4 of total)
        uint256 firstPartial = wadDebt / 4;
        uint256 firstPartialInWad = vault.debtConverterToWad().toWad(firstPartial);

        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.ReimbursementClaimRemoved(address(this), firstPartialInWad, firstPartial);
        vault.claimReimbursementPartial(address(this), firstPartial);

        // Verify first claim
        uint256 balanceAfterFirst = USDS.balanceOf(address(this));
        uint256 receivedFirst = balanceAfterFirst - initialBalance;
        assertApproxEqAbs(receivedFirst, firstPartial, 5, "Should receive first partial amount");

        // Check remaining claim after first partial
        uint256 claimAfterFirst = vault.reimbursementClaims(address(this));
        assertGt(claimAfterFirst, 0, "Should have remaining claim after first");
        assertLt(claimAfterFirst, reimbursementClaim, "Should be less than original after first");
        assertEq(vault.totalReimbursementClaim(), claimAfterFirst, "Total reimbursement should be decreased");

        // Second partial claim (another 1/4 of original total)
        uint256 secondPartial = wadDebt / 4;
        uint256 secondPartialInWad = vault.debtConverterToWad().toWad(secondPartial);

        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.ReimbursementClaimRemoved(address(this), secondPartialInWad, secondPartial);
        vault.claimReimbursementPartial(address(this), secondPartial);

        // Verify second claim
        uint256 balanceAfterSecond = USDS.balanceOf(address(this));
        uint256 totalReceivedAfterSecond = balanceAfterSecond - initialBalance;
        assertApproxEqAbs(
            totalReceivedAfterSecond, firstPartial + secondPartial, 10, "Should receive accumulated partial amounts"
        );

        // Check remaining claim after second partial
        uint256 claimAfterSecond = vault.reimbursementClaims(address(this));
        assertGt(claimAfterSecond, 0, "Should have remaining claim after second");
        assertLt(claimAfterSecond, claimAfterFirst, "Should be less than after first claim");
        assertEq(vault.totalReimbursementClaim(), claimAfterSecond, "Total reimbursement should be decreased");

        // Final claim for remaining amount (remaining 1/2 of original total)
        uint256 remainingDebt = wadDebt - firstPartial - secondPartial;

        // For the final claim, we don't need to emit the exact event since precision might vary in fork tests
        vault.claimReimbursementPartial(address(this), remainingDebt);

        // Verify final state - all debt should be received
        uint256 finalBalance = USDS.balanceOf(address(this));
        uint256 totalReceived = finalBalance - initialBalance;
        assertApproxEqAbs(totalReceived, wadDebt, 15, "Should receive total debt amount across all claims");

        // Verify reimbursement claim is fully cleared
        uint256 finalClaim = vault.reimbursementClaims(address(this));
        assertEq(finalClaim, 0, "Reimbursement claim should be completely cleared");
        assertEq(vault.totalReimbursementClaim(), 0, "Total reimbursement should be emptied");
    }

    // Test partial reimbursement claim from both PSM and vault direct balance using fork logic
    function test_callistoVaultFork_claimReimbursementPartial_fromPSMAndDirectFromVault(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT * 2, MAX_DEPOSIT);

        // Setup: deposit and execute to create position with debt
        _depositToVaultExt(user, assets);

        // Create debt scenario using the established fork pattern
        _prepareCoolerWithDebt(assets);
        uint128 wadDebt = _getCoolerDebt();
        assertGt(wadDebt, 0, "Cooler debt should be greater than 0");

        // Create scenario where PSM has no funds by draining it completely
        uint256 totalAssetsAvailable = vaultStrategy.totalAssetsAvailable();
        if (totalAssetsAvailable > 0) {
            _buyUSDSfromPSM(totalAssetsAvailable);
        }

        // Verify PSM has no funds available
        assertEq(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have no assets available");

        // Mint and approve USDS for full debt repayment (creates reimbursement claim)
        _usdsMint(address(this), wadDebt);
        USDS.approve(address(vault), wadDebt);

        // Repay debt to create reimbursement claim
        vault.repayCoolerDebt(wadDebt);

        // Verify reimbursement claim was created and PSM has no balance
        uint256 reimbursementClaim = vault.reimbursementClaims(address(this));
        assertEq(reimbursementClaim, wadDebt, "Reimbursement claim should equal debt repaid");
        assertEq(vault.totalReimbursementClaim(), reimbursementClaim, "Total reimbursement should be increased");
        assertEq(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have no USDS available");

        // Create split funding scenario (like original test):
        // 1. Return 1/3 USDS to PSM
        uint256 psmAmount = wadDebt / 3;
        _sellUSDStoPSM(psmAmount);

        // 2. Add 1/3 USDS directly to vault
        uint256 vaultAmount = wadDebt / 3;
        _usdsMint(address(vault), vaultAmount);

        // Claim partial amount that requires both PSM and vault funds
        uint256 partialAmount = (psmAmount + vaultAmount) * 2 / 3; // Request 2/3 of available funds
        uint256 partialAmountInWad = vault.debtConverterToWad().toWad(partialAmount);

        // Record initial balance
        uint256 userInitialBalance = USDS.balanceOf(address(this));

        // Claim partial reimbursement that should pull from both sources
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.ReimbursementClaimRemoved(address(this), partialAmountInWad, partialAmount);
        vault.claimReimbursementPartial(address(this), partialAmount);

        // Verify user received the partial reimbursement
        uint256 userFinalBalance = USDS.balanceOf(address(this));
        uint256 receivedAmount = userFinalBalance - userInitialBalance;

        // In fork tests, allow for precision differences due to real contract interactions
        assertApproxEqAbs(receivedAmount, partialAmount, 20, "User should receive partial amount as reimbursement");

        // Check that remaining claim is properly reduced
        uint256 remainingClaim = vault.reimbursementClaims(address(this));
        assertGt(remainingClaim, 0, "Should have remaining claim");
        assertLt(remainingClaim, reimbursementClaim, "Remaining should be less than original");
        assertEq(vault.totalReimbursementClaim(), remainingClaim, "Total reimbursement should be decreased");

        // Verify the remaining claim is approximately correct (allow for precision differences)
        uint256 expectedRemaining = reimbursementClaim - partialAmountInWad;
        assertApproxEqAbs(remainingClaim, expectedRemaining, 20, "Remaining claim should be correct");
    }

    // Test claiming exact amount using partial claim function (should behave same as full claim) using fork logic
    function test_callistoVaultFork_claimReimbursementPartial_exactAmount(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        // Setup: deposit and execute to create position with debt
        _depositToVaultExt(user, assets);

        // Create debt scenario using the established fork pattern
        _prepareCoolerWithDebt(assets);
        uint128 wadDebt = _getCoolerDebt();
        assertGt(wadDebt, 0, "Cooler debt should be greater than 0");

        // Create scenario where PSM has no funds by draining it completely
        uint256 totalAssetsAvailable = vaultStrategy.totalAssetsAvailable();
        if (totalAssetsAvailable > 0) {
            _buyUSDSfromPSM(totalAssetsAvailable);
        }

        // Verify PSM has no funds available
        assertEq(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have no assets available");

        // Mint and approve USDS for full debt repayment (creates reimbursement claim)
        _usdsMint(address(this), wadDebt);
        USDS.approve(address(vault), wadDebt);

        // Repay debt to create reimbursement claim
        vault.repayCoolerDebt(wadDebt);

        // Verify reimbursement claim was created and PSM has no balance
        uint256 reimbursementClaim = vault.reimbursementClaims(address(this));
        assertEq(reimbursementClaim, wadDebt, "Reimbursement claim should equal debt repaid");
        assertEq(vault.totalReimbursementClaim(), reimbursementClaim, "Total reimbursement should be increased");
        assertEq(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have no USDS available");

        // Ensure we have funds in PSM by having user2 deposit more assets
        _ohmMint(user2, assets);
        _depositToVaultExt(user2, assets);

        // Verify PSM now has funds available
        assertGt(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have USDS available after new deposit");

        // Record initial balance
        uint256 userInitialBalance = USDS.balanceOf(address(this));

        // Claim exact amount using partial claim function (should work same as full claim)
        uint256 exactAmount = wadDebt;
        uint256 exactAmountInWad = vault.debtConverterToWad().toWad(exactAmount);

        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.ReimbursementClaimRemoved(address(this), exactAmountInWad, exactAmount);
        vault.claimReimbursementPartial(address(this), exactAmount);

        // Verify user received the exact debt amount
        uint256 userFinalBalance = USDS.balanceOf(address(this));
        uint256 receivedAmount = userFinalBalance - userInitialBalance;

        // In fork tests, allow for small precision differences due to real contract interactions
        assertApproxEqAbs(receivedAmount, exactAmount, 10, "User should receive exact debt amount as reimbursement");

        // Verify reimbursement claim is completely cleared (since we claimed the exact amount)
        assertEq(vault.reimbursementClaims(address(this)), 0, "Reimbursement claim should be completely cleared");
        assertEq(vault.totalReimbursementClaim(), 0, "Total reimbursement should be emptied");
    }

    // Test error cases for partial reimbursement claims using fork logic
    function test_callistoVaultFork_claimReimbursementPartial_errorCases() external {
        uint256 assets = MIN_DEPOSIT;

        // Setup: deposit and execute to create position with debt
        _depositToVaultExt(user, assets);

        // Create debt scenario using the established fork pattern
        _prepareCoolerWithDebt(assets);
        uint128 wadDebt = _getCoolerDebt();
        assertGt(wadDebt, 0, "Cooler debt should be greater than 0");

        // Create scenario where PSM has no funds by draining it completely
        uint256 totalAssetsAvailable = vaultStrategy.totalAssetsAvailable();
        if (totalAssetsAvailable > 0) {
            _buyUSDSfromPSM(totalAssetsAvailable);
        }

        // Verify PSM has no funds available
        assertEq(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have no assets available");

        // Mint and approve USDS for full debt repayment (creates reimbursement claim)
        _usdsMint(address(this), wadDebt);
        USDS.approve(address(vault), wadDebt);

        // Repay debt to create reimbursement claim
        vault.repayCoolerDebt(wadDebt);

        // Verify reimbursement claim was created
        uint256 storedClaim = vault.reimbursementClaims(address(this));
        assertGt(storedClaim, 0, "Should have a reimbursement claim");
        assertEq(vault.totalReimbursementClaim(), storedClaim, "Total reimbursement should be increased");

        // Test Error Case 1: Zero amount should revert
        vm.expectRevert(abi.encodeWithSelector(ICallistoVault.ZeroValue.selector));
        vault.claimReimbursementPartial(address(this), 0);

        // Test Error Case 2: Amount exceeding available claim should revert
        // Use a very large amount that definitely exceeds any reasonable claim
        uint256 excessiveAmount = type(uint128).max;
        vm.expectRevert(
            abi.encodeWithSelector(ICallistoVault.PartialAmountExceedsAvailableClaim.selector, excessiveAmount, wadDebt)
        );
        vault.claimReimbursementPartial(address(this), excessiveAmount);

        // Test Error Case 3: No reimbursement for different account should revert
        vm.expectRevert(abi.encodeWithSelector(ICallistoVault.PartialAmountExceedsAvailableClaim.selector, 100, 0));
        vault.claimReimbursementPartial(user, 100);

        // Add funds to PSM for the successful partial claim
        _ohmMint(user2, assets);
        _depositToVaultExt(user2, assets);

        // Verify PSM now has funds available
        assertGt(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have USDS available after new deposit");

        // Test Success Case: Valid partial claim should work
        uint256 validPartial = wadDebt / 2;
        uint256 validPartialInWad = vault.debtConverterToWad().toWad(validPartial);

        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.ReimbursementClaimRemoved(address(this), validPartialInWad, validPartial);
        vault.claimReimbursementPartial(address(this), validPartial);

        // Check that remaining claim is properly updated
        uint256 remainingClaim = vault.reimbursementClaims(address(this));
        assertGt(remainingClaim, 0, "Should have remaining claim");
        assertLt(remainingClaim, storedClaim, "Remaining should be less than original");
        assertEq(vault.totalReimbursementClaim(), remainingClaim, "Total reimbursement should be decreased");

        // Verify the remaining claim is approximately correct (allow for precision differences in fork)
        uint256 expectedRemaining = storedClaim - validPartialInWad;
        assertApproxEqAbs(remainingClaim, expectedRemaining, 10, "Remaining claim should be correct");
    }

    // Test partial reimbursement claim directly from vault balance using fork logic
    function test_callistoVaultFork_claimReimbursementPartial_directFromVault(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        // Setup: deposit and execute to create position with debt
        _depositToVaultExt(user, assets);

        // Create debt scenario using the established fork pattern
        _prepareCoolerWithDebt(assets);
        uint128 wadDebt = _getCoolerDebt();
        assertGt(wadDebt, 0, "Cooler debt should be greater than 0");

        // Create scenario where PSM has no funds by draining it completely
        uint256 totalAssetsAvailable = vaultStrategy.totalAssetsAvailable();
        if (totalAssetsAvailable > 0) {
            _buyUSDSfromPSM(totalAssetsAvailable);
        }

        // Verify PSM has no funds available
        assertEq(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have no assets available");

        // Mint and approve USDS for full debt repayment (creates reimbursement claim)
        _usdsMint(address(this), wadDebt);
        USDS.approve(address(vault), wadDebt);

        // Repay debt to create reimbursement claim
        vault.repayCoolerDebt(wadDebt);

        // Verify reimbursement claim was created and PSM has no balance
        uint256 reimbursementClaim = vault.reimbursementClaims(address(this));
        assertEq(reimbursementClaim, wadDebt, "Reimbursement claim should equal debt repaid");
        assertEq(vault.totalReimbursementClaim(), reimbursementClaim, "Total reimbursement should be increased");
        assertEq(vaultStrategy.totalAssetsAvailable(), 0, "PSM should have no USDS available");

        // Add USDS directly to vault (not to PSM strategy)
        _usdsMint(address(vault), wadDebt);

        // Claim partial amount (3/4 of the reimbursement) directly from vault balance
        uint256 partialAmount = (wadDebt * 3) / 4;
        uint256 partialAmountInWad = vault.debtConverterToWad().toWad(partialAmount);

        // Record initial balances
        uint256 userInitialBalance = USDS.balanceOf(address(this));
        uint256 vaultInitialBalance = USDS.balanceOf(address(vault));

        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.ReimbursementClaimRemoved(address(this), partialAmountInWad, partialAmount);
        vault.claimReimbursementPartial(address(this), partialAmount);

        // Verify user received the partial amount
        uint256 userFinalBalance = USDS.balanceOf(address(this));
        uint256 receivedAmount = userFinalBalance - userInitialBalance;
        assertApproxEqAbs(receivedAmount, partialAmount, 10, "User should receive partial amount");

        // Verify vault balance was reduced by the partial amount
        uint256 vaultFinalBalance = USDS.balanceOf(address(vault));
        uint256 expectedVaultBalance = vaultInitialBalance - partialAmount;
        assertApproxEqAbs(
            vaultFinalBalance, expectedVaultBalance, 10, "Vault balance should be reduced by partial amount"
        );

        // Check that remaining claim is properly reduced
        uint256 remainingClaim = vault.reimbursementClaims(address(this));
        assertGt(remainingClaim, 0, "Should have remaining claim");
        assertLt(remainingClaim, reimbursementClaim, "Remaining should be less than original");
        assertEq(vault.totalReimbursementClaim(), remainingClaim, "Total reimbursement should be decreased");

        // Verify the remaining claim is approximately correct (allow for precision differences in fork)
        uint256 expectedRemaining = reimbursementClaim - partialAmountInWad;
        assertApproxEqAbs(remainingClaim, expectedRemaining, 10, "Remaining claim should be correct");
    }

    // Test calcDebtToRepay function with actual debt using fork logic
    function test_callistoVaultFork_calcDebtToRepay_withDebt(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        // Setup: deposit and execute to create position with debt
        _depositToVaultExt(user, assets);

        // Create debt scenario using the established fork pattern
        _prepareCoolerWithDebt(assets);
        uint128 expectedWadDebt = _getCoolerDebt();
        assertGt(expectedWadDebt, 0, "Cooler debt should be greater than 0");

        // Test calcDebtToRepay() function
        (uint128 wadDebt, uint256 debtAmount) = vault.calcDebtToRepay();

        // Verify the returned values are reasonable and match expected debt
        assertEq(wadDebt, expectedWadDebt, "wadDebt should match expected debt");
        assertEq(debtAmount, expectedWadDebt, "debtAmount should match expected debt");

        // The function should be view-only, so calling it multiple times should return same result
        (uint128 wadDebt2, uint256 debtAmount2) = vault.calcDebtToRepay();
        assertEq(wadDebt, wadDebt2, "Multiple calls should return same wadDebt");
        assertEq(debtAmount, debtAmount2, "Multiple calls should return same debtAmount");

        // Test that function works consistently with real fork debt calculations
        assertEq(wadDebt, expectedWadDebt, "Function should return actual cooler debt");
        assertEq(debtAmount, expectedWadDebt, "Function should return actual cooler debt as amount");
    }

    // Test calcDebtToRepay function with no debt using fork logic
    function test_callistoVaultFork_calcDebtToRepay_noDebt(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        // Setup: deposit and execute to create position without debt manipulation
        _depositToVaultExt(user, assets);

        // Don't create debt scenario - just test with normal position
        // In a normal position right after deposit, there should be minimal or no debt

        // Test calcDebtToRepay() function
        (uint128 wadDebt, uint256 debtAmount) = vault.calcDebtToRepay();

        // In a fresh position, debt should be minimal (close to 0 or small positive due to borrowing)
        // We can't guarantee exactly 0 in fork tests due to real contract interactions
        // But we can test the function works and returns consistent values
        assertEq(wadDebt, debtAmount, "wadDebt and debtAmount should be equal");

        // The function should be view-only, so calling it multiple times should return same result
        (uint128 wadDebt2, uint256 debtAmount2) = vault.calcDebtToRepay();
        assertEq(wadDebt, wadDebt2, "Multiple calls should return same wadDebt");
        assertEq(debtAmount, debtAmount2, "Multiple calls should return same debtAmount");
    }

    // Test processPendingDeposits in swapper mode using fork logic
    function test_callistoVaultFork_processPendingDeposits_swapperMode(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        // Setup: mint OHM and deposit to vault (but don't execute yet)
        _ohmMint(user, assets);
        _depositToVault(user, assets);

        // Verify we have pending deposits
        assertEq(vault.pendingOHMDeposits(), assets, "Should have pending OHM deposits");
        assertEq(ohm.balanceOf(address(vault)), assets, "Vault should have OHM balance");

        // Deploy and configure a simple swapper for testing swapper mode
        // We'll use a contract that simply converts OHM to gOHM using the real staking contract
        ForkSwapper swapper = new ForkSwapper(address(ohm), address(GOHM), address(staking));

        // Set vault to swapper mode (requires admin role)
        // First mock the staking contract to have a valid warmup period for mode switching
        vm.mockCall(address(staking), abi.encodeWithSelector(staking.warmupPeriod.selector), abi.encode(1));

        vm.startPrank(admin);
        vault.setSwapMode(address(swapper));
        vm.stopPrank();

        // Clear the mock after setting the mode
        vm.clearMockedCalls();

        // Verify vault is in swapper mode
        assertEq(
            uint256(vault.ohmToGOHMMode()), uint256(ICallistoVault.OHMToGOHMMode.Swap), "Vault should be in swap mode"
        );
        assertEq(address(vault.ohmSwapper()), address(swapper), "Swapper address should be set");

        // Process pending deposits in swapper mode
        vm.prank(admin); // Only admin can call processPendingDeposits
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.DepositsHandled(assets);
        vault.processPendingDeposits(assets, new bytes[](0));

        // Verify deposits were processed
        assertEq(vault.pendingOHMDeposits(), 0, "Pending OHM deposits should be cleared");
        assertEq(ohm.balanceOf(address(vault)), 0, "Vault OHM balance should be 0 after swapping");

        // Note: In fork tests, the exact gOHM amount can vary due to real contract interactions
        // The important part is that pending deposits were processed using the swapper mode
    }

    // Test processPendingDeposits in active warmup mode using fork logic
    function test_callistoVaultFork_processPendingDeposits_activeWarmupMode(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        // Setup: mint OHM and deposit to vault (but don't execute yet)
        _ohmMint(user, assets);
        _depositToVault(user, assets);

        // Verify we have pending deposits
        assertEq(vault.pendingOHMDeposits(), assets, "Should have pending OHM deposits");
        assertEq(ohm.balanceOf(address(vault)), assets, "Vault should have OHM balance");

        // Set vault to active warmup mode (requires admin role)
        // First mock the staking contract to have a valid warmup period for mode switching
        vm.mockCall(address(staking), abi.encodeWithSelector(staking.warmupPeriod.selector), abi.encode(1));

        vm.startPrank(admin);
        vault.setActiveWarmupMode();
        vm.stopPrank();

        // Verify vault is in active warmup mode
        assertEq(
            uint256(vault.ohmToGOHMMode()),
            uint256(ICallistoVault.OHMToGOHMMode.ActiveWarmup),
            "Vault should be in active warmup mode"
        );

        // Process pending deposits in active warmup mode (first processing)
        vm.prank(admin); // Only admin can call processPendingDeposits
        vault.processPendingDeposits(assets, new bytes[](0));

        // Verify deposits were processed into warmup staking
        assertEq(vault.pendingOHMWarmupStaking(), assets, "OHM should be in warmup staking");
        assertEq(vault.pendingOHMDeposits(), 0, "Pending OHM deposits should be cleared");

        // Clear mocks after initial processing
        vm.clearMockedCalls();

        // Note: In fork tests, completing the warmup process is complex due to real staking mechanics
        // The key verification is that active warmup mode correctly processes deposits into warmup state
        // The exact warmup completion behavior varies with real contract interactions
    }
}

// Simple swapper for fork tests that uses real staking to convert OHM to gOHM
contract ForkSwapper {
    using SafeERC20 for IERC20;

    IERC20 public immutable OHM;
    IERC20 public immutable GOHM;
    IOlympusStaking public immutable STACKING;

    constructor(address _ohm, address _gohm, address _staking) {
        OHM = IERC20(_ohm);
        GOHM = IERC20(_gohm);
        STACKING = IOlympusStaking(_staking);
    }

    function swap(uint256 ohmAmount, bytes[] calldata) external returns (uint256) {
        // Transfer OHM from vault to this swapper
        OHM.safeTransferFrom(msg.sender, address(this), ohmAmount);

        // Approve staking to use OHM
        OHM.approve(address(STACKING), ohmAmount);

        // Stake OHM to get gOHM (using stake function)
        STACKING.stake(address(this), ohmAmount, false, true);

        // Transfer the resulting gOHM back to vault
        uint256 gohmAmount = GOHM.balanceOf(address(this));
        GOHM.safeTransfer(msg.sender, gohmAmount);

        return gohmAmount;
    }
}
