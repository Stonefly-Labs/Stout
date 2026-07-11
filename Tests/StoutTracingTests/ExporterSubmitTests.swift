// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import XCTest

@testable import StoutTracing

/// User Story 1 — the exporter's submit contract (FR-004): `export(...)` returns
/// promptly with `.success`, hands items off to the pipeline, and never blocks the
/// host on network I/O.
final class ExporterSubmitTests: XCTestCase {
  private func exporter(_ harness: TracingTestHarness) -> AzureMonitorTraceExporter {
    AzureMonitorTraceExporter(pipeline: harness.pipeline, envelopeFactory: harness.envelopeFactory)
  }

  func testSyncExportReturnsSuccess() {
    let harness = makeTracingHarness()
    let span = SpanDataBuilder(kind: .server).build()
    let result = exporter(harness).export(spans: [span], explicitTimeout: nil)
    XCTAssertEqual(result, .success)
  }

  func testAsyncExportReturnsSuccess() async {
    let harness = makeTracingHarness()
    let span = SpanDataBuilder(kind: .server).build()
    let result = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    XCTAssertEqual(result, .success)
  }

  func testExportSubmitsThroughPipeline() async {
    let harness = makeTracingHarness()
    _ = await exporter(harness).export(
      spans: [SpanDataBuilder(kind: .server).build()], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)
    XCTAssertEqual(envelopes.count, 1)
    XCTAssertEqual(envelopes[0].baseType, "RequestData")
  }

  func testExportDoesNotBlockOnSubmission() {
    // `submit` is fire-and-forget: the synchronous call must return without waiting
    // for the actor to enqueue, encode, or POST anything.
    let harness = makeTracingHarness()
    let spans = (0..<50).map { _ in SpanDataBuilder(kind: .server).build() }
    let result = exporter(harness).export(spans: spans, explicitTimeout: nil)
    XCTAssertEqual(result, .success)
    // Nothing has necessarily reached the transport yet — no network on the host path.
  }

  func testMultipleSpansEachProduceOneEnvelope() async {
    let harness = makeTracingHarness()
    let spans = (0..<3).map { index in
      var builder = SpanDataBuilder(kind: .server, attributes: ["i": .int(index)])
      builder.spanIdHex = String(format: "%016x", index + 1)
      return builder.build()
    }
    _ = await exporter(harness).export(spans: spans, explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 3)
    XCTAssertEqual(envelopes.count, 3)
    XCTAssertTrue(envelopes.allSatisfy { $0.baseType == "RequestData" })
  }
}
