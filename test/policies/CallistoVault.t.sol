// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import { ConverterToWadDebt } from "../../src/external/ConverterToWadDebt.sol";
import { CommonRoles } from "../../src/libraries/CommonRoles.sol";

import { MockCoolerTreasuryBorrower } from "../mocks/MockCoolerTreasuryBorrower.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IDLGTEv1, MockMonoCooler } from "../mocks/MockMonoCooler.sol";
import { MockSwapper } from "../mocks/MockSwapper.sol";
import { CallistoVaultTestBase } from "../test-common/CallistoVaultTestBase.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { ICallistoVault } from "src/interfaces/ICallistoVault.sol";
import { CallistoConstants } from "src/libraries/CallistoConstants.sol";

contract CallistoVaultRestrictedFuncTests is CallistoVaultTestBase {
    using SafeCast for *;

    function test_callistoVault_setMinDeposit() external {
        uint256 minDeposit = CallistoConstants.MIN_OHM_DEPOSIT_BOUND;
        uint256 tooSmallDeposit = CallistoConstants.MIN_OHM_DEPOSIT_BOUND - 1;

        // Test unauthorized access
        vm.expectRevert();
        vault.setMinDeposit(minDeposit);

        // Test value below minimum bound
        err = abi.encodeWithSelector(
            ICallistoVault.AmountLessThanMinDeposit.selector, tooSmallDeposit, CallistoConstants.MIN_OHM_DEPOSIT_BOUND
        );
        vm.prank(admin);
        vm.expectRevert(err);
        vault.setMinDeposit(tooSmallDeposit);

        // Test valid minimum deposit
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.MinDepositSet(minDeposit);
        vault.setMinDeposit(minDeposit);
        assertEq(vault.minDeposit(), minDeposit);
    }

    function test_callistoVault_setOHMToGOHMMode() external {
        MockSwapper swapper = new MockSwapper(ohm, gohm);
        assertEq(abi.encode(vault.ohmToGOHMMode()), abi.encode(ICallistoVault.OHMToGOHMMode.ZeroWarmup));
        // 1. revert not permission
        vm.expectRevert();
        vault.setSwapMode(address(swapper));

        // 2. revert same mode
        vm.prank(admin);
        vm.expectRevert(ICallistoVault.OHMToGOHMModeUnchanged.selector);
        vault.setZeroWarmupMode();

        // 3. revert warmupPeriod = 0
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICallistoVault.InvalidWarmupPeriod.selector, 0));
        vault.setSwapMode(address(swapper));

        // 4. warmupPeriod > 0
        staking.setWarmupPeriod(1);
        vm.prank(admin);

        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.OHMExchangeModeSet(ICallistoVault.OHMToGOHMMode.Swap, address(swapper));
        vault.setSwapMode(address(swapper));

        assertEq(abi.encode(vault.ohmToGOHMMode()), abi.encode(ICallistoVault.OHMToGOHMMode.Swap));

        // 5. return  ZeroWarmup
        staking.setWarmupPeriod(0);
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.OHMExchangeModeSet(ICallistoVault.OHMToGOHMMode.ZeroWarmup, address(0));
        vault.setZeroWarmupMode();

        assertEq(abi.encode(vault.ohmToGOHMMode()), abi.encode(ICallistoVault.OHMToGOHMMode.ZeroWarmup));
    }

    function test_callistoVault_setZeroWarmupMode_pendingWarmupStakingReverts() external {
        uint256 assets = vault.minDeposit();
        ohm.mint(user, assets);
        _depositToVault(user, assets);

        // Set warmup period and switch to ActiveWarmup mode
        staking.setWarmupPeriod(1);
        vm.prank(admin);
        vault.setActiveWarmupMode();

        // Process deposits to create pending warmup staking
        vm.prank(multisig);
        vault.processPendingDeposits(assets, new bytes[](0));

        // Verify pending warmup staking exists
        assertEq(vault.pendingOHMWarmupStaking(), assets);

        // Attempt to switch to ZeroWarmup mode should revert due to pending warmup staking
        staking.setWarmupPeriod(0);
        vm.prank(admin);
        vm.expectRevert(ICallistoVault.PendingWarmupStakingExists.selector);
        vault.setZeroWarmupMode();
    }

    function test_callistoVault_setSwapMode_pendingWarmupStakingReverts() external {
        uint256 assets = vault.minDeposit();
        ohm.mint(user, assets);
        _depositToVault(user, assets);

        MockSwapper swapper = new MockSwapper(ohm, gohm);

        // Set warmup period and switch to ActiveWarmup mode
        staking.setWarmupPeriod(1);
        vm.prank(admin);
        vault.setActiveWarmupMode();

        // Process deposits to create pending warmup staking
        vm.prank(multisig);
        vault.processPendingDeposits(assets, new bytes[](0));

        // Verify pending warmup staking exists
        assertEq(vault.pendingOHMWarmupStaking(), assets);

        // Attempt to switch to Swap mode should revert due to pending warmup staking
        vm.prank(admin);
        vm.expectRevert(ICallistoVault.PendingWarmupStakingExists.selector);
        vault.setSwapMode(address(swapper));
    }

    function test_callistoVault_setZeroWarmupMode_successAfterCancelingStake() external {
        uint256 assets = vault.minDeposit();
        ohm.mint(user, assets);
        _depositToVault(user, assets);

        // Set warmup period and switch to ActiveWarmup mode
        staking.setWarmupPeriod(1);
        vm.prank(admin);
        vault.setActiveWarmupMode();

        // Process deposits to create pending warmup staking
        vm.prank(multisig);
        vault.processPendingDeposits(assets, new bytes[](0));

        // Verify pending warmup staking exists
        assertEq(vault.pendingOHMWarmupStaking(), assets);

        // Cancel the stake to clear pending warmup staking
        vm.prank(admin);
        vault.cancelOHMStake();

        // Verify pending warmup staking is cleared
        assertEq(vault.pendingOHMWarmupStaking(), 0);

        // Now switching to ZeroWarmup mode should succeed
        staking.setWarmupPeriod(0);
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.OHMExchangeModeSet(ICallistoVault.OHMToGOHMMode.ZeroWarmup, address(0));
        vault.setZeroWarmupMode();

        assertEq(abi.encode(vault.ohmToGOHMMode()), abi.encode(ICallistoVault.OHMToGOHMMode.ZeroWarmup));
    }

    function test_callistoVault_setSwapMode_successAfterCancelingStake() external {
        uint256 assets = vault.minDeposit();
        ohm.mint(user, assets);
        _depositToVault(user, assets);

        MockSwapper swapper = new MockSwapper(ohm, gohm);

        // Set warmup period and switch to ActiveWarmup mode
        staking.setWarmupPeriod(1);
        vm.prank(admin);
        vault.setActiveWarmupMode();

        // Process deposits to create pending warmup staking
        vm.prank(multisig);
        vault.processPendingDeposits(assets, new bytes[](0));

        // Verify pending warmup staking exists
        assertEq(vault.pendingOHMWarmupStaking(), assets);

        // Cancel the stake to clear pending warmup staking
        vm.prank(admin);
        vault.cancelOHMStake();

        // Verify pending warmup staking is cleared
        assertEq(vault.pendingOHMWarmupStaking(), 0);

        // Now switching to Swap mode should succeed
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.OHMExchangeModeSet(ICallistoVault.OHMToGOHMMode.Swap, address(swapper));
        vault.setSwapMode(address(swapper));

        assertEq(abi.encode(vault.ohmToGOHMMode()), abi.encode(ICallistoVault.OHMToGOHMMode.Swap));
    }

    function test_callistoVault_setSwapMode_zeroWarmupPeriodNotAllowed() external {
        MockSwapper swapper = new MockSwapper(ohm, gohm);

        // Ensure warmup period is 0 (default state)
        assertEq(staking.warmupPeriod(), 0);

        // Attempting to switch to Swap mode with zero warmup period should revert
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICallistoVault.InvalidWarmupPeriod.selector, 0));
        vault.setSwapMode(address(swapper));
    }

    function test_callistoVault_setSwapMode_duplicateSettingsReverts() external {
        MockSwapper swapper = new MockSwapper(ohm, gohm);

        // First, set up the conditions to allow Swap mode
        staking.setWarmupPeriod(1);
        vm.prank(admin);
        vault.setSwapMode(address(swapper));

        // Verify mode is set
        assertEq(abi.encode(vault.ohmToGOHMMode()), abi.encode(ICallistoVault.OHMToGOHMMode.Swap));
        assertEq(address(vault.ohmSwapper()), address(swapper));

        // Now try to set the same mode with the same swapper - should revert
        vm.prank(admin);
        vm.expectRevert(ICallistoVault.OHMToGOHMModeUnchanged.selector);
        vault.setSwapMode(address(swapper));
    }

    function test_callistoVault_invalidActiveWarmup_bothScenarios() external {
        MockSwapper swapper = new MockSwapper(ohm, gohm);

        // Test 1: Zero warmup period prevents Swap mode (requires non-zero)
        assertEq(staking.warmupPeriod(), 0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICallistoVault.InvalidWarmupPeriod.selector, 0));
        vault.setSwapMode(address(swapper));

        // Test 2: Non-zero warmup period prevents ZeroWarmup mode (requires zero)
        // First set warmup period and switch to ActiveWarmup mode
        staking.setWarmupPeriod(2);
        vm.prank(admin);
        vault.setActiveWarmupMode();

        // Now try to switch back to ZeroWarmup mode - should fail due to non-zero warmup period
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICallistoVault.InvalidWarmupPeriod.selector, 2));
        vault.setZeroWarmupMode();
    }

    function test_callistoVault_pauses() external {
        vm.expectRevert();
        vault.setDepositsPause(true);

        vm.startPrank(admin);
        // 1. deposit paused
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.DepositPauseStatusChanged(true);
        vault.setDepositsPause(true);
        assertEq(vault.depositPaused(), true);
        assertEq(vault.withdrawalPaused(), false);

        vm.expectRevert(ICallistoVault.PauseStatusUnchanged.selector);
        vault.setDepositsPause(true);

        // 2. deposit unpaused
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.DepositPauseStatusChanged(false);
        vault.setDepositsPause(false);
        assertEq(vault.depositPaused(), false);
        assertEq(vault.withdrawalPaused(), false);

        vm.expectRevert(ICallistoVault.PauseStatusUnchanged.selector);
        vault.setDepositsPause(false);

        // 3. withdraw paused
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.WithdrawalPauseStatusChanged(true);
        vault.setWithdrawalsPause(true);
        assertEq(vault.depositPaused(), false);
        assertEq(vault.withdrawalPaused(), true);

        vm.expectRevert(ICallistoVault.PauseStatusUnchanged.selector);
        vault.setWithdrawalsPause(true);

        // 4. withdraw unpaused
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICallistoVault.WithdrawalPauseStatusChanged(false);
        vault.setWithdrawalsPause(false);
        assertEq(vault.depositPaused(), false);
        assertEq(vault.withdrawalPaused(), false);

        vm.expectRevert(ICallistoVault.PauseStatusUnchanged.selector);
        vault.setWithdrawalsPause(false);
        vm.stopPrank();
    }

    function test_callistoVault_transferUnexpectedTokens(uint256 assets, uint256 unexpectedAssets) external {
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);
        unexpectedAssets = bound(unexpectedAssets, vault.minDeposit(), MAX_DEPOSIT);
        ohm.mint(user, assets);
        address receiver = user2;
        _depositToVault(user, assets);

        ohm.mint(address(vault), unexpectedAssets);
        usds.mint(address(vault), unexpectedAssets);

        assertEq(ohm.balanceOf(address(vault)), assets + unexpectedAssets);

        vm.prank(admin);
        vault.sweepTokens(address(ohm), receiver, unexpectedAssets);

        assertEq(ohm.balanceOf(address(vault)), vault.pendingOHMDeposits(), "OHM = pendingOHMDeposits");
        assertEq(ohm.balanceOf(address(receiver)), unexpectedAssets);

        // check assets of other token (example usds)
        assertEq(usds.balanceOf(address(vault)), unexpectedAssets);

        vm.prank(admin);
        vault.sweepTokens(address(usds), receiver, unexpectedAssets);

        assertEq(usds.balanceOf(address(vault)), 0);
        assertEq(usds.balanceOf(address(receiver)), unexpectedAssets);
    }

    function test_callistoVault_sweepTokens_accessControl() external {
        address receiver = user2;
        uint256 amount = 1000e9;

        // Mint some tokens to the vault
        usds.mint(address(vault), amount);

        // Test unauthorized access - should revert
        vm.expectRevert(abi.encodeWithSelector(CommonRoles.Unauthorized.selector, address(this)));
        vault.sweepTokens(address(usds), receiver, amount);

        // Test with user (no admin/manager role) - should revert
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CommonRoles.Unauthorized.selector, user));
        vault.sweepTokens(address(usds), receiver, amount);

        // Test with admin - should work
        vm.prank(admin);
        vault.sweepTokens(address(usds), receiver, amount);
        assertEq(usds.balanceOf(receiver), amount);
    }

    function test_callistoVault_sweepTokens_zeroAmount() external {
        address receiver = user2;

        // Mint some tokens to the vault
        usds.mint(address(vault), 1000e9);

        // Test sweeping zero amount - should not transfer anything
        uint256 vaultBalanceBefore = usds.balanceOf(address(vault));
        uint256 receiverBalanceBefore = usds.balanceOf(receiver);

        vm.prank(admin);
        vault.sweepTokens(address(usds), receiver, 0);

        // Balances should remain unchanged
        assertEq(usds.balanceOf(address(vault)), vaultBalanceBefore);
        assertEq(usds.balanceOf(receiver), receiverBalanceBefore);
    }

    function test_callistoVault_sweepTokens_noBalance() external {
        address receiver = user2;
        uint256 amount = 1000e9;

        // Ensure vault has no USDS balance
        assertEq(usds.balanceOf(address(vault)), 0);

        // Attempting to sweep should fail (transfer would fail with insufficient balance)
        vm.prank(admin);
        vm.expectRevert();
        vault.sweepTokens(address(usds), receiver, amount);
    }

    function test_callistoVault_sweepTokens_excessiveAmount_OHM() external {
        uint256 assets = 1000e9;
        uint256 unexpectedAssets = 500e9;
        address receiver = user2;

        // Deposit to vault first
        ohm.mint(user, assets);
        _depositToVault(user, assets);

        // Add unexpected OHM tokens
        ohm.mint(address(vault), unexpectedAssets);

        uint256 totalVaultOHM = assets + unexpectedAssets;
        uint256 availableForSweep = totalVaultOHM - vault.pendingOHMDeposits();

        // Try to sweep more than available (should only sweep available amount)
        uint256 requestedAmount = availableForSweep + 100e9;

        vm.prank(admin);
        vault.sweepTokens(address(ohm), receiver, requestedAmount);

        // Should only transfer the available amount
        assertEq(ohm.balanceOf(receiver), availableForSweep);
        assertEq(ohm.balanceOf(address(vault)), vault.pendingOHMDeposits());
    }

    function test_callistoVault_sweepTokens_partialSweep_OHM() external {
        uint256 assets = 1000e9;
        uint256 unexpectedAssets = 500e9;
        uint256 partialAmount = 200e9;
        address receiver = user2;

        // Deposit to vault first
        ohm.mint(user, assets);
        _depositToVault(user, assets);

        // Add unexpected OHM tokens
        ohm.mint(address(vault), unexpectedAssets);

        uint256 vaultBalanceBefore = ohm.balanceOf(address(vault));

        // Sweep partial amount
        vm.prank(admin);
        vault.sweepTokens(address(ohm), receiver, partialAmount);

        // Check balances
        assertEq(ohm.balanceOf(receiver), partialAmount);
        assertEq(ohm.balanceOf(address(vault)), vaultBalanceBefore - partialAmount);
        assertEq(ohm.balanceOf(address(vault)), vault.pendingOHMDeposits() + (unexpectedAssets - partialAmount));
    }

    function test_callistoVault_sweepTokens_multipleDifferentTokens() external {
        uint256 amount1 = 1000e9;
        uint256 amount2 = 2000e18;
        address receiver = user2;

        // Create another mock token
        MockERC20 token2 = new MockERC20("Token2", "TK2", 18);

        // Mint tokens to vault
        usds.mint(address(vault), amount1);
        token2.mint(address(vault), amount2);

        // Sweep first token
        vm.prank(admin);
        vault.sweepTokens(address(usds), receiver, amount1);

        // Sweep second token
        vm.prank(admin);
        vault.sweepTokens(address(token2), receiver, amount2);

        // Check balances
        assertEq(usds.balanceOf(receiver), amount1);
        assertEq(token2.balanceOf(receiver), amount2);
        assertEq(usds.balanceOf(address(vault)), 0);
        assertEq(token2.balanceOf(address(vault)), 0);
    }

    function test_callistoVault_sweepTokens_differentReceivers() external {
        uint256 amount = 1000e9;
        address receiver1 = user;
        address receiver2 = user2;

        // Mint tokens to vault
        usds.mint(address(vault), amount * 2);

        // Sweep to first receiver
        vm.prank(admin);
        vault.sweepTokens(address(usds), receiver1, amount);

        // Sweep to second receiver
        vm.prank(admin);
        vault.sweepTokens(address(usds), receiver2, amount);

        // Check balances
        assertEq(usds.balanceOf(receiver1), amount);
        assertEq(usds.balanceOf(receiver2), amount);
        assertEq(usds.balanceOf(address(vault)), 0);
    }

    function test_callistoVault_applyDelegations() external {
        vm.expectRevert(abi.encodeWithSelector(CommonRoles.Unauthorized.selector, address(this)));
        vault.applyDelegations(new IDLGTEv1.DelegationRequest[](0));

        vm.mockCall(
            address(cooler), abi.encodeWithSelector(MockMonoCooler.applyDelegations.selector), abi.encode(123, 456, 789)
        );

        vm.expectRevert(abi.encodeWithSelector(CommonRoles.Unauthorized.selector, address(this)));
        vault.applyDelegations(new IDLGTEv1.DelegationRequest[](0));

        vm.prank(admin);
        (uint256 v1, uint256 v2, uint256 v3) = vault.applyDelegations(new IDLGTEv1.DelegationRequest[](0));
        assertEq(v1, 123);
        assertEq(v2, 456);
        assertEq(v3, 789);
    }

    function test_callistoVault_migrateDebtToken_simple() external {
        uint256 assets = vault.minDeposit();
        ohm.mint(user, assets);
        _depositToVault(user, assets);

        MockERC20 newToken = new MockERC20("New Debt Token", "NDT", 9);
        ConverterToWadDebt newConverterToWadDebt = new ConverterToWadDebt();

        // Change the debt token in the cooler to match what we're migrating to
        MockCoolerTreasuryBorrower newCoolerTreasuryBorrower = new MockCoolerTreasuryBorrower(address(newToken));
        cooler.setNewUsdsToken(address(newToken));
        cooler.setNewTreasuryBorrower(address(newCoolerTreasuryBorrower));

        assertEq(address(vault.debtToken()), address(usds));
        assertEq(address(vault.debtConverterToWad()), address(converterToWadDebt));

        // First test revert when migrator not set
        vm.expectRevert(abi.encodeWithSelector(ICallistoVault.OnlyDebtTokenMigrator.selector, address(0)));
        vault.migrateDebtToken(address(newToken), address(newConverterToWadDebt));

        // Set the migrator
        vm.prank(admin);
        vault.setDebtTokenMigrator(address(debtTokenMigrator));

        // check revert when not DebtTokenMigrator
        vm.expectRevert(
            abi.encodeWithSelector(ICallistoVault.OnlyDebtTokenMigrator.selector, address(debtTokenMigrator))
        );
        vault.migrateDebtToken(address(newToken), address(newConverterToWadDebt));

        // chec success when DebtTokenMigrator
        vm.prank(address(debtTokenMigrator));
        vault.migrateDebtToken(address(newToken), address(newConverterToWadDebt));

        assertEq(address(vault.debtToken()), address(newToken));
        assertEq(address(vault.debtConverterToWad()), address(newConverterToWadDebt));
        // Check that old debt token approval to strategy was set to 0
        assertEq(usds.allowance(address(vault), address(vaultStrategy)), 0);
        // Check that new debt token approval to strategy is set to max
        assertEq(newToken.allowance(address(vault), address(vaultStrategy)), type(uint256).max);
    }

    function test_callistoVault_migrateDebtToken(uint256 assets) external {
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);
        ohm.mint(user, assets);
        _depositToVault(user, assets);

        MockERC20 newToken = new MockERC20("New Debt Token", "NDT", 9);
        ConverterToWadDebt newConverterToWadDebt = new ConverterToWadDebt();

        // Change the debt token in the cooler to match what we're migrating to
        MockCoolerTreasuryBorrower newCoolerTreasuryBorrower = new MockCoolerTreasuryBorrower(address(newToken));
        cooler.setNewUsdsToken(address(newToken));
        cooler.setNewTreasuryBorrower(address(newCoolerTreasuryBorrower));

        assertEq(address(vault.debtToken()), address(usds));
        assertEq(address(vault.debtConverterToWad()), address(converterToWadDebt));

        // First test revert when migrator not set
        vm.expectRevert(abi.encodeWithSelector(ICallistoVault.OnlyDebtTokenMigrator.selector, address(0)));
        vault.migrateDebtToken(address(newToken), address(newConverterToWadDebt));

        // Set the migrator
        vm.prank(admin);
        vault.setDebtTokenMigrator(address(debtTokenMigrator));

        // check revert when not DebtTokenMigrator
        vm.expectRevert(
            abi.encodeWithSelector(ICallistoVault.OnlyDebtTokenMigrator.selector, address(debtTokenMigrator))
        );
        vault.migrateDebtToken(address(newToken), address(newConverterToWadDebt));

        // chec success when DebtTokenMigrator
        vm.prank(address(debtTokenMigrator));
        vault.migrateDebtToken(address(newToken), address(newConverterToWadDebt));

        assertEq(address(vault.debtToken()), address(newToken));
        assertEq(address(vault.debtConverterToWad()), address(newConverterToWadDebt));
        // Check that old debt token approval to strategy was set to 0
        assertEq(usds.allowance(address(vault), address(vaultStrategy)), 0);
        // Check that new debt token approval to strategy is set to max
        assertEq(newToken.allowance(address(vault), address(vaultStrategy)), type(uint256).max);
    }
}

