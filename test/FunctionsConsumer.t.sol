// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FunctionsConsumer} from "../src/FunctionsConsumer.sol";

/// @notice Stands in for the real Functions router. Records what the consumer sent
///         and hands back a deterministic request ID.
contract MockFunctionsRouter {
    bytes32 public constant REQUEST_ID = keccak256("mock-request");

    uint64 public lastSubscriptionId;
    bytes public lastData;
    uint16 public lastDataVersion;
    uint32 public lastCallbackGasLimit;
    bytes32 public lastDonId;
    uint256 public sendRequestCalls;

    function sendRequest(
        uint64 subscriptionId,
        bytes calldata data,
        uint16 dataVersion,
        uint32 callbackGasLimit,
        bytes32 donId
    ) external returns (bytes32) {
        lastSubscriptionId = subscriptionId;
        lastData = data;
        lastDataVersion = dataVersion;
        lastCallbackGasLimit = callbackGasLimit;
        lastDonId = donId;
        sendRequestCalls++;
        return REQUEST_ID;
    }
}

contract FunctionsConsumerTest is Test {
    // Mirrors of the consumer's internal constants.
    address constant ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    bytes32 constant DON_ID =
        0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000;
    uint32 constant GAS_LIMIT = 300000;
    uint64 constant SUB_ID = 42;

    FunctionsConsumer consumer;
    MockFunctionsRouter router;

    event RequestSent(bytes32 indexed id);
    event RequestFulfilled(bytes32 indexed id);

    function setUp() public {
        // The router address is hardcoded in the consumer, so put the mock's
        // runtime code at that exact address.
        MockFunctionsRouter deployed = new MockFunctionsRouter();
        vm.etch(ROUTER, address(deployed).code);
        router = MockFunctionsRouter(ROUTER);

        consumer = new FunctionsConsumer();
    }

    /* ------------------------------ SOURCE ------------------------------ */

    /// @dev Pins the exact script the DON will run. Each line ends in \n, so a
    ///      line that lost its terminator shows up here rather than at the DON.
    function test_SourceMatchesExpectedScript() public view {
        string memory expected = "const city = args[0];\n"
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

        assertEq(consumer.SOURCE(), expected);
    }

    /// @dev Adjacent Solidity literals concatenate with nothing between them, so
    ///      every line must carry its own terminator to survive the join.
    function test_SourceLinesAreProperlyTerminated() public view {
        bytes memory src = bytes(consumer.SOURCE());
        uint256 lineStart = 0;
        uint256 lineCount = 0;

        for (uint256 i = 0; i < src.length; i++) {
            if (src[i] == 0x0a) {
                assertGt(i, lineStart, "empty line in SOURCE");
                _assertTerminator(src[i - 1]);
                lineCount++;
                lineStart = i + 1;
            }
        }

        assertGt(src.length, lineStart, "SOURCE ends with a stray newline");
        _assertTerminator(src[src.length - 1]);
        lineCount++;

        assertGt(lineCount, 1, "SOURCE should be multi-line");
    }

    function test_SourceTargetsOpenMeteoAndEscapesCity() public view {
        bytes memory src = bytes(consumer.SOURCE());
        assertTrue(
            _contains(src, bytes("geocoding-api.open-meteo.com")),
            "geocoding host missing"
        );
        assertTrue(
            _contains(src, bytes("api.open-meteo.com/v1/forecast")),
            "forecast host missing"
        );
        // Guards against URL injection and literal spaces in city names.
        assertTrue(
            _contains(src, bytes("encodeURIComponent(city)")),
            "city arg is not URL-encoded"
        );
        // Returning the raw body would break DON consensus on generationtime_ms.
        assertTrue(
            _contains(src, bytes("wx.data.current.temperature_2m")),
            "should extract only the temperature field"
        );
    }

    /* --------------------------- getTemperature -------------------------- */

    function test_GetTemperature_ForwardsRequestToRouter() public {
        bytes32 requestId = consumer.getTemperature("London", SUB_ID);

        assertEq(requestId, router.REQUEST_ID());
        assertEq(consumer.s_lastRequestId(), router.REQUEST_ID());
        assertEq(router.sendRequestCalls(), 1);
        assertEq(router.lastSubscriptionId(), SUB_ID);
        assertEq(router.lastCallbackGasLimit(), GAS_LIMIT);
        assertEq(router.lastDonId(), DON_ID);
        assertEq(router.lastDataVersion(), 1);
        assertGt(router.lastData().length, 0, "empty CBOR payload");
    }

    function test_GetTemperature_RecordsRequestedCity() public {
        consumer.getTemperature("Paris", SUB_ID);
        assertEq(consumer.s_requestedCity(), "Paris");
        // Not promoted to s_lastCity until fulfillment lands.
        assertEq(consumer.s_lastCity(), "");
    }

    function test_GetTemperature_EncodesSourceAndArgIntoPayload() public {
        consumer.getTemperature("Berlin", SUB_ID);
        bytes memory payload = router.lastData();

        assertTrue(_contains(payload, bytes(consumer.SOURCE())), "source missing from CBOR");
        assertTrue(_contains(payload, bytes("Berlin")), "city arg missing from CBOR");
    }

    function test_GetTemperature_EmitsRequestSent() public {
        vm.expectEmit(true, false, false, false, address(consumer));
        emit RequestSent(MockFunctionsRouter(ROUTER).REQUEST_ID());
        consumer.getTemperature("Tokyo", SUB_ID);
    }

    function testFuzz_GetTemperature_StoresAnyCity(string calldata city) public {
        consumer.getTemperature(city, SUB_ID);
        assertEq(consumer.s_requestedCity(), city);
    }

    /* --------------------------- fulfillRequest -------------------------- */

    function test_Fulfill_StoresResponseAndPromotesCity() public {
        bytes32 requestId = consumer.getTemperature("Lisbon", SUB_ID);
        bytes memory response = bytes("Lisbon: 22 C");

        vm.prank(ROUTER);
        consumer.handleOracleFulfillment(requestId, response, "");

        assertEq(consumer.s_lastTemperature(), "Lisbon: 22 C");
        assertEq(consumer.s_lastCity(), "Lisbon");
        assertEq(consumer.s_lastResponse(), response);
        assertEq(consumer.s_lastError(), "");
    }

    function test_Fulfill_EmitsResponseEvent() public {
        bytes32 requestId = consumer.getTemperature("Oslo", SUB_ID);
        bytes memory response = bytes("Oslo: 3 C");

        vm.expectEmit(true, false, false, true, address(consumer));
        emit FunctionsConsumer.Response(requestId, "Oslo: 3 C", response, "");

        vm.prank(ROUTER);
        consumer.handleOracleFulfillment(requestId, response, "");
    }

    function test_Fulfill_StoresErrorPath() public {
        bytes32 requestId = consumer.getTemperature("Cairo", SUB_ID);
        bytes memory err = bytes("Request failed");

        vm.prank(ROUTER);
        consumer.handleOracleFulfillment(requestId, "", err);

        assertEq(consumer.s_lastError(), err);
        assertEq(consumer.s_lastResponse(), "");
        // Empty response still overwrites the temperature.
        assertEq(consumer.s_lastTemperature(), "");
    }

    function test_Fulfill_RevertsOnUnexpectedRequestId() public {
        consumer.getTemperature("Madrid", SUB_ID);
        bytes32 wrongId = keccak256("not-the-request");

        vm.prank(ROUTER);
        vm.expectRevert(
            abi.encodeWithSelector(FunctionsConsumer.UnexpectedRequestID.selector, wrongId)
        );
        consumer.handleOracleFulfillment(wrongId, bytes("x"), "");
    }

    function test_Fulfill_RevertsWhenCallerIsNotRouter() public {
        bytes32 requestId = consumer.getTemperature("Rome", SUB_ID);

        vm.prank(address(0xBAD));
        vm.expectRevert(bytes4(keccak256("OnlyRouterCanFulfill()")));
        consumer.handleOracleFulfillment(requestId, bytes("x"), "");
    }

    /* ------------------------------ helpers ------------------------------ */

    /// @dev Valid line endings: ';' '{' '}' close a statement or block; '`' ends a
    ///      template literal on a continuation line inside an object literal
    ///      (the `url:` lines). Anything else means a line lost its terminator.
    function _assertTerminator(bytes1 c) internal pure {
        assertTrue(
            c == 0x3b || c == 0x7b || c == 0x7d || c == 0x60,
            "SOURCE line ends in an unexpected character"
        );
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || needle.length > haystack.length) return false;
        for (uint256 i = 0; i <= haystack.length - needle.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
