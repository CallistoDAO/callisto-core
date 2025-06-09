// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IERC20 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC20.sol";

interface ICOLLAR is IERC20 {
    function mintFromWhitelistedContract(address to, uint256 value) external;

    function burnFromWhitelistedContract(uint256 value) external;
}