contract CallistoVaultDepositTests is CallistoVaultTestBase {
    using SafeCast for *;

    function test_callistoVault_depositWithdrawOnPausedVault(uint256 assets) external {
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);

        ohm.mint(user, assets);
        _depositToVault(user, assets);

        // test deposit reverts on pause
        vm.prank(admin);
        vault.setDepositsPause(true);

        vm.prank(user);
        vm.expectRevert(ICallistoVault.DepositsPaused.selector);
        vault.deposit(assets, user);

        vm.prank(user);
        vm.expectRevert(ICallistoVault.DepositsPaused.selector);
        vault.mint(shares, user);

        vm.prank(admin);
        vault.setWithdrawalsPause(true);

        // test withdraw reverts on pause
        vm.prank(user);
        vm.expectRevert(ICallistoVault.WithdrawalsPaused.selector);
        vault.withdraw(assets, user, user);

        vm.prank(user);
        vm.expectRevert(ICallistoVault.WithdrawalsPaused.selector);
        vault.redeem(shares, user, user);
    }

    function test_callistoVault_depositReverts(uint256 badAmount) external {
        // 1. min deposits check - use vault.minDeposit() for dynamic testing
        uint256 currentMinDeposit = vault.minDeposit();
        badAmount = bound(badAmount, 0, currentMinDeposit - 1);

        err = abi.encodeWithSelector(ICallistoVault.AmountLessThanMinDeposit.selector, badAmount, currentMinDeposit);
        vm.expectRevert(err);
        vault.deposit(badAmount, address(1));
    }

    function test_callistoVault_deposit(uint256 assets) external {
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);
        ohm.mint(user, assets);

        vm.startPrank(user);
        ohm.approve(address(vault), assets);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Deposit(user, user, assets, shares);
        vault.deposit(assets, user);
        vm.stopPrank();

        assertEq(ohm.balanceOf(user), 0);
        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.pendingOHMDeposits(), assets);
    }

    function test_callistoVault_mint(uint256 assets) external {
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);

        ohm.mint(user, assets);

        vm.startPrank(user);
        ohm.approve(address(vault), assets);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Deposit(user, user, assets, shares);
        vault.mint(shares, user);
        vm.stopPrank();

        assertEq(ohm.balanceOf(user), 0);
        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.pendingOHMDeposits(), assets);
    }

    function test_callistoVault_processPendingDeposits_amountGreaterThanPendingOHMRevert(uint256 assets) external {
        MockSwapper swapper = new MockSwapper(ohm, gohm);
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);

        ohm.mint(user, assets);
        _depositToVault(user, assets);

        uint256 pendingOHM = vault.pendingOHMDeposits();
        assertEq(pendingOHM, assets);

        uint256 badPendingOHM = assets + 1;

        // processPendingDeposits skips if OHMToGOHMMode is ZeroWarmup
        staking.setWarmupPeriod(1);
        vm.startPrank(admin);
        vault.setSwapMode(address(swapper));

        vm.expectRevert(
            abi.encodeWithSelector(
                ICallistoVault.AmountGreaterThanPendingOHMDeposits.selector, badPendingOHM, pendingOHM
            )
        );

        vault.processPendingDeposits(badPendingOHM, new bytes[](0));
    }

    function test_callistoVault_execute_notAuthorizedRevert() external {
        vm.expectRevert();
        vault.execute();
    }

    function test_callistoVault_execute_warmupPeriodError(uint256 assets) external {
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);

        ohm.mint(user, assets);
        _depositToVault(user, assets);
        _prepareCoolerAmounts(assets);

        staking.setWarmupPeriod(1);

        vm.prank(heart);
        vm.expectRevert(abi.encodeWithSelector(ICallistoVault.InvalidWarmupPeriod.selector, 1));
        vault.execute();
    }
}

