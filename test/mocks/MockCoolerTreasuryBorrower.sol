// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ERC20 } from "solmate-6.8.0/tokens/ERC20.sol";

import { IERC20 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC20.sol";

import { Math } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/Math.sol";

contract MockCoolerTreasuryBorrower {
    uint8 public constant DECIMALS = 18;

    ERC20 public immutable DEBT_TOKEN;

    uint256 private immutable _CONVERSION_PRECISION;

    constructor(address debtToken_) {
        DEBT_TOKEN = ERC20(debtToken_);
        uint8 tokenDecimals = DEBT_TOKEN.decimals();
        _CONVERSION_PRECISION = 10 ** (DECIMALS - tokenDecimals);
    }

    function debtToken() external view returns (IERC20) {
        return IERC20(address(DEBT_TOKEN));
    }

    function convertToDebtTokenAmount(uint256 amountInWei)
        external
        view
        returns (IERC20 dToken, uint256 dTokenAmount)
    {
        dToken = IERC20(address(DEBT_TOKEN));
        dTokenAmount = _convertToDebtTokenAmount(amountInWei);
    }

    function _convertToDebtTokenAmount(uint256 amountInWei) private view returns (uint256) {
        return Math.mulDiv(amountInWei, 1, _CONVERSION_PRECISION, Math.Rounding.Ceil);
    }
}
