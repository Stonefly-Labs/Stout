// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

/// US4 — `RetryPolicy` wired into the export loop (T028): a transient failure
/// recovers, and a `206` re-queues only the retriable survivors while dropping the
/// permanent rejects (Acc #8; FR-025).
final class RetryPipelineTests: XCTestCase {
  private let endpoint = URL(string: "https://dc.example.com")!

  private func makeEnvelope(_ index: Int) -> Envelope {
    EnvelopeFactory(instrumentationKey: "00000000-0000-0000-0000-000000000000")
      .makeEnvelope(
        name: "Microsoft.ApplicationInsights.Message",
        payload: TestData(message: "m\(index)"),
        time: Date(timeIntervalSince1970: 0))
  }

  func testTransientFailureThenSuccessDropsNothing() async {
    // 503 (retriable whole-response) then 200: the batch recovers on retry.
    let transport = MockTransport(script: [
      .respond(statusCode: 503),
      .respond(statusCode: 200),
    ])
    let diagnostics = RecordingDiagnostics()
    let pipeline = ExportPipeline(
      configuration: ExporterConfiguration(
        flushInterval: 60, maxBatchSize: 1, maxRetryDelay: 0),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: diagnostics)

    pipeline.submit(makeEnvelope(0))
    await waitUntil { await transport.requestCount == 2 }

    let dropped = await pipeline.droppedCount
    XCTAssertEqual(dropped, 0, "a transient failure that then succeeds drops nothing")
    XCTAssertTrue(diagnostics.events.isEmpty, "successful recovery emits no diagnostics")

    await pipeline.shutdown()
  }

  func testPartialSuccessRetriesSurvivorsAndDropsPermanent() async {
    // Batch of 3 → 206: index errored-retriable (500) is resent, errored-permanent
    // (400) is dropped, the third (not in errors) is accepted. The resend gets 200.
    let partial = """
      {"itemsReceived":3,"itemsAccepted":1,\
      "errors":[{"index":0,"statusCode":500,"message":"retry me"},\
      {"index":1,"statusCode":400,"message":"reject me"}]}
      """
    let transport = MockTransport(script: [
      .respond(statusCode: 206, body: Data(partial.utf8)),
      .respond(statusCode: 200),
    ])
    let diagnostics = RecordingDiagnostics()
    let pipeline = ExportPipeline(
      configuration: ExporterConfiguration(
        flushInterval: 60, maxBatchSize: 3, maxRetryDelay: 0),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: diagnostics)

    for index in 0..<3 { pipeline.submit(makeEnvelope(index)) }

    await waitUntil { await transport.requestCount == 2 }

    // Exactly the one permanently-rejected item is dropped.
    let dropped = await pipeline.droppedCount
    XCTAssertEqual(dropped, 1, "only the non-retriable per-item reject is dropped")

    // First POST carried all 3; the retry carried only the 1 retriable survivor.
    let totalEnvelopes = await transport.totalEnvelopes()
    XCTAssertEqual(totalEnvelopes, 4, "3 sent, then 1 survivor resent")

    let permanentDrops = diagnostics.events.filter { $0.code == .permanentDrop }
    XCTAssertEqual(permanentDrops.reduce(UInt64(0)) { $0 + ($1.itemCount ?? 0) }, 1)

    await pipeline.shutdown()
  }
}
