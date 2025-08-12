// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import { ICOLLAR } from "../../src/interfaces/ICOLLAR.sol";

interface IMockDebtToken is ICOLLAR {
    function sendToPool(address sender, uint256 amount) external;
}

contract MockStabilityPool {
    address debtToken;

    constructor(address debtToken_) {
        debtToken = debtToken_;
    }

    function deposit(uint256 amount) external {
        IMockDebtToken(debtToken).sendToPool(msg.sender, amount);
    }
}
