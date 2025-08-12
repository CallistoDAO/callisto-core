// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title IConverterToWadDebt
 * @notice Interface for converting a debt token amount to wad (Olympus Cooler V2 standard 18 decimals).
 */
interface IConverterToWadDebt {
    /**
     * @notice Converts debt token amount to wad format
     * @param debtTokens The amount of debt tokens to convert
     * @return The equivalent amount in wad format (18 decimals)
     */
    function toWad(uint256 debtTokens) external pure returns (uint128);
}
