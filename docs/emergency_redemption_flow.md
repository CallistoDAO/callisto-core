# Emergency Redemption Flow

The Callisto vault's `emergencyRedeem` function burns `cOHMAmount` of the caller, withdrawing a corresponding amount of USDS.

This function is designed for an emergency situation where the vault is liquidated in Olympus Cooler.

Emits an `EmergencyRedeemed` event if redeemed.

Requirements:

- `cOHMAmount` should not be zero.
- The caller should own `cOHMAmount`.
- The vault must have enough sUSDS in the PSM to redeem `cOHMAmount`.
- The vault must have been liquidated in Olympus Cooler.

`cOHMAmount` specifies the number of cOHM (shares) to burn.

The function returns the amount of USDS transferred to the caller for `cOHMAmount` if redeemed. Otherwise, returns 0.

Of course, Callisto provides various measures to avoid liquidation, including:

- Acquiring and holding cOHM (shares) by the protocol through convertible deposits.
- Regular automatic debt repayment to keep it at the origination LTV when processing batched deposits (`_processPendingDeposits`). Typically invoked by th Callisto Heart module by auctioning CALL rewards.
- A dedicated `repayCoolerDebt` function to allow proactive debt repayment if new deposits slow.

Under normal conditions, each cOHM share is fully backed by OHM, and users can redeem cOHM for OHM at any time.

If the vault is liquidated in Olympus Cooler, this no longer holds since the gOHM collateral is lost and OHM cannot be returned.

Redemption steps in case of liquidation:

1. First, try to withdraw using `withdraw` (or `redeem`). There may still be available OHM in the vault to redeem `cOHMAmount`, for example:

   - Pending OHM deposits not yet processed.
   - Additional OHM transferred to teh vault to compensate for lost collateral.

2. Fallback to emergency redemption. If a standard withdrawal is unavailable, holders may call `emergencyRedeem`. This allows the user to claim a proportional amount of USDS based on their cOHM balance relative to `totalSupply`.

Caution 1. The dollar value of redeemed USDS is typically lower than the equivalent OHM amount, as the vault only provides USDS corresponding to a portion of OHM deposits. This is due to the vault's design: each OHM deposit is exchanged for gOHM and used to borrow USDS at a conservative LTV, so the USDS amount is less than the full market value of OHM.

Caution 2. In an emergency, available USDS in the PSM may be insufficient for all cOHM holders. Only those who redeem early may successfully claim USDS. Latecomers may receive nothing.
