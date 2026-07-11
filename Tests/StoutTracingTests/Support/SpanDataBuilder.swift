// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenTelemetryApi

// `@testable` exposes `SpanData`'s synthesized memberwise initializer, which is
// internal to `OpenTelemetrySdk` (all its stored properties are
// `public private(set)`, so there is no public way to construct one). This is the
// same construction path the SDK's own `SpanDataTests` use, and it lets every
// suite build a fully-controlled `SpanData` with no `TracerProvider`, no
// `BatchSpanProcessor`, and no network.
@testable import OpenTelemetrySdk

/// A hand-built `SpanData` factory for the tracing translation suites.
///
/// Construct with the fields a test cares about (kind, ids, timing, attributes,
/// status, events, links, resource) and call ``build()``; everything else takes a
/// deterministic default. All ids default to fixed, recognizable canonical-hex
/// values so correlation goldens (US3) are stable and readable. Timing defaults to
/// a start of epoch + 1s and a 250 ms duration.
///
/// This is deliberately a value type with named, defaulted parameters rather than
/// a fluent builder: every suite reads as `SpanDataBuilder(kind: .server, ...)`,
/// and overriding one field never disturbs the others.
struct SpanDataBuilder {
  // A stable, canonical 32-hex trace id and 16-hex span/parent ids. Chosen so the
  // lowercased-hex correlation output is easy to eyeball in golden assertions.
  static let defaultTraceIdHex = "0af7651916cd43dd8448eb211c80319c"
  static let defaultSpanIdHex = "b7ad6b7169203331"
  static let defaultParentSpanIdHex = "0000000000000001"

  var traceIdHex: String = SpanDataBuilder.defaultTraceIdHex
  var spanIdHex: String = SpanDataBuilder.defaultSpanIdHex
  /// Parent span id in 16-hex, or `nil` for a root span (absent `parentSpanId`).
  var parentSpanIdHex: String? = nil

  var name: String = "operation"
  var kind: SpanKind = .server
  var status: Status = .unset

  var startTime: Date = Date(timeIntervalSince1970: 1)
  /// Span duration in seconds; `endTime` is derived as `startTime + duration`.
  var duration: TimeInterval = 0.25

  var attributes: [String: AttributeValue] = [:]
  var events: [SpanData.Event] = []
  var links: [SpanData.Link] = []
  var resource: Resource = Resource(attributes: [:])

  /// Materialize the configured `SpanData`.
  func build() -> SpanData {
    SpanData(
      traceId: TraceId(fromHexString: traceIdHex),
      spanId: SpanId(fromHexString: spanIdHex),
      traceFlags: TraceFlags().settingIsSampled(true),
      traceState: TraceState(),
      parentSpanId: parentSpanIdHex.map { SpanId(fromHexString: $0) },
      resource: resource,
      instrumentationScope: InstrumentationScopeInfo(name: "stout.tests"),
      name: name,
      kind: kind,
      startTime: startTime,
      attributes: attributes,
      events: events,
      links: links,
      status: status,
      endTime: startTime.addingTimeInterval(duration),
      hasRemoteParent: parentSpanIdHex != nil,
      hasEnded: true
    )
  }

  // MARK: - Convenience constructors for common shapes

  /// A span `Event` at a fixed offset after the default start.
  static func event(
    _ name: String,
    attributes: [String: AttributeValue] = [:],
    at offset: TimeInterval = 0.1
  ) -> SpanData.Event {
    SpanData.Event(
      name: name,
      timestamp: Date(timeIntervalSince1970: 1).addingTimeInterval(offset),
      attributes: attributes)
  }

  /// A span `Link` to another trace/span with optional attributes.
  static func link(
    traceIdHex: String = SpanDataBuilder.defaultTraceIdHex,
    spanIdHex: String,
    attributes: [String: AttributeValue] = [:]
  ) -> SpanData.Link {
    let context = SpanContext.create(
      traceId: TraceId(fromHexString: traceIdHex),
      spanId: SpanId(fromHexString: spanIdHex),
      traceFlags: TraceFlags().settingIsSampled(true),
      traceState: TraceState())
    return SpanData.Link(context: context, attributes: attributes)
  }
}
