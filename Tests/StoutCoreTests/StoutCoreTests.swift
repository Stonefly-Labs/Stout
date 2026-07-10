// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

/// Foundational-type sanity checks (spec 001, Phase 2). Story-level suites
/// (connection string, envelope-encoding golden tests, pipeline, retry, …) are
/// added by their respective user-story tasks.
final class StoutCoreTests: XCTestCase {
  // MARK: TelemetryTags

  func testTelemetryTagsMergePrefersOverlay() {
    let base = TelemetryTags([
      "ai.cloud.role": "orders-api",
      "ai.internal.sdkVersion": "stout:0.1.0",
    ])
    let overlay = TelemetryTags(["ai.cloud.role": "payments"])

    let merged = overlay.merging(over: base)

    XCTAssertEqual(merged["ai.cloud.role"], "payments")
    XCTAssertEqual(merged["ai.internal.sdkVersion"], "stout:0.1.0")
  }

  func testTelemetryTagsEncodeAsFlatObject() throws {
    let tags = TelemetryTags(["ai.cloud.role": "orders-api"])
    let data = try JSONEncoder().encode(tags)
    let decoded = try JSONSerialization.jsonObject(with: data) as? [String: String]
    XCTAssertEqual(decoded, ["ai.cloud.role": "orders-api"])
  }

  // MARK: ExporterConfiguration defaults (FR-017)

  func testExporterConfigurationDefaults() {
    let config = ExporterConfiguration()
    XCTAssertEqual(config.bufferCapacity, 2048)
    XCTAssertEqual(config.flushInterval, 5)
    XCTAssertEqual(config.maxBatchSize, 512)
    XCTAssertEqual(config.shutdownDrainTimeout, 30)
    XCTAssertEqual(config.maxRetryAttempts, 3)
    XCTAssertEqual(config.maxRetryDelay, 60)
  }

  // MARK: Envelope seam + wire shape (FR-006/007/008)

  func testEnvelopeEncodesSeamAndOmitsVersion() throws {
    struct StubData: BaseData {
      static var baseType: String { "StubData" }
      let ver = 2
      let message: String
    }

    let envelope = Envelope(
      name: "Microsoft.ApplicationInsights.Message",
      time: "2026-07-09T14:12:03.412Z",
      sampleRate: 100,
      instrumentationKey: "00000000-0000-0000-0000-000000000000",
      tags: TelemetryTags(["ai.internal.sdkVersion": "stout:0.1.0"]),
      data: DataContainer(baseType: StubData.baseType, baseData: StubData(message: "hi"))
    )

    let data = try JSONEncoder().encode(envelope)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertNil(object["ver"], "envelope ver must be omitted on the wire")
    XCTAssertEqual(object["name"] as? String, "Microsoft.ApplicationInsights.Message")
    XCTAssertEqual(object["time"] as? String, "2026-07-09T14:12:03.412Z")
    XCTAssertEqual(object["sampleRate"] as? Double, 100)
    XCTAssertEqual(object["iKey"] as? String, "00000000-0000-0000-0000-000000000000")

    let dataObject = try XCTUnwrap(object["data"] as? [String: Any])
    XCTAssertEqual(dataObject["baseType"] as? String, "StubData")
    let baseData = try XCTUnwrap(dataObject["baseData"] as? [String: Any])
    XCTAssertEqual(baseData["ver"] as? Int, 2)
    XCTAssertEqual(baseData["message"] as? String, "hi")
  }

  // MARK: Diagnostics event is secret-free by construction (FR-028)

  func testDiagnosticEventCarriesOnlyEnumeratedFields() {
    let event = DiagnosticEvent(
      severity: .warning,
      code: .bufferOverflow,
      itemCount: 7,
      message: "buffer full"
    )
    XCTAssertEqual(event.code, .bufferOverflow)
    XCTAssertEqual(event.itemCount, 7)
  }
}
