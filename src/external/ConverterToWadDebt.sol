// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { SafeCast } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/SafeCast.sol";

/**
 * @title ConverterToWadDebt
 * @notice Converts a debt token amount to wad (Olympus Cooler V2 standard 18 decimals).
 *
 * @dev If Olympus Cooler V2 replaces the debt token, this contract should implement conversion from the new token's
 * decimals to wad, considering `CoolerTreasuryBorrower.convertToDebtTokenAmount`. This contract is replaced via
 * `DebtTokenMigrator.migrateDebtToken`.
 */
contract ConverterToWadDebt {
    using SafeCast for uint256;

    function toWad(uint256 debtTokens) external pure returns (uint128) {
        return debtTokens.toUint128();
    }
}
