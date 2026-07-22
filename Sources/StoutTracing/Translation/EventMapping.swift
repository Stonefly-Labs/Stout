// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import OpenTelemetrySdk

/// Maps a span's `events` to their derived Breeze items (data-model §1c/§1d).
///
/// An OTel `exception` event becomes an ``ExceptionData`` (User Story 4, FR-019);
/// any non-`exception` event becomes a ``MessageData`` (User Story 5, FR-020). This
/// type is pure and deterministic — it only inspects one `SpanData.Event` and never
/// touches the span's own item, correlation, or the envelope. The `SpanTranslator`
/// stamps the correlated envelope (`ai.operation.parentId` = owning span id).
enum EventMapping {
  /// Whether `event` is the OTel `exception` event (name `"exception"`).
  static func isException(_ event: SpanData.Event) -> Bool {
    event.name == SemanticConventions.exceptionEventName
  }

  /// Build an ``ExceptionData`` from an `exception` event, or `nil` to drop it.
  ///
  /// The **drop rule** (matches .NET, research.md D-08): emit only when **both**
  /// `exception.type` and `exception.message` are present; otherwise return `nil` —
  /// never fabricate a placeholder. `hasFullStack`/`stack` are set only when
  /// `exception.stacktrace` is present. Every remaining event attribute (e.g.
  /// `exception.escaped`) is carried into `properties`, stringified with the single
  /// ``AttributeStringifier`` rule.
  static func exceptionData(from event: SpanData.Event) -> ExceptionData? {
    let attributes = event.attributes
    guard
      let typeName = attributes[SemanticConventions.exceptionType],
      let message = attributes[SemanticConventions.exceptionMessage]
    else {
      return nil
    }

    let stack = attributes[SemanticConventions.exceptionStacktrace]
      .map(AttributeStringifier.string(from:))
    let details = ExceptionData.Details(
      typeName: AttributeStringifier.string(from: typeName),
      message: AttributeStringifier.string(from: message),
      hasFullStack: stack != nil,
      stack: stack)

    let consumed: Set<String> = [
      SemanticConventions.exceptionType,
      SemanticConventions.exceptionMessage,
      SemanticConventions.exceptionStacktrace,
    ]
    return ExceptionData(
      exceptions: [details],
      properties: properties(from: event, consuming: consumed))
  }

  /// Build a ``MessageData`` from a non-`exception` span event (FR-020).
  ///
  /// Unlike the exception path there is **no drop rule**: every non-`exception` event
  /// always yields one item. The message text is the event's `message` attribute when
  /// present, otherwise the event name; when the `message` attribute supplies the text
  /// it is consumed (not duplicated into `properties`). Every remaining event
  /// attribute is carried into `properties` with the single ``AttributeStringifier``
  /// rule.
  static func messageData(from event: SpanData.Event) -> MessageData {
    let messageAttribute = event.attributes[SemanticConventions.messageAttribute]
    let message = messageAttribute.map(AttributeStringifier.string(from:)) ?? event.name
    let consumed: Set<String> =
      messageAttribute == nil ? [] : [SemanticConventions.messageAttribute]
    return MessageData(
      message: message,
      properties: properties(from: event, consuming: consumed))
  }

  /// Every event attribute the caller did **not** consume, stringified with the
  /// single ``AttributeStringifier`` rule. Deterministic (compared as a map, INV-8);
  /// span events carry no links, so this is attributes-only.
  static func properties(
    from event: SpanData.Event, consuming consumedKeys: Set<String>
  ) -> [String: String] {
    var properties: [String: String] = [:]
    for (key, value) in event.attributes where !consumedKeys.contains(key) {
      properties[key] = AttributeStringifier.string(from: value)
    }
    return properties
  }
}
