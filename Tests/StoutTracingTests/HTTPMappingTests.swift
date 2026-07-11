// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import XCTest

@testable import StoutTracing

/// User Story 1 — shared HTTP derivation on the Request side (FR-010, INV-3): URL
/// reconstruction, route/method-derived name, and current-over-legacy key
/// precedence. Pure, so asserted directly against ``HTTPMapping``.
final class HTTPMappingTests: XCTestCase {
  func testExplicitFullURLFromCurrentKey() {
    let http = HTTPMapping.derive(from: [
      SemanticConventions.httpRequestMethod: .string("GET"),
      SemanticConventions.urlFull: .string("https://host/a?b=c"),
    ])
    XCTAssertEqual(http?.url, "https://host/a?b=c")
  }

  func testFullURLFromLegacyHTTPURL() {
    let http = HTTPMapping.derive(from: [
      SemanticConventions.httpMethodLegacy: .string("POST"),
      SemanticConventions.httpUrlLegacy: .string("https://legacy/host"),
    ])
    XCTAssertEqual(http?.url, "https://legacy/host")
  }

  func testURLReconstructedFromSchemeHostPortPath() {
    let http = HTTPMapping.derive(from: [
      SemanticConventions.httpRequestMethod: .string("GET"),
      SemanticConventions.urlScheme: .string("https"),
      SemanticConventions.serverAddress: .string("example.com"),
      SemanticConventions.serverPort: .int(8443),
      SemanticConventions.urlPath: .string("/things"),
    ])
    XCTAssertEqual(http?.url, "https://example.com:8443/things")
    XCTAssertEqual(http?.target, "example.com:8443")
  }

  func testDerivedNameFromMethodAndRoute() {
    let http = HTTPMapping.derive(from: [
      SemanticConventions.httpRequestMethod: .string("GET"),
      SemanticConventions.httpRoute: .string("/widgets/{id}"),
    ])
    XCTAssertEqual(http?.derivedName, "GET /widgets/{id}")
  }

  func testDerivedNameFromRouteWithoutMethod() {
    let http = HTTPMapping.derive(from: [
      SemanticConventions.httpRoute: .string("/widgets/{id}")
    ])
    XCTAssertEqual(http?.derivedName, "/widgets/{id}")
  }

  func testCurrentMethodKeyWinsOverLegacy() {
    let http = HTTPMapping.derive(from: [
      SemanticConventions.httpRequestMethod: .string("GET"),
      SemanticConventions.httpMethodLegacy: .string("POST"),
      SemanticConventions.httpRoute: .string("/r"),
    ])
    XCTAssertEqual(http?.derivedName, "GET /r")
  }

  func testStatusCodeParsedFromCurrentKey() {
    let http = HTTPMapping.derive(from: [
      SemanticConventions.httpResponseStatusCode: .int(503)
    ])
    XCTAssertEqual(http?.statusCode, 503)
    XCTAssertEqual(http?.statusString, "503")
  }

  func testNonHTTPSpanYieldsNil() {
    // Generic keys alone (no HTTP-specific signal) must not classify as HTTP.
    let http = HTTPMapping.derive(from: [
      SemanticConventions.serverAddress: .string("db.internal")
    ])
    XCTAssertNil(http)
  }
}
