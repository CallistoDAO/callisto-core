// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

interface IExecutableByHeart {
    /// @dev Should only revert if the call can not be skipped in a heartbeat cycle.
    function execute() external;
}
