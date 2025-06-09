// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {
    ERC20, ERC4626, IERC20
} from "../../dependencies/@openzeppelin-contracts-5.3.0/token/ERC20/extensions/ERC4626.sol";

contract MockSusds is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Savings USDS", "sUSDS") { }

    function mint(address to, uint256 value) public virtual {
        _mint(to, value);
    }

    function burn(uint256 value) public virtual {
        _burn(msg.sender, value);
    }
}
