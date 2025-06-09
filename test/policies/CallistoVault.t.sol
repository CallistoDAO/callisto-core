// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import { IERC4626 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";
import { ConverterToWadDebt } from "../../src/external/ConverterToWadDebt.sol";
import { CommonRoles } from "../../src/policies/common/CommonRoles.sol";
import { CallistoOHMVaultBase, CallistoVaultLogic, SafeCast } from "../../src/policies/vault/CallistoVaultLogic.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IDLGTEv1, MockMonoCooler } from "../mocks/MockMonoCooler.sol";
import { MockSwapper } from "../mocks/MockSwapper.sol";
import { CallistoVaultTestBase } from "../test-common/CallistoVaultTestBase.sol";
import { CallistoVaultHelper } from "./CallistoVaultHelper.sol";

contract CallistoVaultRestrictedFuncTests is CallistoVaultTestBase {
    using SafeCast for *;

    function test_callistoVault_setMinDeposit() external {
        uint256 minDeposit = 1e3;
        vm.expectRevert();
        vault.setMinDeposit(minDeposit);

        vm.prank(admin);
        vm.expectRevert(CallistoVaultLogic.ZeroValue.selector);
        vault.setMinDeposit(0);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.MinDepositSet(minDeposit);
        vault.setMinDeposit(minDeposit);
        assertEq(vault.minDeposit(), minDeposit);
    }

    function test_callistoVault_setOHMExchangeMode() external {
        assertEq(abi.encode(vault.ohmExchangeMode()), abi.encode(CallistoVaultLogic.OHMExchangeMode.OlympusStaking));
        // 1. revert not permission
        vm.expectRevert();
        vault.setOHMExchangeMode(CallistoVaultLogic.OHMExchangeMode.Swap);

        // 2. revert same mode
        vm.prank(admin);
        vm.expectRevert(CallistoVaultLogic.FailureToSetExchangeMode.selector);
        vault.setOHMExchangeMode(CallistoVaultLogic.OHMExchangeMode.OlympusStaking);

        // 3. revert warmupPeriod = 0
        vm.prank(admin);
        vm.expectRevert(CallistoVaultLogic.FailureToSetExchangeMode.selector);
        vault.setOHMExchangeMode(CallistoVaultLogic.OHMExchangeMode.Swap);

        // 4. warmupPeriod > 0
        staking.setWarmupPeriod(1);
        vm.prank(admin);

        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.OHMExchangeModeSet(CallistoVaultLogic.OHMExchangeMode.Swap);
        vault.setOHMExchangeMode(CallistoVaultLogic.OHMExchangeMode.Swap);

        assertEq(abi.encode(vault.ohmExchangeMode()), abi.encode(CallistoVaultLogic.OHMExchangeMode.Swap));

        // 5. return  OlympusStaking
        staking.setWarmupPeriod(0);
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.OHMExchangeModeSet(CallistoVaultLogic.OHMExchangeMode.OlympusStaking);
        vault.setOHMExchangeMode(CallistoVaultLogic.OHMExchangeMode.OlympusStaking);

        assertEq(abi.encode(vault.ohmExchangeMode()), abi.encode(CallistoVaultLogic.OHMExchangeMode.OlympusStaking));
    }

    function test_callistoVault_pauses() external {
        vm.expectRevert();
        vault.setPause(true, true);

        vm.startPrank(admin);
        // 1. deposit paused
        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.DepositPaused();
        vault.setPause(true, true);
        assertEq(vault.depositPaused(), true);
        assertEq(vault.withdrawalPaused(), false);

        vm.expectRevert(CallistoVaultLogic.EnforcedPause.selector);
        vault.setPause(true, true);

        // 2. deposit unpaused
        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.DepositUnpaused();
        vault.setPause(true, false);
        assertEq(vault.depositPaused(), false);
        assertEq(vault.withdrawalPaused(), false);

        vm.expectRevert(CallistoVaultLogic.ExpectedPause.selector);
        vault.setPause(true, false);

        // 3. withdraw paused
        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.WithdrawalPaused();
        vault.setPause(false, true);
        assertEq(vault.depositPaused(), false);
        assertEq(vault.withdrawalPaused(), true);

        vm.expectRevert(CallistoVaultLogic.EnforcedPause.selector);
        vault.setPause(false, true);

        // 4. withdraw unpaused
        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.WithdrawalUnpaused();
        vault.setPause(false, false);
        assertEq(vault.depositPaused(), false);
        assertEq(vault.withdrawalPaused(), false);

        vm.expectRevert(CallistoVaultLogic.ExpectedPause.selector);
        vault.setPause(false, false);
        vm.stopPrank();
    }

    function test_callistoVault_transferUnexpectedTokens(uint256 assets, uint256 unexpectedAssets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        unexpectedAssets = bound(unexpectedAssets, MIN_DEPOSIT, MAX_DEPOSIT);
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

    function test_callistoVault_migrateDebtToken(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        ohm.mint(user, assets);
        _depositToVault(user, assets);

        MockERC20 newToken = new MockERC20("New Debt Token", "NDT", 9);
        ConverterToWadDebt newConverterToWadDebt = new ConverterToWadDebt();

        assertEq(address(vault.debtToken()), address(usds));
        assertEq(address(vault.debtConverterToWad()), address(converterToWadDebt));

        // check revert when not DebtTokenMigrator
        vm.expectRevert(
            abi.encodeWithSelector(CallistoVaultLogic.OnlyDebtTokenMigrator.selector, address(debtTokenMigrator))
        );
        vault.migrateDebtToken(address(newToken), address(newConverterToWadDebt));

        // chec success when DebtTokenMigrator
        vm.prank(address(debtTokenMigrator));
        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.DebtTokenMigrated(address(newToken));
        vault.migrateDebtToken(address(newToken), address(newConverterToWadDebt));

        assertEq(address(vault.debtToken()), address(newToken));
        assertEq(address(vault.debtConverterToWad()), address(newConverterToWadDebt));
        assertEq(newToken.allowance(address(vault), address(vaultStrategy)), type(uint256).max);
    }
}

contract CallistoVaultDepositTests is CallistoVaultTestBase {
    using SafeCast for *;

    function test_callistoVault_depositWithdrawOnPausedVault(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);

        ohm.mint(user, assets);
        _depositToVault(user, assets);

        // test deposit reverts on pause
        vm.prank(admin);
        vault.setPause(true, true);

        vm.prank(user);
        vm.expectRevert(CallistoVaultLogic.EnforcedPause.selector);
        vault.deposit(assets, user);

        vm.prank(user);
        vm.expectRevert(CallistoVaultLogic.EnforcedPause.selector);
        vault.mint(shares, user);

        vm.prank(admin);
        vault.setPause(false, true);

        // test withdraw reverts on pause
        vm.prank(user);
        vm.expectRevert(CallistoVaultLogic.EnforcedPause.selector);
        vault.withdraw(assets, user, user);

        vm.prank(user);
        vm.expectRevert(CallistoVaultLogic.EnforcedPause.selector);
        vault.redeem(shares, user, user);
    }

    function test_callistoVault_depositReverts() external {
        // 1. min deposits check
        uint256 badAmount = MIN_DEPOSIT - 1;
        vm.expectRevert(
            abi.encodeWithSelector(CallistoVaultLogic.AmountLessThanMinDeposit.selector, badAmount, MIN_DEPOSIT)
        );
        vault.deposit(badAmount, address(1));

        vm.expectRevert(abi.encodeWithSelector(CallistoVaultLogic.AmountLessThanMinDeposit.selector, 1, MIN_DEPOSIT));
        vault.mint(badAmount, address(1));
    }

    function test_callistoVault_deposit(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
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
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
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
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        ohm.mint(user, assets);
        _depositToVault(user, assets);

        uint256 pendingOHM = vault.pendingOHMDeposits();
        assertEq(pendingOHM, assets);

        uint256 badPendingOHM = assets + 1;

        // processPendingDeposits skips if OHMExchangeMode is OlympusStaking
        staking.setWarmupPeriod(1);
        vm.startPrank(admin);
        vault.setOHMExchangeMode(CallistoVaultLogic.OHMExchangeMode.Swap);

        vm.expectRevert(
            abi.encodeWithSelector(
                CallistoVaultLogic.AmountGreaterThanPendingOHMDeposits.selector, badPendingOHM, pendingOHM
            )
        );

        vault.processPendingDeposits(badPendingOHM, new bytes[](0));
    }

    function test_callistoVault_execute_notAuthorizedRevert() external {
        vm.expectRevert();
        vault.execute();
    }

    function test_callistoVault_execute_byHeart(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        ohm.mint(user, assets);
        _depositToVault(user, assets);
        _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.DepositsHandled(assets);
        vault.execute();

        assertEq(vault.pendingOHMDeposits(), 0);
        assertEq(ohm.balanceOf(address(vault)), 0);
    }

    function test_callistoVault_execute_warmupPeriodError(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        ohm.mint(user, assets);
        _depositToVault(user, assets);
        _prepareCoolerAmounts(assets);

        staking.setWarmupPeriod(1);

        vm.prank(heart);
        vm.expectRevert(abi.encodeWithSelector(CallistoVaultLogic.StakingPeriodExists.selector, 1));
        vault.execute();
    }

    function test_callistoVault_processPendingDeposits_swapperMode(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        ohm.mint(user, assets);
        _depositToVault(user, assets);
        _prepareCoolerAmounts(assets);

        MockSwapper swapper = new MockSwapper(ohm, gohm);
        // set SWAP mode
        staking.setWarmupPeriod(1);
        vm.startPrank(admin);
        vault.setOHMExchangeMode(CallistoVaultLogic.OHMExchangeMode.Swap);
        vault.setOHMSwapper(address(swapper));
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.DepositsHandled(assets);
        vault.processPendingDeposits(assets, new bytes[](0));

        assertEq(vault.pendingOHMDeposits(), 0);
        assertEq(ohm.balanceOf(address(vault)), 0);
    }

    function test_callistoVault_processPendingDeposits_waitingForWarmupPeriodMode(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        ohm.mint(user, assets);
        _depositToVault(user, assets);
        _prepareCoolerAmounts(assets);

        // set WaitingForWarmupPeriod mode
        staking.setWarmupPeriod(1);
        vm.startPrank(admin);
        vault.setOHMExchangeMode(CallistoVaultLogic.OHMExchangeMode.WaitingForWarmupPeriod);
        vm.stopPrank();

        vm.prank(multisig);
        vault.processPendingDeposits(assets, new bytes[](0));

        assertEq(vault.stakedOHM(), assets, "staked OHM > 0");
        assertEq(vault.pendingOHMDeposits(), 0);

        staking.setEpochNumber(2);

        vm.prank(multisig);
        vault.processPendingDeposits(MIN_DEPOSIT, new bytes[](0));

        assertEq(vault.stakedOHM(), 0);
    }

    /**
     * Tests methods with signature
     */
    function test_callistoVault_depositWithSig(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);

        uint256 userPrivateKey = 0xA11CE;
        user = vm.addr(userPrivateKey);
        uint256 deadline = block.timestamp + 1 hours;
        ohm.mint(user, assets);

        CallistoVaultLogic.SignatureParameters memory ps = CallistoVaultHelper.getPermitSignature(
            vm, user, userPrivateKey, assets, deadline, address(ohm), address(vault)
        );

        CallistoVaultLogic.SignatureParameters memory ds = CallistoVaultHelper.getDepositSignature(
            vm, userPrivateKey, user, assets, deadline, address(vault), address(this)
        );

        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Deposit(user, user, assets, shares);
        vault.depositWithSig(assets, user, user, ps, ds);

        assertEq(ohm.balanceOf(user), 0);
        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.pendingOHMDeposits(), assets);
    }

    function test_callistoVault_mintWithSig(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);

        uint256 userPrivateKey = 0xA11CE;
        user = vm.addr(userPrivateKey);
        uint256 deadline = block.timestamp + 1 hours;
        ohm.mint(user, assets);

        CallistoVaultLogic.SignatureParameters memory ps = CallistoVaultHelper.getPermitSignature(
            vm, user, userPrivateKey, assets, deadline, address(ohm), address(vault)
        );

        CallistoVaultLogic.SignatureParameters memory ds = CallistoVaultHelper.getMintSignature(
            vm, userPrivateKey, user, assets, deadline, address(vault), address(this)
        );

        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Deposit(user, user, assets, shares);
        vault.mintWithSig(shares, user, user, ps, ds);

        assertEq(ohm.balanceOf(user), 0);
        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.pendingOHMDeposits(), assets);
    }
}

