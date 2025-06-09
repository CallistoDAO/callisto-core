// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

// See https://etherscan.io/address/0xf7602c0421c283a2fc113172ebdf64c30f21654d
interface IOlympusHeart {
    /// @notice Beats the heart
    /// @notice Only callable when enough time has passed since last beat (determined by frequency variable)
    /// @notice This function is incentivized with a token reward (see rewardToken and reward variables).
    /// @dev    Triggers price oracle update and market operations
    function beat() external;

    /// @notice Timestamp of the last beat (UTC, in seconds)
    function lastBeat() external view returns (uint48);

    function resetBeat() external;
}
