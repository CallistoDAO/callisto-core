// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IMonoCooler } from "../../../src/interfaces/IMonoCooler.sol";

interface IMonoCoolerExtended is IMonoCooler {
    /// @notice An account's collateral and debt position details
    /// Provided for UX
    struct AccountPosition {
        /// @notice The amount [in gOHM collateral terms] of collateral which has been provided by the user
        /// @dev To 18 decimal places
        uint256 collateral;
        /// @notice The up to date amount of debt
        /// @dev To 18 decimal places
        uint256 currentDebt;
        /// @notice The maximum amount of debtToken's this account can borrow given the
        /// collateral posted, up to `maxOriginationLtv`
        /// @dev To 18 decimal places
        uint256 maxOriginationDebtAmount;
        /// @notice The maximum amount of debtToken's this account can accrue before being
        /// eligable to be liquidated, up to `liquidationLtv`
        /// @dev To 18 decimal places
        uint256 liquidationDebtAmount;
        /// @notice The health factor of this accounts position.
        /// Anything less than 1 can be liquidated, relative to `liquidationLtv`
        /// @dev To 18 decimal places
        uint256 healthFactor;
        /// @notice The current LTV of this account [in debtTokens per gOHM collateral terms]
        /// @dev To 18 decimal places
        uint256 currentLtv;
        /// @notice The total collateral delegated for this user across all delegates
        /// @dev To 18 decimal places
        uint256 totalDelegated;
        /// @notice The current number of addresses this account has delegated to
        uint256 numDelegateAddresses;
        /// @notice The max number of delegates this account is allowed to delegate to
        uint256 maxDelegateAddresses;
    }

    function accountPosition(address account) external view returns (AccountPosition memory position);
}
