// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

/**
 * @title IStabilityPool
 * @notice Interface for the Stability Pool contract that manages user deposits and offsets debt assets
 *         during liquidations
 */
interface IStabilityPool {
    /**
     * @notice Emitted when a user's deposit is updated
     * @param depositor The address of the depositor
     * @param newDeposit The new deposit amount
     */
    event DepositUpdated(address indexed depositor, uint256 indexed newDeposit);

    /**
     * @notice Emitted when gains are claimed by an account
     * @param account The address claiming gains
     * @param amounts Array of gain amounts claimed
     */
    event GainsClaimed(address indexed account, uint256[] amounts);

    /**
     * @notice Emitted when total deposits in the pool increase
     * @param amount The amount by which deposits increased
     */
    event TotalDepositsIncreased(uint256 indexed amount);

    /**
     * @notice Emitted when total deposits in the pool decrease
     * @param amount The amount by which deposits decreased
     */
    event TotalDepositsDecreased(uint256 indexed amount);

    error ZeroValue();

    /**
     * @notice Deposits exactly `amount` of underlying tokens from the caller and accrues the collateral gains.
     *
     * Does not require pre-approval of the stability pool with the pool's underlying asset token.
     * `amount` should not be zero.
     * @param amount The amount of tokens to deposit
     */
    function deposit(uint256 amount) external;

    /**
     * @notice Withdraws underlying tokens to the caller and accrues the collateral gains.
     *
     * If `amount` is greater than the caller's compounded deposit, withdraws the entire deposit.
     * @param amount The amount of tokens to withdraw
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Claims collateral gains for the specified receiver
     * @param receiver The address to receive the claimed gains
     * @param assetPositions Array of asset positions to claim gains from
     */
    function claimGains(address receiver, uint256[] calldata assetPositions) external;

    /**
     * @notice Returns the total amount of the underlying asset on the balance of the stability pool.
     *
     * @dev Changed on deposit, withdrawal and liquidation (offset).
     * @return The total deposits in the stability pool
     */
    function totalDeposits() external view returns (uint256);

    /**
     * @notice Returns the `account`'s compounded deposit: the maximum amount of the underlying asset that can be
     * withdrawn by `account` through `withdraw`.
     * @param account The account to calculate the compounded deposit for
     * @return The compounded deposit amount
     */
    function calcCompoundedDeposit(address account) external view returns (uint256);

    /**
     * @notice Calculates collateral gains and debt token interest earned by the `account`.
     *
     * @dev Collateral gains and debt token interest are calculated since `account`'s last snapshots were taken.
     * Given by the formula:
     *     E = d0 * (S - S(0))/P(0)
     * where S(0) and P(0) are the `account`'s snapshots of the sum S and product P, respectively.
     * d0 is the last recorded deposit value.
     * @param account The account to calculate gains for
     * @return gains Array of gain amounts for different collateral types
     */
    function getGainsOf(address account) external view returns (uint256[] memory gains);

    /**
     * @notice Returns the array of all assets in the stability pool.
     * @return The array of asset addresses.
     */
    function getAssets() external view returns (address[] memory);

    /**
     * @notice Setting the `psmStrategy` to the `address(0)` disables integration with the PSM strategy.
     * @param newPSMStrategy The address of the new PSM strategy.
     */
    function setPSMStrategy(address newPSMStrategy) external;
}
