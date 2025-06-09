// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.29;

import { MockERC20 } from "./MockERC20.sol";

contract MockGohm is MockERC20 {
    uint256 public index = 10_000 * 1e9;

    mapping(address => uint256) public votes;

    constructor() MockERC20("gOHM", "gOHM", 18) { }

    function balanceFrom(uint256 amount_) public view returns (uint256) {
        return (amount_ * index) / 10 ** decimals;
    }

    function balanceTo(uint256 amount_) public view returns (uint256) {
        return (amount_ * 10 ** decimals) / index;
    }

    function getPriorVotes(address account, uint256 blockNumber) public view returns (uint256) {
        require(blockNumber < block.number, "gOHM::getPriorVotes: not yet determined");
        return votes[account];
    }

    function checkpointVotes(address account) public {
        votes[account] = MockERC20(address(this)).balanceOf(account);
    }

    function setIndex(uint256 index_) public {
        index = index_;
    }
}
