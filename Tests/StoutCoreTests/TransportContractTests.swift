// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

/// US2 — the request the pipeline puts on the wire (Acc #7; FR-022/023).
final class TransportContractTests: XCTestCase {
  private let endpoint = URL(string: "https://dc.example.com")!

  private func makeEnvelope(_ index: Int) -> Envelope {
    EnvelopeFactory(
      instrumentationKey: "00000000-0000-0000-0000-000000000000",
      resourceTags: TelemetryTags(["ai.internal.sdkVersion": "stout:0.1.0"])
    ).makeEnvelope(
      name: "Microsoft.ApplicationInsights.Message",
      payload: TestData(message: "m\(index)"),
      time: Date(timeIntervalSince1970: 0))
  }

  func testRequestPathHeadersAndGzipBody() async throws {
    let transport = MockTransport(statusCode: 200)
    let pipeline = ExportPipeline(
      configuration: ExporterConfiguration(flushInterval: 60, maxBatchSize: 2),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: RecordingDiagnostics())

    pipeline.submit(makeEnvelope(0))
    pipeline.submit(makeEnvelope(1))
    await waitUntil { await transport.requestCount == 1 }

    let requests = await transport.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url.absoluteString, "https://dc.example.com/v2.1/track")
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.headers["Content-Type"], "application/x-json-stream")
    XCTAssertEqual(request.headers["Content-Encoding"], "gzip")

    // Body is gzip (magic bytes) and decompresses to exactly-2 newline-JSON lines.
    XCTAssertEqual(request.body[request.body.startIndex], 0x1F)
    let lines = try MockTransport.envelopeLines(request.body)
    XCTAssertEqual(lines.count, 2)
    let first = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    XCTAssertEqual(first["name"] as? String, "Microsoft.ApplicationInsights.Message")

    await pipeline.shutdown()
    let shutdownCalled = await transport.shutdownCalled
    XCTAssertTrue(shutdownCalled)
  }

  func testTwoHundredIsSuccessNoDrops() async {
    let transport = MockTransport(statusCode: 200)
    let diagnostics = RecordingDiagnostics()
    let pipeline = ExportPipeline(
      configuration: ExporterConfiguration(flushInterval: 60, maxBatchSize: 1),
      ingestionEndpoint: endpoint, transport: transport, diagnostics: diagnostics)

    pipeline.submit(makeEnvelope(0))
    await waitUntil { await transport.requestCount == 1 }

    let dropped = await pipeline.droppedCount
    XCTAssertEqual(dropped, 0)
    XCTAssertTrue(diagnostics.events.isEmpty)
    await pipeline.shutdown()
  }
}
