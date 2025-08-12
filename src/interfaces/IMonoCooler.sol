// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import { ICoolerTreasuryBorrower } from "./ICoolerTreasuryBorrower.sol";
import { IDLGTEv1 } from "./IDLGTEv1.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// [Source](https://github.com/OlympusDAO/olympus-v3/blob/a307c4e1dbdadfb1c478fcfcdcb7fbc5e3b5746d/src/policies/interfaces/cooler/IMonoCooler.sol).
interface IMonoCooler {
    event BorrowPausedSet(bool isPaused);
    event LiquidationsPausedSet(bool isPaused);
    event InterestRateSet(uint96 interestRateWad);
    event LtvOracleSet(address indexed oracle);
    event TreasuryBorrowerSet(address indexed treasuryBorrower);
    event CollateralAdded(address indexed caller, address indexed onBehalfOf, uint128 collateralAmount);
    event CollateralWithdrawn(
        address indexed caller, address indexed onBehalfOf, address indexed recipient, uint128 collateralAmount
    );
    event Borrow(address indexed caller, address indexed onBehalfOf, address indexed recipient, uint128 amount);
    event Repay(address indexed caller, address indexed onBehalfOf, uint128 repayAmount);
    event Liquidated(
        address indexed caller, address indexed account, uint128 collateralSeized, uint128 debtWiped, uint128 incentives
    );
    event AuthorizationSet(
        address indexed caller, address indexed account, address indexed authorized, uint96 authorizationDeadline
    );

    error ExceededMaxOriginationLtv(uint256 newLtv, uint256 maxOriginationLtv);
    error ExceededCollateralBalance();
    error MinDebtNotMet(uint256 minRequired, uint256 current);
    error InvalidAddress();
    error InvalidParam();
    error ExpectedNonZero();
    error Paused();
    error CannotLiquidate();
    error InvalidDelegationRequests();
    error ExceededPreviousLtv(uint256 oldLtv, uint256 newLtv);
    error InvalidCollateralDelta();
    error ExpiredSignature(uint256 deadline);
    error InvalidNonce(uint256 deadline);
    error InvalidSigner(address signer, address owner);
    error UnauthorizedOnBehalfOf();

    /**
     * @notice Deposit gOHM as collateral
     * @param collateralAmount The amount to deposit to 18 decimal places
     *    - MUST be greater than zero
     * @param onBehalfOf A caller can add collateral on behalf of themselves or another address.
     *    - MUST NOT be address(0)
     * @param delegationRequests The set of delegations to apply after adding collateral.
     *    - MAY be empty, meaning no delegations are applied.
     *    - MUST ONLY be requests to add delegations, and that total MUST BE less than the `collateralAmount` argument
     *    - If `onBehalfOf` does not equal the caller, the caller must be authorized via
     *      `setAuthorization()` or `setAuthorizationWithSig()`
     */
    function addCollateral(
        uint128 collateralAmount,
        address onBehalfOf,
        IDLGTEv1.DelegationRequest[] calldata delegationRequests
    ) external;

    /**
     * @notice Withdraw gOHM collateral.
     *    - Account LTV MUST be less than or equal to `maxOriginationLtv` after the withdraw is applied
     *    - At least `collateralAmount` collateral MUST be undelegated for this account.
     *      Use the `delegationRequests` to rescind enough as part of this request.
     * @param collateralAmount The amount of collateral to remove to 18 decimal places
     *    - MUST be greater than zero
     *    - If set to type(uint128).max then withdraw the max amount up to maxOriginationLtv
     * @param onBehalfOf A caller can withdraw collateral on behalf of themselves or another address if
     *      authorized via `setAuthorization()` or `setAuthorizationWithSig()`
     * @param recipient Send the gOHM collateral to a specified recipient address.
     *    - MUST NOT be address(0)
     * @param delegationRequests The set of delegations to apply before removing collateral.
     *    - MAY be empty, meaning no delegations are applied.
     *    - MUST ONLY be requests to undelegate, and that total undelegated MUST BE less than the `collateralAmount`
     *      argument
     */
    function withdrawCollateral(
        uint128 collateralAmount,
        address onBehalfOf,
        address recipient,
        IDLGTEv1.DelegationRequest[] calldata delegationRequests
    ) external returns (uint128 collateralWithdrawn);

