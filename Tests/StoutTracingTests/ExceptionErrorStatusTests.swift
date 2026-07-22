// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import StoutCore
import XCTest

@testable import StoutTracing

/// User Story 4 — an error span `Status` forces `success = false` on the owning
/// Request/Dependency **independent of any event** (US4 Acc 1, FR-021, INV-4), and
/// the exception drop rule holds: no `ExceptionData` is fabricated unless both
/// `exception.type` and `exception.message` are present (data-model D-08).
final class ExceptionErrorStatusTests: XCTestCase {
  private func exporter(_ harness: TracingTestHarness) -> AzureMonitorTraceExporter {
    AzureMonitorTraceExporter(pipeline: harness.pipeline, envelopeFactory: harness.envelopeFactory)
  }

  func testErrorStatusFailsRequestWithNoEvent() async {
    let harness = makeTracingHarness()
    let span = SpanDataBuilder(
      name: "GET /widgets", kind: .server, status: .error(description: "boom")
    ).build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    // Only the request item — no fabricated exception.
    XCTAssertEqual(envelopes.count, 1)
    XCTAssertEqual(envelopes[0].baseType, "RequestData")
    XCTAssertEqual(envelopes[0].baseData?["success"]?.boolValue, false)
  }

  func testErrorStatusFailsDependencyWithNoEvent() async {
    let harness = makeTracingHarness()
    let span = SpanDataBuilder(
      name: "SELECT", kind: .client, status: .error(description: "query failed")
    ).build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    XCTAssertEqual(envelopes.count, 1)
    XCTAssertEqual(envelopes[0].baseType, "RemoteDependencyData")
    XCTAssertEqual(envelopes[0].baseData?["success"]?.boolValue, false)
  }

  func testErrorStatusAndExceptionEventProduceBoth() async {
    let harness = makeTracingHarness()
    var builder = SpanDataBuilder(
      name: "GET /widgets", kind: .server, status: .error(description: "boom"))
    builder.events = [
      SpanDataBuilder.event(
        "exception",
        attributes: [
          "exception.type": .string("NetworkError"),
          "exception.message": .string("connection reset"),
        ])
    ]
    let span = builder.build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 2)

    let request = envelopes.first { $0.baseType == "RequestData" }
    let exc = envelopes.first { $0.baseType == "ExceptionData" }
    XCTAssertEqual(request?.baseData?["success"]?.boolValue, false)
    XCTAssertNotNil(exc, "an exception event with type+message must yield ExceptionData")
  }

  func testExceptionEventMissingMessageIsDropped() async {
    let harness = makeTracingHarness()
    var builder = SpanDataBuilder(kind: .server, status: .error(description: "boom"))
    builder.events = [
      SpanDataBuilder.event(
        "exception", attributes: ["exception.type": .string("NetworkError")])
    ]
    let span = builder.build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    // No message ⇒ no ExceptionData; only the owning request survives.
    XCTAssertEqual(envelopes.count, 1)
    XCTAssertEqual(envelopes[0].baseType, "RequestData")
    XCTAssertNil(envelopes.first { $0.baseType == "ExceptionData" })
  }

  func testExceptionEventMissingTypeIsDropped() async {
    let harness = makeTracingHarness()
    var builder = SpanDataBuilder(kind: .client)
    builder.events = [
      SpanDataBuilder.event(
        "exception", attributes: ["exception.message": .string("connection reset")])
    ]
    let span = builder.build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    XCTAssertEqual(envelopes.count, 1)
    XCTAssertEqual(envelopes[0].baseType, "RemoteDependencyData")
    XCTAssertNil(envelopes.first { $0.baseType == "ExceptionData" })
  }
}
