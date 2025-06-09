// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import { IERC20Metadata } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC20Metadata.sol";
import { IERC4626 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";
import { IERC20, IERC4626 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";
import { IDLGTEv1, IGOHM, IOlympusStaking, Math, SafeCast } from "../../src/policies/vault/CallistoVaultLogic.sol";
import { Ethereum } from "../test-common/ForkConstants.sol";
import { IMonoCoolerExtended } from "../test-common/interfaces/IMonoCoolerExtended.sol";
import { IOlympusHeart } from "../test-common/interfaces/IOlympusHeart.sol";
import { Test } from "forge-std/Test.sol";

contract OlympusBehaviorResearchEthereumTests is Test {
    using Math for uint256;
    using Math for uint128;
    using SafeCast for uint256;
    using SafeCast for int256;

    IGOHM gOHMToken;
    IMonoCoolerExtended olympusCooler;
    IERC20 usdsToken;
    IERC4626 sUSDSVault;

    uint256 ohmDecimals;

    function setUp() external {
        vm.createSelectFork(vm.envOr("ETHEREUM_RPC_URL", string("https://eth.blockrazor.xyz")));

        gOHMToken = IGOHM(Ethereum.GOHM);
        olympusCooler = IMonoCoolerExtended(Ethereum.OLYMPUS_COOLER);
        usdsToken = IERC20(Ethereum.USDS);
        sUSDSVault = IERC4626(Ethereum.SUSDS);

        ohmDecimals = 10 ** IERC20Metadata(Ethereum.OHM).decimals();
    }

    function testUserDepositsAndWithdrawsAllGOHMAtDifferentIntervals() external {
        uint256 snapshotID;

        IGOHM gOHM = gOHMToken;
        IMonoCoolerExtended ocooler = olympusCooler;
        IERC20 usds = usdsToken;
        IERC4626 sUSDS = sUSDSVault;

        uint256 usdsReceived;
        uint256 sUSDSReceived;
        uint128 usdsToRepay;
        uint256 maxWithdrawal;
        uint256 usdsToWithdraw;
        uint256 sUSDSBurnt;
        uint128 usdsRepaid;
        uint128 gOHMWithdrawn;

        // Intervals to be tested.
        uint256 intervalNum = 6;
        uint256[] memory intervals = new uint256[](intervalNum);
        // intervals[0] = 0 seconds;
        intervals[1] = 1 seconds;
        intervals[2] = 7 days;
        intervals[3] = 30 days;
        intervals[4] = 365 days;
        intervals[5] = 365 days * 11;

        // Calculate gOHM amount to be deposited in Olympus Cooler.
        uint256 ohmAmount = 1000 * ohmDecimals;
        uint256 gOHMAmount = gOHM.balanceTo(ohmAmount);
        // Imitate gOHM getting from Olympus Staking.
        vm.prank(Ethereum.GOHM_HOLDER);
        gOHM.transfer(address(this), gOHMAmount);

        for (uint256 i = 0; i < intervalNum; ++i) {
            snapshotID = vm.snapshotState();

            // 1. Deposit.
            // Add collateral to the cooler.
            address ocoolerAddr = address(ocooler);
            gOHM.approve(ocoolerAddr, gOHMAmount);
            ocooler.addCollateral({
                collateralAmount: gOHMAmount.toUint128(),
                onBehalfOf: address(this),
                delegationRequests: new IDLGTEv1.DelegationRequest[](0)
            });
            assertEq(gOHM.balanceOf(address(this)), 0);
            // Borrow USDS from the cooler.
            usdsReceived = ocooler.borrow({
                borrowAmountInWad: type(uint128).max, // Borrow up to `_globalStateRW().maxOriginationLtv` of Cooler.
                onBehalfOf: address(this),
                recipient: address(this)
            });
            assertGt(usds.balanceOf(address(this)), 0);

            // Deposit USDS to Sky Protocol.
            usds.approve(address(sUSDS), usdsReceived);
            sUSDSReceived = sUSDS.deposit(usdsReceived, address(this));

            // Wait for accumulating sUSDS profits and Olympus Cooler debt.
            if (intervals[i] != 0) skip(intervals[i]);

            // 2. Withdrawal.
            // Calculate the amount of USDS to be repaid to withdraw the entire gOHM collateral.
            usdsToRepay = uint128(
                -ocooler.debtDeltaForMaxOriginationLtv({
                    account: address(this),
                    collateralDelta: -(gOHMAmount.toInt256().toInt128())
                })
            );
            assertGe(usdsToRepay, usdsReceived);

            // Withdraw all USDS from Sky Protocol.
            maxWithdrawal = sUSDS.maxWithdraw(address(this));
            usdsToWithdraw = usdsToRepay > maxWithdrawal ? maxWithdrawal : usdsToRepay;
            assertEq(usdsToWithdraw, i != 0 ? usdsToRepay : usdsToRepay - 1); // `- 1` because of sUSDS rounding.
            sUSDSBurnt = sUSDS.withdraw({ assets: usdsToWithdraw, receiver: address(this), owner: address(this) });
            assertLe(sUSDSBurnt, sUSDSReceived);

            // Check that no time skip in this iteration.
            if (intervals[i] == 0) {
                // Add 1 wei of USDS to withdraw the entire gOHM collateral because of sUSDS rounding.
                vm.prank(Ethereum.USDS_HOLDER);
                usds.transfer(address(this), 1);
            }

            // Repay the USDS debt.
            usds.approve(ocoolerAddr, usdsToRepay);
            usdsRepaid = ocooler.repay({ repayAmountInWad: usdsToRepay, onBehalfOf: address(this) });
            assertEq(usdsRepaid, usdsToRepay);
            assertEq(usds.balanceOf(address(this)), 0);

            // Withdraw gOHM (the collateral) from Olympus Cooler.
            gOHMWithdrawn = ocooler.withdrawCollateral({
                collateralAmount: gOHMAmount.toUint128(),
                onBehalfOf: address(this),
                recipient: address(this),
                delegationRequests: new IDLGTEv1.DelegationRequest[](0)
            });
            assertEq(gOHMWithdrawn, gOHMAmount);
            assertEq(gOHM.balanceOf(address(this)), gOHMAmount);

            vm.revertToState(snapshotID);
        }
    }

    // TODO: `testGOHMOwnerAppliesDelegations()`.
}

contract OlympusOHMExchangeEthereumTests is Test {
    IERC20Metadata ohm;
    IGOHM gOHM;
    IOlympusStaking olympusStaking;
    IOlympusHeart olympusHeart;

    uint256 ohmDecimals;
    uint256 gOHMDecimals;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETHEREUM_RPC_URL", string("https://eth.blockrazor.xyz")));
        // 22245271

        ohm = IERC20Metadata(Ethereum.OHM);
        ohmDecimals = 10 ** ohm.decimals();
        gOHM = IGOHM(Ethereum.GOHM);
        gOHMDecimals = 10 ** gOHM.decimals();
        olympusStaking = IOlympusStaking(Ethereum.OLYMPUS_STAKING);

        /* Update the price feed for Olympus Staking for the Tenderly fork to prevent the failure because of
         * `Distributor_NotUnlocked`.
         */
        IOlympusHeart oheart = IOlympusHeart(Ethereum.OLYMPUS_HEART);
        olympusHeart = oheart;
        vm.warp(oheart.lastBeat() + 8 hours /* Heartbeat frequency */ );
        oheart.beat();
    }

    function _toOHM(uint256 value) private view returns (uint256) {
        return value * ohmDecimals;
    }

    function _toGOHM(uint256 value) private view returns (uint256) {
        return value * gOHMDecimals;
    }

    function testUserExchangesOHMToGOHM() external {
        uint256 ohmAmount = _toOHM(100);
        vm.prank(Ethereum.OHM_HOLDER);
        ohm.transfer(address(this), ohmAmount);

        uint256 expectedGOHM = gOHM.balanceTo(ohmAmount);

        // Exchange.
        ohm.approve(address(olympusStaking), ohmAmount);
        olympusStaking.stake({ to: address(this), amount: ohmAmount, rebasing: false, claim: true });

        assertEq(ohm.balanceOf(address(this)), 0);
        assertEq(gOHM.balanceOf(address(this)), expectedGOHM);
    }

    function testUserExchangesGOHMToOHM() external {
        uint256 gOHMAmount = _toGOHM(10);
        vm.prank(Ethereum.GOHM_HOLDER);
        gOHM.transfer(address(this), gOHMAmount);

        uint256 expectedOHM = gOHM.balanceFrom(gOHMAmount);

        // Exchange.
        gOHM.approve(address(olympusStaking), gOHMAmount);
        olympusStaking.unstake({ to: address(this), amount: gOHMAmount, trigger: false, rebasing: false });

        assertEq(ohm.balanceOf(address(this)), expectedOHM);
        assertEq(gOHM.balanceOf(address(this)), 0);
    }
}
