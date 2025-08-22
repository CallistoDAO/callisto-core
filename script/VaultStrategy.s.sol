// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { console } from "../dependencies/forge-std-1.9.6/src/console.sol";

import { CallistoPSM } from "../src/external/CallistoPSM.sol";
import { VaultStrategy } from "../src/external/VaultStrategy.sol";
import { BaseScript } from "./BaseScript.sol";
import { IERC20 } from "@openzeppelin-contracts-5.3.0/token/ERC20/IERC20.sol";

contract DeployVaultStrategy is BaseScript {
    bytes32 private constant _SALT = keccak256(abi.encode("VaultStrategy_V1"));

    function run() public {
        address usds = _envAddress("USDS_TOKEN");
        address susds = _envAddress("SUSDS_TOKEN");
        address DEPLOYED_DEBT_TOKEN_MIGRATOR = _envAddress("DEPLOYED_DEBT_TOKEN_MIGRATOR");
        address psm = _envAddress("DEPLOYED_CALLISTO_PSM");
        CallistoPSM callistoPSM = CallistoPSM(psm);
        // TODO: transfer owner as final step
        bytes memory encodedArgs = abi.encode(deployer, IERC20(usds), psm, susds, DEPLOYED_DEBT_TOKEN_MIGRATOR);
        bytes memory initCode = abi.encodePacked(type(VaultStrategy).creationCode, encodedArgs);
        string memory name = type(VaultStrategy).name;
        address strategy = _deploy(name, "DEPLOYED_VAULT_STRATEGY", _SALT, initCode, true);

        if (callistoPSM.liquidityProvider() != strategy) {
            console.log("Setting LP to:", strategy);
            vm.startBroadcast(deployer);
            callistoPSM.finalizeInitialization(strategy);
            vm.stopBroadcast();
        } else {
            console.log("LP already set to", callistoPSM.liquidityProvider());
        }
    }
}
