// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import { CallistoToken } from "../../src/external/CallistoToken.sol";
import { Test } from "forge-std-1.9.6/Test.sol";

contract CallistoTokenTests is Test {
    address defaultAdmin;
    address minter;
    address account;

    CallistoToken callistoToken;

    function setUp() public {
        defaultAdmin = makeAddr("[ defaultAdmin ]");
        minter = makeAddr("[ minter ]");
        account = makeAddr("[ account ]");

        callistoToken = new CallistoToken(defaultAdmin);

        vm.startPrank(defaultAdmin);
        callistoToken.grantRole(callistoToken.MINTER_ROLE(), minter);
        vm.stopPrank();
    }

    function test_mint() external {
        uint256 amount = 100e18;
        vm.prank(minter);
        callistoToken.mint(account, amount);
        assertEq(callistoToken.balanceOf(account), amount);
    }
}
