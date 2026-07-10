// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

/// US2 — non-blocking submit + flush on size and on interval
/// (Acc #4; FR-012/013; SC-001).
final class PipelineFlushTests: XCTestCase {
  private let endpoint = URL(string: "https://dc.example.com")!

  private func makeEnvelope(_ index: Int) -> Envelope {
    EnvelopeFactory(instrumentationKey: "00000000-0000-0000-0000-000000000000")
      .makeEnvelope(
        name: "Microsoft.ApplicationInsights.Message",
        payload: TestData(message: "m\(index)"),
        time: Date(timeIntervalSince1970: 0))
  }

  func testSubmitDoesNotAwaitNetwork() async {
    let transport = MockTransport()
    let pipeline = ExportPipeline(
      configuration: ExporterConfiguration(flushInterval: 60, maxBatchSize: 512),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: RecordingDiagnostics())

    // A single submit below the batch threshold must not synchronously trigger a
    // network call.
    pipeline.submit(makeEnvelope(0))
    let immediate = await transport.requestCount
    XCTAssertEqual(immediate, 0, "submit must not synchronously perform network I/O")

    await pipeline.shutdown()
  }

  func testFlushTriggersOnBatchSize() async {
    let transport = MockTransport()
    let pipeline = ExportPipeline(
      configuration: ExporterConfiguration(flushInterval: 60, maxBatchSize: 3),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: RecordingDiagnostics())

    for index in 0..<3 { pipeline.submit(makeEnvelope(index)) }

    await waitUntil { await transport.requestCount == 1 }
    let total = await transport.totalEnvelopes()
    XCTAssertEqual(total, 3)

    await pipeline.shutdown()
  }

  func testFlushTriggersOnIntervalForPartialBatch() async {
    let transport = MockTransport()
    let pipeline = ExportPipeline(
      configuration: ExporterConfiguration(flushInterval: 0.05, maxBatchSize: 512),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: RecordingDiagnostics())

    // Two items, well under the batch size: only the interval trigger can flush.
    pipeline.submit(makeEnvelope(0))
    pipeline.submit(makeEnvelope(1))

    await waitUntil { await transport.requestCount >= 1 }
    let total = await transport.totalEnvelopes()
    XCTAssertEqual(total, 2)

    await pipeline.shutdown()
  }

  func testSuccessfulSendDropsNothing() async {
    let transport = MockTransport(statusCode: 200)
    let pipeline = ExportPipeline(
      configuration: ExporterConfiguration(flushInterval: 0.05, maxBatchSize: 2),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: RecordingDiagnostics())

    for index in 0..<4 { pipeline.submit(makeEnvelope(index)) }
    await waitUntil { await transport.totalEnvelopes() == 4 }

    let dropped = await pipeline.droppedCount
    XCTAssertEqual(dropped, 0)
    await pipeline.shutdown()
  }
}
