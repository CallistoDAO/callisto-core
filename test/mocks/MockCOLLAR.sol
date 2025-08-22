// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ICOLLAR } from "../../src/interfaces/ICOLLAR.sol";
import { MockERC20 } from "./MockERC20.sol";

contract MockCOLLAR is MockERC20, ICOLLAR {
    constructor() MockERC20("COLLAR", "COLLAR", 18) { }

    function mintByPSM(address to, uint256 value) external override {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external override {
        _burn(from, value);
    }

    function sendToPool(address sender, uint256 amount) external override {
        _transfer(sender, msg.sender, amount);
    }
}
