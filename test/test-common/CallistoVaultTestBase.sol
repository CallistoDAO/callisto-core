// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import { IERC20, IERC4626 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";
import { CallistoPSM } from "../../src/external/CallistoPSM.sol";
import { ConverterToWadDebt } from "../../src/external/ConverterToWadDebt.sol";
import { DebtTokenMigrator } from "../../src/external/DebtTokenMigrator.sol";
import { PSMStrategy } from "../../src/external/PSMStrategy.sol";
import { VaultStrategy } from "../../src/external/VaultStrategy.sol";
import { IGOHM } from "../../src/interfaces/IGOHM.sol";
import { CommonRoles } from "../../src/libraries/CommonRoles.sol";
import { CallistoVault } from "../../src/policies/CallistoVault.sol";
import { MockCOLLAR } from "../mocks/MockCOLLAR.sol";
import { MockCoolerTreasuryBorrower } from "../mocks/MockCoolerTreasuryBorrower.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockGohm } from "../mocks/MockGohm.sol";
import { IDLGTEv1, MockMonoCooler } from "../mocks/MockMonoCooler.sol";
import { MockStabilityPool } from "../mocks/MockStabilityPool.sol";
import { MockStaking } from "../mocks/MockStaking.sol";
import { MockSusds } from "../mocks/MockSusds.sol";
import { CallistoVaultTester } from "../testers/CallstoVaultTester.sol";
import { Actions, KernelTestBase } from "./KernelTestBase.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract CallistoVaultTestBase is KernelTestBase {
    using SafeCast for *;

    uint256 private constant MIN_DEPOSIT = 10e9;
    uint256 public constant MAX_DEPOSIT = 1e18;

    MockGohm public gohm;
    MockERC20 public sohm;
    MockCOLLAR public collar;
    MockERC20 public usds;
    MockSusds public susds;
    MockStaking public staking;
    MockMonoCooler public cooler;
    CallistoPSM public psm;
    address public user;
    address public user2;
    address public multisig;
    address public heart;
    address public exchanger;
    PSMStrategy public psmStrategy;
    DebtTokenMigrator public debtTokenMigrator;
    ConverterToWadDebt public converterToWadDebt;
    VaultStrategy public vaultStrategy;
    MockStabilityPool public stabilityPool;

    bytes public err;

    function setUp() public virtual override {
        super.setUp();

        multisig = makeAddr("[ Multisig ]");
        heart = makeAddr("[ Heart ]");
        exchanger = makeAddr("[ Exchanger ]");

        ohm = new MockERC20("OHM", "OHM", 9);
        gohm = new MockGohm();
        sohm = new MockERC20("sOHM", "sOHM", 18);
        usds = new MockERC20("USDS", "USDS", 18);
        collar = new MockCOLLAR();

        susds = new MockSusds(IERC20(address(usds)));

        MockCoolerTreasuryBorrower coolerTreasuryBorrower = new MockCoolerTreasuryBorrower(address(usds));

        cooler = new MockMonoCooler(IGOHM(address(gohm)), address(usds), 1, address(coolerTreasuryBorrower));

        staking = new MockStaking(address(ohm), address(sohm), address(gohm), 0, 0, 0);
        converterToWadDebt = new ConverterToWadDebt();

        vm.startPrank(admin);
        stabilityPool = new MockStabilityPool(address(collar));
        vm.stopPrank();
        psmStrategy = new PSMStrategy(
            admin,
            address(stabilityPool),
            address(collar),
            makeAddr("[ False auctioneer ]"),
            makeAddr("[ False Callisto treasury ]")
        );
        debtTokenMigrator = new DebtTokenMigrator(admin, address(cooler));
        psm = new CallistoPSM(admin, address(usds), address(collar), address(susds), address(psmStrategy));

        vaultStrategy = new VaultStrategy(admin, IERC20(address(usds)), address(psm), IERC4626(address(susds)));

        vm.prank(admin);
        debtTokenMigrator.initializePSMAddress(address(psm));

        vm.label(address(ohm), "[ OHM ]");
        vm.label(address(gohm), "[ gOHM ]");
        vm.label(address(sohm), "[ sOHM ]");
        vm.label(address(usds), "[ USDS ]");
        vm.label(address(susds), "[ SUSDS ]");
        vm.label(address(cooler), "[ Olympus Cooler ]");
        vm.label(address(staking), "[ Olympus Staking ]");
        vm.label(address(psm), "[ PSM ]");
        vm.label(address(collar), "[ COLLAR ]");

        // Deploy the Callisto vault policy.
        vault = new CallistoVaultTester(
            kernel,
            CallistoVault.InitialParameters({
                asset: address(ohm),
                olympusStaking: address(staking),
                olympusCooler: address(cooler),
                strategy: address(vaultStrategy),
                debtConverterToWad: address(converterToWadDebt),
                minDeposit: MIN_DEPOSIT
            })
        );
        kernel.executeAction(Actions.ActivatePolicy, address(vault));
        rolesAdmin.grantRole(CommonRoles.MANAGER, multisig);
        rolesAdmin.grantRole(vault.HEART_ROLE(), heart);

        // Init COLLAR
        vm.startPrank(admin);
        psm.grantRole(psm.ADMIN_ROLE(), admin);
        psm.setLP(address(vaultStrategy));
        psmStrategy.finalizeInitialization(address(psm));

        vaultStrategy.initVault(address(vault));
        vm.stopPrank();

        usds.mint(address(cooler), 1e50);

        user = accounts[0];
        user2 = accounts[1];
    }

    function _depositToVaultExt(address user_, uint256 assets) internal override returns (uint256 cOHMAmount) {
        vm.prank(user_);
        ohm.mint(user_, assets);

        cOHMAmount = _depositToVault(user_, assets);
        _prepareCoolerAmounts(assets);

        vm.prank(heart);
        vault.execute();
    }

    function _prepareCoolerAmounts(uint256 assets) internal returns (uint128 borrowAmount) {
        borrowAmount = _gohmToUsds(gohm.balanceTo(assets)).toUint128();
        cooler.setBorrowingAmount(borrowAmount);
        cooler.setDebtDelta(-(borrowAmount).toInt256().toInt128());
        cooler.setRepaymentAmount((borrowAmount).toUint128());
    }

    function _buyUSDSfromPSM(uint256 amount) internal {
        (uint256 collarAmount,) = psm.calcCOLLARIn(amount);
        collar.mint(exchanger, collarAmount);
        vm.startPrank(exchanger);
        collar.approve(address(psm), collarAmount);
        psm.swapIn(exchanger, amount);
        vm.stopPrank();
    }

    function _sellUSDStoPSM(uint256 amount) internal {
        vm.startPrank(exchanger);
        collar.mint(exchanger, amount);
        usds.approve(address(psm), amount);
        psm.swapOut(exchanger, amount);
        vm.stopPrank();
    }

    function _liquidateVaultPositionInCooler() internal {
        // full liquidation
        uint128 gohmAssets = cooler.accountCollateral(address(vault));
        vm.prank(address(vault));
        cooler.withdrawCollateral(gohmAssets, address(vault), address(vault), new IDLGTEv1.DelegationRequest[](0));
    }

    function _gohmToUsds(uint256 gohmAssets) internal pure returns (uint256) {
        return gohmAssets * 3; // exchange rate gohm-usds 1:3
    }

    function _usdsToGohm(uint256 usdsAssets) internal pure returns (uint256) {
        return usdsAssets / 3; // exchange rate gohm-usds 1:3
    }

    function _depositSusds(uint256 assets, address to) internal {
        usds.mint(to, assets);
        vm.startPrank(to);
        usds.approve(address(susds), assets);
        susds.deposit(assets, to);
        vm.stopPrank();
    }
}
