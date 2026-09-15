// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ⚠️  DEAD SERVICE - KEPT FOR REFERENCE ONLY
//
// Chainlink Functions sunset on 2026-06-15 (testnet) / 2026-06-30 (mainnet).
// New subscriptions cannot be created and the DON no longer fulfils requests,
// so getTemperature() will consume gas and never receive a callback.
//
// This is the original contract from Cyfrin Updraft's Chainlink Fundamentals
// course, kept as the "before" half of the CRE migration. The working
// replacement is src/TemperatureConsumer.sol.
//
// Deployed (unfulfillable) at 0x2968e237d04126b5A35ff62f34020079A0D1A0Ee on Sepolia.

import {FunctionsClient} from "@chainlink/contracts@1.3.0/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts@1.3.0/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

contract FunctionsConsumer is FunctionsClient {
    using FunctionsRequest for FunctionsRequest.Request;

    string public s_lastCity;
    string public s_requestedCity;
    string public s_lastTemperature;

    // State variables to store the last request ID, response, and error
    bytes32 public s_lastRequestId;
    bytes public s_lastResponse;
    bytes public s_lastError;

    // Hardcoded for Sepolia
    // Supported networks https://docs.chain.link/chainlink-functions/supported-networks
    address constant ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    bytes32 constant DON_ID = 0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000;
    //Callback gas limit
    uint32 constant GAS_LIMIT = 300000;
    // JavaScript source code run by the DON.
    // Open-Meteo quantises "current" readings into 15-minute buckets (interval: 900),
    // so every node querying the same window sees an identical value and the DON
    // reaches consensus. Only the temperature field is returned -- the raw body
    // carries a per-request generationtime_ms that would break consensus.
    // Each line ends in \n: adjacent Solidity literals concatenate with no separator.
    // forgefmt: disable-next-item
    string public constant SOURCE =
        "const city = args[0];\n"
        "const geo = await Functions.makeHttpRequest({\n"
        "  url: `https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(city)}&count=1`\n"
        "});\n"
        "if (geo.error || !geo.data.results || geo.data.results.length === 0) {\n"
        "  throw Error('City not found');\n"
        "}\n"
        "const { latitude, longitude, name } = geo.data.results[0];\n"
        "const wx = await Functions.makeHttpRequest({\n"
        "  url: `https://api.open-meteo.com/v1/forecast?latitude=${latitude}&longitude=${longitude}&current=temperature_2m&timezone=UTC`\n"
        "});\n"
        "if (wx.error) {\n"
        "  throw Error('Forecast request failed');\n"
        "}\n"
        "const temp = Math.round(wx.data.current.temperature_2m);\n"
        "return Functions.encodeString(`${name}: ${temp}C`);";

    // Event to log responses
    event Response(bytes32 indexed requestId, string temperature, bytes response, bytes err);

    error UnexpectedRequestID(bytes32 requestId);

    constructor() FunctionsClient(ROUTER) {}

    function getTemperature(string memory city, uint64 subscriptionId) external returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(SOURCE); // Initialize the request with JS code

        string[] memory args = new string[](1);
        args[0] = city;
        req.setArgs(args); // Set the arguments for the request

        // Send the request and store the request ID
        s_lastRequestId = _sendRequest(req.encodeCBOR(), subscriptionId, GAS_LIMIT, DON_ID);

        // set the city for which we are obtaining the temperature
        s_requestedCity = city;
        return s_lastRequestId;
    }

    // Receive the weather in the city requested
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        if (s_lastRequestId != requestId) {
            revert UnexpectedRequestID(requestId); // Check if request IDs match
        }

        s_lastError = err;
        s_lastResponse = response;

        s_lastTemperature = string(response);
        s_lastCity = s_requestedCity;

        // Emit an event to log the response
        emit Response(requestId, s_lastTemperature, s_lastResponse, s_lastError);
    }
}
