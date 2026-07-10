// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

/// US4 — status classification, `Retry-After` parsing, and bounded full-jitter
/// backoff (Acc #8/#9; FR-025/026/027).
final class RetryClassificationTests: XCTestCase {
  private let policy = RetryPolicy(configuration: ExporterConfiguration())

  // MARK: - Whole-response classification

  func testWholeResponseRetriableSet() {
    for status in [408, 429, 439, 401, 403, 500, 502, 503, 504] {
      XCTAssertTrue(policy.isWholeResponseRetriable(status), "\(status) must be retriable")
    }
  }

  func testWholeResponseNonRetriable() {
    for status in [200, 206, 400, 402, 404, 405, 409, 413] {
      XCTAssertFalse(policy.isWholeResponseRetriable(status), "\(status) must be non-retriable")
    }
  }

  /// `401`/`403` mirror .NET: classified retriable (they exhaust the budget here,
  /// but survive the token refresh added in spec 05).
  func testAuthStatusesAreRetriable() {
    XCTAssertTrue(policy.isWholeResponseRetriable(401))
    XCTAssertTrue(policy.isWholeResponseRetriable(403))
  }

  // MARK: - Per-item (206) classification

  func testPerItemRetriableSet() {
    for status in [408, 429, 439, 500, 503] {
      XCTAssertTrue(policy.isPerItemRetriable(status), "\(status) must be per-item retriable")
    }
  }

  func testPerItemNonRetriable() {
    // The per-item set is strictly narrower than the whole-response set.
    for status in [400, 401, 402, 403, 404, 502, 504] {
      XCTAssertFalse(policy.isPerItemRetriable(status), "\(status) must be per-item non-retriable")
    }
  }

  // MARK: - Attempt budget

  func testCanRetryHonorsBudget() {
    // Default maxRetryAttempts == 3 → attempts 0,1,2 permitted, 3 exhausted.
    XCTAssertTrue(policy.canRetry(afterAttempt: 0))
    XCTAssertTrue(policy.canRetry(afterAttempt: 1))
    XCTAssertTrue(policy.canRetry(afterAttempt: 2))
    XCTAssertFalse(policy.canRetry(afterAttempt: 3))
    XCTAssertFalse(policy.canRetry(afterAttempt: 4))
  }

  // MARK: - Backoff schedule

  func testBackoffCeilingIsExponentialThenCapped() {
    // baseDelay 1s, cap 60s: 1, 2, 4, 8, 16, 32, then capped at 60.
    XCTAssertEqual(policy.backoffCeiling(forAttempt: 0), 1, accuracy: 1e-9)
    XCTAssertEqual(policy.backoffCeiling(forAttempt: 1), 2, accuracy: 1e-9)
    XCTAssertEqual(policy.backoffCeiling(forAttempt: 2), 4, accuracy: 1e-9)
    XCTAssertEqual(policy.backoffCeiling(forAttempt: 5), 32, accuracy: 1e-9)
    XCTAssertEqual(policy.backoffCeiling(forAttempt: 6), 60, accuracy: 1e-9)  // 64 → capped
    XCTAssertEqual(policy.backoffCeiling(forAttempt: 20), 60, accuracy: 1e-9)
  }

  func testJitteredDelayStaysWithinCeiling() {
    var generator = SystemRandomNumberGenerator()
    for attempt in 0..<8 {
      let ceiling = policy.backoffCeiling(forAttempt: attempt)
      for _ in 0..<64 {
        let delay = policy.jitteredDelay(forAttempt: attempt, using: &generator)
        XCTAssertGreaterThanOrEqual(delay, 0)
        XCTAssertLessThanOrEqual(delay, ceiling)
      }
    }
  }

  func testJitteredDelayIsZeroWhenCeilingIsZero() {
    // maxRetryDelay 0 collapses the ceiling → a deterministic immediate retry.
    let fast = RetryPolicy(configuration: ExporterConfiguration(maxRetryDelay: 0))
    var generator = SystemRandomNumberGenerator()
    XCTAssertEqual(fast.jitteredDelay(forAttempt: 3, using: &generator), 0)
  }

  // MARK: - Retry-After parsing

  func testRetryAfterDeltaSeconds() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    XCTAssertEqual(policy.retryAfterDelay(headerValue: "120", now: now), 120)
    XCTAssertEqual(policy.retryAfterDelay(headerValue: "  30 ", now: now), 30)
    XCTAssertEqual(policy.retryAfterDelay(headerValue: "0", now: now), 0)
  }

  func testRetryAfterNegativeDeltaClampsToZero() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    XCTAssertEqual(policy.retryAfterDelay(headerValue: "-5", now: now), 0)
  }

  func testRetryAfterHTTPDateInFuture() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let future = now.addingTimeInterval(3600)
    let header = Self.httpDate(future)
    let delay = try XCTUnwrap(policy.retryAfterDelay(headerValue: header, now: now))
    XCTAssertEqual(delay, 3600, accuracy: 1.0)
  }

  func testRetryAfterHTTPDateInPastClampsToZero() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let past = now.addingTimeInterval(-3600)
    let delay = try XCTUnwrap(policy.retryAfterDelay(headerValue: Self.httpDate(past), now: now))
    XCTAssertEqual(delay, 0, accuracy: 1e-9)
  }

  func testRetryAfterAbsentOrUnparseableReturnsNil() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    XCTAssertNil(policy.retryAfterDelay(headerValue: nil, now: now))
    XCTAssertNil(policy.retryAfterDelay(headerValue: "", now: now))
    XCTAssertNil(policy.retryAfterDelay(headerValue: "   ", now: now))
    XCTAssertNil(policy.retryAfterDelay(headerValue: "not-a-date", now: now))
  }

  /// Format a `Date` as an RFC 7231 IMF-fixdate (the form the service emits).
  private static func httpDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.string(from: date)
  }
}
