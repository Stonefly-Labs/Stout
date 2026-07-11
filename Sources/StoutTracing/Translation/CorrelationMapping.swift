// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import StoutCore

/// The single, shared correlation rule (FR-007, shared contract FR-024): map W3C
/// trace/span ids to Application Insights `ai.operation.*` Part A tags and the item
/// `id`, byte-for-byte in canonical lowercase hex — no re-encoding, no truncation
/// (data-model §2, SC-002).
///
/// It operates on `TraceId`/`SpanId`/`SpanId?` — **not** on `SpanData` — so spec 03
/// (Logs) reuses it verbatim for log-record correlation (INV-7). `TraceId.hexString`
/// (32-hex) and `SpanId.hexString` (16-hex) are already canonical lowercase, so this
/// is a pure relabeling.
enum CorrelationMapping {
  /// The Breeze item `id` for a span's own Request/Dependency item — its span id.
  static func itemId(for spanId: SpanId) -> String {
    spanId.hexString
  }

  /// Part A correlation tags for a span's own Request/Dependency item.
  ///
  /// - `ai.operation.id` ← `traceId` (32-hex).
  /// - `ai.operation.parentId` ← `parentSpanId` (16-hex), **absent for a root span**
  ///   (`parentSpanId == nil`) — never an empty string on the wire.
  static func spanTags(traceId: TraceId, parentSpanId: SpanId?) -> TelemetryTags {
    var tags = TelemetryTags()
    tags[PartATagKeys.operationId] = traceId.hexString
    if let parentSpanId {
      tags[PartATagKeys.operationParentId] = parentSpanId.hexString
    }
    return tags
  }

  /// Part A correlation tags for an item **derived from a span event**
  /// (Exception/Message): it hangs under the span, so its `ai.operation.parentId`
  /// is the owning span's id (data-model §2 per-item rule).
  ///
  /// - `ai.operation.id` ← `traceId` (32-hex).
  /// - `ai.operation.parentId` ← `owningSpanId` (16-hex), always present.
  static func eventTags(traceId: TraceId, owningSpanId: SpanId) -> TelemetryTags {
    var tags = TelemetryTags()
    tags[PartATagKeys.operationId] = traceId.hexString
    tags[PartATagKeys.operationParentId] = owningSpanId.hexString
    return tags
  }
}
