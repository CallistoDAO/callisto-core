// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import { IERC20 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";

import { Math } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/Math.sol";
import { SafeCast } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/SafeCast.sol";
import { DebtTokenMigrator, Ownable } from "../../src/external/DebtTokenMigrator.sol";
import { MockConverterToWadDebt } from "../mocks/MockConverterToWadDebt.sol";
import {
    CallistoPSM,
    CallistoVaultLogic,
    CallistoVaultTestBase,
    MockCoolerTreasuryBorrower,
    MockERC20,
    MockSusds,
    VaultStrategy
} from "../test-common/CallistoVaultTestBase.sol";

contract DebtTokenMigratorTests is CallistoVaultTestBase {
    using SafeCast for *;
    using Math for uint256;

    function test_debtTokenMigrator_initializePSMAddress_reverts() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        debtTokenMigrator.initializePSMAddress(address(1));

        vm.prank(admin);
        vm.expectRevert(DebtTokenMigrator.ZeroAddress.selector);
        debtTokenMigrator.initializePSMAddress(address(0));

        vm.prank(admin);
        vm.expectRevert(DebtTokenMigrator.AlreadyInitialized.selector);
        debtTokenMigrator.initializePSMAddress(address(psm));
    }

    function test_debtTokenMigrator_setMigration_reverts() external {
        uint256 migrationTime = block.timestamp + 86_400;
        uint256 slippage = 1000;
        MockERC20 newUsds = new MockERC20("NEW USDS", "NEW USDS", 18);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        debtTokenMigrator.setMigration(migrationTime, slippage, address(1), address(converterToWadDebt));

        vm.startPrank(admin);

        vm.expectRevert(DebtTokenMigrator.MigrationTimeInPast.selector);
        debtTokenMigrator.setMigration(block.timestamp, slippage, address(1), address(converterToWadDebt));

        vm.expectRevert(DebtTokenMigrator.ZeroAddress.selector);
        debtTokenMigrator.setMigration(migrationTime, slippage, address(1), address(0));

        vm.expectRevert(DebtTokenMigrator.NewDebtTokenExpected.selector);
        debtTokenMigrator.setMigration(migrationTime, slippage, address(1), address(converterToWadDebt));

        // change usds token in Coller
        cooler.setNewUsdsToken(address(newUsds));

        vm.expectRevert(
            abi.encodeWithSelector(
                DebtTokenMigrator.YieldVaultHasAnotherAsset.selector, address(usds), address(newUsds)
            )
        );
        debtTokenMigrator.setMigration(migrationTime, slippage, address(susds), address(converterToWadDebt));
    }

    function test_debtTokenMigrator_setMigration_success() external {
        uint256 migrationTime = block.timestamp + 86_400;
        uint256 slippage = 1000;
        MockERC20 newUsds = new MockERC20("NEW USDS", "NEW USDS", 18);
        MockSusds newSusds = new MockSusds(IERC20(address(newUsds)));

        // change usds token in Coller
        cooler.setNewUsdsToken(address(newUsds));

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(debtTokenMigrator));
        emit DebtTokenMigrator.MigrationSet(
            address(newUsds), address(newSusds), address(converterToWadDebt), migrationTime, slippage
        );
        debtTokenMigrator.setMigration(migrationTime, slippage, address(newSusds), address(converterToWadDebt));

        assertEq(address(debtTokenMigrator.newYieldVault()), address(newSusds), "New yield vault address mismatch");
        assertEq(address(debtTokenMigrator.newDebtToken()), address(newUsds), "New debt token address mismatch");
        assertEq(
            address(debtTokenMigrator.newConverterToWadDebt()),
            address(converterToWadDebt),
            "New converter to wad debt address mismatch"
        );
        assertEq(debtTokenMigrator.migrationTime(), migrationTime, "Migration time mismatch");
        assertEq(debtTokenMigrator.slippage(), slippage, "Slippage mismatch");
    }

    function _prepareForMigration(uint256 slippage, uint8 decimals, bool needWarp)
        internal
        returns (MockERC20 newUsds, MockSusds newSusds)
    {
        uint256 migrationTime = block.timestamp + 86_400;
        newUsds = new MockERC20("NEW USDS", "NEW USDS", decimals);
        newSusds = new MockSusds(IERC20(address(newUsds)));

        newUsds.mint(address(this), 1e50);
        newUsds.approve(address(debtTokenMigrator), 1e50);

        // change usds token in Coller
        MockCoolerTreasuryBorrower coolerTreasuryBorrower = new MockCoolerTreasuryBorrower(address(newUsds));
        cooler.setNewUsdsToken(address(newUsds));
        cooler.setNewTreasuryBorrower(address(coolerTreasuryBorrower));

        MockConverterToWadDebt _converterToWadDebt = new MockConverterToWadDebt(decimals);

        vm.prank(admin);
        debtTokenMigrator.setMigration(migrationTime, slippage, address(newSusds), address(_converterToWadDebt));
        if (needWarp) {
            vm.warp(migrationTime + 1);
        }
    }

    function test_debtTokenMigrator_migrateDebtToken_toSoonCheck() external {
        vm.expectRevert(DebtTokenMigrator.TooSoon.selector);
        debtTokenMigrator.migrateDebtToken({ newDebtTokenAmount: MIN_DEPOSIT });

        _prepareForMigration(0, 18, false);

        vm.expectRevert(DebtTokenMigrator.TooSoon.selector);
        debtTokenMigrator.migrateDebtToken({ newDebtTokenAmount: MIN_DEPOSIT });
    }

    function test_debtTokenMigrator_migrateDebtToken_slippageExceeded_noSlippage() external {
        _depositToVaultExt(user, MIN_DEPOSIT);
        _prepareForMigration(0, 18, true);
        uint256 suppliedInPSM = psm.suppliedByLP();

        vm.expectRevert(abi.encodeWithSelector(DebtTokenMigrator.SlippageExceeded.selector, 1, 0));
        debtTokenMigrator.migrateDebtToken({ newDebtTokenAmount: suppliedInPSM - 1 });

        vm.expectRevert(abi.encodeWithSelector(DebtTokenMigrator.SlippageExceeded.selector, suppliedInPSM - 1, 0));
        debtTokenMigrator.migrateDebtToken({ newDebtTokenAmount: 1 });
    }

    function test_debtTokenMigrator_migrateDebtToken_slippageExceeded_withSlippage() external {
        _depositToVaultExt(user, 10e9); // 10 OHM
        _prepareForMigration(5000, /* 5% */ 18, true);
        uint256 suppliedInPSM = psm.suppliedByLP();
        assertEq(suppliedInPSM, 30e14); // 30 USDS = 30 * e18 / 1e4 (gohm index)
        uint256 fivePercent = (suppliedInPSM * 5) / 100;
        vm.expectRevert(
            abi.encodeWithSelector(
                DebtTokenMigrator.SlippageExceeded.selector,
                fivePercent + 1, // current diff
                fivePercent // max diff
            )
        );
        debtTokenMigrator.migrateDebtToken({ newDebtTokenAmount: suppliedInPSM - fivePercent - 1 });
    }

    function test_debtTokenMigrator_migrateDebtToken_slippageExceeded_lessDecimals() external {
        _depositToVaultExt(user, 100e9); // 100 OHM
        _prepareForMigration(0, 10, true); // -8 decimals
        uint256 suppliedInPSM = psm.suppliedByLP();
        assertEq(suppliedInPSM, 300e14); // 300 USDS = 300 * e18 / 1e4 (gohm index)
        vm.expectRevert(abi.encodeWithSelector(DebtTokenMigrator.SlippageExceeded.selector, 1, 0));
        debtTokenMigrator.migrateDebtToken({ newDebtTokenAmount: 300e6 - 1 }); // 300 * 1e10 / 1e4 (gohm index)
    }

    function test_debtTokenMigrator_migrateDebtToken_slippageExceeded_greaterDecimals() external {
        _depositToVaultExt(user, 100e9); // 100 OHM

        // Prepare for migration with smaller decimals first
        _prepareForMigration(0, 10, true); // -8 decimals
        uint256 suppliedInPSM = psm.suppliedByLP();
        uint256 expectedSuppliedInPSM = suppliedInPSM.ceilDiv(10 ** 8);
        debtTokenMigrator.migrateDebtToken({ newDebtTokenAmount: expectedSuppliedInPSM });

        // migrate to greater decimals
        _prepareForMigration(0, 18, true); // +8 decimals
        uint256 suppliedInPSM2 = psm.suppliedByLP();
        assertEq(suppliedInPSM2, 300e6); // 300 USDS = 300 * e10 / 1e4 (gohm index)
        vm.expectRevert(abi.encodeWithSelector(DebtTokenMigrator.SlippageExceeded.selector, 1, 0));
        debtTokenMigrator.migrateDebtToken({ newDebtTokenAmount: 300e14 - 1 }); // 300 * 1e18 / 1e4 (gohm index)
    }

    function test_debtTokenMigrator_migrateDebtToken_sameDecimals(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        _depositToVaultExt(user, assets);
        (MockERC20 newUsds, MockSusds newSusds) = _prepareForMigration(
            0, // 100% must be repaid
            18,
            true
        );

        uint256 suppliedInPSM = psm.suppliedByLP();

        vm.expectEmit(true, true, true, true, address(psm));
        emit CallistoPSM.AssetMigrated(address(newUsds), address(newSusds), address(this), suppliedInPSM, suppliedInPSM);

        vm.expectEmit(true, true, true, true, address(vaultStrategy));
        emit VaultStrategy.AssetMigrated(address(newUsds), address(newSusds));

        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.DebtTokenMigrated(address(newUsds));

        vm.expectEmit(true, true, true, true, address(debtTokenMigrator));
        emit DebtTokenMigrator.DebtTokenMigrated(
            address(newUsds), address(newSusds), address(this), suppliedInPSM, suppliedInPSM
        );
        debtTokenMigrator.migrateDebtToken({ newDebtTokenAmount: suppliedInPSM });

        // Check balances after migration
        assertEq(newSusds.maxWithdraw(address(psm)), suppliedInPSM, "New yield vault balance");
        assertEq(susds.maxWithdraw(address(psm)), 0, "Old yield balance mismatch");
        assertEq(usds.balanceOf(address(this)), suppliedInPSM, "Migrator received assets");

        // PSM checks
        assertEq(address(psm.asset()), address(newUsds), "PSM asset mismatch");
        assertEq(address(psm.yieldVault()), address(newSusds), "PSM yieldVault mismatch");
        assertEq(psm.to18DecimalsMultiplier(), 1, "PSM to18DecimalsMultiplier mismatch");
        assertEq(psm.suppliedByLP(), suppliedInPSM, "PSM suppliedByLP mismatch");

        // Vault strategy checks
        assertEq(
            newUsds.allowance(address(vaultStrategy), address(newSusds)),
            type(uint256).max,
            "New USDS allowance mismatch"
        );
        assertEq(address(vaultStrategy.asset()), address(newUsds), "Vault strategy asset mismatch");
        assertEq(address(vaultStrategy.yieldVault()), address(newSusds), "Vault strategy yield vault mismatch");

        // Debt token migrator checks
        assertEq(debtTokenMigrator.migrationTime(), 0, "Migration time must be 0");
        assertEq(debtTokenMigrator.slippage(), 0, "Slippage must be 0");

        // Vault checks
        assertEq(address(vault.debtToken()), address(newUsds), "Vault asset mismatch");
    }

    function test_debtTokenMigrator_migrateDebtToken_differentDecimals(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        _depositToVaultExt(user, assets);

        // Prepare for migration with smaller decimals first
        (MockERC20 newUsds, MockSusds newSusds) = _prepareForMigration(0, 10, true);

        uint256 suppliedInPSM = psm.suppliedByLP();
        uint256 expectedSuppliedInPSM = suppliedInPSM.ceilDiv(10 ** 8);
        // assertEq(suppliedInPSM, gohm.balanceFrom(amount);, "Supplied in PSM mismatch after migration");
        vm.expectEmit(true, true, true, true, address(debtTokenMigrator));
        emit DebtTokenMigrator.DebtTokenMigrated(
            address(newUsds), address(newSusds), address(this), suppliedInPSM, expectedSuppliedInPSM
        );
        debtTokenMigrator.migrateDebtToken({ newDebtTokenAmount: expectedSuppliedInPSM });

        // Check balances after migration
        assertEq(newSusds.maxWithdraw(address(psm)), expectedSuppliedInPSM, "New yield vault balance");
        assertEq(susds.maxWithdraw(address(psm)), 0, "Old yield balance mismatch");
        assertEq(usds.balanceOf(address(this)), suppliedInPSM, "Migrator received assets");
        assertEq(psm.suppliedByLP(), expectedSuppliedInPSM, "Supplied in PSM mismatch after migration");

        // Migrate token to greater decimals
        (newUsds, newSusds) = _prepareForMigration(0, 18, true);

        uint256 suppliedInPSM2 = psm.suppliedByLP();
        uint256 expectedSuppliedInPSM2 = suppliedInPSM2 * 1e8;

        emit DebtTokenMigrator.DebtTokenMigrated(
            address(newUsds), address(newSusds), address(this), suppliedInPSM2, expectedSuppliedInPSM2
        );
        debtTokenMigrator.migrateDebtToken({ newDebtTokenAmount: expectedSuppliedInPSM2 });

        assertEq(newSusds.maxWithdraw(address(psm)), expectedSuppliedInPSM2, "New yield vault balance");
        assertEq(susds.maxWithdraw(address(psm)), 0, "Old yield balance mismatch");
        assertEq(usds.balanceOf(address(this)), suppliedInPSM, "Migrator received assets");
        assertEq(psm.suppliedByLP(), expectedSuppliedInPSM2, "Supplied in PSM mismatch after migration");
        assertApproxEqAbs(expectedSuppliedInPSM2, suppliedInPSM, 1e10);
    }

    function test_debtTokenMigrator_migrateDebtToken_checkSlippageDecimals(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        _depositToVaultExt(user, assets);
        (, MockSusds newSusds) = _prepareForMigration(5000, 10, true); //  5%, -8 decimals
        uint256 suppliedInPSM = psm.suppliedByLP();

        uint256 expectedSuppliedInPSM = suppliedInPSM.ceilDiv(10 ** 8);
        uint256 fivePercent = (expectedSuppliedInPSM * 5) / 100;

        debtTokenMigrator.migrateDebtToken({ newDebtTokenAmount: expectedSuppliedInPSM - fivePercent });

        assertEq(newSusds.maxWithdraw(address(psm)), expectedSuppliedInPSM - fivePercent, "New yield vault balance");
        assertEq(susds.maxWithdraw(address(psm)), 0, "Old yield balance mismatch");
        assertEq(usds.balanceOf(address(this)), suppliedInPSM, "Migrator received assets");
        assertEq(psm.suppliedByLP(), expectedSuppliedInPSM, "Supplied in PSM mismatch after migration");
    }
}
