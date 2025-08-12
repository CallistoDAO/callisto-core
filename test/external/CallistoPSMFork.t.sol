// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import { CallistoPSM } from "../../src/external/CallistoPSM.sol";
import { CallistoVaultTestForkBase, SafeCast } from "../test-common/CallistoVaultTestForkBase.sol";

contract CallistoPSMForkTests is CallistoVaultTestForkBase {
    using SafeCast for *;

    function setUp() public virtual override {
        vm.createSelectFork("mainnet", 23_016_996);
        super.setUp();
    }

    function test_callistoPSMFork_removeLiquidity(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);

        // Deposit to vault which will add liquidity to PSM
        _depositToVaultExt(user, assets);

        // Get the actual sUSDS balance and shares after deposit
        uint256 susdsBalance = SUSDS.balanceOf(address(psm));
        uint256 shares = psm.suppliedByLP();

        assertGt(shares, 0, "PSM should have liquidity from LP");
        assertGt(susdsBalance, 0, "PSM should have sUSDS balance");

        // Test that non-LP cannot remove liquidity
        vm.expectRevert(CallistoPSM.OnlyLP.selector);
        psm.removeLiquidity(shares, user2);

        // Test successful liquidity removal by LP (vault strategy)
        vm.prank(address(vaultStrategy));
        vm.expectEmit(true, true, true, true, address(psm));
        emit CallistoPSM.LiquidityRemoved(shares, 0);
        psm.removeLiquidity(shares, user2);

        // Verify recipient received sUSDS tokens
        assertEq(SUSDS.balanceOf(user2), susdsBalance, "user2 should receive sUSDS tokens");

        // Verify PSM state is updated
        assertEq(psm.suppliedByLP(), 0, "PSM supplied by LP should be reset to 0");
    }

    function test_callistoPSMFork_removeLiquidityAsAssets(uint256 assets) external {
        assets = bound(assets, MIN_DEPOSIT + 1, MAX_DEPOSIT);

        // Deposit to vault which will add liquidity to PSM
        _depositToVaultExt(user, assets);

        // Get the actual sUSDS balance and shares after deposit
        uint256 susdsBalance = SUSDS.balanceOf(address(psm));
        uint256 shares = psm.suppliedByLP();

        assertGt(shares, 0, "PSM should have liquidity from LP");
        assertGt(susdsBalance, 0, "PSM should have sUSDS balance");

        // Calculate the expected assets available from the sUSDS balance
        uint256 maxWithdrawable = SUSDS.maxWithdraw(address(psm));

        // Test that non-LP cannot remove liquidity as assets
        vm.expectRevert(CallistoPSM.OnlyLP.selector);
        psm.removeLiquidityAsAssets(maxWithdrawable, user2);

        // Test successful liquidity removal as assets by LP (vault strategy)
        vm.prank(address(vaultStrategy));
        uint256 assetsReturned = psm.removeLiquidityAsAssets(maxWithdrawable, user2);

        // The returned value should be the actual shares that were withdrawn
        assertGt(assetsReturned, 0, "Should return withdrawn shares amount");

        // Verify recipient received USDS tokens (assets)
        assertEq(USDS.balanceOf(user2), maxWithdrawable, "user2 should receive USDS tokens");

        // Verify PSM state is updated - should be close to 0 (allowing for small rounding)
        assertLt(psm.suppliedByLP(), 1e15, "PSM supplied by LP should be close to 0");
    }
}
