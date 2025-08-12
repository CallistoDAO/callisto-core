// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { MockERC20 } from "./MockERC20.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockSwapper {
    using SafeERC20 for IERC20;

    MockERC20 public token1;
    MockERC20 public token2;

    constructor(MockERC20 token1_, MockERC20 token2_) {
        token1 = token1_;
        token2 = token2_;
    }

    function swap(uint256 ohmAmount, bytes[] calldata) external returns (uint256) {
        uint256 returnAmount = ohmAmount;
        IERC20(address(token1)).safeTransferFrom(msg.sender, address(this), ohmAmount);
        token2.mint(address(this), returnAmount);
        IERC20(address(token2)).safeTransfer(msg.sender, returnAmount);
        return returnAmount;
    }
}
