// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import { IERC20Metadata } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC20Metadata.sol";

// [Source](https://etherscan.io/address/0x0ab87046fBb341D058F17CBC4c1133F25a20a52f).
interface IGOHM is IERC20Metadata {
    function mint(address _to, uint256 _amount) external;

    function burn(address _from, uint256 _amount) external;

    /// @notice Converts gOHM amount to OHM.
    function balanceFrom(uint256 amount) external view returns (uint256);

    /// @notice Converts OHM amount to gOHM.
    function balanceTo(uint256 amount) external view returns (uint256);

    /// @notice Pull index from sOHM token.
    function index() external view returns (uint256);
}
