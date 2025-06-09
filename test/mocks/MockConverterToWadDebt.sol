// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { Math } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/Math.sol";
import { SafeCast } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/SafeCast.sol";

contract MockConverterToWadDebt {
    using SafeCast for uint256;

    uint8 public constant DECIMALS = 18;

    uint256 private immutable _conversionScalar;

    constructor(uint8 tokenDecimals) {
        _conversionScalar = 10 ** (DECIMALS - tokenDecimals);
    }

    // TODO: check formula
    function toWad(uint256 debtTokens) external view returns (uint128) {
        return Math.mulDiv(debtTokens, _conversionScalar, 1, Math.Rounding.Ceil).toUint128();
    }
}
