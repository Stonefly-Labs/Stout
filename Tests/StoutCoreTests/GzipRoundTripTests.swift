// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

/// US2 — gzip round-trip + framing (Acc #3; FR-010; SC-004). Runs identically on
/// Apple (SDK zlib) and Linux (CZlib).
final class GzipRoundTripTests: XCTestCase {
  func testRoundTripReproducesInput() throws {
    let inputs: [[UInt8]] = [
      [],
      Array("hello".utf8),
      Array(String(repeating: "Breeze\n", count: 5000).utf8),
      (0..<4096).map { UInt8($0 % 256) },
    ]
    for input in inputs {
      let compressed = try gzip(input)
      let restored = try gunzip(compressed)
      XCTAssertEqual(restored, input)
    }
  }

  func testOutputHasGzipHeaderAndTrailer() throws {
    let compressed = try gzip(Array("payload".utf8))
    XCTAssertGreaterThanOrEqual(compressed.count, 18)
    // gzip magic + DEFLATE method.
    XCTAssertEqual(compressed[0], 0x1F)
    XCTAssertEqual(compressed[1], 0x8B)
    XCTAssertEqual(compressed[2], 0x08)
  }

  func testCompressionActuallyShrinksRepetitiveInput() throws {
    let input = Array(String(repeating: "AAAA", count: 10000).utf8)
    let compressed = try gzip(input)
    XCTAssertLessThan(compressed.count, input.count)
  }
}
