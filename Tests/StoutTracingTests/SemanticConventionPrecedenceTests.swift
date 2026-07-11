// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import XCTest

@testable import StoutTracing

/// Current-over-legacy semantic-convention precedence and order-independence
/// (T018, INV-3). The **current** key must win when both are present, and the
/// result must not depend on attribute dictionary order.
final class SemanticConventionPrecedenceTests: XCTestCase {
  func testCurrentKeyWinsOverLegacy() {
    let attributes: [String: AttributeValue] = [
      SemanticConventions.httpRequestMethod: .string("GET"),
      SemanticConventions.httpMethodLegacy: .string("POST"),
    ]
    XCTAssertEqual(
      SemanticConventions.firstString(in: attributes, SemanticConventions.httpMethod), "GET")
  }

  func testLegacyKeyUsedWhenCurrentAbsent() {
    let attributes: [String: AttributeValue] = [
      SemanticConventions.httpMethodLegacy: .string("POST")
    ]
    XCTAssertEqual(
      SemanticConventions.firstString(in: attributes, SemanticConventions.httpMethod), "POST")
  }

  func testMissingConceptReturnsNil() {
    XCTAssertNil(SemanticConventions.firstString(in: [:], SemanticConventions.httpMethod))
  }

  func testPrecedenceIsDictionaryOrderIndependent() {
    // The winner is decided by the precedence LIST order, not attribute insertion
    // order. Both keys present → current wins regardless of how the dict is built.
    let a: [String: AttributeValue] = [
      SemanticConventions.httpMethodLegacy: .string("POST"),
      SemanticConventions.httpRequestMethod: .string("GET"),
    ]
    let b: [String: AttributeValue] = [
      SemanticConventions.httpRequestMethod: .string("GET"),
      SemanticConventions.httpMethodLegacy: .string("POST"),
    ]
    let ra = SemanticConventions.firstString(in: a, SemanticConventions.httpMethod)
    let rb = SemanticConventions.firstString(in: b, SemanticConventions.httpMethod)
    XCTAssertEqual(ra, "GET")
    XCTAssertEqual(rb, "GET")
    XCTAssertEqual(ra, rb)
  }

  func testHostPrecedenceThreeLevels() {
    // server.address wins over net.peer.name wins over http.host.
    let all: [String: AttributeValue] = [
      SemanticConventions.serverAddress: .string("current.example"),
      SemanticConventions.netPeerNameLegacy: .string("legacy1.example"),
      SemanticConventions.httpHostLegacy: .string("legacy2.example"),
    ]
    XCTAssertEqual(
      SemanticConventions.firstString(in: all, SemanticConventions.host), "current.example")

    let legacyOnly: [String: AttributeValue] = [
      SemanticConventions.netPeerNameLegacy: .string("legacy1.example"),
      SemanticConventions.httpHostLegacy: .string("legacy2.example"),
    ]
    XCTAssertEqual(
      SemanticConventions.firstString(in: legacyOnly, SemanticConventions.host), "legacy1.example")
  }

  func testDbStatementPrecedence() {
    let attributes: [String: AttributeValue] = [
      SemanticConventions.dbQueryText: .string("SELECT 1"),
      SemanticConventions.dbStatementLegacy: .string("SELECT 2"),
    ]
    XCTAssertEqual(
      SemanticConventions.firstString(in: attributes, SemanticConventions.dbStatement), "SELECT 1")
  }

  func testPresentKeysReportsOnlyThoseSet() {
    let attributes: [String: AttributeValue] = [
      SemanticConventions.httpRequestMethod: .string("GET")
    ]
    XCTAssertEqual(
      SemanticConventions.presentKeys(in: attributes, SemanticConventions.httpMethod),
      [SemanticConventions.httpRequestMethod])
  }
}
