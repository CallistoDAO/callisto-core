// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

/// @notice Simple oracle interface for price feeds.
interface IOracle {
    function getPrice() external view returns (uint256 value);

    error Oracle__InvalidResponse();
}
