// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi

/// Maps an OTel `SpanKind` to the Breeze telemetry family it becomes (data-model
/// §3, FR-006), mirroring the .NET Azure Monitor exporter.
enum SpanKindMapping {
  /// The Breeze item a span becomes.
  enum ItemType: Equatable {
    /// `RequestData` — inbound work (`.server`/`.consumer`).
    case request
    /// `RemoteDependencyData` — outbound/internal work
    /// (`.client`/`.producer`/`.internal`/unspecified).
    case dependency
  }

  /// Resolve the item type for a span kind. `.server`/`.consumer` ⇒ Request;
  /// everything else — including `.internal` and any future/unspecified kind —
  /// ⇒ Dependency (the .NET default). Total over `SpanKind` so no kind can slip
  /// through unmapped (SC-001).
  static func itemType(for kind: SpanKind) -> ItemType {
    switch kind {
    case .server, .consumer:
      return .request
    case .client, .producer, .internal:
      return .dependency
    }
  }
}
