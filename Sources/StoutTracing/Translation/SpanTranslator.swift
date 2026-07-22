// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import OpenTelemetrySdk
import StoutCore

/// The pure, deterministic `SpanData` → `[Envelope]` translator (mapping contract
/// §Orchestration, FR-028). Identical input yields byte-identical output; no side
/// effects; `Sendable` (an `enum` of static functions — no state, INV-8).
///
/// The orchestration is the spine every translation story shares (data-model,
/// contracts/span-to-breeze-mapping.md):
///
/// 1. Resolve the envelope family from `kind` (`SpanKindMapping`).
/// 2. Build correlation `itemTags` (`CorrelationMapping`) — `ai.operation.id` from
///    the trace id, `ai.operation.parentId` from the parent span id (absent when
///    root), plus `ai.operation.name` for Request items.
/// 3. Populate protocol fields via the matching per-protocol mapper (HTTP for
///    requests; DB/RPC/messaging/HTTP for dependencies), consuming recognized keys.
/// 4. Carry every unconsumed attribute **and** span link into `properties`.
/// 5. Compute `success`/`responseCode`/`resultCode` via `SuccessPredicate`.
/// 6. Emit exactly one Request/Dependency item (event-derived Exception/Message
///    items arrive with US4/US5).
/// 7. Stamp each item into an `Envelope` (`time` = span `startTime`; `sampleRate` =
///    100, no sampling decision — spec 05 owns that).
///
/// This feature never throws into the host: a translation that cannot be completed
/// yields a best-effort item (or is dropped), never a crash (FR-026, INV-5).
enum SpanTranslator {
  /// The default per-item `sampleRate`: 100 (no sampling). This feature attaches the
  /// rate; the sampling *decision* is spec 05 (INV-6).
  static let defaultSampleRate: Double = 100

  /// The Breeze property key under which span links are carried (App Insights has no
  /// first-class span-link field — FR-022). Mirrors the .NET exporter's `_MS.links`.
  static let linksPropertyKey = "_MS.links"

  /// Translate one finished span into its Breeze envelopes.
  ///
  /// `.server`/`.consumer` spans become exactly one `RequestData`; all other kinds
  /// become a `RemoteDependencyData`. Exactly one Request/Dependency item per span
  /// (INV-1), followed by one correlated item per emitted span event (an `exception`
  /// event ⇒ `ExceptionData`, US4; non-`exception` events ⇒ `MessageData`, US5).
  static func translate(_ span: SpanData, using factory: EnvelopeFactory) -> [Envelope] {
    var envelopes: [Envelope]
    switch SpanKindMapping.itemType(for: span.kind) {
    case .request:
      envelopes = [requestEnvelope(for: span, using: factory)]
    case .dependency:
      envelopes = [dependencyEnvelope(for: span, using: factory)]
    }
    envelopes.append(contentsOf: eventEnvelopes(for: span, using: factory))
    return envelopes
  }

  // MARK: - Request path (User Story 1)

  private static func requestEnvelope(
    for span: SpanData, using factory: EnvelopeFactory
  ) -> Envelope {
    let data = RequestMapping.requestData(for: span)
    var tags = CorrelationMapping.spanTags(traceId: span.traceId, parentSpanId: span.parentSpanId)
    // `ai.operation.name` is the request name, set on server/consumer items for
    // transaction search (.NET parity, data-model §2).
    tags[PartATagKeys.operationName] = data.name
    return factory.makeEnvelope(
      name: RequestData.telemetryName,
      payload: data,
      time: span.startTime,
      sampleRate: defaultSampleRate,
      itemTags: tags)
  }

  // MARK: - Dependency path (User Story 2)

  private static func dependencyEnvelope(
    for span: SpanData, using factory: EnvelopeFactory
  ) -> Envelope {
    let data = DependencyMapping.remoteDependencyData(for: span)
    // Dependencies carry `ai.operation.id`/`ai.operation.parentId` but not
    // `ai.operation.name` (that names the owning request — data-model §2).
    let tags = CorrelationMapping.spanTags(traceId: span.traceId, parentSpanId: span.parentSpanId)
    return factory.makeEnvelope(
      name: RemoteDependencyData.telemetryName,
      payload: data,
      time: span.startTime,
      sampleRate: defaultSampleRate,
      itemTags: tags)
  }

  // MARK: - Event-derived items (User Story 4/5)

  /// One correlated envelope per emitted span event, in span-event order. An
  /// `exception` event with both `exception.type` and `exception.message` becomes an
  /// `ExceptionData` (US4, FR-019); events failing the drop rule are skipped, and
  /// non-`exception` events are handled by US5. Every event item hangs under the
  /// owning span — `ai.operation.parentId` = span id (`CorrelationMapping.eventTags`,
  /// data-model §2) — with the same operation id, and is stamped at the event's own
  /// timestamp. Error status → `success = false` is owned by the Request/Dependency
  /// item's `SuccessPredicate`, independent of whether any event is present (INV-4).
  private static func eventEnvelopes(
    for span: SpanData, using factory: EnvelopeFactory
  ) -> [Envelope] {
    var envelopes: [Envelope] = []
    for event in span.events where EventMapping.isException(event) {
      guard let data = EventMapping.exceptionData(from: event) else { continue }
      let tags = CorrelationMapping.eventTags(traceId: span.traceId, owningSpanId: span.spanId)
      envelopes.append(
        factory.makeEnvelope(
          name: ExceptionData.telemetryName,
          payload: data,
          time: event.timestamp,
          sampleRate: defaultSampleRate,
          itemTags: tags))
    }
    return envelopes
  }

  // MARK: - Shared property carriage

  /// Every attribute the protocol mappers did **not** consume, stringified with the
  /// single `AttributeStringifier` rule, plus the span's links under
  /// ``linksPropertyKey`` (FR-022). Deterministic: the property map is compared as a
  /// map, so key ordering never affects the result (INV-8).
  static func properties(
    from span: SpanData, consuming consumedKeys: Set<String>
  ) -> [String: String] {
    var properties: [String: String] = [:]
    for (key, value) in span.attributes where !consumedKeys.contains(key) {
      properties[key] = AttributeStringifier.string(from: value)
    }
    if !span.links.isEmpty {
      properties[linksPropertyKey] = renderLinks(span.links)
    }
    return properties
  }

  /// Render span links as a compact JSON array of `{operation_Id, id}` objects (the
  /// .NET `_MS.links` form). Ids are canonical lowercase hex — no characters needing
  /// JSON escaping — so a manual, allocation-light encoding is safe and portable.
  private static func renderLinks(_ links: [SpanData.Link]) -> String {
    let items = links.map { link in
      "{\"operation_Id\":\"\(link.context.traceId.hexString)\",\"id\":\"\(link.context.spanId.hexString)\"}"
    }
    return "[" + items.joined(separator: ",") + "]"
  }
}
