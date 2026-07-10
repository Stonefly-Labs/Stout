// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

/// US2 — many concurrent producers below capacity: no corruption, no races, all
/// items enqueued and eventually flushed (Edge Case "concurrent producers";
/// FR-012; analysis C2). Runs under Swift 6 strict concurrency.
final class ConcurrentProducersTests: XCTestCase {
  func testConcurrentSubmitsAllEnqueuedAndFlushed() async {
    let endpoint = URL(string: "https://dc.example.com")!
    let transport = MockTransport(statusCode: 200)
    let pipeline = ExportPipeline(
      configuration: ExporterConfiguration(
        bufferCapacity: 4096, flushInterval: 0.05, maxBatchSize: 64),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: RecordingDiagnostics())

    let producerCount = 500
    let factory = EnvelopeFactory(instrumentationKey: "00000000-0000-0000-0000-000000000000")

    await withTaskGroup(of: Void.self) { group in
      for index in 0..<producerCount {
        group.addTask {
          pipeline.submit(
            factory.makeEnvelope(
              name: "Microsoft.ApplicationInsights.Message",
              payload: TestData(message: "m\(index)"),
              time: Date(timeIntervalSince1970: 0)))
        }
      }
    }

    // All 500 (below the 4096 capacity) must eventually be flushed, none dropped.
    await waitUntil(timeout: 5.0) { await transport.totalEnvelopes() == producerCount }
    let total = await transport.totalEnvelopes()
    XCTAssertEqual(total, producerCount)
    let dropped = await pipeline.droppedCount
    XCTAssertEqual(dropped, 0)

    await pipeline.shutdown()
  }
}