contract CallistoVaultWithdrawTests is CallistoVaultTestBase {
    using SafeCast for *;

    function test_callistoVault_withdrawSimple(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
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
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
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
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);

        ohm.mint(user, assets);
        _depositToVault(user, assets);

        // 1. check min amount of withdraw
        vm.expectRevert(
            abi.encodeWithSelector(CallistoOHMVaultBase.ERC4626ExceededMaxWithdraw.selector, address(1), MIN_DEPOSIT, 0)
        );
        vault.withdraw(MIN_DEPOSIT, address(1), address(1));

        vm.expectRevert(
            abi.encodeWithSelector(CallistoOHMVaultBase.ERC4626ExceededMaxRedeem.selector, address(1), MIN_DEPOSIT, 0)
        );
        vault.redeem(MIN_DEPOSIT, address(1), address(1));

        vm.expectRevert(CallistoVaultLogic.ZeroValue.selector);
        vault.withdraw(0, user, user);

        vm.expectRevert(CallistoVaultLogic.ZeroOHM.selector);
        vault.redeem(0, user, user);

        // 2. paused checks
        vm.prank(admin);
        vault.setPause(false, true);

        vm.startPrank(user);
        vm.expectRevert(CallistoVaultLogic.EnforcedPause.selector);
        vault.withdraw(assets, user, user);

        vm.expectRevert(CallistoVaultLogic.EnforcedPause.selector);
        vault.redeem(shares, user, user);
    }

    // Withdrawal after user deposit without calling processPendingDeposits()
    // 1.1. Full withdrawal should succeed. (without calling processPendingDeposits())
    function test_callistoVault_withdrawFull(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);

        ohm.mint(user, assets);
        _depositToVault(user, assets);
        _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(user, user, user, assets, shares);
        vault.withdraw(assets, user, user);
        assertEq(ohm.balanceOf(address(user)), assets);
    }

    // Withdrawal after user deposit without calling processPendingDeposits()
    // 1.2. Partial withdrawal should succeed.
    function test_callistoVault_withdrawPartial(uint256 assets, uint256 partialAssets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets - 1);
        uint256 partialShares = vault.previewDeposit(partialAssets);

        ohm.mint(user, assets);
        _depositToVault(user, assets);
        _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(user, user, user, partialAssets, partialShares);
        vault.withdraw(partialAssets, user, user);
        assertEq(ohm.balanceOf(address(user)), partialAssets);
    }

    // Withdrawal when the vault’s Cooler V2 loan has been liquidated
    //  2.1. If pendingOHM ≥ requested amount → withdrawal should succeed.
    function test_callistoVault_withdrawEnoughPendingValue(uint256 assets, uint256 partialAssets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets - 1);
        ohm.mint(user, assets);

        _depositToVault(user, assets);
        _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();

        ohm.mint(user2, partialAssets);
        _depositToVault(user2, partialAssets);

        assertEq(vault.pendingOHMDeposits(), partialAssets);

        vm.prank(user);
        vault.withdraw(partialAssets, user, user);
        assertEq(ohm.balanceOf(address(user)), partialAssets);
        assertEq(vault.pendingOHMDeposits(), 0);
    }

    // Withdrawal when the vault’s Cooler V2 loan has been liquidated
    // 2.2. If pendingOHM is insufficient:
    function test_callistoVault_withdrawInsufficientPendingOHM(uint256 assets, uint256 partialAssets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets - 1);
        ohm.mint(user, assets);

        _depositToVault(user, assets);
        uint128 borrowAmount = _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();

        assertEq(vault.pendingOHMDeposits(), 0);
        assertEq(susds.balanceOf(address(psm)), borrowAmount);
        assertEq(cooler.accountCollateral(address(vault)), gohm.balanceTo(assets));

        uint256 partialDebt = (borrowAmount * partialAssets) / assets;
        cooler.setDebtDelta(-(partialDebt).toInt256().toInt128());
        cooler.setRepaymentAmount(partialDebt.toUint128());

        vm.prank(user);
        vault.withdraw(partialAssets, user, user);
        assertEq(ohm.balanceOf(address(user)), partialAssets);
        assertEq(susds.balanceOf(address(psm)), borrowAmount - partialDebt);
        assertEq(cooler.accountCollateral(address(vault)), gohm.balanceTo(assets - partialAssets));
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

    // 2.2.2. If there is not enough OHM → should revert.
    function test_callistoVault_withdrawCoolerV2LoanHasBeenLiquidated_Revert(uint256 assets, uint256 partialAssets)
        external
    {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets - 1);

        _prepareWithdrawCoolerV2LoanHasBeenLiquidated(assets, partialAssets);

        // check revert when not enough OHM
        vm.prank(user);
        vm.expectRevert();
        vault.withdraw(assets, user, user);
    }

    // 2.2.1. If the collateral=0 and contract has enough OHM in its balance → withdrawal should succeed.
    function test_callistoVault_withdrawCoolerV2LoanHasBeenLiquidated_Ok(uint256 assets, uint256 partialAssets)
        external
    {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets - 1);

        _prepareWithdrawCoolerV2LoanHasBeenLiquidated(assets, partialAssets);

        // withdraw assets directly from OHM wallet
        vm.prank(user);
        vault.withdraw(partialAssets, user, user);
        assertEq(ohm.balanceOf(address(user)), partialAssets);
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

    // 3.1. If the available gOHM in Cooler is less than required due to rounding → should revert.
    function test_callistoVault_withdrawalEdgeCaseDueToRoundingErrorInGOHM_Revert(uint256 assets, uint256 partialAssets)
        external
    {
        assets = bound(assets, MIN_DEPOSIT + 10, MAX_DEPOSIT);
        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets - 1);
        _prepareWithdrawalEdgeCaseDueToRounding(assets, partialAssets);

        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(CallistoVaultLogic.NotEnoughGOHM.selector, gohm.balanceTo(partialAssets))
        );
        vault.withdraw(assets, user, user);
    }

    // 3.2. After the protocol sends the missing gOHM directly to the vault → withdrawal should succeed.
    function test_callistoVault_withdrawalEdgeCaseDueToRoundingErrorInGOHM_Ok(uint256 assets, uint256 partialAssets)
        external
    {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);

        partialAssets = bound(partialAssets, MIN_DEPOSIT, assets - 1);
        _prepareWithdrawalEdgeCaseDueToRounding(assets, partialAssets);

        // protocol sends the missing gOHM directly to the vault
        gohm.mint(address(vault), gohm.balanceTo(partialAssets));

        // withdraw must be success
        vm.prank(user);
        uint256 withdrawShares = vault.withdraw(assets, user, user);
        assertEq(withdrawShares, shares);
        assertEq(ohm.balanceOf(address(user)), assets);
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

    // 4.2. If the user has not approved USDS spend → should revert.
    function test_callistoVault_withdrawPSMhasInsufficientUSDS_Revert(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        _prepareInsufficientUsdsInPSM(assets);

        // revert with NotEnoughGOHM on withdraw
        vm.prank(user);
        vm.expectRevert();
        vault.withdraw(assets, user, user);
    }

    // 4.1. If the user has approved USDS spend by the vault → vault pulls remaining USDS and withdrawal should succeed.
    function test_callistoVault_withdrawPSMhasInsufficientUSDS_Ok(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        uint256 insufficientUsds = _prepareInsufficientUsdsInPSM(assets);
        uint256 shares = vault.previewDeposit(assets);

        vm.startPrank(user);
        // mint and approve susds
        usds.mint(user, insufficientUsds);
        usds.approve(address(vault), insufficientUsds);

        // withdraw must be success
        uint256 withdrawsShares = vault.withdraw(assets, user, user);
        assertEq(withdrawsShares, shares);
        assertEq(ohm.balanceOf(address(user)), assets);

        assertEq(vault.reimbursementClaims(address(user)), insufficientUsds);
    }

    // 4.1. If the user has approved USDS spend by the vault → vault pulls remaining USDS and withdrawal should succeed.
    // And claim reimbursment
    function test_callistoVault_withdrawPSMhasInsufficientUSDS_WithClaimReimbursement(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        uint256 insufficientUsds = _prepareInsufficientUsdsInPSM(assets);

        vm.startPrank(user);
        // mint and approve susds
        usds.mint(user, insufficientUsds);
        usds.approve(address(vault), insufficientUsds);
        // withdraw must be success
        vault.withdraw(assets, user, user);
        assertEq(vault.reimbursementClaims(address(user)), insufficientUsds);
        // sell usds for liquidity
        _sellUSDStoPSM(insufficientUsds);
        // claim reimbursement for user
        vault.claimReimbursement(user);
        assertEq(usds.balanceOf(address(user)), insufficientUsds);
        assertEq(vault.reimbursementClaims(address(user)), 0);
    }

    function test_callistoVault_withdrawYieldToTreasury_full(uint256 assets, uint256 yuild) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        yuild = bound(yuild, MIN_DEPOSIT, assets);
        ohm.mint(user, assets);
        _depositToVault(user, assets);
        uint128 borrowAmount = _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();

        assertEq(susds.balanceOf(address(psm)), borrowAmount);
        usds.mint(address(susds), yuild);

        uint256 totalYield = vault.totalYield();
        assertEq(totalYield, yuild - 1);

        vm.expectRevert(abi.encodeWithSelector(CommonRoles.Unauthorized.selector, address(this)));
        vault.sweepYield(totalYield);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CallistoVaultLogic.YieldWithdrawalExceedsTotalYield.selector, totalYield)
        );
        vault.sweepYield(totalYield + 1);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.YieldWithdrawnToTreasury(totalYield);
        vault.sweepYield(type(uint256).max);

        assertEq(usds.balanceOf(address(treasury)), totalYield);
        assertEq(vault.totalYield(), 0);
    }

    function test_callistoVault_withdrawYieldToTreasury_partial(uint256 assets, uint256 yuild, uint256 partialYuild)
        external
    {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        yuild = bound(yuild, MIN_DEPOSIT, assets);
        partialYuild = bound(partialYuild, 1, yuild - 1);
        ohm.mint(user, assets);
        _depositToVault(user, assets);
        uint128 borrowAmount = _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();

        assertEq(susds.balanceOf(address(psm)), borrowAmount);
        usds.mint(address(susds), yuild);
        uint256 totalYield = vault.totalYield();
        assertEq(totalYield, yuild - 1);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.YieldWithdrawnToTreasury(partialYuild);
        vault.sweepYield(partialYuild);

        assertEq(usds.balanceOf(address(treasury)), partialYuild);
        assertEq(vault.totalYield(), totalYield - partialYuild);
    }

    function test_callistoVault_cancelOHMStake(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        ohm.mint(user, assets);
        _depositToVault(user, assets);

        vm.expectRevert(abi.encodeWithSelector(CommonRoles.Unauthorized.selector, address(this)));
        vault.cancelOHMStake();

        vm.prank(multisig);
        vm.expectRevert(CallistoVaultLogic.ZeroValue.selector);
        vault.cancelOHMStake();

        // set WaitingForWarmupPeriod mode
        staking.setWarmupPeriod(1);
        vm.startPrank(admin);
        vault.setOHMExchangeMode(CallistoVaultLogic.OHMExchangeMode.WaitingForWarmupPeriod);
        vm.stopPrank();

        vm.prank(heart);
        vault.execute();

        assertEq(vault.stakedOHM(), 0, "staked OHM == 0 after execute");

        vault.processPendingDeposits(assets, new bytes[](0));

        assertEq(vault.stakedOHM(), assets, "staked OHM > 0 after processPendingDeposits");
        assertEq(vault.pendingOHMDeposits(), 0);

        vm.prank(multisig);
        vault.cancelOHMStake();

        assertEq(vault.stakedOHM(), 0);
        assertEq(vault.pendingOHMDeposits(), assets);
        assertEq(ohm.balanceOf(address(vault)), assets);
    }

    function test_callistoVault_withdrawExcessGOHM_full(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        ohm.mint(user, assets);
        _depositToVault(user, assets);
        _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();

        uint256 indexInc = 1e9;

        gohm.setIndex(gohm.index() + indexInc);

        uint256 excessGOHM = vault.excessGOHM();
        assertGt(excessGOHM, 0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CallistoVaultLogic.NotEnoughGOHM.selector, 1));
        vault.withdrawExcessGOHM(excessGOHM + 1, user);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.GOHMExcessWithdrawn(user, excessGOHM);
        vault.withdrawExcessGOHM(excessGOHM, user);
    }

    function test_callistoVault_withdrawExcessGOHM_noExcessGOHMreve(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        ohm.mint(user, assets);
        _depositToVault(user, assets);
        _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();

        uint256 indexInc = 1e9;

        gohm.setIndex(gohm.index() + indexInc);
        _liquidateVaultPositionInCooler();

        uint256 excessGOHM = vault.excessGOHM();
        vm.prank(admin);
        vm.expectRevert(CallistoVaultLogic.NoExcessGOHM.selector);
        vault.withdrawExcessGOHM(excessGOHM, user);
    }

    function test_callistoVault_withdrawExcessGOHM_partial(uint256 assets, uint256 partialAssets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        ohm.mint(user, assets);
        _depositToVault(user, assets);
        _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();

        uint256 indexInc = 1e9;

        gohm.setIndex(gohm.index() + indexInc);

        uint256 excessGOHM = vault.excessGOHM();
        assertGt(excessGOHM, 0);

        partialAssets = bound(partialAssets, 1, excessGOHM - 1);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.GOHMExcessWithdrawn(user, partialAssets);
        vault.withdrawExcessGOHM(partialAssets, user);
    }

    function _prepareForReimbursement(uint256 amount) internal {
        // remove USDS from PSM
        _buyUSDSfromPSM(amount);
        usds.mint(address(this), amount);
        usds.approve(address(vault), amount);
    }

    function test_callistoVault_claimReimbursement_fromPSM(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        ohm.mint(user, assets);
        _depositToVault(user, assets);
        uint128 debtDelta = _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();

        uint256 reimbursementValue = debtDelta;

        _prepareForReimbursement(reimbursementValue);
        vault.repayCoolerDebt(debtDelta);

        assertEq(usds.balanceOf(address(psm)), 0);
        assertEq(vault.reimbursementClaims(address(this)), reimbursementValue);

        // add USDS to PSM
        ohm.mint(user2, assets * 2);
        _depositToVault(user2, assets * 2);

        vm.prank(heart);
        vault.execute();

        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.ReimbursementClaimed(address(this), debtDelta);
        vault.claimReimbursement(address(this));

        assertEq(usds.balanceOf(address(this)), debtDelta);
        assertEq(vault.reimbursementClaims(address(this)), 0);
    }

    function test_callistoVault_claimReimbursement_directFromVault(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        ohm.mint(user, assets);
        _depositToVault(user, assets);

        uint128 debtDelta = _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();

        uint256 reimbursementValue = debtDelta;

        _prepareForReimbursement(reimbursementValue);
        vault.repayCoolerDebt(debtDelta);

        assertEq(usds.balanceOf(address(psm)), 0);
        assertEq(vault.reimbursementClaims(address(this)), reimbursementValue);

        // add USDS to vault
        usds.mint(address(vault), debtDelta);

        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.ReimbursementClaimed(address(this), debtDelta);
        vault.claimReimbursement(address(this));

        assertEq(usds.balanceOf(address(this)), debtDelta);
        assertEq(usds.balanceOf(address(vault)), 0);
        assertEq(vault.reimbursementClaims(address(this)), 0);
    }

    function test_callistoVault_claimReimbursement_fromPSMAndDirectFromVault(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT * 2, MAX_DEPOSIT);

        ohm.mint(user, assets);
        _depositToVault(user, assets);
        uint128 debtDelta = _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();

        uint256 reimbursementValue = debtDelta;

        _prepareForReimbursement(reimbursementValue);
        vault.repayCoolerDebt(debtDelta);

        assertEq(usds.balanceOf(address(psm)), 0);
        assertEq(usds.balanceOf(address(vault)), 0);
        assertEq(vault.reimbursementClaims(address(this)), reimbursementValue);

        // return half USDS to PSM
        uint128 halfAssets = (debtDelta / 2).toUint128();

        _sellUSDStoPSM(halfAssets);

        // also add half USDS to vault
        usds.mint(address(vault), debtDelta - halfAssets);

        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.ReimbursementClaimed(address(this), debtDelta);
        vault.claimReimbursement(address(this));

        assertEq(usds.balanceOf(address(this)), debtDelta);
        assertEq(usds.balanceOf(address(vault)), 0);
        assertEq(vault.reimbursementClaims(address(this)), 0);
    }

    function test_callistoVault_repayCoolerDebt_full(uint256 assets, bool withReimbursement) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);

        ohm.mint(user, assets);
        _depositToVault(user, assets);
        uint128 debtDelta = _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();

        uint256 reimbursementValue;

        if (withReimbursement) {
            reimbursementValue = debtDelta;
            _prepareForReimbursement(reimbursementValue);
        }

        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.CoolerDebtRepaid(address(this), debtDelta);
        vault.repayCoolerDebt(debtDelta);
        assertEq(usds.balanceOf(address(psm)), 0);
        assertEq(vault.reimbursementClaims(address(this)), reimbursementValue);
    }

    function test_callistoVault_repayCoolerDebt_partial(uint256 assets, uint128 partialAssets, bool withReimbursement)
        external
    {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);
        ohm.mint(user, assets);
        _depositToVault(user, assets);
        uint128 debtDelta = _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();

        partialAssets = bound(partialAssets, 1, debtDelta - 1).toUint128();
        uint256 reimbursementValue;

        if (withReimbursement) {
            reimbursementValue = partialAssets; // TODO: reimbursement half part of debt
            _prepareForReimbursement(debtDelta);
        }

        cooler.setRepaymentAmount(partialAssets);

        vm.expectEmit(true, true, true, true, address(vault));
        emit CallistoVaultLogic.CoolerDebtRepaid(address(this), partialAssets);
        vault.repayCoolerDebt(partialAssets);

        assertEq(usds.balanceOf(address(psm)), 0);
        assertEq(vault.reimbursementClaims(address(this)), reimbursementValue);
    }

    function test_callistoVault_withdrawWithSig(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);

        uint256 userPrivateKey = 0xA11CE;
        user = vm.addr(userPrivateKey);
        uint256 deadline = block.timestamp + 1 hours;
        ohm.mint(user, assets);

        _depositToVault(user, assets);

        CallistoVaultLogic.SignatureParameters memory ds = CallistoVaultHelper.getWithdrawSignature(
            vm, userPrivateKey, user, assets, deadline, address(vault), address(this)
        );

        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(user, user, user, assets, shares);
        uint256 res = vault.withdrawWithSig(assets, user, user, ds);

        assertEq(res, shares);
        assertEq(ohm.balanceOf(user), assets);
        assertEq(vault.balanceOf(user), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_callistoVault_redeemWitSig(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);

        uint256 userPrivateKey = 0xA11CE;
        user = vm.addr(userPrivateKey);
        uint256 deadline = block.timestamp + 1 hours;
        ohm.mint(user, assets);

        _depositToVault(user, assets);

        CallistoVaultLogic.SignatureParameters memory ds = CallistoVaultHelper.getRedeemSignature(
            vm, userPrivateKey, user, assets, deadline, address(vault), address(this)
        );

        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(user, user, user, assets, shares);
        vault.redeemWithSig(shares, user, user, ds);

        assertEq(ohm.balanceOf(user), assets);
        assertEq(vault.balanceOf(user), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_callistoVault_emergencyRedeem(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 shares = vault.previewDeposit(assets);
        ohm.mint(user, assets);
        _depositToVault(user, assets);
        uint256 borrowAmount = _prepareCoolerAmounts(assets);

        assertEq(psm.suppliedByLP(), 0);

        // should skip and return 0
        vault.emergencyRedeem(1234);

        vm.prank(heart);
        vault.execute();
        _liquidateVaultPositionInCooler();

        vm.prank(user);
        uint256 returnedUSDS = vault.emergencyRedeem(shares);

        assertEq(returnedUSDS, borrowAmount);
        assertEq(usds.balanceOf(address(user)), borrowAmount);
    }
}
