// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import StoutCore
import XCTest

@testable import StoutTracing

/// User Story 3 — the shared correlation rule maps W3C trace/span ids to
/// `ai.operation.*` and the item `id` byte-for-byte in canonical lowercase hex, with
/// a root span's `ai.operation.parentId` truly absent (INV-2, SC-002). Exercises
/// ``CorrelationMapping`` directly (it operates on `TraceId`/`SpanId`/`SpanId?`, not
/// on `SpanData`, so this is the unit-level golden for the rule spec 03 reuses).
final class CorrelationMappingTests: XCTestCase {
  private let traceIdHex = "0af7651916cd43dd8448eb211c80319c"
  private let spanIdHex = "b7ad6b7169203331"
  private let parentSpanIdHex = "0000000000000001"

  private var traceId: TraceId { TraceId(fromHexString: traceIdHex) }
  private var spanId: SpanId { SpanId(fromHexString: spanIdHex) }
  private var parentSpanId: SpanId { SpanId(fromHexString: parentSpanIdHex) }

  // MARK: - Item id

  func testItemIdIsSixteenHexSpanId() {
    let id = CorrelationMapping.itemId(for: spanId)
    XCTAssertEqual(id, spanIdHex)
    XCTAssertEqual(id.count, 16)
    XCTAssertTrue(isCanonicalLowercaseHex(id), "item id must be canonical lowercase hex")
  }

  // MARK: - Span tags (non-root)

  func testSpanTagsMapTraceAndParentByteForByte() {
    let tags = CorrelationMapping.spanTags(traceId: traceId, parentSpanId: parentSpanId)

    // `ai.operation.id` ← trace id, 32-hex, byte-for-byte.
    let operationId = tags[PartATagKeys.operationId]
    XCTAssertEqual(operationId, traceIdHex)
    XCTAssertEqual(operationId?.count, 32)
    XCTAssertTrue(isCanonicalLowercaseHex(operationId ?? ""))

    // `ai.operation.parentId` ← parent span id, 16-hex, byte-for-byte.
    let parentId = tags[PartATagKeys.operationParentId]
    XCTAssertEqual(parentId, parentSpanIdHex)
    XCTAssertEqual(parentId?.count, 16)
    XCTAssertTrue(isCanonicalLowercaseHex(parentId ?? ""))
  }

  // MARK: - Span tags (root)

  func testRootSpanHasAbsentParentIdNotEmptyString() {
    let tags = CorrelationMapping.spanTags(traceId: traceId, parentSpanId: nil)

    XCTAssertEqual(tags[PartATagKeys.operationId], traceIdHex)
    // Absent, not present-and-empty — a root span must not emit the tag at all
    // (data-model §2, INV-2).
    XCTAssertNil(
      tags[PartATagKeys.operationParentId],
      "root span must omit ai.operation.parentId entirely, never an empty string")
  }

  // MARK: - Event tags (derived items)

  func testEventTagsAlwaysCarryOwningSpanAsParent() {
    let tags = CorrelationMapping.eventTags(traceId: traceId, owningSpanId: spanId)

    XCTAssertEqual(tags[PartATagKeys.operationId], traceIdHex)
    // An event-derived Exception/Message item hangs under its span, so its parent is
    // the span id — always present (data-model §2 per-item rule).
    XCTAssertEqual(tags[PartATagKeys.operationParentId], spanIdHex)
    XCTAssertEqual(tags[PartATagKeys.operationParentId]?.count, 16)
  }

  // MARK: - Determinism

  func testMappingIsPureAndRepeatable() {
    let first = CorrelationMapping.spanTags(traceId: traceId, parentSpanId: parentSpanId)
    let second = CorrelationMapping.spanTags(traceId: traceId, parentSpanId: parentSpanId)
    XCTAssertEqual(first, second, "identical ids must yield identical tags (INV-8)")
  }

  // MARK: - Helpers

  private func isCanonicalLowercaseHex(_ value: String) -> Bool {
    !value.isEmpty && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }
}
