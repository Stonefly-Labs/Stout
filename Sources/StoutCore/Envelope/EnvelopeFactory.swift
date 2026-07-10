// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Stamps the shared Part A fields around a caller-supplied signal payload,
/// producing a ready-to-encode `Envelope` (FR-007).
///
/// The factory is initialized with the **instrumentation key string** and the
/// resource-level `TelemetryTags` — not a `ConnectionConfiguration` — so it is
/// fully usable and testable without the connection-string parser (US1). The
/// umbrella wires it up by passing `config.instrumentationKey`.
public struct EnvelopeFactory: Sendable {
  private let instrumentationKey: String
  private let resourceTags: TelemetryTags

  /// Create a factory bound to an instrumentation key and the resource tags
  /// applied to every envelope.
  public init(instrumentationKey: String, resourceTags: TelemetryTags = TelemetryTags()) {
    self.instrumentationKey = instrumentationKey
    self.resourceTags = resourceTags
  }

  /// Build an envelope wrapping `payload`.
  ///
  /// - Parameters:
  ///   - name: the telemetry item type name (e.g.
  ///     `Microsoft.ApplicationInsights.Request`).
  ///   - payload: the signal `baseData`; its `Self.baseType` supplies the
  ///     `data.baseType` discriminator.
  ///   - time: the item timestamp; formatted to deterministic UTC ISO-8601.
  ///   - sampleRate: sampling percentage `0...100` (default `100`, no sampling).
  ///   - itemTags: optional per-item tags, merged **over** the resource tags
  ///     (per-item wins on conflict).
  public func makeEnvelope<D: BaseData>(
    name: String,
    payload: D,
    time: Date,
    sampleRate: Double = 100,
    itemTags: TelemetryTags? = nil
  ) -> Envelope {
    let tags = itemTags?.merging(over: resourceTags) ?? resourceTags
    return Envelope(
      name: name,
      time: BreezeTimestamp.string(from: time),
      sampleRate: sampleRate,
      instrumentationKey: instrumentationKey,
      tags: tags,
      data: DataContainer(baseType: D.baseType, baseData: payload)
    )
  }
}
