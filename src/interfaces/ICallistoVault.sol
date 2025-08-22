// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import { IDLGTEv1 } from "./IDLGTEv1.sol";

/**
 * @title ICallistoVault
 * @author Callisto Protocol
 * @notice Interface for the Callisto Vault
 */
interface ICallistoVault {
    /**
     * @notice Modes for obtaining gOHM from OHM.
     *
     * - `ZeroWarmup`: Exchange OHM for gOHM directly (default).
     * - `ActiveWarmup`: Stake OHM, then claim gOHM after warm-up.
     * - `Swap`: Use an external swapper if staking is unavailable (e.g., warm-up period active).
     */
    enum OHMToGOHMMode {
        ZeroWarmup,
        ActiveWarmup,
        Swap
    }

    /**
     * @notice Emitted when pending OHM deposits are processed and converted to gOHM
     * @param ohmAmount The amount of OHM that was processed
     */
    event DepositsHandled(uint256 indexed ohmAmount);

    /**
     * @notice Emitted when profit is withdrawn to the treasury
     * @param amount The amount of profit withdrawn
     */
    event TreasuryProfitWithdrawn(uint256 indexed amount);

    /**
     * @notice Emitted when excess gOHM is withdrawn from the vault
     * @param to The address receiving the excess gOHM
     * @param gOHMAmount The amount of gOHM withdrawn
     */
    event GOHMExcessWithdrawn(address indexed to, uint256 indexed gOHMAmount);

    /**
     * @notice Emitted when Cooler debt is repaid on behalf of the vault
     * @param account The account that repaid the debt
     * @param debtAmount The amount of debt tokens used for repayment
     */
    event CoolerDebtRepaid(address indexed account, uint256 indexed debtAmount);

    /**
     * @notice Emitted when a reimbursement claim is added for an account
     * @param account The account eligible for reimbursement
     * @param amount The amount of the reimbursement claim (in wad format)
     * @param callerContribution The debt token amount contributed by the caller
     */
    event ReimbursementClaimAdded(address indexed account, uint256 indexed amount, uint256 indexed callerContribution);

    /**
     * @notice Emitted when a reimbursement claim is reduced or removed for an account
     * @param account The account whose reimbursement claim was modified
     * @param removedAmount The amount of reimbursement claim that was removed (in wad format)
     * @param debt The debt token amount that corresponds to the removed claim
     */
    event ReimbursementClaimRemoved(address indexed account, uint256 indexed removedAmount, uint256 indexed debt);

    /**
     * @notice Emitted when the minimum deposit amount is updated
     * @param minDeposit The new minimum deposit amount
     */
    event MinDepositSet(uint256 indexed minDeposit);

    /**
     * @notice Emitted when the OHM exchange mode is updated
     * @param mode The new OHM exchange mode
     * @param swapper The swapper address (address(0) for non-Swap modes)
     */
    event OHMExchangeModeSet(OHMToGOHMMode mode, address indexed swapper);

    /**
     * @notice Emitted when OHM staking is cancelled
     * @param ohmAmount The amount of OHM that was unstaked
     */
    event OHMStakeCancelled(uint256 indexed ohmAmount);

    /**
     * @notice Emitted when deposit pause status changes
     * @param paused True if deposits are now paused, false if unpaused
     */
    event DepositPauseStatusChanged(bool indexed paused);

    /**
     * @notice Emitted when withdrawal pause status changes
     * @param paused True if withdrawals are now paused, false if unpaused
     */
    event WithdrawalPauseStatusChanged(bool indexed paused);

    /**
     * @notice Emitted when the debt token is updated to a new token
     * @param newDebtToken The address of the new debt token
     * @param debtConverterFromWad The debt converter from wad
     * @param debtConverterToWad The debt converter to wad
     */
    event DebtTokenUpdated(
        address indexed newDebtToken, address indexed debtConverterFromWad, address indexed debtConverterToWad
    );

    /**
     * @notice Emitted when emergency redemption is performed
     * @param to The address receiving the redeemed tokens
     * @param amount The amount of tokens redeemed
     */
    event EmergencyRedeemed(address indexed to, uint256 indexed amount);

    /**
     * @notice Emitted when pending OHM deposits amount changes
     * @param delta The change in pending OHM deposits (positive for increase, negative for decrease)
     * @param newAmount The new total amount of pending OHM deposits
     */
    event PendingOHMDepositsChanged(int256 indexed delta, uint256 indexed newAmount);

