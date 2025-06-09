// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { MockERC20 } from "./MockERC20.sol";

contract MockCOLLAR is MockERC20 {
    constructor() MockERC20("COLLAR", "COLLAR", 18) { }

    function mintFromWhitelistedContract(address to, uint256 value) external {
        _mint(to, value);
    }

    function burnFromWhitelistedContract(uint256 value) external {
        _burn(msg.sender, value);
    }
}
