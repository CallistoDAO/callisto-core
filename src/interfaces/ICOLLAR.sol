// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

interface ICOLLAR {
    function mintByPSM(address to, uint256 value) external;

    function burn(address from, uint256 value) external;

    function sendToPool(address sender, uint256 amount) external;
}
