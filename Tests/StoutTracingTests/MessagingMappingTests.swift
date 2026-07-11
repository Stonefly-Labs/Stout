// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import XCTest

@testable import StoutTracing

/// User Story 2 — messaging mapping: a `.producer` span becomes a dependency with
/// `type`/`target`/`data` from `messaging.*`; a `.consumer` span populates
/// `RequestData.source` (FR-008/013–015). Non-messaging requests leave `source`
/// empty.
final class MessagingMappingTests: XCTestCase {
  func testProducerMessagingTypeTargetData() {
    let span = SpanDataBuilder(
      kind: .producer,
      attributes: [
        SemanticConventions.messagingSystem: .string("servicebus"),
        SemanticConventions.messagingDestinationName: .string("orders"),
        SemanticConventions.serverAddress: .string("sb.example.net"),
        SemanticConventions.networkProtocolName: .string("amqp"),
      ]
    ).build()

    let data = DependencyMapping.remoteDependencyData(for: span)
    XCTAssertEqual(data.type, "servicebus")
    XCTAssertEqual(data.target, "sb.example.net/orders")
    XCTAssertEqual(data.data, "amqp://sb.example.net/orders")
    // messaging keys consumed, not in properties.
    XCTAssertNil(data.properties[SemanticConventions.messagingSystem])
    XCTAssertNil(data.properties[SemanticConventions.messagingDestinationName])
  }

  func testLegacyMessagingDestinationKey() {
    let mapping = MessagingMapping.derive(from: [
      SemanticConventions.messagingSystem: .string("kafka"),
      SemanticConventions.messagingDestinationLegacy: .string("events"),
      SemanticConventions.serverAddress: .string("broker"),
    ])
    XCTAssertEqual(mapping?.target, "broker/events")
  }

  func testConsumerMessagingPopulatesRequestSource() {
    let span = SpanDataBuilder(
      name: "process-order",
      kind: .consumer,
      attributes: [
        SemanticConventions.messagingSystem: .string("servicebus"),
        SemanticConventions.messagingDestinationName: .string("orders"),
        SemanticConventions.serverAddress: .string("sb.example.net"),
      ]
    ).build()

    let data = RequestMapping.requestData(for: span)
    XCTAssertEqual(data.source, "sb.example.net/orders")
    // messaging keys are consumed on the request path too.
    XCTAssertNil(data.properties[SemanticConventions.messagingSystem])
  }

  func testNonMessagingRequestHasNoSource() {
    let span = SpanDataBuilder(name: "GET /", kind: .server).build()
    XCTAssertNil(RequestMapping.requestData(for: span).source)
  }

  func testNonMessagingSpanReturnsNil() {
    XCTAssertNil(MessagingMapping.derive(from: [SemanticConventions.serverAddress: .string("h")]))
  }
}
