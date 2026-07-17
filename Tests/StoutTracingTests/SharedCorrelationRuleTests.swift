// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import StoutCore
import XCTest

@testable import StoutTracing

/// User Story 3 — the trace/span-id → `ai.operation.*` mapping is a single shared
/// rule that depends **only** on the ids, not on where they came from (SC-007,
/// FR-024). ``CorrelationMapping`` takes `TraceId`/`SpanId`/`SpanId?` — never a
/// `SpanData` — so spec 03 (Logs) reuses it verbatim for log-record correlation and
/// gets byte-identical `ai.operation.*` tags. This suite locks that contract: same
/// ids in, same tags out, regardless of the originating signal.
final class SharedCorrelationRuleTests: XCTestCase {
  private let traceIdHex = "0af7651916cd43dd8448eb211c80319c"
  private let spanIdHex = "b7ad6b7169203331"
  private let parentSpanIdHex = "00f067aa0ba902b7"

  private var traceId: TraceId { TraceId(fromHexString: traceIdHex) }
  private var spanId: SpanId { SpanId(fromHexString: spanIdHex) }
  private var parentSpanId: SpanId { SpanId(fromHexString: parentSpanIdHex) }

  /// The rule output matches a hand-built expected tag set — the exact contract
  /// spec 03 depends on when it correlates a `ReadableLogRecord` with the same ids.
  func testSpanTagsMatchTheExpectedSharedContract() {
    var expected = TelemetryTags()
    expected[PartATagKeys.operationId] = traceIdHex
    expected[PartATagKeys.operationParentId] = parentSpanIdHex

    let actual = CorrelationMapping.spanTags(traceId: traceId, parentSpanId: parentSpanId)
    XCTAssertEqual(actual, expected)
  }

  /// The same ids produce the same tags no matter which caller supplies them: a
  /// "span" caller and a "log record" caller (both reduced to raw ids) are
  /// indistinguishable to the rule.
  func testIdenticalIdsProduceIdenticalTagsAcrossSignals() {
    // Signal A: ids as a span exporter would pass them.
    let fromSpan = CorrelationMapping.spanTags(traceId: traceId, parentSpanId: parentSpanId)
    // Signal B: the very same ids as a (future) log exporter would pass them —
    // re-derived independently to prove the rule ignores provenance.
    let fromLog = CorrelationMapping.spanTags(
      traceId: TraceId(fromHexString: traceIdHex),
      parentSpanId: SpanId(fromHexString: parentSpanIdHex))

    XCTAssertEqual(fromSpan, fromLog, "correlation must depend only on the ids (FR-024)")
  }

  /// Event-derived items (Exception/Message) use the same rule with the owning span
  /// id as parent — also id-only, so spec 03's log-scoped events stay consistent.
  func testEventTagsAreIdOnlyAndRepeatable() {
    let first = CorrelationMapping.eventTags(traceId: traceId, owningSpanId: spanId)
    let second = CorrelationMapping.eventTags(traceId: traceId, owningSpanId: spanId)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first[PartATagKeys.operationId], traceIdHex)
    XCTAssertEqual(first[PartATagKeys.operationParentId], spanIdHex)
  }
}
