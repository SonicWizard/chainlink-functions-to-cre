// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {FunctionsConsumer} from "../src/FunctionsConsumer.sol";

/// @notice Deploys FunctionsConsumer. Router, DON ID and gas limit are hardcoded
///         in the contract for Sepolia, so there are no constructor arguments.
contract DeployFunctionsConsumer is Script {
    function run() external returns (FunctionsConsumer consumer) {
        vm.startBroadcast();
        consumer = new FunctionsConsumer();
        vm.stopBroadcast();

        console.log("FunctionsConsumer deployed at:", address(consumer));
        console.log("Add this address as a consumer on your Functions subscription:");
        console.log("  https://functions.chain.link/sepolia");
    }
}