    /**
     * @notice Emitted when pending OHM warmup staking amount changes
     * @param delta The change in pending OHM warmup staking (positive for increase, negative for decrease)
     */
    event PendingOHMWarmupStakingChanged(int256 indexed delta);

    /**
     * @notice Emitted when the debt token migrator address is updated
     * @param oldMigrator The previous migrator address
     * @param newMigrator The new migrator address
     */
    event DebtTokenMigratorSet(address indexed oldMigrator, address indexed newMigrator);

    /// @notice Thrown when a zero address is provided where a valid address is expected
    error ZeroAddress();

    /**
     * @notice Thrown when an unexpected token address is provided instead of the expected debt token
     * @param debtTokenAddress The unexpected token address that was provided
     */
    error DebtTokenExpected(address debtTokenAddress);

    /// @notice Thrown when a zero value is provided where a non-zero value is expected
    error ZeroValue();

    /// @notice Thrown when the debt token migrator's cooler address doesn't match the vault's cooler address
    error MismatchedCoolerAddress();

    /**
     * @notice Thrown when the deposit amount is less than the minimum required deposit
     * @param assets The amount being deposited
     * @param minDeposit The minimum deposit amount required
     */
    error AmountLessThanMinDeposit(uint256 assets, uint256 minDeposit);

    /**
     * @notice Thrown when there is insufficient gOHM available for an operation
     * @param missingAmount The amount of gOHM that is missing to complete the operation
     */
    error NotEnoughGOHM(uint256 missingAmount);

    /**
     * @notice Thrown when trying to process more OHM than is available in pending deposits
     * @param ohmAmount The amount of OHM requested to process
     * @param pendingOHMDeposits The amount of OHM available in pending deposits
     */
    error AmountGreaterThanPendingOHMDeposits(uint256 ohmAmount, uint256 pendingOHMDeposits);

    /**
     * @notice Thrown when attempting to withdraw more profit than is available
     * @param totalProfit The total profit available for withdrawal
     */
    error ProfitWithdrawalExceedsTotalProfit(uint256 totalProfit);

    /// @notice Thrown when there is pending OHM warm-up staking that prevents mode changes
    error PendingWarmupStakingExists();

    /**
     * @notice Thrown when the warmup period is invalid for the requested exchange mode operation
     * @param period The current warmup period that prevents the operation
     */
    error InvalidWarmupPeriod(uint256 period);

    /// @notice Thrown when attempting to set an exchange mode that is already active
    error OHMToGOHMModeUnchanged();

    /// @notice Thrown when zero OHM is provided where a positive amount is expected
    error ZeroOHM();

    /**
     * @notice Thrown when the repayment amount exceeds the outstanding debt
     * @param excess The amount by which the repayment exceeds the debt
     */
    error RepaymentAmountExceedsDebt(uint256 excess);

    /// @notice Thrown when there is no excess gOHM available for withdrawal
    error NoExcessGOHM();

    /**
     * @notice Thrown when an account has no reimbursement available to claim
     * @param account The account that attempted to claim reimbursement
     */
    error NoReimbursementFor(address account);

    /// @notice Thrown when trying to change pause status but it's already in that state
    error PauseStatusUnchanged();

    /// @notice Thrown when withdrawals are paused and a withdrawal operation is attempted
    error WithdrawalsPaused();

    /// @notice Thrown when deposits are paused and a deposit operation is attempted
    error DepositsPaused();

    /**
     * @notice Thrown when a function can only be called by the debt token migrator
     * @param migrator The address of the authorized debt token migrator
     */
    error OnlyDebtTokenMigrator(address migrator);

    /// @notice Thrown when OHM token is expected but a different token is provided
    error OHMExpected();

    /// @notice Thrown when no debt token migrator is set but migration is attempted
    error MigratorNotSet();

    /// @notice Thrown when the provided debt token doesn't match the expected debt token
    error MismatchedDebtTokenAddress();

    /**
     * @notice Thrown when the partial amount exceeds the available reimbursement claim
     * @param partialAmount The partial amount requested
     * @param availableClaim The available reimbursement claim amount
     */
    error PartialAmountExceedsAvailableClaim(uint256 partialAmount, uint256 availableClaim);

