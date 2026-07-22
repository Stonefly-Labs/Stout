// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import StoutCore
import XCTest

@testable import StoutTracing

/// User Story 4 — an `exception` span event yields a correlated `ExceptionData`
/// alongside the span's own item (US4 Acc 2, INV-4, FR-019). Exercised end-to-end
/// through ``AzureMonitorTraceExporter`` and the mock pipeline harness — no network.
final class EventMappingTests: XCTestCase {
  private func exporter(_ harness: TracingTestHarness) -> AzureMonitorTraceExporter {
    AzureMonitorTraceExporter(pipeline: harness.pipeline, envelopeFactory: harness.envelopeFactory)
  }

  /// The `ExceptionData` envelope among a captured batch, if any.
  private func exception(in envelopes: [CapturedEnvelope]) -> CapturedEnvelope? {
    envelopes.first { $0.baseType == "ExceptionData" }
  }

  func testExceptionEventBecomesCorrelatedExceptionData() async {
    let harness = makeTracingHarness()
    var builder = SpanDataBuilder(name: "GET /widgets", kind: .server)
    builder.events = [
      SpanDataBuilder.event(
        "exception",
        attributes: [
          "exception.type": .string("NetworkError"),
          "exception.message": .string("connection reset"),
          "exception.stacktrace": .string("at foo()\nat bar()"),
        ])
    ]
    let span = builder.build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    // One RequestData for the span + one ExceptionData for the event.
    let envelopes = await harness.envelopes(atLeast: 2)

    XCTAssertEqual(envelopes.count, 2)
    XCTAssertNotNil(envelopes.first { $0.baseType == "RequestData" })

    guard let exc = exception(in: envelopes) else {
      return XCTFail("expected an ExceptionData envelope")
    }
    XCTAssertEqual(exc.name, "Microsoft.ApplicationInsights.Exception")

    let details = exc.baseData?["exceptions"]?[0]
    XCTAssertEqual(exc.baseData?["ver"]?.doubleValue, 2)
    XCTAssertEqual(details?["typeName"]?.stringValue, "NetworkError")
    XCTAssertEqual(details?["message"]?.stringValue, "connection reset")
    XCTAssertEqual(details?["hasFullStack"]?.boolValue, true)
    XCTAssertEqual(details?["stack"]?.stringValue, "at foo()\nat bar()")

    // Correlated under the owning span: same operation id, parentId = span id.
    XCTAssertEqual(exc.tag(PartATagKeys.operationId), SpanDataBuilder.defaultTraceIdHex)
    XCTAssertEqual(exc.tag(PartATagKeys.operationParentId), SpanDataBuilder.defaultSpanIdHex)
    // Exception is not a request, so it carries no `ai.operation.name`.
    XCTAssertNil(exc.tag(PartATagKeys.operationName))
  }

  func testExceptionWithoutStacktraceHasNoFullStack() async {
    let harness = makeTracingHarness()
    var builder = SpanDataBuilder(kind: .client)
    builder.events = [
      SpanDataBuilder.event(
        "exception",
        attributes: [
          "exception.type": .string("IllegalState"),
          "exception.message": .string("bad state"),
        ])
    ]
    let span = builder.build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 2)

    guard let exc = exception(in: envelopes) else {
      return XCTFail("expected an ExceptionData envelope")
    }
    let details = exc.baseData?["exceptions"]?[0]
    XCTAssertEqual(details?["hasFullStack"]?.boolValue, false)
    // `stack` is absent (encodeIfPresent) when there is no stacktrace.
    XCTAssertNil(details?["stack"])
  }

  func testRemainingExceptionEventAttributesGoToProperties() async {
    let harness = makeTracingHarness()
    var builder = SpanDataBuilder(kind: .server)
    builder.events = [
      SpanDataBuilder.event(
        "exception",
        attributes: [
          "exception.type": .string("NetworkError"),
          "exception.message": .string("timeout"),
          "exception.escaped": .bool(true),
          "retry.count": .int(3),
        ])
    ]
    let span = builder.build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 2)

    guard let exc = exception(in: envelopes) else {
      return XCTFail("expected an ExceptionData envelope")
    }
    let props = exc.baseData?["properties"]
    XCTAssertEqual(props?["exception.escaped"]?.stringValue, "true")
    XCTAssertEqual(props?["retry.count"]?.stringValue, "3")
    // Consumed exception fields are not duplicated into `properties`.
    XCTAssertNil(props?["exception.type"])
    XCTAssertNil(props?["exception.message"])
  }
}
