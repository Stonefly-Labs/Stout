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

  // MARK: - Dependency side (US2)

  func testDependencyErrorStatusFails() {
    XCTAssertFalse(SuccessPredicate.dependencySuccess(status: .error(description: "boom")))
  }

  func testDependencyUnsetStatusIsSuccess() {
    // No code threshold on the dependency side — unset status is a success.
    XCTAssertTrue(SuccessPredicate.dependencySuccess(status: .unset))
  }

  func testDependencyOkStatusIsSuccess() {
    XCTAssertTrue(SuccessPredicate.dependencySuccess(status: .ok))
  }

  func testDependency4xx5xxWithUnsetStatusIsStillSuccess() {
    // A dependency HTTP 4xx/5xx with an unset span status is a **success** — there
    // is no HTTP/gRPC code threshold for dependencies (INV-3b, FR-012).
    let span = SpanDataBuilder(
      kind: .client,
      status: .unset,
      attributes: [
        SemanticConventions.httpRequestMethod: .string("GET"),
        SemanticConventions.httpResponseStatusCode: .int(503),
        SemanticConventions.urlFull: .string("https://api.example.com/x"),
      ]
    ).build()

    let data = DependencyMapping.remoteDependencyData(for: span)
    XCTAssertEqual(data.resultCode, "503")
    XCTAssertTrue(data.success, "a dependency 5xx with unset status must be a success")
  }

  func testDependencyErrorStatusFailsEndToEnd() {
    let span = SpanDataBuilder(
      kind: .client,
      status: .error(description: "timeout"),
      attributes: [
        SemanticConventions.httpRequestMethod: .string("GET"),
        SemanticConventions.httpResponseStatusCode: .int(200),
        SemanticConventions.urlFull: .string("https://api.example.com/x"),
      ]
    ).build()

    XCTAssertFalse(DependencyMapping.remoteDependencyData(for: span).success)
  }
}
