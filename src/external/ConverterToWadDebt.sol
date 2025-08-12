// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IConverterToWadDebt } from "../interfaces/IConverterToWadDebt.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title ConverterToWadDebt
 * @notice Converts a debt token amount to wad (Olympus Cooler V2 standard 18 decimals).
 *
 * @dev If Olympus Cooler V2 replaces the debt token, this contract should implement conversion from the new token's
 * decimals to wad, considering `CoolerTreasuryBorrower.convertToDebtTokenAmount`. This contract is replaced via
 * `DebtTokenMigrator.migrateDebtToken`.
 */
contract ConverterToWadDebt is IConverterToWadDebt {
    using SafeCast for uint256;

    /// @inheritdoc IConverterToWadDebt
    function toWad(uint256 debtTokens) external pure override returns (uint128) {
        return debtTokens.toUint128();
    }
}
