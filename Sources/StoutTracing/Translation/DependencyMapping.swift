// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import OpenTelemetrySdk

/// Builds the Breeze `RemoteDependencyData` for a `.client`/`.producer`/`.internal`/
/// unspecified span (User Story 2, FR-012–016). Pure and deterministic: it selects a
/// single protocol in a fixed precedence — **DB → RPC → messaging → HTTP** — so the
/// `type`/`target`/`data` are never attribute-order dependent (FR-016, INV-3). A span
/// with no protocol signal falls back to `InProc` (internal kind) or a bare
/// dependency.
enum DependencyMapping {
  /// The resolved protocol fields for a dependency span.
  private struct Fields {
    var type: String
    var target: String?
    var data: String?
    var resultCode: String?
    var consumedKeys: [String]
  }

  /// Populate a `RemoteDependencyData` from a dependency span.
  ///
  /// - `id` ← span id (16-hex, `CorrelationMapping`).
  /// - `name` ← the span name.
  /// - `duration` ← `endTime − startTime` (`BreezeDuration`).
  /// - `resultCode` ← the protocol status string, else `"0"`.
  /// - `success` ← the dependency-side `SuccessPredicate` (`status != .error` only —
  ///   no HTTP/gRPC code threshold).
  /// - `type`/`target`/`data` ← the winning protocol mapper.
  /// - `properties` ← unconsumed attributes + links.
  static func remoteDependencyData(for span: SpanData) -> RemoteDependencyData {
    let fields = resolve(span)
    let properties = SpanTranslator.properties(from: span, consuming: Set(fields.consumedKeys))

    return RemoteDependencyData(
      id: CorrelationMapping.itemId(for: span.spanId),
      name: span.name,
      duration: BreezeDuration.string(from: span.startTime, to: span.endTime),
      resultCode: SuccessPredicate.codeString(fields.resultCode),
      success: SuccessPredicate.dependencySuccess(status: span.status),
      type: fields.type,
      target: fields.target,
      data: fields.data,
      properties: properties)
  }

  /// Deterministic protocol selection (DB → RPC → messaging → HTTP → InProc/bare).
  private static func resolve(_ span: SpanData) -> Fields {
    let attributes = span.attributes

    if let db = DBMapping.derive(from: attributes) {
      return Fields(
        type: db.type, target: db.target, data: db.data, resultCode: nil,
        consumedKeys: db.consumedKeys)
    }
    if let rpc = RPCMapping.derive(from: attributes) {
      return Fields(
        type: rpc.type, target: rpc.target, data: rpc.data, resultCode: rpc.resultCode,
        consumedKeys: rpc.consumedKeys)
    }
    if let messaging = MessagingMapping.derive(from: attributes) {
      return Fields(
        type: messaging.type, target: messaging.target, data: messaging.data, resultCode: nil,
        consumedKeys: messaging.consumedKeys)
    }
    if let http = HTTPMapping.derive(from: attributes) {
      return Fields(
        type: "HTTP", target: http.target, data: http.url, resultCode: http.statusString,
        consumedKeys: http.consumedKeys)
    }
    return fallback(span)
  }

  /// No protocol signal: `.internal` spans are `InProc`; any other kind becomes a
  /// bare dependency whose `target` is the peer host/service when known.
  private static func fallback(_ span: SpanData) -> Fields {
    let attributes = span.attributes
    let host = SemanticConventions.firstString(in: attributes, SemanticConventions.host)
    let peer = SemanticConventions.firstString(in: attributes, [SemanticConventions.peerService])
    let target = host ?? peer

    var consumed: [String] = []
    if host != nil {
      consumed += SemanticConventions.presentKeys(in: attributes, SemanticConventions.host)
    } else if peer != nil {
      consumed.append(SemanticConventions.peerService)
    }

    let type = span.kind == .internal ? "InProc" : ""
    return Fields(type: type, target: target, data: nil, resultCode: nil, consumedKeys: consumed)
  }
}