    /**
     * @notice Allows to apply delegations of gOHM collateral on behalf of the vault in Olympus Cooler Loans V2
     * @dev This function enables the Callisto CDP market to delegate the vault's gOHM collateral that corresponds to
     * account's cOHM collateral deposit.
     *
     * @param requests Array of delegation requests to process
     * @return totalDelegated Total amount of gOHM delegated
     * @return totalUndelegated Total amount of gOHM undelegated
     * @return undelegatedBalance Remaining undelegated gOHM balance
     */
    function applyDelegations(IDLGTEv1.DelegationRequest[] calldata requests)
        external
        returns (uint256 totalDelegated, uint256 totalUndelegated, uint256 undelegatedBalance);

    /**
     * @notice Deposits OHM `assets` and mints cOHM shares 1:1.
     *
     * @param assets Amount of OHM to deposit. (9 decimals).
     * @param receiver Address to receive cOHM.
     * @return Amount of cOHM minted to `receiver`. (18 decimals).
     */
    function deposit(uint256 assets, address receiver) external returns (uint256);

    /**
     * @notice Mints cOHM `shares` and deposits OHM 1:1.
     *
     * @param shares Amount of cOHM to mint. (18 decimals).
     * @param receiver Address to receive cOHM.
     * @return Amount of OHM deposited by the caller. (9 decimals).
     */
    function mint(uint256 shares, address receiver) external returns (uint256);

