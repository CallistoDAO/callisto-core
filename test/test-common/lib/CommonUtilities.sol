// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

contract CommonUtilities is Test {
    function createAccounts(uint256 number, string memory namePrefix) public returns (address[] memory) {
        address[] memory accounts = new address[](number);
        for (uint256 i = 0; i < number; ++i) {
            accounts[i] = makeAddr(string.concat(namePrefix, vm.toString(i)));
        }
        return accounts;
    }
}
