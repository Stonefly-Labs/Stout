// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

/// US5 — drain-and-go-inert shutdown (D1): shutdown drains buffered items
/// best-effort within a bounded timeout, then the pipeline is inert; post-shutdown
/// submits are dropped without crash/block and only the first surfaces a single
/// rate-limited warning (Acc #6; FR-015/FR-016).
final class ShutdownTests: XCTestCase {
  private let endpoint = URL(string: "https://dc.example.com")!

  private func makeEnvelope(_ index: Int) -> Envelope {
    EnvelopeFactory(instrumentationKey: "00000000-0000-0000-0000-000000000000")
      .makeEnvelope(
        name: "Microsoft.ApplicationInsights.Message",
        payload: TestData(message: "m\(index)"),
        time: Date(timeIntervalSince1970: 0))
  }

  /// Nothing auto-flushes during submit: batch size above the item count and a long
  /// interval, so items sit buffered until `shutdown()` drains them.
  private func noAutoFlushConfig() -> ExporterConfiguration {
    ExporterConfiguration(bufferCapacity: 1024, flushInterval: 60, maxBatchSize: 10_000)
  }

  // MARK: Drain

  func testShutdownDrainsBufferedItems() async {
    let count = 5
    let transport = MockTransport(statusCode: 200)
    let pipeline = ExportPipeline(
      configuration: noAutoFlushConfig(),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: RecordingDiagnostics())

    for index in 0..<count { pipeline.submit(makeEnvelope(index)) }
    // Synchronize on the fire-and-forget submits landing in the buffer before we
    // shut down — otherwise the drain could race an un-enqueued item.
    await waitUntil { await pipeline.bufferedCount == count }

    await pipeline.shutdown()

    // The drain delivered everything and released the transport.
    let delivered = await transport.totalEnvelopes()
    XCTAssertEqual(delivered, count, "shutdown must drain all buffered items")
    let closed = await transport.shutdownCalled
    XCTAssertTrue(closed, "shutdown must release the transport")
    let dropped = await pipeline.droppedCount
    XCTAssertEqual(dropped, 0, "a successful drain drops nothing")
  }

  // MARK: Inert + single warning

  func testPostShutdownSubmitsDroppedWithSingleWarning() async {
    let diagnostics = RecordingDiagnostics()
    let pipeline = ExportPipeline(
      configuration: noAutoFlushConfig(),
      ingestionEndpoint: endpoint, transport: MockTransport(), diagnostics: diagnostics)

    await pipeline.shutdown()

    let posted = 4
    for index in 0..<posted { pipeline.submit(makeEnvelope(index)) }
    // Every post-shutdown submit is dropped (counted), none block or crash.
    await waitUntil { await pipeline.droppedCount == UInt64(posted) }
    let dropped = await pipeline.droppedCount
    XCTAssertEqual(dropped, UInt64(posted), "all post-shutdown submits are dropped")

    // Exactly one rate-limited warning, secret-free.
    let warnings = diagnostics.events.filter { $0.code == .postShutdownSubmit }
    XCTAssertEqual(warnings.count, 1, "only the first post-shutdown submit warns")
    XCTAssertEqual(warnings.first?.severity, .warning)
    XCTAssertNil(warnings.first?.message, "post-shutdown warning carries no payload")
  }

  func testPostShutdownSubmitsNeverReachTransport() async {
    let transport = MockTransport(statusCode: 200)
    let pipeline = ExportPipeline(
      configuration: noAutoFlushConfig(),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: RecordingDiagnostics())

    await pipeline.shutdown()
    for index in 0..<3 { pipeline.submit(makeEnvelope(index)) }
    await waitUntil { await pipeline.droppedCount == 3 }

    let requests = await transport.requestCount
    XCTAssertEqual(requests, 0, "inert pipeline must never hit the network")
  }

  // MARK: Idempotency

  func testSecondShutdownIsSafeNoOp() async {
    let diagnostics = RecordingDiagnostics()
    let pipeline = ExportPipeline(
      configuration: noAutoFlushConfig(),
      ingestionEndpoint: endpoint, transport: MockTransport(), diagnostics: diagnostics)

    await pipeline.shutdown()
    await pipeline.shutdown()  // must not crash, hang, or re-run the drain

    XCTAssertTrue(
      diagnostics.events.isEmpty, "idempotent shutdown emits no diagnostics on its own")
  }

  // MARK: Bounded timeout

  func testShutdownIsBoundedWhenTransportStalls() async {
    let transport = MockTransport(statusCode: 200)
    await transport.setStall(true)  // the in-flight POST hangs until cancelled
    let pipeline = ExportPipeline(
      configuration: ExporterConfiguration(
        flushInterval: 60, maxBatchSize: 10_000, shutdownDrainTimeout: 0.2),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: RecordingDiagnostics())

    pipeline.submit(makeEnvelope(0))
    await waitUntil { await pipeline.bufferedCount == 1 }

    // Shutdown must return promptly (bounded by the 0.2s drain timeout) even though
    // the transport never completes the request (FR-015).
    let start = Date()
    await pipeline.shutdown()
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertLessThan(elapsed, 2.0, "shutdown must be bounded by the drain timeout, not hang")

    // Post-shutdown the pipeline is inert regardless of the stalled drain.
    pipeline.submit(makeEnvelope(1))
    await waitUntil { await pipeline.droppedCount >= 1 }
  }
}
