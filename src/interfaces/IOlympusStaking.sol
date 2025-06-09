// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

// [Source](https://etherscan.io/address/0xB63cac384247597756545b500253ff8E607a8020).
interface IOlympusStaking {
    function stake(address to, uint256 amount, bool rebasing, bool claim) external returns (uint256);

    function unstake(address to, uint256 amount, bool trigger, bool rebasing) external returns (uint256 amount_);

    function claim(address to, bool rebasing) external returns (uint256);

    function forfeit() external returns (uint256);

    function warmupPeriod() external view returns (uint256);
}
