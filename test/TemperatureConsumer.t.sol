// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TemperatureConsumer} from "../src/TemperatureConsumer.sol";
import {ReceiverTemplate} from "@cre/ReceiverTemplate.sol";

contract TemperatureConsumerTest is Test {
    TemperatureConsumer consumer;

    address constant FORWARDER = address(0xF0);
    address constant WORKFLOW_OWNER = address(0x0B);
    bytes32 constant WORKFLOW_ID = keccak256("weather-workflow-id");

    event TemperatureRequested(bytes32 indexed requestId, string city);
    event TemperatureReceived(
        bytes32 indexed requestId, string city, int32 temperatureC, uint32 observedAt
    );

    function setUp() public {
        consumer = new TemperatureConsumer(FORWARDER);
    }

    /* ------------------------------ helpers ------------------------------ */

    /// @dev Matches the Forwarder's abi.encodePacked(workflowId, workflowName, workflowOwner).
    function _metadata(bytes32 id, bytes10 name, address owner)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(id, name, owner);
    }

    function _report(bytes32 requestId, string memory city, int32 temp, uint32 at)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(requestId, city, temp, at);
    }

    function _deliver(bytes32 id, string memory city, int32 temp, uint32 at) internal {
        vm.prank(FORWARDER);
        consumer.onReport(
            _metadata(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER), _report(id, city, temp, at)
        );
    }

    /* ------------------------------ requests ------------------------------ */

    function test_Request_StoresCityAndEmits() public {
        bytes32 id = consumer.requestTemperature("Paris");
        assertEq(consumer.s_requestedCity(id), "Paris");
        assertEq(consumer.s_lastCity(), "");
    }

    function test_Request_RevertsOnEmptyCity() public {
        vm.expectRevert(TemperatureConsumer.EmptyCity.selector);
        consumer.requestTemperature("");
    }

    function test_Request_ConcurrentRequestsDoNotCollide() public {
        bytes32 a = consumer.requestTemperature("Oslo");
        vm.roll(block.number + 1);
        bytes32 b = consumer.requestTemperature("Cairo");
        assertTrue(a != b, "request IDs collided");

        // Fulfil out of order - the single-slot Functions version could not.
        _deliver(b, "Cairo", 34, 1);
        assertEq(consumer.s_lastCity(), "Cairo");
        _deliver(a, "Oslo", -3, 2);
        assertEq(consumer.s_lastCity(), "Oslo");
        assertEq(consumer.s_lastTemperatureC(), -3);
    }

    /* ------------------------------ reports ------------------------------- */

    function test_Report_StoresAndEmits() public {
        bytes32 id = consumer.requestTemperature("Lisbon");

        vm.expectEmit(true, false, false, true, address(consumer));
        emit TemperatureReceived(id, "Lisbon", 22, 1234);

        _deliver(id, "Lisbon", 22, 1234);

        assertEq(consumer.s_lastRequestId(), id);
        assertEq(consumer.s_lastCity(), "Lisbon");
        assertEq(consumer.s_lastTemperatureC(), 22);
        assertEq(consumer.s_lastObservedAt(), 1234);
    }

    function test_Report_HandlesNegativeTemperatures() public {
        bytes32 id = consumer.requestTemperature("Vostok Station");
        _deliver(id, "Vostok Station", -68, 9);
        assertEq(consumer.s_lastTemperatureC(), -68);
    }

    function test_Report_RevertsForUnknownRequestId() public {
        bytes32 bogus = keccak256("never-requested");
        vm.expectRevert(
            abi.encodeWithSelector(TemperatureConsumer.UnknownRequestId.selector, bogus)
        );
        _deliver(bogus, "Ghost", 1, 1);
    }

    /// @dev Regression guard. viem's encodeAbiParameters produces a flat tuple; encoding a
    ///      Solidity struct instead prepends an offset word, which decodes to garbage.
    ///      This is the encoding mismatch the CRE reference template revealed.
    function test_Report_StructEncodingIsRejected() public {
        bytes32 id = consumer.requestTemperature("Berlin");
        // abi.encode of a dynamic struct == flat payload prefixed with a 0x20 offset word.
        bytes memory structEncoded = abi.encode(_report(id, "Berlin", 20, 5));

        vm.prank(FORWARDER);
        vm.expectRevert();
        consumer.onReport(_metadata(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER), structEncoded);
    }

    /* ------------------------------ security ------------------------------ */

    function test_Report_RevertsForNonForwarder() public {
        bytes32 id = consumer.requestTemperature("Rome");
        vm.prank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                ReceiverTemplate.InvalidSender.selector, address(0xBAD), FORWARDER
            )
        );
        consumer.onReport(
            _metadata(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER), _report(id, "Rome", 20, 1)
        );
    }

    function test_Report_RevertsForWrongAuthorWhenConfigured() public {
        consumer.setExpectedAuthor(WORKFLOW_OWNER);
        bytes32 id = consumer.requestTemperature("Rome");

        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReceiverTemplate.InvalidAuthor.selector, address(0xDEAD), WORKFLOW_OWNER
            )
        );
        consumer.onReport(
            _metadata(WORKFLOW_ID, bytes10(0), address(0xDEAD)), _report(id, "Rome", 20, 1)
        );
    }

    /// @dev The name in metadata is not the plaintext name: it is the first 10 chars of the
    ///      hex-encoded sha256 of the name. setExpectedWorkflowName does that derivation.
    function test_WorkflowNameIsDerivedNotPlaintext() public {
        consumer.setExpectedAuthor(WORKFLOW_OWNER);
        consumer.setExpectedWorkflowName("weather");

        bytes10 derived = consumer.getExpectedWorkflowName();
        assertTrue(derived != bytes10("weather"), "name should not be stored as plaintext");

        bytes32 h = sha256(bytes("weather"));
        bytes memory hexChars = "0123456789abcdef";
        bytes memory first10 = new bytes(10);
        for (uint256 i = 0; i < 10; i++) {
            uint8 b = uint8(h[i / 2]);
            first10[i] = (i % 2 == 0) ? hexChars[b >> 4] : hexChars[b & 0x0f];
        }
        assertEq(derived, bytes10(first10), "derivation mismatch");
    }

    function test_SetForwarder_OnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        consumer.setForwarderAddress(address(0xBAD));
    }
}
