// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import XCTest

@testable import StoutTracing

/// The success / responseCode / resultCode predicate (data-model §4, INV-3b).
/// User Story 1 covers the **Request** side here; User Story 2 extends the same
/// file with the Dependency side (T032).
final class SuccessPredicateTests: XCTestCase {
  // MARK: - Request side (US1)

  func testUnsetStatusHTTPSuccessBelow400() {
    XCTAssertTrue(SuccessPredicate.requestSuccess(status: .unset, httpStatusCode: 200))
    XCTAssertTrue(SuccessPredicate.requestSuccess(status: .unset, httpStatusCode: 302))
    XCTAssertTrue(SuccessPredicate.requestSuccess(status: .unset, httpStatusCode: 399))
  }

  func testUnsetStatusHTTP4xxAnd5xxFail() {
    XCTAssertFalse(SuccessPredicate.requestSuccess(status: .unset, httpStatusCode: 404))
    XCTAssertFalse(SuccessPredicate.requestSuccess(status: .unset, httpStatusCode: 500))
  }

  func testUnsetStatusZeroCodeFails() {
    XCTAssertFalse(SuccessPredicate.requestSuccess(status: .unset, httpStatusCode: 0))
  }

  func testErrorStatusForcesFailureEvenWith200() {
    XCTAssertFalse(
      SuccessPredicate.requestSuccess(status: .error(description: "boom"), httpStatusCode: 200))
  }

  func testOkStatusIsSuccessRegardlessOfCode() {
    // An explicit `.ok` is already a success; the code threshold only applies to
    // an *unset* status.
    XCTAssertTrue(SuccessPredicate.requestSuccess(status: .ok, httpStatusCode: 500))
  }

  func testNonHTTPUnsetStatusIsSuccess() {
    // No HTTP code ⇒ falls through to `status != .error`.
    XCTAssertTrue(SuccessPredicate.requestSuccess(status: .unset, httpStatusCode: nil))
  }

  func testCodeStringDefaultsToZero() {
    XCTAssertEqual(SuccessPredicate.codeString(nil), "0")
    XCTAssertEqual(SuccessPredicate.codeString("404"), "404")
  }
}