    /**
     * @notice Borrow `debtToken`
     *    - Account LTV MUST be less than or equal to `maxOriginationLtv` after the borrow is applied
     *    - Total debt for this account MUST be greater than or equal to the `minDebtRequired`
     *      after the borrow is applied
     * @param borrowAmountInWad The amount of `debtToken` to borrow, to 18 decimals regardless of the debt token
     *    - MUST be greater than zero
     *    - If set to type(uint128).max then borrow the max amount up to maxOriginationLtv
     * @param onBehalfOf A caller can borrow on behalf of themselves or another address if
     *      authorized via `setAuthorization()` or `setAuthorizationWithSig()`
     * @param recipient Send the borrowed token to a specified recipient address.
     *    - MUST NOT be address(0)
     * @return amountBorrowedInWad The amount actually borrowed.
     */
    function borrow(uint128 borrowAmountInWad, address onBehalfOf, address recipient)
        external
        returns (uint128 amountBorrowedInWad);

    /**
     * @notice Repay a portion, or all of the debt
     *    - MUST NOT be called for an account which has no debt
     *    - If the entire debt isn't paid off, then the total debt for this account
     *      MUST be greater than or equal to the `minDebtRequired` after the borrow is applied
     * @param repayAmountInWad The amount to repay, to 18 decimals regardless of the debt token
     *    - MUST be greater than zero
     *    - MAY be greater than the latest debt as of this block. In which case it will be capped
     *      to that latest debt
     * @param onBehalfOf A caller can repay the debt on behalf of themselves or another address
     * @return amountRepaidInWad The amount actually repaid.
     */
    function repay(uint128 repayAmountInWad, address onBehalfOf) external returns (uint128 amountRepaidInWad);

    /**
     * @notice Apply a set of delegation requests on behalf of a given user.
     * @param delegationRequests The set of delegations to apply.
     *    - MAY be empty, meaning no delegations are applied.
     *    - Total collateral delegated as part of these requests MUST BE less than the account collateral.
     *    - MUST NOT apply delegations that results in more collateral being undelegated than
     *      the account has collateral for.
     *    - It applies across total gOHM balances for a given account across all calling policies
     *      So this may (un)delegate the account's gOHM set by another policy
     * @param onBehalfOf A caller can apply delegations on behalf of themselves or another address if
     *      authorized via `setAuthorization()` or `setAuthorizationWithSig()`
     */
    function applyDelegations(IDLGTEv1.DelegationRequest[] calldata delegationRequests, address onBehalfOf)
        external
        returns (uint256 totalDelegated, uint256 totalUndelegated, uint256 undelegatedBalance);

    /// @notice The collateral token supplied by users/accounts, eg gOHM
    function collateralToken() external view returns (IERC20);

    /// @notice The debt token which can be borrowed, eg DAI or USDS
    function debtToken() external view returns (IERC20);

    /// @notice The policy which borrows/repays from Treasury on behalf of Cooler
    function treasuryBorrower() external view returns (ICoolerTreasuryBorrower);

    /**
     * @notice An account's current collateral
     * @dev to 18 decimal places
     */
    function accountCollateral(address account) external view returns (uint128 collateralInWad);

    /**
     * @notice An account's current debt as of this block
     * to 18 decimal places regardless of the debt token
     */
    function accountDebt(address account) external view returns (uint128 debtInWad);

    /**
     * @notice Calculate the difference in debt required in order to be at or just under
     * the maxOriginationLTV if `collateralDelta` was added/removed
     * from the current position.
     * A positive `debtDeltaInWad` means the account can borrow that amount after adding that `collateralDelta`
     * collateral
     * A negative `debtDeltaInWad` means it needs to repay that amount in order to withdraw that `collateralDelta`
     * collateral
     * @dev debtDeltaInWad is always to 18 decimal places
     */
    function debtDeltaForMaxOriginationLtv(address account, int128 collateralDelta)
        external
        view
        returns (int128 debtDeltaInWad);
}
