// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

bytes32 constant DEPOSIT_TYPEHASH = keccak256(
    "DepositWithSig(address caller,address owner,address receiver,uint256 value,uint256 nonce,uint256 deadline)"
);

bytes32 constant MINT_TYPEHASH =
    keccak256("MintWithSig(address caller,address owner,address receiver,uint256 value,uint256 nonce,uint256 deadline)");

bytes32 constant WITHDRAW_TYPEHASH = keccak256(
    "WithdrawWithSig(address caller,address owner,address receiver,uint256 value,uint256 nonce,uint256 deadline)"
);

bytes32 constant REDEEM_TYPEHASH = keccak256(
    "RedeemWithSig(address caller,address owner,address receiver,uint256 value,uint256 nonce,uint256 deadline)"
);
