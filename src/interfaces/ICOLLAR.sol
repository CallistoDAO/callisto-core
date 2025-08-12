// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ICOLLAR {
    function mintByPSM(address to, uint256 value) external;

    function burn(address from, uint256 value) external;
}
