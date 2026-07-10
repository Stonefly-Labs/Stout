// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

/// US1 — connection-string parsing/validation (Acc #1/#2/#11; FR-001–005/028/029).
final class ConnectionStringTests: XCTestCase {
  private let iKey = "00000000-0000-0000-0000-000000000000"

  // MARK: Valid parsing

  func testValidStringParsesKeyAndEndpoints() throws {
    let config = try ConnectionConfiguration(
      connectionString:
        "InstrumentationKey=\(iKey);IngestionEndpoint=https://westus.example.com/;LiveEndpoint=https://live.example.com/"
    )
    XCTAssertEqual(config.instrumentationKey, iKey)
    XCTAssertEqual(config.ingestionEndpoint.absoluteString, "https://westus.example.com")
    XCTAssertEqual(config.liveEndpoint?.absoluteString, "https://live.example.com")
    XCTAssertEqual(config.trackURL.absoluteString, "https://westus.example.com/v2.1/track")
  }

  func testKeysAreCaseInsensitiveAndTrimmed() throws {
    let config = try ConnectionConfiguration(
      connectionString:
        "  instrumentationkey = \(iKey) ; INGESTIONENDPOINT = https://a.example.com/ "
    )
    XCTAssertEqual(config.instrumentationKey, iKey)
    XCTAssertEqual(config.ingestionEndpoint.absoluteString, "https://a.example.com")
  }

  func testUnknownFieldsRetainedNotRequired() throws {
    let config = try ConnectionConfiguration(
      connectionString: "InstrumentationKey=\(iKey);AADAudience=https://monitor.azure.com/"
    )
    XCTAssertEqual(config.retainedFields["AADAudience"], "https://monitor.azure.com/")
  }

  // MARK: Endpoint precedence (FR-004)

  func testEndpointPrecedenceExplicitWins() throws {
    let config = try ConnectionConfiguration(
      connectionString:
        "InstrumentationKey=\(iKey);IngestionEndpoint=https://explicit.example.com/;EndpointSuffix=applicationinsights.azure.com"
    )
    XCTAssertEqual(config.ingestionEndpoint.absoluteString, "https://explicit.example.com")
  }

  func testEndpointPrecedenceSuffixDerived() throws {
    let config = try ConnectionConfiguration(
      connectionString:
        "InstrumentationKey=\(iKey);EndpointSuffix=applicationinsights.azure.com"
    )
    XCTAssertEqual(
      config.ingestionEndpoint.absoluteString, "https://dc.applicationinsights.azure.com")
  }

  func testEndpointPrecedenceSuffixWithLocation() throws {
    let config = try ConnectionConfiguration(
      connectionString:
        "InstrumentationKey=\(iKey);Location=westus2;EndpointSuffix=applicationinsights.azure.com"
    )
    XCTAssertEqual(
      config.ingestionEndpoint.absoluteString,
      "https://westus2.dc.applicationinsights.azure.com")
  }

  func testEndpointPrecedenceDefault() throws {
    let config = try ConnectionConfiguration(connectionString: "InstrumentationKey=\(iKey)")
    XCTAssertEqual(
      config.ingestionEndpoint.absoluteString, "https://dc.services.visualstudio.com")
    XCTAssertEqual(
      config.trackURL.absoluteString, "https://dc.services.visualstudio.com/v2.1/track")
  }

  // MARK: Invalid variants (each → matching, secret-free error)

  func testEmptyStringThrows() {
    assertThrows("   ", .empty)
  }

  func testMissingInstrumentationKeyThrows() {
    assertThrows("IngestionEndpoint=https://a.example.com/", .missingInstrumentationKey)
  }

  func testMalformedInstrumentationKeyThrows() {
    assertThrows("InstrumentationKey=not-a-guid", .malformedInstrumentationKey)
  }

  func testNonHTTPSEndpointThrows() {
    assertThrows(
      "InstrumentationKey=\(iKey);IngestionEndpoint=http://insecure.example.com/",
      .nonHTTPSEndpoint(field: "IngestionEndpoint"))
  }

  func testMalformedEndpointThrows() {
    assertThrows(
      "InstrumentationKey=\(iKey);IngestionEndpoint=not a url",
      .missingOrMalformedEndpoint(field: "IngestionEndpoint"))
  }

  func testDuplicateKeyThrows() {
    assertThrows(
      "InstrumentationKey=\(iKey);InstrumentationKey=\(iKey)",
      .duplicateKey("InstrumentationKey"))
  }

  // MARK: Secret safety (FR-028) + redaction

  func testNoErrorDescriptionLeaksSecret() {
    let secretKey = "12345678-1234-1234-1234-1234567890ab"
    // A malformed non-HTTPS endpoint plus a real-looking key: no path may echo
    // the key value into the error text.
    let strings = [
      "",
      "IngestionEndpoint=https://a.example.com/",
      "InstrumentationKey=\(secretKey)-bad",
      "InstrumentationKey=\(secretKey);IngestionEndpoint=http://insecure.example.com/",
      "InstrumentationKey=\(secretKey);InstrumentationKey=\(secretKey)",
    ]
    for string in strings {
      do {
        _ = try ConnectionConfiguration(connectionString: string)
      } catch let error as ConnectionStringError {
        XCTAssertFalse(
          error.description.contains(secretKey),
          "error description leaked a secret: \(error.description)")
      } catch {
        XCTFail("unexpected error type: \(error)")
      }
    }
  }

  func testDebugDescriptionRedactsInstrumentationKey() throws {
    let config = try ConnectionConfiguration(connectionString: "InstrumentationKey=\(iKey)")
    XCTAssertFalse(config.description.contains(iKey))
    XCTAssertTrue(config.description.contains("<redacted>"))
  }

  // MARK: Helper

  private func assertThrows(
    _ connectionString: String,
    _ expected: ConnectionStringError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try ConnectionConfiguration(connectionString: connectionString), file: file, line: line
    ) { error in
      XCTAssertEqual(error as? ConnectionStringError, expected, file: file, line: line)
    }
  }
}
