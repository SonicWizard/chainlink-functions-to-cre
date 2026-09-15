// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Deploy on Sepolia. CRE replacement for FunctionsConsumer.
//
// Chainlink Functions sunset on 2026-06-15 (testnet), so its request/callback
// model is gone. CRE inverts the flow:
//
//   1. requestTemperature() emits TemperatureRequested
//   2. a CRE workflow (EVM log trigger) sees the event and calls Open-Meteo
//   3. the workflow writes a signed report to the Chainlink Forwarder
//   4. the forwarder verifies it and calls onReport(), which lands in
//      _processReport() below
//
// No subscription and no LINK billing here; the workflow pays for its writes.

import {ReceiverTemplate} from "@cre/ReceiverTemplate.sol";

contract TemperatureConsumer is ReceiverTemplate {
    string public s_lastCity;
    int32 public s_lastTemperatureC;
    uint32 public s_lastObservedAt;
    bytes32 public s_lastRequestId;

    mapping(bytes32 requestId => string city) public s_requestedCity;

    event TemperatureRequested(bytes32 indexed requestId, string city);
    event TemperatureReceived(
        bytes32 indexed requestId, string city, int32 temperatureC, uint32 observedAt
    );

    error UnknownRequestId(bytes32 requestId);
    error EmptyCity();

    /// @param forwarder The CRE Forwarder for this chain. Only it may deliver reports.
    constructor(address forwarder) ReceiverTemplate(forwarder) {}

    /// @notice Ask the workflow for a city's temperature. The request ID binds the
    ///         answer to this call, so concurrent requests no longer collide the way
    ///         they did under the single-slot Functions pattern.
    function requestTemperature(string calldata city) external returns (bytes32 requestId) {
        if (bytes(city).length == 0) revert EmptyCity();

        requestId = keccak256(
            abi.encodePacked(
                block.chainid, address(this), msg.sender, city, block.number, block.prevrandao
            )
        );
        s_requestedCity[requestId] = city;

        emit TemperatureRequested(requestId, city);
    }

    /// @notice Called by ReceiverTemplate.onReport after forwarder and workflow checks.
    /// @param report ABI-encoded (bytes32 requestId, string city, int32 temperatureC, uint32 observedAt).
    /// @dev Flat parameters, matching viem's encodeAbiParameters on the workflow side.
    ///      Encoding a struct instead would add a leading offset word and fail to decode.
    function _processReport(bytes calldata report) internal override {
        (bytes32 requestId, string memory city, int32 temperatureC, uint32 observedAt) =
            abi.decode(report, (bytes32, string, int32, uint32));

        if (bytes(s_requestedCity[requestId]).length == 0) revert UnknownRequestId(requestId);

        s_lastRequestId = requestId;
        s_lastCity = city;
        s_lastTemperatureC = temperatureC;
        s_lastObservedAt = observedAt;

        emit TemperatureReceived(requestId, city, temperatureC, observedAt);
    }
}
