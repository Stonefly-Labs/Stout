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
  /// `source` is populated for messaging-consumer requests from the messaging origin
  /// (`host[/destination]`), else absent (FR-008, D-05).
  static func requestData(for span: SpanData) -> RequestData {
    let http = HTTPMapping.derive(from: span.attributes)
    let messaging = MessagingMapping.derive(from: span.attributes)
    var consumed = Set(http?.consumedKeys ?? [])
    consumed.formUnion(messaging?.consumedKeys ?? [])
    let properties = SpanTranslator.properties(from: span, consuming: consumed)

    return RequestData(
      id: CorrelationMapping.itemId(for: span.spanId),
      name: http?.derivedName ?? span.name,
      duration: BreezeDuration.string(from: span.startTime, to: span.endTime),
      responseCode: SuccessPredicate.codeString(http?.statusString),
      success: SuccessPredicate.requestSuccess(
        status: span.status, httpStatusCode: http?.statusCode),
      url: http?.url,
      source: messaging?.source,
      properties: properties)
  }
}