    /**
     * @notice Withdraws `assets` of OHM from the vault, burning corresponding amount of cOHM.
     *
     * @param assets Amount of OHM to withdraw. (9 decimals).
     * @param receiver Address to receive OHM.
     * @param owner Address burning cOHM.
     * @return Amount of shares burned. (18 decimals).
     */
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);

    /**
     * @notice Redeems cOHM for OHM.
     *
     * @param shares Amount of cOHM to redeem. (18 decimals).
     * @param receiver Address to receive OHM.
     * @param owner Address burning cOHM.
     * @return Amount of OHM withdrawn. (9 decimals).
     */
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);

    /**
     * @notice Burns cOHM and redeems proportional amount of `debtToken`.
     *
     * This function is only available if the Callisto vault position has been liquidated in Olympus Cooler V2.
     * It provides a last-resort exit for cOHM holders to claim debt tokens from the strategy based on their share of
     * the total supply.
     *
     * @param shares Amount of cOHM to redeem. (18 decimals).
     * @return debtAmount Amount of `debtToken` transferred, or 0 if not available.
     */
    function emergencyRedeem(uint256 shares) external returns (uint256 debtAmount);

    /**
     * @notice Repays vault's debt to Olympus Cooler V2 to restore max origination LTV.
     * Withdraws funds from the strategy (up to available), transfers the rest from the caller, and records
     * a reimbursement to be claimed by the caller.
     * @param amount Amount of `debtToken` to repay.
     */
    function repayCoolerDebt(uint256 amount) external;

    /**
     * @notice Allows an account to claim reimbursement for `debtToken` previously supplied to repay vault debt
     * with `repayCoolerDebt`, or for covering withdrawals during emergencies
     * when the vault strategy lacked sufficient funds.
     *
     * @param account Address claiming reimbursement.
     */
    function claimReimbursement(address account) external;

    /**
     * @notice Allows an account to claim a partial reimbursement for `debtToken` previously supplied to repay
     * vault debt with `repayCoolerDebt`, or for covering withdrawals during emergencies
     * when the vault strategy lacked sufficient funds.
     *
     * @param account Address claiming reimbursement.
     * @param partialAmount The partial amount to claim in debt token decimals.
     */
    function claimReimbursementPartial(address account, uint256 partialAmount) external;

    /**
     * @notice Processes pending OHM deposits: converts to gOHM, borrows `debtToken`, deposits into the strategy
     * @dev Assumed to be called:
     * 1. Manually before the next `_executeByHeart` to increase the gOHM collateral in Olympus Cooler V2 so that more
     *    voting power for gOHM can be delegated in the Callisto CDP.
     * 2. When `OLYMPUS_STAKING` does not exchange OHM to gOHM without a warm-up period.
     * @param ohmAmount The amount of OHM to process
     * @param swapperData Data for external swapper if needed
     */
    function processPendingDeposits(uint256 ohmAmount, bytes[] memory swapperData) external;

    /**
     * @notice Returns the total amount of underlying assets (OHM) held by the vault.
     *
     * @dev This overrides the standard ERC4626 implementation to use a cached value
     * instead of calculating the balance dynamically. This is necessary because:
     * - OHM deposits are processed asynchronously via `processPendingDeposits()`
     * - The vault's OHM balance doesn't directly reflect the total assets until processing
     * - Provides consistent totalAssets() value regardless of pending deposit processing state
     *
     * @return The total assets in OHM (9 decimals)
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Returns the total profit available to be swept to the treasury.
     * @return The total profit amount in debt tokens.
     */
    function totalProfit() external view returns (uint256);

    /**
     * @notice Withdraws profit from the strategy to the treasury.
     * @dev Only callable by addresses with admin or manager roles.
     * @param amount Amount of profit to sweep. Use type(uint256).max to sweep all available profit.
     */
    function sweepProfit(uint256 amount) external;

    /**
     * @notice Returns the excess gOHM available for withdrawal.
     * @return The excess gOHM amount.
     */
    function excessGOHM() external view returns (uint256);

    /**
     * @notice Calculates the debt amount required to be repaid to return to max origination LTV.
     * @dev This function calculates the debt repayment needed to restore the vault position
     * to the maximum origination loan-to-value ratio without withdrawing any gOHM collateral.
     * It uses the current vault state and assumes no gOHM withdrawal (gOHMAmount = 0).
     *
     * @return wadDebt The debt amount to repay in wad format (18 decimals)
     * @return debtAmount The debt amount to repay in debt token decimals
     */
    function calcDebtToRepay() external view returns (uint128 wadDebt, uint256 debtAmount);

    /**
     * @notice Sets the pause status for deposits
     * @param pause True to pause deposits, false to unpause
     */
    function setDepositsPause(bool pause) external;

    /**
     * @notice Sets the pause status for withdrawals
     * @param pause True to pause withdrawals, false to unpause
     */
    function setWithdrawalsPause(bool pause) external;

    /// @notice Sets the OHM exchange mode to ZeroWarmup (direct staking)
    function setZeroWarmupMode() external;

    /// @notice Sets the OHM exchange mode to ActiveWarmup
    function setActiveWarmupMode() external;

    /**
     * @notice Sets the OHM exchange mode to Swap and configures the swapper
     * @param swapper The address of the OHM swapper contract
     */
    function setSwapMode(address swapper) external;

    /**
     * @notice Sets the minimum deposit amount for the vault
     * @dev Only callable by addresses with admin or manager roles. The minimum deposit
     * must be large enough to prevent mint/redeem inconsistencies and meet Cooler V2 requirements.
     * @param minOhmAmount The new minimum deposit amount in OHM (9 decimals)
     */
    function setMinDeposit(uint256 minOhmAmount) external;

    /**
     * @notice Executes pending OHM deposits processing when warmup period is zero
     * @dev Only callable by addresses with HEART_ROLE. Processes all pending OHM deposits
     * if the current mode is ZeroWarmup, otherwise does nothing.
     */
    function execute() external;

    /**
     * @notice Withdraws excess gOHM from the vault to the specified address
     * @dev Only callable by addresses with admin or manager roles. Withdraws a specified amount of
     * excess gOHM after repaying necessary debt to maintain vault health.
     * @param gOHMAmount The amount of excess gOHM to withdraw
     * @param to The address to receive the withdrawn gOHM
     */
    function withdrawExcessGOHM(uint256 gOHMAmount, address to) external;

    /**
     * @notice Cancels pending OHM staking and returns OHM to pending deposits
     * @dev Only callable by addresses with admin or manager roles. Forfeits any pending
     * staked OHM and returns it to the pending deposits pool for reprocessing.
     */
    function cancelOHMStake() external;

    /**
     * @notice Sweeps specified tokens from the vault to a destination address
     * @dev Only callable by addresses with admin or manager roles. For OHM tokens,
     * only sweeps amounts above pending deposits. For other tokens, sweeps the full amount.
     * @param token The address of the token to sweep
     * @param to The address to receive the swept tokens
     * @param value The amount of tokens to sweep
     */
    function sweepTokens(address token, address to, uint256 value) external;
}
