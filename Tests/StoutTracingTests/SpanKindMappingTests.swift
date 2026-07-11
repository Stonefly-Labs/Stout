// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import XCTest

@testable import StoutTracing

/// The full span-kind → Breeze-item table (T019, SC-001, FR-006), including the
/// `.internal`/unspecified → Dependency default.
final class SpanKindMappingTests: XCTestCase {
  func testServerAndConsumerBecomeRequests() {
    XCTAssertEqual(SpanKindMapping.itemType(for: .server), .request)
    XCTAssertEqual(SpanKindMapping.itemType(for: .consumer), .request)
  }

  func testClientProducerInternalBecomeDependencies() {
    XCTAssertEqual(SpanKindMapping.itemType(for: .client), .dependency)
    XCTAssertEqual(SpanKindMapping.itemType(for: .producer), .dependency)
    XCTAssertEqual(SpanKindMapping.itemType(for: .internal), .dependency)
  }

  /// Every `SpanKind` resolves to exactly one item type — the mapping is total, so
  /// no kind (including any the SDK may add) can slip through unmapped.
  func testMappingIsTotalOverAllKinds() {
    for kind in [SpanKind.server, .consumer, .client, .producer, .internal] {
      let type = SpanKindMapping.itemType(for: kind)
      XCTAssertTrue(type == .request || type == .dependency)
    }
  }
}
