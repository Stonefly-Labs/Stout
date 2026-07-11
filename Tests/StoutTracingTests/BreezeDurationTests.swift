// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutTracing

/// Duration formatting goldens (T017). Values mirror .NET
/// `TimeSpan.ToString("c")`: fraction padded to 7 digits when non-zero and omitted
/// when zero, day group only when non-zero — plus Stout's zero/negative clamp.
final class BreezeDurationTests: XCTestCase {
  private func duration(seconds: TimeInterval) -> String {
    let start = Date(timeIntervalSince1970: 1)
    return BreezeDuration.string(from: start, to: start.addingTimeInterval(seconds))
  }

  func testSubSecondPrecisionPadsToSevenDigits() {
    XCTAssertEqual(duration(seconds: 0.25), "00:00:00.2500000")
    XCTAssertEqual(duration(seconds: 1.5), "00:00:01.5000000")
  }

  func testWholeSecondOmitsFraction() {
    XCTAssertEqual(duration(seconds: 5), "00:00:05")
  }

  func testHoursMinutesSeconds() {
    // 1h 2m 3s = 3723 s.
    XCTAssertEqual(duration(seconds: 3723), "01:02:03")
  }

  func testDayGroupPresentOnlyWhenNonZero() {
    // 2d 3h 4m 5s.
    let seconds: TimeInterval = 2 * 86_400 + 3 * 3600 + 4 * 60 + 5
    XCTAssertEqual(duration(seconds: seconds), "2.03:04:05")
    // Exactly one day.
    XCTAssertEqual(duration(seconds: 86_400), "1.00:00:00")
  }

  func testZeroClampsToZeroString() {
    XCTAssertEqual(duration(seconds: 0), "00:00:00")
  }

  func testNegativeClampsToZeroString() {
    XCTAssertEqual(duration(seconds: -5), "00:00:00")
  }

  func testExtremeDurationClampsToMax() {
    // ≥ 1000 days clamps to the .NET Duration_MaxValue literal.
    XCTAssertEqual(duration(seconds: 1000 * 86_400 + 10), "999.23:59:59.9999999")
  }

  func testDeterministicForIdenticalInput() {
    XCTAssertEqual(duration(seconds: 0.123_456_7), duration(seconds: 0.123_456_7))
  }
}
