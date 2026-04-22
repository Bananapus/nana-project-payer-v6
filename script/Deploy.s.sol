// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {JBProjectPayerDeployer} from "../src/JBProjectPayerDeployer.sol";

contract Deploy is Script {
    function run() public {
        // The JBDirectory address for the target chain. Set via environment variable.
        address directoryAddress = vm.envAddress("JB_DIRECTORY");
        require(directoryAddress != address(0), "Deploy: zero directory address");
        require(directoryAddress.code.length != 0, "Deploy: directory has no code");

        vm.startBroadcast();
        new JBProjectPayerDeployer(IJBDirectory(directoryAddress));
        vm.stopBroadcast();
    }
}
