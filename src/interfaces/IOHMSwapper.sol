// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title The OHM swapper interface.
 *
 * @notice This contract exchanges OHM for gOHM by exchanging in any way.
 *
 * It is assumed to be used when the `warmupPeriod` has been activated in Olympus Staking by Olympus DAO that blocks
 * the direct exchange of OHM for gOHM.
 */
interface IOHMSwapper {
    function swap(uint256 ohmAmount, bytes[] memory data) external returns (uint256);
}
