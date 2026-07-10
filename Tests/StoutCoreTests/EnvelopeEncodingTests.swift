// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

/// US2 — newline-JSON batch encoding + timestamp/field wire correctness
/// (Acc #3; FR-006/009; SC-004).
final class EnvelopeEncodingTests: XCTestCase {
  private func makeFactory() -> EnvelopeFactory {
    EnvelopeFactory(
      instrumentationKey: "00000000-0000-0000-0000-000000000000",
      resourceTags: TelemetryTags(["ai.internal.sdkVersion": "stout:0.1.0"]))
  }

  func testBatchProducesExactlyNNewlineDelimitedObjects() throws {
    let factory = makeFactory()
    let envelopes = (0..<5).map { index in
      factory.makeEnvelope(
        name: "Microsoft.ApplicationInsights.Message",
        payload: TestData(message: "m\(index)"),
        time: Date(timeIntervalSince1970: 0))
    }
    let body = try EnvelopeEncoding.encodeBatch(envelopes)
    let text = try XCTUnwrap(String(data: body, encoding: .utf8))
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    XCTAssertEqual(lines.count, 5)
    for line in lines {
      XCTAssertFalse(line.contains("\n"))
      let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      XCTAssertNotNil(object)
    }
  }

  func testEnvelopeFieldsAndVersionOmission() throws {
    let factory = makeFactory()
    let envelope = factory.makeEnvelope(
      name: "Microsoft.ApplicationInsights.Message",
      payload: TestData(message: "hi"),
      time: Date(timeIntervalSince1970: 0))
    let body = try EnvelopeEncoding.encodeBatch([envelope])
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: body) as? [String: Any])

    XCTAssertNil(object["ver"], "envelope ver must be omitted on the wire")
    XCTAssertEqual(object["name"] as? String, "Microsoft.ApplicationInsights.Message")
    XCTAssertEqual(object["iKey"] as? String, "00000000-0000-0000-0000-000000000000")
    XCTAssertEqual(object["sampleRate"] as? Double, 100)

    let data = try XCTUnwrap(object["data"] as? [String: Any])
    XCTAssertEqual(data["baseType"] as? String, "TestData")
    let baseData = try XCTUnwrap(data["baseData"] as? [String: Any])
    XCTAssertEqual(baseData["ver"] as? Int, 2)
  }

  func testTimestampIsDeterministicUTCFractionalZ() {
    XCTAssertEqual(
      BreezeTimestamp.string(from: Date(timeIntervalSince1970: 0)),
      "1970-01-01T00:00:00.000Z")
    XCTAssertEqual(
      BreezeTimestamp.string(from: Date(timeIntervalSince1970: 1_234_567_890.123)),
      "2009-02-13T23:31:30.123Z")
  }

  func testTimestampFormatMatchesISO8601Pattern() {
    let value = BreezeTimestamp.string(from: Date(timeIntervalSince1970: 1_700_000_000.5))
    let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
    XCTAssertNotNil(value.range(of: pattern, options: .regularExpression), value)
  }
}
