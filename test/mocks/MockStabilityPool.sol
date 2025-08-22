// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import { ICOLLAR } from "../../src/interfaces/ICOLLAR.sol";

interface IMockDebtToken is ICOLLAR {
    function sendToPool(address sender, uint256 amount) external;
}

contract MockStabilityPool {
    address debtToken;
    address[] private _assets;

    constructor(address debtToken_) {
        debtToken = debtToken_;
        _assets.push(debtToken);
    }

    function deposit(uint256 amount) external {
        IMockDebtToken(debtToken).sendToPool(msg.sender, amount);
    }

    function getAssets() external view returns (address[] memory) {
        return _assets;
    }
}
