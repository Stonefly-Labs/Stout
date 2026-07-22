// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import XCTest

@testable import OpenTelemetrySdk
@testable import StoutCore
@testable import StoutTracing

/// User Story 6 — graceful shutdown / flush, then go inert.
///
/// Two guarantees are asserted end-to-end through the real `ExportPipeline`:
///
/// 1. `flush()` forwards everything currently buffered promptly and strands
///    nothing (US6 Acc #1, FR-004).
/// 2. After the pipeline shuts down, `export(...)` is a safe no-op drop: it never
///    crashes or blocks, emits **no** telemetry, and surfaces exactly one
///    rate-limited `postShutdownSubmit` diagnostic (US6 Acc #2, FR-005/FR-016).
final class ExporterLifecycleTests: XCTestCase {
  private func exporter(_ harness: TracingTestHarness) -> AzureMonitorTraceExporter {
    AzureMonitorTraceExporter(pipeline: harness.pipeline, envelopeFactory: harness.envelopeFactory)
  }

  private func serverSpans(_ count: Int) -> [SpanData] {
    (0..<count).map { index in
      var builder = SpanDataBuilder(kind: .server, attributes: ["i": .int(index)])
      builder.spanIdHex = String(format: "%016x", index + 1)
      return builder.build()
    }
  }

  // MARK: - T048: flush forwards buffered items (US6 Acc #1)

  func testAsyncFlushForwardsBufferedItems() async {
    // A large batch size and long flush interval keep submitted items parked in the
    // buffer, so only the explicit `flush()` can forward them — proving the flush
    // path itself does the work (not the background loop).
    let harness = makeTracingHarness(
      configuration: ExporterConfiguration(flushInterval: 60, maxBatchSize: 100))
    let exp = exporter(harness)

    _ = await exp.export(spans: serverSpans(3), explicitTimeout: nil)
    await harness.waitForBuffered(atLeast: 3)

    // Nothing has been forwarded yet: the interval has not elapsed and the batch is
    // not full.
    let sentBeforeFlush = await harness.transport.requestCount
    XCTAssertEqual(sentBeforeFlush, 0)

    let result = await exp.flush(explicitTimeout: nil)
    XCTAssertEqual(result, .success)

    // All three are forwarded and nothing is stranded in the buffer.
    let envelopes = await harness.transport.capturedEnvelopes()
    XCTAssertEqual(envelopes.count, 3)
    XCTAssertTrue(envelopes.allSatisfy { $0.baseType == "RequestData" })
    let remaining = await harness.pipeline.bufferedCount
    XCTAssertEqual(remaining, 0)
    let dropped = await harness.pipeline.droppedCount
    XCTAssertEqual(dropped, 0)
  }

  /// The synchronous `flush` overload (the OTel SDK's non-`async` path) cannot await
  /// the drain, so it kicks it off and returns `.success` promptly without blocking
  /// the host. Selected here by calling from a non-`async` test.
  func testSyncFlushReturnsSuccessWithoutBlocking() {
    let harness = makeTracingHarness()
    let exp = exporter(harness)
    _ = exp.export(spans: [SpanDataBuilder(kind: .server).build()], explicitTimeout: nil)
    let result = exp.flush(explicitTimeout: nil)
    XCTAssertEqual(result, .success)
  }

  // MARK: - T049: post-shutdown export is an inert, one-warning drop (US6 Acc #2)

  func testExportAfterShutdownDropsWithoutTelemetryAndWarnsOnce() async {
    let harness = makeTracingHarness()
    let exp = exporter(harness)

    // Drain-and-go-inert: after the async shutdown returns, the pipeline is inert.
    await exp.shutdown(explicitTimeout: nil)

    // Five post-shutdown exports. Each returns without crashing or blocking; every
    // item is dropped by the inert pipeline.
    for _ in 0..<5 {
      let result = await exp.export(
        spans: [SpanDataBuilder(kind: .server).build()], explicitTimeout: nil)
      XCTAssertEqual(result, .success)
    }
    await harness.waitForDropped(atLeast: 5)

    // No telemetry left the exporter after shutdown …
    let requestCount = await harness.transport.requestCount
    XCTAssertEqual(requestCount, 0)
    let captured = await harness.transport.capturedEnvelopes()
    XCTAssertTrue(captured.isEmpty)

    // … and the post-shutdown drop is surfaced by exactly one rate-limited warning,
    // no matter how many submits arrived.
    let postShutdown = harness.diagnostics.events.filter { $0.code == .postShutdownSubmit }
    XCTAssertEqual(postShutdown.count, 1)
    XCTAssertEqual(postShutdown.first?.severity, .warning)
  }

  func testShutdownIsIdempotent() async {
    let harness = makeTracingHarness()
    let exp = exporter(harness)

    // A repeated shutdown must be a safe no-op — never hang, never fault.
    await exp.shutdown(explicitTimeout: nil)
    await exp.shutdown(explicitTimeout: nil)

    _ = await exp.export(
      spans: [SpanDataBuilder(kind: .server).build()], explicitTimeout: nil)
    await harness.waitForDropped(atLeast: 1)
    let requestCount = await harness.transport.requestCount
    XCTAssertEqual(requestCount, 0)
  }

  /// The synchronous `shutdown` overload (the OTel SDK's non-`async` exit path) must
  /// return promptly without blocking the host; it kicks the drain off in a task.
  func testSyncShutdownReturnsWithoutBlocking() {
    let harness = makeTracingHarness()
    let exp = exporter(harness)
    // In a non-`async` context the sync overload is selected; it must not block.
    exp.shutdown(explicitTimeout: nil)
  }
}
