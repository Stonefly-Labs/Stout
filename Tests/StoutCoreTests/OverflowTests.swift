// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

/// US3 — bounded buffer with drop-on-overflow: submits never block, memory stays
/// bounded to the configured capacity, and `droppedCount` increments by exactly
/// the overflow count (Acc #5; FR-014; SC-003).
final class OverflowTests: XCTestCase {
  private let endpoint = URL(string: "https://dc.example.com")!

  private func makeEnvelope(_ index: Int) -> Envelope {
    EnvelopeFactory(instrumentationKey: "00000000-0000-0000-0000-000000000000")
      .makeEnvelope(
        name: "Microsoft.ApplicationInsights.Message",
        payload: TestData(message: "m\(index)"),
        time: Date(timeIntervalSince1970: 0))
  }

  /// A configuration where nothing flushes during submit — `maxBatchSize` above
  /// capacity (no size trigger) and a long `flushInterval` (no interval trigger)
  /// — so the buffer simply fills to `bufferCapacity` and the rest overflow.
  private func noAutoFlushConfig(capacity: Int) -> ExporterConfiguration {
    ExporterConfiguration(
      bufferCapacity: capacity, flushInterval: 60, maxBatchSize: capacity + 10_000)
  }

  func testOverflowDropsExactCountAndBoundsMemory() async {
    let capacity = 8
    let overflow = 5
    let transport = MockTransport(statusCode: 200)
    let pipeline = ExportPipeline(
      configuration: noAutoFlushConfig(capacity: capacity),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: RecordingDiagnostics())

    for index in 0..<(capacity + overflow) { pipeline.submit(makeEnvelope(index)) }

    // Exactly the overflow count is dropped; submits never blocked to get here.
    await waitUntil { await pipeline.droppedCount == UInt64(overflow) }
    let dropped = await pipeline.droppedCount
    XCTAssertEqual(dropped, UInt64(overflow), "droppedCount must equal the exact overflow")

    // Drain what was retained: exactly `capacity` items survived, proving the
    // buffer never grew past capacity (SC-003).
    await pipeline.flushNow()
    let delivered = await transport.totalEnvelopes()
    XCTAssertEqual(delivered, capacity, "buffer must retain exactly capacity items, no more")

    await pipeline.shutdown()
  }

  func testOverflowEmitsSecretFreeDiagnostic() async {
    let capacity = 4
    let overflow = 3
    let diagnostics = RecordingDiagnostics()
    let pipeline = ExportPipeline(
      configuration: noAutoFlushConfig(capacity: capacity),
      ingestionEndpoint: endpoint, transport: MockTransport(), diagnostics: diagnostics)

    for index in 0..<(capacity + overflow) { pipeline.submit(makeEnvelope(index)) }
    await waitUntil { await pipeline.droppedCount == UInt64(overflow) }

    let overflowEvents = diagnostics.events.filter { $0.code == .bufferOverflow }
    XCTAssertFalse(overflowEvents.isEmpty, "overflow must surface via diagnostics")
    for event in overflowEvents {
      XCTAssertEqual(event.severity, .warning)
      // Secret-free by construction: no free-form message carrying payload.
      XCTAssertNil(event.message, "overflow diagnostics must carry no message/payload")
    }
    // Accounting is exact: the reported item magnitudes sum to the overflow.
    let reported = overflowEvents.reduce(UInt64(0)) { $0 + ($1.itemCount ?? 0) }
    XCTAssertEqual(reported, UInt64(overflow), "reported item magnitudes must sum to the overflow")

    await pipeline.shutdown()
  }

  func testLargeBurstStaysBoundedAndCountsExactly() async {
    let capacity = 16
    let burst = capacity * 4  // 3× capacity of overflow
    let transport = MockTransport(statusCode: 200)
    let pipeline = ExportPipeline(
      configuration: noAutoFlushConfig(capacity: capacity),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: RecordingDiagnostics())

    for index in 0..<burst { pipeline.submit(makeEnvelope(index)) }

    let expectedDrops = UInt64(burst - capacity)
    await waitUntil { await pipeline.droppedCount == expectedDrops }
    let dropped = await pipeline.droppedCount
    XCTAssertEqual(dropped, expectedDrops, "a large burst drops everything past capacity, no more")

    await pipeline.flushNow()
    let delivered = await transport.totalEnvelopes()
    XCTAssertEqual(delivered, capacity, "memory stayed bounded to capacity under a large burst")

    await pipeline.shutdown()
  }
}
