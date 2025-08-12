// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import { IERC20 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";
import { Math } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/Math.sol";
import { SafeCast } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/SafeCast.sol";

import { MockConverterToWadDebt } from "../mocks/MockConverterToWadDebt.sol";
import { MockCoolerTreasuryBorrower } from "../mocks/MockCoolerTreasuryBorrower.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockMonoCooler } from "../mocks/MockMonoCooler.sol";
import { MockSusds } from "../mocks/MockSusds.sol";

import { CallistoVaultTestForkBase } from "../test-common/CallistoVaultTestForkBase.sol";
import { DebtTokenMigrator, Ownable } from "src/external/DebtTokenMigrator.sol";
import { VaultStrategy } from "src/external/VaultStrategy.sol";
import { CallistoConstants } from "src/libraries/CallistoConstants.sol";

contract DebtTokenMigratorForkTests is CallistoVaultTestForkBase {
    using SafeCast for *;
    using Math for uint256;

    function setUp() public virtual override {
        vm.createSelectFork("mainnet", 23_016_996);
        super.setUp();
    }

    function test_debtTokenMigratorFork_initializePSMAddress_reverts() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        debtTokenMigrator.initializePSMAddress(address(1));

        vm.prank(admin);
        vm.expectRevert(DebtTokenMigrator.ZeroAddress.selector);
        debtTokenMigrator.initializePSMAddress(address(0));

        vm.prank(admin);
        vm.expectRevert(DebtTokenMigrator.AlreadyInitialized.selector);
        debtTokenMigrator.initializePSMAddress(address(psm));
    }

    function test_debtTokenMigratorFork_setMigration_success() external {
        uint256 migrationTime = block.timestamp + 86_400;
        uint256 slippage = 1000;
        MockERC20 newUsds = new MockERC20("NEW USDS", "NEW USDS", 18);
        MockSusds newSusds = new MockSusds(IERC20(address(newUsds)));

        // Create a mock cooler with the new debt token to simulate future migration scenario
        MockCoolerTreasuryBorrower treasuryBorrower = new MockCoolerTreasuryBorrower(address(newUsds));
        MockMonoCooler mockCooler = new MockMonoCooler(GOHM, address(newUsds), 1e18, address(treasuryBorrower));

        // Create a new migrator that uses the mock cooler (simulates future state)
        DebtTokenMigrator testMigrator = new DebtTokenMigrator(admin, address(mockCooler));
        vm.prank(admin);
        testMigrator.initializePSMAddress(address(psm));

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(testMigrator));
        emit DebtTokenMigrator.MigrationSet(
            address(newUsds), address(newSusds), address(converterToWadDebt), migrationTime, slippage
        );
        testMigrator.setMigration(migrationTime, slippage, address(newSusds), address(converterToWadDebt));

        assertEq(address(testMigrator.newYieldVault()), address(newSusds), "New yield vault address mismatch");
        assertEq(address(testMigrator.newDebtToken()), address(newUsds), "New debt token address mismatch");
        assertEq(
            address(testMigrator.newConverterToWadDebt()),
            address(converterToWadDebt),
            "New converter to wad debt address mismatch"
        );
        assertEq(testMigrator.migrationTime(), migrationTime, "Migration time mismatch");
        assertEq(testMigrator.slippage(), slippage, "Slippage mismatch");
    }

    function test_debtTokenMigratorFork_setMigration_reverts() external {
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

        // Test NewDebtTokenExpected - the current setup has USDS as both cooler debt token and vault strategy asset
        vm.expectRevert(DebtTokenMigrator.NewDebtTokenExpected.selector);
        debtTokenMigrator.setMigration(migrationTime, slippage, address(SUSDS), address(converterToWadDebt));

        vm.stopPrank();

        // Test YieldVaultHasAnotherAsset - create a yield vault with wrong underlying asset
        // The scenario: cooler returns newUsds, but wrongSusds has a different underlying (old USDS)
        MockSusds wrongSusds = new MockSusds(IERC20(address(USDS))); // susds with old USDS underlying
        MockCoolerTreasuryBorrower treasuryBorrower = new MockCoolerTreasuryBorrower(address(newUsds)); // cooler uses
            // new USDS
        MockMonoCooler mockCooler = new MockMonoCooler(GOHM, address(newUsds), 1e18, address(treasuryBorrower));
        DebtTokenMigrator testMigrator = new DebtTokenMigrator(admin, address(mockCooler));
        vm.prank(admin);
        testMigrator.initializePSMAddress(address(psm));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                DebtTokenMigrator.YieldVaultHasAnotherAsset.selector, address(USDS), address(newUsds)
            )
        );
        testMigrator.setMigration(migrationTime, slippage, address(wrongSusds), address(converterToWadDebt));
    }

    function test_debtTokenMigratorFork_migrateDebtToken_tooSoonCheck() external {
        // Create a migrator with a future migration time
        MockERC20 newUsds = new MockERC20("NEW USDS", "NEW USDS", 18);
        MockSusds newSusds = new MockSusds(IERC20(address(newUsds)));
        MockCoolerTreasuryBorrower treasuryBorrower = new MockCoolerTreasuryBorrower(address(newUsds));
        MockMonoCooler mockCooler = new MockMonoCooler(GOHM, address(newUsds), 1e18, address(treasuryBorrower));
        DebtTokenMigrator testMigrator = new DebtTokenMigrator(admin, address(mockCooler));

        vm.prank(admin);
        testMigrator.initializePSMAddress(address(psm));

        // Test before any migration is set
        vm.expectRevert(DebtTokenMigrator.TooSoon.selector);
        testMigrator.migrateDebtToken({ newDebtTokenAmount: CallistoConstants.MIN_OHM_DEPOSIT_BOUND });

        // Set migration for future time
        uint256 futureTime = block.timestamp + 86_400;
        vm.prank(admin);
        testMigrator.setMigration(futureTime, 0, address(newSusds), address(converterToWadDebt));

        // Test before migration time
        vm.expectRevert(DebtTokenMigrator.TooSoon.selector);
        testMigrator.migrateDebtToken({ newDebtTokenAmount: CallistoConstants.MIN_OHM_DEPOSIT_BOUND });
    }

    function test_debtTokenMigratorFork_migrateDebtToken_slippageExceeded() external {
        // Set up a deposit in the original vault to have some assets to migrate
        _depositToVaultFork(user, vault.minDeposit());

        // Create migration setup
        MockERC20 newUsds = new MockERC20("NEW USDS", "NEW USDS", 18);
        MockSusds newSusds = new MockSusds(IERC20(address(newUsds)));
        MockCoolerTreasuryBorrower treasuryBorrower = new MockCoolerTreasuryBorrower(address(newUsds));
        MockMonoCooler mockCooler = new MockMonoCooler(GOHM, address(newUsds), 1e18, address(treasuryBorrower));
        DebtTokenMigrator testMigrator = new DebtTokenMigrator(admin, address(mockCooler));

        vm.prank(admin);
        testMigrator.initializePSMAddress(address(psm));

        uint256 migrationTime = block.timestamp + 86_400;
        vm.prank(admin);
        testMigrator.setMigration(migrationTime, 0, address(newSusds), address(converterToWadDebt)); // 0% slippage

        vm.warp(migrationTime + 1);

        // Get the actual amount that will be used in slippage calculation
        // This mirrors the logic in migrateDebtToken function lines 170-174
        address psmAddr = address(psm);
        uint256 debtTokenAmount = SUSDS.maxWithdraw(psmAddr);

        // Test slippage exceeded with 0% allowed slippage
        if (debtTokenAmount > 1) {
            vm.expectRevert(abi.encodeWithSelector(DebtTokenMigrator.SlippageExceeded.selector, 1, 0));
            testMigrator.migrateDebtToken({ newDebtTokenAmount: debtTokenAmount - 1 });
        }

        if (debtTokenAmount > 1) {
            vm.expectRevert(abi.encodeWithSelector(DebtTokenMigrator.SlippageExceeded.selector, debtTokenAmount - 1, 0));
            testMigrator.migrateDebtToken({ newDebtTokenAmount: 1 });
        }
    }

    function test_debtTokenMigratorFork_migrateDebtToken_differentDecimals() external {
        // Set up a deposit to have assets to migrate
        _depositToVaultFork(user, vault.minDeposit());

        // Test with 10-decimal token (8 decimals less than standard 18)
        MockERC20 newUsds = new MockERC20("NEW USDS", "NEW USDS", 10);
        MockSusds newSusds = new MockSusds(IERC20(address(newUsds)));
        MockConverterToWadDebt _converterToWadDebt = new MockConverterToWadDebt(10);

        // Mock the cooler's debt token to return the new token (simulating future state)
        vm.mockCall(address(COOLER), abi.encodeWithSignature("debtToken()"), abi.encode(address(newUsds)));

        // Also need to mock the treasuryBorrower's debtToken call
        address treasuryBorrower = address(COOLER.treasuryBorrower());
        vm.mockCall(treasuryBorrower, abi.encodeWithSignature("debtToken()"), abi.encode(address(newUsds)));

        uint256 migrationTime = block.timestamp + 86_400;
        vm.prank(admin);
        debtTokenMigrator.setMigration(migrationTime, 0, address(newSusds), address(_converterToWadDebt));

        // Set the migrator in PSM and VaultStrategy to allow migration
        vm.startPrank(admin);
        psm.setDebtTokenMigrator(address(debtTokenMigrator));
        VaultStrategy(psm.liquidityProvider()).setDebtTokenMigrator(address(debtTokenMigrator));
        vault.setDebtTokenMigrator(address(debtTokenMigrator));
        vm.stopPrank();

        vm.warp(migrationTime + 1);

        // Get the actual debt token amount that will be used in the migration
        // This mirrors the logic in migrateDebtToken function lines 170-174
        address psmAddr = address(psm);
        uint256 debtTokenAmount = SUSDS.maxWithdraw(psmAddr);

        // Calculate expected conversion from 18 decimals (current USDS) to 10 decimals (new token)
        // This mirrors the logic in migrateDebtToken function lines 185-201
        uint8 fromDecimals = USDS.decimals(); // Current debt token (18 decimals)
        uint8 toDecimals = 10; // New debt token decimals
        uint256 expectedNewAmount;
        if (fromDecimals > toDecimals) {
            uint256 precisionDiff = 10 ** uint256(fromDecimals - toDecimals);
            expectedNewAmount = debtTokenAmount.ceilDiv(precisionDiff);
        } else {
            expectedNewAmount = debtTokenAmount; // Should not happen in this test
        }

        newUsds.mint(address(this), expectedNewAmount);
        newUsds.approve(address(debtTokenMigrator), expectedNewAmount);

        // Verify the migration executes with proper decimal conversion
        vm.expectEmit(true, true, true, true, address(debtTokenMigrator));
        emit DebtTokenMigrator.DebtTokenMigrated(
            address(newUsds), address(newSusds), address(this), debtTokenAmount, expectedNewAmount
        );
        debtTokenMigrator.migrateDebtToken({ newDebtTokenAmount: expectedNewAmount });

        // Verify migration completed
        assertEq(debtTokenMigrator.migrationTime(), 0, "Migration time should be reset");
        assertEq(debtTokenMigrator.slippage(), 0, "Slippage should be reset");
    }

    /// Helper function for fork-specific deposits
    function _depositToVaultFork(address _user, uint256 assets) internal {
        _ohmMint(_user, assets);

        vm.startPrank(_user);
        ohm.approve(address(vault), assets);
        vault.deposit(assets, _user);
        vm.stopPrank();

        // Execute to process the deposit
        vm.prank(heart);
        vault.execute();
    }
}
