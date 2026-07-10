// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

/// US4 — parse `itemsReceived`/`itemsAccepted`/per-item `errors`; tolerate empty,
/// non-JSON, and malformed bodies without crashing (Acc #8; FR-024).
final class IngestionResponseTests: XCTestCase {
  private func data(_ json: String) -> Data { Data(json.utf8) }

  func testParsesPartialSuccessBody() throws {
    let body = data(
      """
      {"itemsReceived":3,"itemsAccepted":2,"errors":[{"index":1,"statusCode":429,"message":"throttled"}]}
      """)
    let parsed = try XCTUnwrap(IngestionResponse.parse(body))
    XCTAssertEqual(parsed.itemsReceived, 3)
    XCTAssertEqual(parsed.itemsAccepted, 2)
    XCTAssertEqual(parsed.errors.count, 1)
    let error = try XCTUnwrap(parsed.errors.first)
    XCTAssertEqual(error.index, 1)
    XCTAssertEqual(error.statusCode, 429)
    XCTAssertEqual(error.message, "throttled")
  }

  func testParsesMultipleErrors() throws {
    let body = data(
      """
      {"itemsReceived":4,"itemsAccepted":1,"errors":[\
      {"index":0,"statusCode":400,"message":"bad"},\
      {"index":2,"statusCode":500,"message":"boom"},\
      {"index":3,"statusCode":503,"message":"busy"}]}
      """)
    let parsed = try XCTUnwrap(IngestionResponse.parse(body))
    XCTAssertEqual(parsed.errors.map(\.index), [0, 2, 3])
    XCTAssertEqual(parsed.errors.map(\.statusCode), [400, 500, 503])
  }

  func testFullSuccessHasNoErrors() throws {
    let parsed = try XCTUnwrap(
      IngestionResponse.parse(data(#"{"itemsReceived":2,"itemsAccepted":2}"#)))
    XCTAssertEqual(parsed.itemsReceived, 2)
    XCTAssertEqual(parsed.itemsAccepted, 2)
    XCTAssertTrue(parsed.errors.isEmpty)
  }

  func testMissingCountsDefaultToZero() throws {
    let parsed = try XCTUnwrap(IngestionResponse.parse(data("{}")))
    XCTAssertEqual(parsed.itemsReceived, 0)
    XCTAssertEqual(parsed.itemsAccepted, 0)
    XCTAssertTrue(parsed.errors.isEmpty)
  }

  func testSkipsMalformedErrorEntries() throws {
    // One entry missing `statusCode` is dropped; the well-formed one survives.
    let body = data(
      """
      {"itemsReceived":2,"itemsAccepted":1,"errors":[\
      {"index":0,"message":"no status"},{"index":1,"statusCode":500,"message":"ok"}]}
      """)
    let parsed = try XCTUnwrap(IngestionResponse.parse(body))
    XCTAssertEqual(parsed.errors.count, 1)
    XCTAssertEqual(parsed.errors.first?.statusCode, 500)
  }

  func testEmptyBodyReturnsNil() {
    XCTAssertNil(IngestionResponse.parse(Data()))
  }

  func testNonJSONBodyReturnsNil() {
    XCTAssertNil(IngestionResponse.parse(data("this is not json")))
  }

  func testMalformedJSONReturnsNil() {
    XCTAssertNil(IngestionResponse.parse(data(#"{"itemsReceived":"#)))
  }

  func testNonObjectJSONReturnsNil() {
    // Valid JSON, but an array — not an ingestion result object.
    XCTAssertNil(IngestionResponse.parse(data("[1,2,3]")))
  }
}
