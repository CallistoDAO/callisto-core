# Emergency Redemption Flow

The Callisto vault's `emergencyRedeem` function burns `shares` of the caller, withdrawing a corresponding amount of debt tokens from the strategy.

This function is designed for an emergency situation where the vault's position is liquidated in Olympus Cooler V2.

Emits an `EmergencyRedeemed` event if redeemed.

Requirements:

- `shares` should not be zero (`nonzeroValue` modifier)
- The caller should own `shares` (ERC20 burn will revert if insufficient)
- Withdrawals must not be paused (`whenWithdrawalNotPaused` modifier)
- The vault must have been liquidated in Olympus Cooler V2
- The strategy must have sufficient funds for the proportional redemption

`shares` specifies the number of cOHM (shares) to burn.

The function returns the amount of debt tokens transferred to the caller for `shares` if redeemed. Otherwise, returns 0.

Of course, Callisto provides various measures to avoid liquidation, including:

- Acquiring and holding cOHM (shares) by the protocol through convertible deposits.
- Regular automatic debt repayment to keep it at the origination LTV when processing batched deposits (`_processPendingDeposits`). Typically invoked by the Callisto Heart module by auctioning CALL rewards.
- A dedicated `repayCoolerDebt` function to allow proactive debt repayment if new deposits slow.

Under normal conditions, each cOHM share is fully backed by OHM, and users can redeem cOHM for OHM at any time.

If the vault is liquidated in Olympus Cooler V2, this no longer holds since the gOHM collateral is lost and OHM cannot be returned.

Redemption steps in case of liquidation:

1. First, try to withdraw using `withdraw` (or `redeem`). There may still be available OHM in the vault to redeem `shares`, for example:

   - Pending OHM deposits not yet processed (`pendingOHMDeposits`)
   - Additional OHM transferred to the vault to compensate for lost collateral

2. Fallback to emergency redemption. If a standard withdrawal is unavailable, holders may call `emergencyRedeem`. This allows the user to claim a proportional amount of debt tokens based on their cOHM balance relative to `totalSupply`:

   ```solidity
   debtAmount = shares * totalAssetsInvested / totalSupply
   ```

   The strategy divests this amount directly to the user.

Caution 1. The dollar value of redeemed debt tokens is typically lower than the equivalent OHM amount, as the vault only provides debt tokens corresponding to a portion of OHM deposits. This is due to the vault's design: each OHM deposit is exchanged for gOHM and used to borrow debt tokens at a conservative LTV (~95% of backing value), so the debt token amount is less than the full market value of OHM.

Caution 2. In an emergency, available funds in the strategy may be insufficient for all cOHM holders. Only those who redeem early may successfully claim debt tokens. Latecomers may receive nothing if the strategy is fully divested.

## Implementation Details

The `emergencyRedeem` function:

1. Checks if the vault position is liquidated using `_isVaultPositionLiquidated()`
2. Calculates proportional debt amount: `shares * totalAssetsInvested / totalSupply`
3. Burns the user's cOHM shares
4. Calls `strategy.divest(debtAmount, msg.sender)` to transfer debt tokens directly
5. Emits `EmergencyRedeemed(msg.sender, debtAmount)` event

Liquidation is detected when:

- `totalAssetsInvested > 1` (strategy has funds)
- `gOHMCollateral == 0` (no collateral in Cooler V2)

The `> 1` threshold accounts for potential rounding artifacts from debt token migrations.
