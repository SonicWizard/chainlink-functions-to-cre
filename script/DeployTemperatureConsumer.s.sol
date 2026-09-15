// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TemperatureConsumer} from "../src/TemperatureConsumer.sol";

/// @notice Deploys TemperatureConsumer for CRE on Sepolia.
/// @dev The constructor takes the CRE Forwarder, which is the ONLY address allowed
///      to call onReport. Two different forwarders exist on Sepolia:
///
///        real       0xF8344CFd5c43616a4366C34E3EEE75af79a74482  (deployed workflows)
///        simulator  0x15fC6ae953E024d975e77382eEeC56A9101f9F88  (cre workflow simulate)
///
///      Deploy with the simulator's address while testing, then switch with
///      setForwarderAddress() once the workflow is deployed for real.
///      Addresses come from `cre workflow supported-chains --output json`.
contract DeployTemperatureConsumer is Script {
    address constant SEPOLIA_FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;
    address constant SEPOLIA_MOCK_FORWARDER = 0x15fC6ae953E024d975e77382eEeC56A9101f9F88;

    function run() external returns (TemperatureConsumer consumer) {
        // Defaults to the simulator's forwarder; override with FORWARDER=0x... to
        // deploy against the real one.
        address forwarder = vm.envOr("FORWARDER", SEPOLIA_MOCK_FORWARDER);

        vm.startBroadcast();
        consumer = new TemperatureConsumer(forwarder);
        vm.stopBroadcast();

        console.log("TemperatureConsumer deployed at:", address(consumer));
        console.log("Configured forwarder:", forwarder);
        if (forwarder == SEPOLIA_MOCK_FORWARDER) {
            console.log("(simulator forwarder - use setForwarderAddress for production)");
        }
        console.log("Set consumerAddress in cre/weather/config.staging.json to this address.");
    }
}