contract CallistoVaultWithdrawTests is CallistoVaultTestBase {
    using SafeCast for *;
    using SafeERC20 for IERC20;

    function test_callistoVault_withdrawSimple(uint256 assets) external {
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);

        ohm.mint(user, assets);
        _depositToVault(user, assets);

        // 2. withdraw OHM
        vm.startPrank(user);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(user, user, user, assets, shares);
        vault.withdraw(assets, user, user);
        vm.stopPrank();

        assertEq(ohm.balanceOf(user), assets);
        assertEq(vault.balanceOf(user), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_callistoVault_redeemSimple(uint256 assets) external {
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);

        ohm.mint(user, assets);
        _depositToVault(user, assets);

        // 2. redeem OHM
        vm.startPrank(user);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(user, user, user, assets, shares);
        vault.redeem(shares, user, user);
        vm.stopPrank();

        assertEq(ohm.balanceOf(user), assets);
        assertEq(vault.balanceOf(user), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_callistoVault_withdrawReverts(uint256 assets) external {
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);

        ohm.mint(user, assets);
        uint256 shares = _depositToVault(user, assets);

        uint256 maxWithdraw = vault.maxWithdraw(user);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, shares)
        );
        vault.withdraw(maxWithdraw, user, user);

        // 1. check min amount of withdraw
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, user, maxWithdraw + 1, maxWithdraw)
        );
        vm.prank(user);
        vault.withdraw(maxWithdraw + 1, user, user);

        vm.expectRevert(ICallistoVault.ZeroValue.selector);
        vm.prank(user);
        vault.withdraw(0, user, user);

        // 2. paused checks
        vm.prank(admin);
        vault.setWithdrawalsPause(true);

        vm.expectRevert(ICallistoVault.WithdrawalsPaused.selector);
        vm.prank(user);
        vault.withdraw(assets, user, user);
    }

    function test_callistoVault_redeemReverts(uint256 assets) external {
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);

        ohm.mint(user, assets);
        _depositToVault(user, assets);

        uint256 maxRedeem = vault.maxRedeem(user);

        vm.expectRevert();
        vault.redeem(maxRedeem, user, user);

        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, user, maxRedeem + 1, maxRedeem)
        );
        vm.prank(user);
        vault.redeem(maxRedeem + 1, user, user);

        vm.expectRevert(ICallistoVault.ZeroOHM.selector);
        vm.prank(user);
        vault.redeem(0, user, user);

        // 2. paused checks
        vm.prank(admin);
        vault.setWithdrawalsPause(true);

        vm.expectRevert(ICallistoVault.WithdrawalsPaused.selector);
        vm.prank(user);
        vault.redeem(shares, user, user);
    }

    /**
     * Withdrawal when the vault’s Cooler V2 loan has been liquidated
     */
    function _prepareWithdrawCoolerV2LoanHasBeenLiquidated(uint256 assets, uint256 partialAssets) internal {
        ohm.mint(user, assets);

        uint128 borrowAmount = _gohmToUsds(gohm.balanceTo(assets)).toUint128();
        cooler.setBorrowingAmount(borrowAmount);

        _depositToVault(user, assets);
        vm.prank(heart);
        vault.execute();

        assertEq(vault.pendingOHMDeposits(), 0);
        assertEq(susds.balanceOf(address(psm)), borrowAmount);
        assertEq(cooler.accountCollateral(address(vault)), gohm.balanceTo(assets));

        // 1. Remove vault liquidity from cooler (aka liquidation)
        _liquidateVaultPositionInCooler();

        assertEq(cooler.accountCollateral(address(vault)), 0);
        // 2. mint extra OHM to vault
        ohm.mint(address(vault), partialAssets);
    }

    /**
     * Final withdrawal edge case due to rounding error in gOHM
     */
    function _prepareWithdrawalEdgeCaseDueToRounding(uint256 assets, uint256 partialAssets) internal {
        ohm.mint(user, assets);

        uint128 borrowAmount = _prepareCoolerAmounts(assets);
        _depositToVault(user, assets);

        vm.prank(heart);
        vault.execute();

        assertEq(vault.pendingOHMDeposits(), 0);
        assertEq(susds.balanceOf(address(psm)), borrowAmount);
        assertEq(cooler.accountCollateral(address(vault)), gohm.balanceTo(assets));

        // Remove partial gohm from cooler
        vm.prank(address(vault));
        cooler.withdrawCollateral(
            gohm.balanceTo(partialAssets).toUint128(),
            address(vault),
            address(vault),
            new IDLGTEv1.DelegationRequest[](0)
        );

        assertEq(cooler.accountCollateral(address(vault)), gohm.balanceTo(assets - partialAssets));
    }

    /**
     * PSM has insufficient USDS to repay Cooler debt
     */
    function _prepareInsufficientUsdsInPSM(uint256 assets) internal returns (uint256) {
        ohm.mint(user, assets);

        uint128 borrowAmount = _prepareCoolerAmounts(assets);
        _depositToVault(user, assets);

        vm.prank(heart);
        vault.execute();

        assertEq(susds.balanceOf(address(psm)), borrowAmount);

        uint256 insufficientUsds = borrowAmount / 5; // example lacks 20% of usds

        // decrease usds from psm
        (uint256 collarAmount,) = psm.calcCOLLARIn(insufficientUsds);
        _buyUSDSfromPSM(collarAmount);
        return insufficientUsds;
    }

    function test_callistoVault_cancelOHMStake(uint256 assets) external {
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);
        ohm.mint(user, assets);
        _depositToVault(user, assets);

        vm.expectRevert(abi.encodeWithSelector(CommonRoles.Unauthorized.selector, address(this)));
        vault.cancelOHMStake();

        vm.prank(multisig);
        vm.expectRevert(ICallistoVault.ZeroValue.selector);
        vault.cancelOHMStake();

        // set ActiveWarmup mode
        staking.setWarmupPeriod(1);
        vm.startPrank(admin);
        vault.setActiveWarmupMode();
        vm.stopPrank();

        vm.prank(heart);
        vault.execute();

        assertEq(vault.pendingOHMWarmupStaking(), 0, "pendingOHMWarmUpStaking OHM == 0 after execute");

        vault.processPendingDeposits(assets, new bytes[](0));

        assertEq(vault.pendingOHMWarmupStaking(), assets, "staked OHM > 0 after processPendingDeposits");
        assertEq(vault.pendingOHMDeposits(), 0);

        vm.prank(multisig);
        vault.cancelOHMStake();

        assertEq(vault.pendingOHMWarmupStaking(), 0);
        assertEq(vault.pendingOHMDeposits(), assets);
        assertEq(ohm.balanceOf(address(vault)), assets);
    }

    function _prepareForReimbursement(uint256 amount) internal {
        // remove USDS from PSM
        _buyUSDSfromPSM(amount);
        usds.mint(address(this), amount);
        usds.approve(address(vault), amount);
    }

    function test_callistoVault_MultipleUsers_MintRedeem_Security() external {
        uint256 minDeposit = vault.minDeposit();
        uint256 sharesEnding = 1e9 - 1; // 1 OHM is 1e9, so we want to get max cOHM to mint but be less than
        uint256 assetsEnding = 1;
        uint256 shareAmount = minDeposit * 1e9; // x shares (18 decimals)
        uint256 shareAmountWithEnding = minDeposit * 1e9 + sharesEnding; // x shares (18 decimals)
        uint256 assetAmountWithEnding = minDeposit + assetsEnding; // x assets (9 decimals) - 1:1 ratio
        uint256 userCount = 100;
        address[] memory users = new address[](userCount);

        // Create count users and prepare OHM for each
        for (uint256 i = 0; i < userCount; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", vm.toString(i))));
            ohm.mint(users[i], assetAmountWithEnding);
        }

        // Store initial vault OHM balance and total supply
        uint256 initialVaultOHMBalance = ohm.balanceOf(address(vault));

        // Each user mints 1e6 shares
        for (uint256 i = 0; i < userCount; i++) {
            vm.startPrank(users[i]);
            ohm.approve(address(vault), assetAmountWithEnding);

            // Call mint() function to mint shareAmount shares
            uint256 actualAssets = vault.mint(shareAmount + sharesEnding, users[i]);

            // Verify mint worked correctly
            assertEq(actualAssets, assetAmountWithEnding, "Assets should equal expected amount");
            assertEq(vault.balanceOf(users[i]), shareAmountWithEnding, "User should have correct share balance");
            assertEq(ohm.balanceOf(users[i]), 0, "User should have no OHM left");
            vm.stopPrank();
        }

        // Verify total state after all mints
        uint256 totalSharesExpected = shareAmountWithEnding * userCount;
        uint256 totalAssetsExpected = assetAmountWithEnding * userCount;

        assertEq(vault.totalSupply(), totalSharesExpected, "Total supply should match expected");
        assertEq(vault.totalAssets(), totalAssetsExpected, "Total assets should match expected");
        assertEq(vault.pendingOHMDeposits(), totalAssetsExpected, "All OHM should be pending");

        // Each user redeems all their shares
        for (uint256 i = 0; i < userCount; i++) {
            vm.startPrank(users[i]);

            // Verify user has expected shares before redemption
            assertEq(vault.balanceOf(users[i]), shareAmount + sharesEnding, "User should have shares before redemption");

            // Call redeem() function to redeem all shares
            uint256 assetsReceived = vault.redeem(shareAmount, users[i], users[i]);

            // Verify redemption worked correctly
            assertEq(assetsReceived, assetAmountWithEnding - 1, "Should receive expected asset amount");
            assertEq(vault.balanceOf(users[i]), sharesEnding, "User should have 0 shares after redemption");
            assertEq(
                ohm.balanceOf(users[i]),
                assetAmountWithEnding - 1,
                "User should have received OHM back without 1 wei slippage"
            );
            vm.stopPrank();
        }

        // Final security assertions

        // 1. All users should have 0 share balance
        for (uint256 i = 0; i < userCount; i++) {
            assertEq(vault.balanceOf(users[i]), sharesEnding, "All users should have 0 shares");
        }

        // 2. Vault should have same total supply as initially (all shares burned)
        assertEq(vault.totalSupply(), sharesEnding * userCount, "Total supply should return to initial state");

        // 3. Total assets should return to initial state
        assertEq(
            vault.totalAssets(),
            assetsEnding * userCount,
            "Total assets should still keep ohm ending after all redemptions"
        );

        // 4. Verify that vault's OHM balance is protected - it should not decrease beyond what was withdrawn
        uint256 vaultOHMAfterRedemptions = ohm.balanceOf(address(vault));
        uint256 expectedVaultOHMBalance = initialVaultOHMBalance;
        assertEq(
            vaultOHMAfterRedemptions,
            expectedVaultOHMBalance + assetsEnding * userCount,
            "Vault OHM balance should be protected"
        );

        // 5. Verify that no OHM was "stolen" - total OHM in system should be conserved
        uint256 totalOHMInUsers = 0;
        for (uint256 i = 0; i < userCount; i++) {
            totalOHMInUsers += ohm.balanceOf(users[i]);
        }

        uint256 expectedTotalOHM = totalAssetsExpected - assetsEnding * userCount; // All users should get back their
            // deposited OHM
        assertEq(totalOHMInUsers, expectedTotalOHM, "Total OHM should be conserved - no theft possible");

        // 6. Verify vault state is clean
        assertEq(vault.pendingOHMDeposits(), assetsEnding * userCount, "No pending deposits should remain");

        // 8. Verify that attempting to redeem non-existent shares fails
        vm.expectRevert();
        vm.prank(users[0]);
        vault.redeem(1, users[0], users[0]);
    }

    function test_callistoVault_AliceTransferToBob_MintRedeem_Security(uint256 sharesEnding) external {
        sharesEnding = bound(sharesEnding, 1, 1e9 - 1);
        uint256 assetsEnding = 1;
        uint256 shareAmount = 1.1e6 * 1e18 + sharesEnding; // 1e6 shares (18 decimals)
        uint256 assetAmount = 1.1e6 * 1e9 + assetsEnding; // 1e6 assets (9 decimals) - 1:1 ratio
        uint256 halfShares = shareAmount / 2;
        uint256 halfAssets = assetAmount / 2;

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        // Setup: Give Alice the OHM tokens enough to cover shares including sharesEnding
        ohm.mint(alice, assetAmount);

        // Store initial vault state

        // Alice mints 1e6 shares
        vm.startPrank(alice);
        ohm.approve(address(vault), assetAmount);
        uint256 actualAssets = vault.mint(shareAmount, alice);
        vm.stopPrank();

        // Verify Alice's mint
        assertEq(actualAssets, assetAmount, "Alice should deposit expected asset amount");
        assertEq(vault.balanceOf(alice), shareAmount, "Alice should have minted shares");
        assertEq(ohm.balanceOf(alice), 0, "Alice should have no OHM left");
        assertEq(vault.totalSupply(), shareAmount, "Total supply should increase");
        assertEq(vault.totalAssets(), assetAmount, "Total assets should match Alice's deposit");

        // Alice transfers half of her shares to Bob
        vm.prank(alice);
        IERC20(address(vault)).safeTransfer(bob, halfShares);

        // Verify transfer
        assertEq(vault.balanceOf(alice), shareAmount - halfShares, "Alice should have half shares after transfer");
        assertEq(vault.balanceOf(bob), halfShares, "Bob should have half shares after transfer");
        assertEq(vault.totalSupply(), shareAmount, "Total supply should remain same after transfer");
        assertEq(vault.totalAssets(), assetAmount, "Total assets should remain same after transfer");

        // Record balances before redemption
        uint256 aliceOHMBefore = ohm.balanceOf(alice);
        uint256 bobOHMBefore = ohm.balanceOf(bob);

        // Alice redeems her remaining half shares
        vm.startPrank(alice);
        uint256 aliceAssetsReceived = vault.redeem(shareAmount - halfShares, alice, alice);
        vm.stopPrank();

        // Verify Alice's redemption
        assertEq(aliceAssetsReceived, halfAssets, "Alice should receive half assets");
        assertEq(vault.balanceOf(alice), 0, "Alice should have 0 shares after redemption");
        assertEq(ohm.balanceOf(alice), aliceOHMBefore + halfAssets, "Alice should receive her OHM");

        // Bob redeems his half shares
        vm.startPrank(bob);
        uint256 bobAssetsReceived = vault.redeem(halfShares, bob, bob);
        vm.stopPrank();

        // Verify Bob's redemption
        assertEq(bobAssetsReceived, halfAssets, "Bob should receive half assets");
        assertEq(vault.balanceOf(bob), 0, "Bob should have 0 shares after redemption");
        assertEq(ohm.balanceOf(bob), bobOHMBefore + halfAssets, "Bob should receive his OHM");

        // Final security assertions

        // 1. Both users should have 0 shares
        assertEq(vault.balanceOf(alice), 0, "Alice should have 0 shares");
        assertEq(vault.balanceOf(bob), 0, "Bob should have 0 shares");

        // 2. Total supply should return to initial state
        assertEq(vault.totalSupply(), 0, "Total supply should return to initial state");

        // 3. Total assets should be 0
        assertEq(vault.totalAssets(), 1, "1 asset stays forever in the vault due to shares rounding down during redeem");

        // 4. Verify OHM conservation - total OHM distributed equals original deposit
        uint256 usersBalances = ohm.balanceOf(alice) + ohm.balanceOf(bob);
        assertEq(usersBalances, assetAmount - assetsEnding, "Total OHM distributed should be lower on assetsEnding");

        // 5. Verify vault's OHM balance is protected
        uint256 vaultOHMAfter = ohm.balanceOf(address(vault));
        assertEq(vaultOHMAfter, assetsEnding, "Vault OHM balance should be protected");

        // 6. Verify clean vault state
        assertEq(vault.pendingOHMDeposits(), assetsEnding, "assetsEnding left over counted in pending");

        // 7. Verify proper share accounting - no shares should remain
        assertEq(vault.totalSupply(), 0, "All new cOHM should be burned");

        // 8. Security check: Verify that neither user can redeem again
        vm.expectRevert();
        vm.prank(alice);
        vault.redeem(1, alice, alice);

        vm.expectRevert();
        vm.prank(bob);
        vault.redeem(1, bob, bob);

        // 9. Additional security: Verify that the transfer + redemption pattern doesn't allow any exploitation
        // The sum of what Alice and Bob received should exactly equal what Alice originally deposited
        assertEq(
            aliceAssetsReceived + bobAssetsReceived,
            assetAmount - assetsEnding,
            "Sum of redemptions should equal original deposit"
        );

        // 10. Verify that share transfers work correctly with the vault's 1:1 asset-to-share ratio
        // Alice deposited assetAmount and got shareAmount, then split it 50/50
        // Each person should get exactly half the assets back
        assertEq(aliceAssetsReceived, halfAssets, "Alice's redemption should be exactly half");
        assertEq(bobAssetsReceived, halfAssets, "Bob's redemption should be exactly half");

        // 11. Final security assertion: No double-spending or asset inflation possible
        uint256 totalSystemOHM = ohm.balanceOf(alice) + ohm.balanceOf(bob) + ohm.balanceOf(address(vault));
        uint256 expectedSystemOHM = assetAmount; // Initial vault balance + Alice's deposit
        assertEq(totalSystemOHM, expectedSystemOHM, "Total system OHM should be conserved - no inflation possible");
    }

    function test_callistoVault_withdraw_permittedAddressCanWithdraw(uint256 assets, address owner, address permitted)
        external
    {
        vm.assume(owner != address(0) && owner != address(vault) && owner != address(this));
        vm.assume(permitted != address(0) && permitted != owner);
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);

        ohm.mint(owner, assets);
        uint256 shares = _depositToVault(owner, assets);

        // Also need to grant ERC20 allowance for the shares
        vm.prank(owner);
        vault.approve(permitted, shares);

        vm.prank(permitted);
        vault.withdraw(assets, permitted, owner);

        assertEq(ohm.balanceOf(permitted), assets);
        assertEq(vault.balanceOf(owner), 0);
    }

    function test_callistoVault_withdraw_unauthorizedAddressCannotWithdraw(
        uint256 assets,
        address owner,
        address unauthorized
    ) external {
        vm.assume(owner != address(0) && owner != address(vault) && owner != address(this));
        vm.assume(unauthorized != address(0) && unauthorized != owner);
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);

        ohm.mint(owner, assets);
        uint256 shares = _depositToVault(owner, assets);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, unauthorized, 0, shares)
        );
        vm.prank(unauthorized);
        vault.withdraw(assets, owner, owner);
    }

    function test_callistoVault_withdraw_revokedPermissionCannotWithdraw(
        uint256 assets,
        address owner,
        address previouslyPermitted
    ) external {
        vm.assume(owner != address(0) && owner != address(vault) && owner != address(this));
        vm.assume(previouslyPermitted != address(0) && previouslyPermitted != owner);
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);

        ohm.mint(owner, assets);
        uint256 shares = _depositToVault(owner, assets);

        vm.prank(owner);
        vault.approve(previouslyPermitted, shares);

        vm.prank(owner);
        vault.approve(previouslyPermitted, 0);

        uint256 maxWithdraw = vault.maxWithdraw(owner);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, previouslyPermitted, 0, shares)
        );
        vm.prank(previouslyPermitted);
        vault.withdraw(maxWithdraw, owner, owner);
    }

    function test_callistoVault_withdraw_multiplePermissions(
        uint256 assets,
        address owner,
        address permitted1,
        address permitted2
    ) external {
        vm.assume(owner != address(0) && owner != address(vault) && owner != address(this));
        vm.assume(permitted1 != address(0) && permitted1 != owner);
        vm.assume(permitted2 != address(0) && permitted2 != owner && permitted2 != permitted1);
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);

        ohm.mint(owner, assets * 2);
        uint256 shares = _depositToVault(owner, assets * 2);

        // Grant ERC20 allowances
        vm.prank(owner);
        vault.approve(permitted1, shares);
        vm.prank(owner);
        vault.approve(permitted2, shares);

        vm.prank(permitted1);
        vault.withdraw(assets, owner, owner);

        vm.prank(permitted2);
        vault.withdraw(assets, owner, owner);

        assertEq(ohm.balanceOf(owner), assets * 2);
        assertEq(vault.balanceOf(owner), 0);
    }

    function test_callistoVault_redeem_permittedAddressCanRedeem(uint256 assets, address owner, address permitted)
        external
    {
        vm.assume(owner != address(0) && owner != address(vault) && owner != address(this));
        vm.assume(permitted != address(0) && permitted != owner);
        assets = bound(assets, vault.minDeposit(), MAX_DEPOSIT);

        ohm.mint(owner, assets);
        uint256 shares = _depositToVault(owner, assets);

        // Grant ERC20 allowance for the shares
        vm.prank(owner);
        vault.approve(permitted, shares);

        vm.prank(permitted);
        vault.redeem(shares, permitted, owner);

        assertEq(ohm.balanceOf(permitted), assets);
        assertEq(vault.balanceOf(owner), 0);
    }
}

contract CallistoVaultViewerTests is CallistoVaultTestBase {
    using SafeCast for *;

    function test_callistoVault_calcDebtToRepay_noDebt() external {
        // When vault has no position in Cooler, should return (0, 0)
        (uint128 wadDebt, uint256 debtAmount) = vault.calcDebtToRepay();
        assertEq(wadDebt, 0);
        assertEq(debtAmount, 0);
    }
}
