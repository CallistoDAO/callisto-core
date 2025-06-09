// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ERC20 } from "solmate-6.8.0/src/tokens/ERC20.sol";

import { IERC20 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC20.sol";

import { Math } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/Math.sol";

contract MockCoolerTreasuryBorrower {
    uint8 public constant DECIMALS = 18;

    ERC20 public immutable _debtToken;

    uint256 private immutable _conversionScalar;

    constructor(address debtToken_) {
        _debtToken = ERC20(debtToken_);
        uint8 tokenDecimals = _debtToken.decimals();
        _conversionScalar = 10 ** (DECIMALS - tokenDecimals);
    }

    function debtToken() external view returns (IERC20) {
        return IERC20(address(_debtToken));
    }

    function convertToDebtTokenAmount(uint256 amountInWei)
        external
        view
        returns (IERC20 dToken, uint256 dTokenAmount)
    {
        dToken = IERC20(address(_debtToken));
        dTokenAmount = _convertToDebtTokenAmount(amountInWei);
    }

    function _convertToDebtTokenAmount(uint256 amountInWei) private view returns (uint256) {
        return Math.mulDiv(amountInWei, 1, _conversionScalar, Math.Rounding.Ceil);
    }
}
