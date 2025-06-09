// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import { CallistoVaultLogic } from "../../src/policies/vault/CallistoVaultLogic.sol";
import {
    DEPOSIT_TYPEHASH,
    MINT_TYPEHASH,
    REDEEM_TYPEHASH,
    WITHDRAW_TYPEHASH
} from "../../src/policies/vault/CallistoVaultSigTypehashes.sol";
import { Vm } from "forge-std/Test.sol";
import { ERC20 } from "solmate-6.8.0/src/tokens/ERC20.sol";

library CallistoVaultHelper {
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function getVaultMethodSignature(Vm vm, uint256 userPrivateKey, uint256 deadline, bytes32 structHash, address vault)
        public
        view
        returns (CallistoVaultLogic.SignatureParameters memory)
    {
        bytes32 DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Callisto OHM")),
                keccak256(bytes("1")),
                block.chainid,
                address(vault)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        return CallistoVaultLogic.SignatureParameters({ deadline: deadline, v: v, r: r, s: s });
    }

    function getDepositSignature(
        Vm vm,
        uint256 userPrivateKey,
        address user,
        uint256 assets,
        uint256 deadline,
        address vault,
        address caller
    ) public view returns (CallistoVaultLogic.SignatureParameters memory) {
        //  Signature 2: Vault EIP-712 Signature
        bytes32 structHash = keccak256(
            abi.encode(
                DEPOSIT_TYPEHASH,
                caller, // msg.sender in call
                user,
                user,
                assets,
                ERC20(vault).nonces(user),
                deadline
            )
        );

        return getVaultMethodSignature(vm, userPrivateKey, deadline, structHash, vault);
    }

    function getMintSignature(
        Vm vm,
        uint256 userPrivateKey,
        address user,
        uint256 assets,
        uint256 deadline,
        address vault,
        address caller
    ) public view returns (CallistoVaultLogic.SignatureParameters memory) {
        //  Vault EIP-712 Signature
        bytes32 structHash = keccak256(
            abi.encode(
                MINT_TYPEHASH,
                caller, // msg.sender in call
                user,
                user,
                assets,
                ERC20(vault).nonces(user),
                deadline
            )
        );

        return getVaultMethodSignature(vm, userPrivateKey, deadline, structHash, vault);
    }

    function getWithdrawSignature(
        Vm vm,
        uint256 userPrivateKey,
        address user,
        uint256 assets,
        uint256 deadline,
        address vault,
        address caller
    ) public view returns (CallistoVaultLogic.SignatureParameters memory) {
        //  Vault EIP-712 Signature
        bytes32 structHash = keccak256(
            abi.encode(
                WITHDRAW_TYPEHASH,
                caller, // msg.sender in call
                user,
                user,
                assets,
                ERC20(vault).nonces(user),
                deadline
            )
        );

        return getVaultMethodSignature(vm, userPrivateKey, deadline, structHash, vault);
    }

    function getRedeemSignature(
        Vm vm,
        uint256 userPrivateKey,
        address user,
        uint256 assets,
        uint256 deadline,
        address vault,
        address caller
    ) public view returns (CallistoVaultLogic.SignatureParameters memory) {
        //  Vault EIP-712 Signature
        bytes32 structHash = keccak256(
            abi.encode(
                REDEEM_TYPEHASH,
                caller, // msg.sender in call
                user,
                user,
                assets,
                ERC20(vault).nonces(user),
                deadline
            )
        );

        return getVaultMethodSignature(vm, userPrivateKey, deadline, structHash, vault);
    }

    //  Signature ERC20 Permit (EIP-2612)
    function getPermitSignature(
        Vm vm,
        address user,
        uint256 userPrivateKey,
        uint256 assets,
        uint256 deadline,
        address token,
        address vault
    ) public view returns (CallistoVaultLogic.SignatureParameters memory) {
        bytes32 permitStructHash = keccak256(
            abi.encode(CallistoVaultHelper.PERMIT_TYPEHASH, user, vault, assets, ERC20(token).nonces(user), deadline)
        );

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(
            userPrivateKey, keccak256(abi.encodePacked("\x19\x01", ERC20(token).DOMAIN_SEPARATOR(), permitStructHash))
        );

        return CallistoVaultLogic.SignatureParameters({ deadline: deadline, v: v1, r: r1, s: s1 });
    }
}
