// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import {
    ERC20, ERC4626, IERC20
} from "../../dependencies/@openzeppelin-contracts-5.3.0/token/ERC20/extensions/ERC4626.sol";

contract MockStabilityPool is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Stability Pool", "Stability Pool") { }
}
