// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { MockERC20 } from "./MockERC20.sol";

contract MockSwapper {
    MockERC20 public token1;
    MockERC20 public token2;

    constructor(MockERC20 token1_, MockERC20 token2_) {
        token1 = token1_;
        token2 = token2_;
    }

    function swap(uint256 ohmAmount, bytes[] calldata) external returns (uint256) {
        uint256 returnAmount = ohmAmount;
        token1.transferFrom(msg.sender, address(this), ohmAmount);
        token2.mint(address(this), returnAmount);
        token2.transfer(msg.sender, returnAmount);
        return returnAmount;
    }
}
