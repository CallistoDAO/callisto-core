// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import { IOlympusAuthority } from "./IOlympusAuthority.sol";

// [Source](https://github.com/OlympusDAO/olympus-contracts/blob/main/contracts/interfaces/IStaking.sol).
interface IOlympusStaking {
    function stake(address to, uint256 amount, bool rebasing, bool claim) external returns (uint256);

    function claim(address to, bool rebasing) external returns (uint256);

    function forfeit() external returns (uint256);

    function toggleLock() external;

    function unstake(address to, uint256 amount, bool trigger, bool rebasing) external returns (uint256 amount_);

    function wrap(address to, uint256 amount) external returns (uint256 gBalance_);

    function unwrap(address to, uint256 amount) external returns (uint256 sBalance_);

    function rebase() external;

    function index() external view returns (uint256);

    function contractBalance() external view returns (uint256);

    function totalStaked() external view returns (uint256);

    function supplyInWarmup() external view returns (uint256);

    /// @dev added by hand from
    /// https://github.com/OlympusDAO/olympus-contracts/blob/main/contracts/types/OlympusAccessControlled.sol#L15
    function authority() external returns (IOlympusAuthority);

    /// @dev added by hand from https://github.com/OlympusDAO/olympus-contracts/blob/main/contracts/Staking.sol#L305
    function setWarmupLength(uint256 _warmupPeriod) external;

    /// @dev added by hand from https://github.com/OlympusDAO/olympus-contracts/blob/main/contracts/Staking.sol#L54
    function warmupPeriod() external view returns (uint256);
}
