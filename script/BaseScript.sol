// SPDX-License-Identifier: MIT
pragma solidity >=0.8.30;

import { ERC1967Proxy } from "../dependencies/@openzeppelin-contracts-5.3.0/proxy/ERC1967/ERC1967Proxy.sol";
import { Script } from "../dependencies/forge-std-1.9.6/src/Script.sol";
import { console } from "../dependencies/forge-std-1.9.6/src/console.sol";
import { LibString } from "../dependencies/solady-0.1.19/src/utils/g/LibString.sol";

abstract contract BaseScript is Script {
    using LibString for *;

    address internal deployer;
    string internal scannerBaseUrl;

    string internal constant DEPLOYED_CALLISTO_TOKEN = "DEPLOYED_CALLISTO_TOKEN";

    string internal constant CALLISTO_ADMIN = "CALLISTO_ADMIN";
    string internal constant INDEX = "INDEX";
    string internal constant DESTINATION = "DESTINATION";
    string internal constant TIMELOCK_DELAY = "TIMELOCK_DELAY";

    function setUp() public virtual {
        deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        scannerBaseUrl = _envString("SCANNER_BASE_URL");
        console.log("Deployer address:", deployer);
    }

    function _printContract(string memory name, address addr, bool printBlock) internal view {
        string memory host = string(abi.encodePacked(scannerBaseUrl, "/"));
        string memory addressUrl = string(abi.encodePacked(host, "address/", (addr).toHexString()));
        string memory env = string(abi.encodePacked(name, "=", (addr).toHexString()));
        console.log(env, addressUrl);
        if (printBlock) {
            console.log(string(abi.encodePacked(name, "_BLOCK=", (block.number).toString())));
        }
    }

    function _printContractAlready(string memory name, string memory varName, address addr) internal view {
        console.log(name, "already deployed");
        _printContract(varName, addr, false);
    }

    function _create2(string memory name, string memory varName, bytes32 salt, bytes memory initCode, bool printBlock)
        private
        returns (address addr)
    {
        bytes32 codeHash = keccak256(initCode);
        addr = vm.computeCreate2Address(salt, codeHash);
        if (addr.code.length > 0) {
            _printContractAlready(name, varName, addr);
        } else {
            vm.startBroadcast(deployer);
            assembly {
                addr := create2(0, add(initCode, 0x20), mload(initCode), salt)
                if iszero(addr) { revert(0, 0) }
            }
            vm.stopBroadcast();
            _printContract(varName, addr, printBlock);
        }
    }

    function _deploy(string memory name, string memory varName, bytes32 salt, bytes memory initCode, bool printBlock)
        internal
        returns (address addr)
    {
        addr = _envOr(varName, address(0));
        if (addr.code.length == 0 || addr == address(0)) {
            addr = _create2(name, varName, salt, initCode, printBlock);
        } else {
            console.log(name, "already deployed");
            _printContract(varName, addr, false);
        }
    }

    function _deployProxy(
        string memory name,
        string memory varName,
        bytes32 salt,
        bytes memory initCode,
        bool printBlock
    ) internal returns (address addr) {
        addr = _envOr(varName, address(0));
        if (addr.code.length == 0 || addr == address(0)) {
            bytes memory proxyBytecode = abi.encodePacked(type(ERC1967Proxy).creationCode, initCode);
            addr = _create2(name, varName, salt, proxyBytecode, printBlock);
        } else {
            console.log(name, "already deployed");
            _printContract(varName, addr, false);
        }
    }

    function _envString(string memory name) internal view returns (string memory value) {
        value = vm.envString(name);
        console.log(string(abi.encodePacked(name, ": '", value, "'")));
    }

    function _envAddress(string memory name) internal view returns (address value) {
        value = vm.envAddress(name);
        console.log(string(abi.encodePacked(name, ": '", value.toHexString(), "'")));
    }

    function _envBytes32(string memory name) internal view returns (bytes32 value) {
        value = vm.envBytes32(name);
        console.log(string(abi.encodePacked(name, ": '", uint256(value).toHexString(), "'")));
    }

    function _envOr(string memory name, address defaultValue) internal view returns (address value) {
        value = vm.envOr(name, defaultValue);
        console.log(string(abi.encodePacked(name, ": '", value.toHexString(), "'")));
    }

    function _envUint(string memory name) internal view returns (uint256 value) {
        value = vm.envUint(name);
        console.log(string(abi.encodePacked(name, ": ", value.toString())));
    }

    function _envInt(string memory name) internal view returns (int256 value) {
        value = vm.envInt(name);
        console.log(string(abi.encodePacked(name, ": ", value.toString())));
    }

    function _envOr(string memory name, uint256 defaultValue) internal view returns (uint256 value) {
        value = vm.envOr(name, defaultValue);
        console.log(string(abi.encodePacked(name, ": '", value.toString(), "'")));
    }

    function _envOr(string memory name, bytes32 defaultValue) internal view returns (bytes32 value) {
        value = vm.envOr(name, defaultValue);
        console.log(string(abi.encodePacked(name, ": '", uint256(value).toHexString(), "'")));
    }
}
