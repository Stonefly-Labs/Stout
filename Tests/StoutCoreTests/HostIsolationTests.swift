// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

/// US4 — the consolidated do-no-harm assertion (Constitution Principle II): a
/// throwing transport and malformed/garbage bodies must never crash or block the
/// host; failures surface ONLY via `Diagnostics`, and retriable errors exhaust the
/// bounded budget then drop (spec Edge Case; FR-031).
final class HostIsolationTests: XCTestCase {
  private let endpoint = URL(string: "https://dc.example.com")!

  private func makeEnvelope(_ index: Int) -> Envelope {
    EnvelopeFactory(instrumentationKey: "00000000-0000-0000-0000-000000000000")
      .makeEnvelope(
        name: "Microsoft.ApplicationInsights.Message",
        payload: TestData(message: "m\(index)"),
        time: Date(timeIntervalSince1970: 0))
  }

  /// One item per POST, no interval flush, and zero backoff so the bounded retry
  /// budget is exercised instantly.
  private func fastRetryConfig() -> ExporterConfiguration {
    ExporterConfiguration(
      flushInterval: 60, maxBatchSize: 1, maxRetryAttempts: 3, maxRetryDelay: 0)
  }

  private func assertSecretFree(_ events: [DiagnosticEvent]) {
    for event in events {
      // Diagnostics carry only enumerated codes + magnitudes — never payload text.
      XCTAssertNil(event.message, "diagnostics must not carry a message/payload")
    }
  }

  func testThrowingTransportExhaustsBudgetThenDropsSecretFree() async {
    let transport = MockTransport(script: [.fail(MockTransportError())])
    let diagnostics = RecordingDiagnostics()
    let pipeline = ExportPipeline(
      configuration: fastRetryConfig(),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: diagnostics)

    // submit is fire-and-forget: it returns to the host without throwing.
    pipeline.submit(makeEnvelope(0))

    await waitUntil { await pipeline.droppedCount == 1 }
    let dropped = await pipeline.droppedCount
    XCTAssertEqual(dropped, 1, "the item drops once the bounded budget is exhausted")

    // Initial attempt + exactly maxRetryAttempts (3) retries.
    let requests = await transport.requestCount
    XCTAssertEqual(requests, 4, "delivery failures retry within the bounded budget")

    XCTAssertTrue(
      diagnostics.events.contains { $0.code == .permanentDrop },
      "the drop surfaces via diagnostics")
    assertSecretFree(diagnostics.events)

    await pipeline.shutdown()
  }

  func testGarbageResponseBodyNeverCrashes() async {
    // A 206 the parser cannot read: pipeline must not crash — it resends within
    // budget and then drops.
    let transport = MockTransport(
      script: [.respond(statusCode: 206, body: Data("}{ not json".utf8))])
    let diagnostics = RecordingDiagnostics()
    let pipeline = ExportPipeline(
      configuration: fastRetryConfig(),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: diagnostics)

    pipeline.submit(makeEnvelope(0))
    await waitUntil { await pipeline.droppedCount == 1 }

    let requests = await transport.requestCount
    XCTAssertEqual(requests, 4, "an unparseable 206 retries within budget, then drops")
    assertSecretFree(diagnostics.events)

    await pipeline.shutdown()
  }

  func testNonRetriableStatusDropsWithoutRetry() async {
    let transport = MockTransport(script: [.respond(statusCode: 400)])
    let diagnostics = RecordingDiagnostics()
    let pipeline = ExportPipeline(
      configuration: fastRetryConfig(),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: diagnostics)

    pipeline.submit(makeEnvelope(0))
    await waitUntil { await pipeline.droppedCount == 1 }

    let requests = await transport.requestCount
    XCTAssertEqual(requests, 1, "a non-retriable status is dropped without any retry")
    XCTAssertTrue(diagnostics.events.contains { $0.code == .permanentDrop })
    assertSecretFree(diagnostics.events)

    await pipeline.shutdown()
  }
}
