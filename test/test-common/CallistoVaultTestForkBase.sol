// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import { IERC20, IERC4626 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";
import { CallistoPSM } from "../../src/external/CallistoPSM.sol";
import { ConverterToWadDebt } from "../../src/external/ConverterToWadDebt.sol";
import { DebtTokenMigrator } from "../../src/external/DebtTokenMigrator.sol";
import { VaultStrategy } from "../../src/external/VaultStrategy.sol";
import { IGOHM } from "../../src/interfaces/IGOHM.sol";
import { IOlympusStaking } from "../../src/interfaces/IOlympusStaking.sol";
import { CommonRoles } from "../../src/policies/common/CommonRoles.sol";
import { CallistoVault } from "../../src/policies/vault/CallistoVault.sol";
import { CallistoVaultLogic, SafeCast } from "../../src/policies/vault/CallistoVaultLogic.sol";
import { MockCOLLAR } from "../mocks/MockCOLLAR.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockStabilityPool } from "../mocks/MockStabilityPool.sol";
import { IMonoCoolerExtended } from "../test-common/interfaces/IMonoCoolerExtended.sol";
import { Ethereum } from "./ForkConstants.sol";
import { Actions, KernelTestBase } from "./KernelTestBase.sol";

contract CallistoVaultTestForkBase is KernelTestBase {
    using SafeCast for *;

    uint256 public constant MIN_DEPOSIT = 100e9; // 100 OHM is the minimum deposit amount for the Callisto vault.
    uint256 public constant MAX_DEPOSIT = 100_000e9; // 100,000 OHM.
    address public constant ZERO_ADDRESS = address(0);

    // https://docs.olympusdao.finance/main/contracts/addresses#modules
    IGOHM public constant gohm = IGOHM(Ethereum.GOHM);
    IERC20 public constant sohm = IERC20(Ethereum.SOHM);
    MockCOLLAR public collar;
    MockERC20 public constant usds = MockERC20(Ethereum.USDS);
    IERC4626 constant susds = IERC4626(Ethereum.SUSDS);
    IOlympusStaking public staking = IOlympusStaking(Ethereum.OLYMPUS_STAKING);
    IMonoCoolerExtended constant cooler = IMonoCoolerExtended(Ethereum.OLYMPUS_COOLER);
    CallistoPSM public psm;
    address public user;
    address public user2;
    address public backend;
    address public heart;
    address public exchanger;
    DebtTokenMigrator public debtTokenMigrator;
    ConverterToWadDebt public converterToWadDebt;
    VaultStrategy public vaultStrategy;

    address public alice;
    address public bob;
    address public carol;
    address public dennis;

    function setUp() public virtual override {
        super.setUp();

        backend = makeAddr("[ Backend ]");
        heart = makeAddr("[ Heart ]");
        exchanger = makeAddr("[ Exchanger ]");
        alice = makeAddr("[ alice ]");
        bob = makeAddr("[ bob ]");
        carol = makeAddr("[ carol ]");
        dennis = makeAddr("[ dennis ]");

        ohm = MockERC20(Ethereum.OHM);

        collar = new MockCOLLAR();

        converterToWadDebt = new ConverterToWadDebt();

        debtTokenMigrator = new DebtTokenMigrator(admin, address(cooler));
        psm = new CallistoPSM(admin, address(usds), address(collar), address(susds), address(debtTokenMigrator));

        vaultStrategy = new VaultStrategy(
            admin, IERC20(address(usds)), address(psm), IERC4626(address(susds)), address(debtTokenMigrator)
        );

        vm.prank(admin);
        debtTokenMigrator.initializePSMAddress(address(psm));

        vm.label(address(ohm), "[ OHM ]");
        vm.label(address(gohm), "[ gOHM ]");
        vm.label(address(sohm), "[ sOHM ]");
        vm.label(address(usds), "[ USDS ]");
        vm.label(address(susds), "[ SUSDS ]");
        vm.label(address(cooler), "[ Olympus Cooler ]");
        vm.label(address(staking), "[ Olympus Staking ]");
        vm.label(address(vaultStrategy), "[ Vault Strategy ]");
        vm.label(address(psm), "[ PSM ]");
        vm.label(address(collar), "[ COLLAR ]");

        // Deploy the Callisto vault policy.
        vault = new CallistoVault(
            kernel,
            CallistoVaultLogic.InitialParameters({
                asset: address(ohm),
                olympusStaking: address(staking),
                olympusCooler: address(cooler),
                strategy: address(vaultStrategy),
                debtConverterToWad: address(converterToWadDebt),
                debtTokenMigrator: address(debtTokenMigrator),
                minDeposit: MIN_DEPOSIT
            })
        );

        kernel.executeAction(Actions.ActivatePolicy, address(vault));
        rolesAdmin.grantRole(CommonRoles.MANAGER, backend);
        rolesAdmin.grantRole(vault.HEART_ROLE(), heart);

        // Init COLLAR
        vm.startPrank(admin);
        MockStabilityPool pool = new MockStabilityPool(IERC20(address(collar)));
        psm.grantRole(psm.ADMIN_ROLE(), admin);
        psm.setLP(address(vaultStrategy));
        psm.initCallistoStabilityPool(address(pool));

        vaultStrategy.initVault(address(vault));
        vm.stopPrank();

        _usdsMint(address(cooler), 1e50);
        // https://etherscan.io/tx/0x3c9a2a60285c972bf103d29ffe97503b25c5dbcb130f2bd862749a69ec21098c#eventlog
        // set wards user of usds

        user = accounts[0];
        user2 = accounts[1];
    }

    function _ohmMint(address to, uint256 amount) internal {
        vm.prank(0xa90bFe53217da78D900749eb6Ef513ee5b6a491e);
        ohm.mint(to, amount);
    }

    function _usdsMint(address to, uint256 amount) internal {
        vm.prank(0xBE8E3e3618f7474F8cB1d074A26afFef007E98FB);
        usds.mint(to, amount);
    }

    function _gohmMint(address to, uint256 amount) internal {
        vm.prank(0xB63cac384247597756545b500253ff8E607a8020);
        gohm.mint(to, amount);
    }

    function _depositToVaultExt(address user_, uint256 assets) internal override returns (uint256 cOHMAmount) {
        _ohmMint(user_, assets);

        cOHMAmount = _depositToVault(user_, assets);

        vm.prank(heart);
        vault.execute();
    }

    function _buyUSDSfromPSM(uint256 amount) internal {
        (uint256 collarAmount,) = psm.calcCOLLARIn(amount);
        collar.mint(exchanger, collarAmount);
        vm.startPrank(exchanger);
        collar.approve(address(psm), collarAmount);
        psm.swapIn(exchanger, amount);
        vm.stopPrank();
    }
}
