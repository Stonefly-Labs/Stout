// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetrySdk

/// Builds the Breeze `RequestData` for a `.server`/`.consumer` span (User Story 1,
/// FR-010/011). Pure and deterministic; consumes recognized HTTP attributes and
/// carries the remainder (plus links) to `properties`.
enum RequestMapping {
  /// Populate a `RequestData` from a request span.
  ///
  /// - `id` ← span id (16-hex, `CorrelationMapping`).
  /// - `name` ← the route/method-derived HTTP name, else the span name.
  /// - `duration` ← `endTime − startTime` (`BreezeDuration`).
  /// - `responseCode` ← HTTP status string, else `"0"`.
  /// - `success` ← the server-side `SuccessPredicate` (error status fails; unset
  ///   HTTP status ⇒ `code != 0 && code < 400`).
  /// - `url` ← reconstructed HTTP URL when derivable.
  /// - `properties` ← unconsumed attributes + links.
  ///
  /// `source` is left absent here; the messaging-consumer origin is populated in
  /// User Story 2 (FR-008).
  static func requestData(for span: SpanData) -> RequestData {
    let http = HTTPMapping.derive(from: span.attributes)
    let consumed = Set(http?.consumedKeys ?? [])
    let properties = SpanTranslator.properties(from: span, consuming: consumed)

    return RequestData(
      id: CorrelationMapping.itemId(for: span.spanId),
      name: http?.derivedName ?? span.name,
      duration: BreezeDuration.string(from: span.startTime, to: span.endTime),
      responseCode: SuccessPredicate.codeString(http?.statusString),
      success: SuccessPredicate.requestSuccess(
        status: span.status, httpStatusCode: http?.statusCode),
      url: http?.url,
      properties: properties)
  }
}
