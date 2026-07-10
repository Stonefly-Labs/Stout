// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

/// A single Breeze telemetry item: the shared wrapper the core stamps around
/// every signal payload before transport (FR-006–FR-009).
///
/// The envelope carries the **Part A** context (name, time, sample rate,
/// instrumentation key, tags) and a discriminated **Part B/C** payload in
/// `data`. On the wire each envelope is one single-line JSON object; a batch is
/// the envelopes joined by `\n` (see spec US2).
///
/// Values of this type are produced by `EnvelopeFactory` and handed to
/// `ExportPipeline.submit(_:)`; consumers never construct them directly.
public struct Envelope: Sendable, Encodable {
  /// Envelope schema version. Fixed at 1 and **omitted on the wire by default**
  /// (design D2) — ingestion assumes 1 when absent.
  public let version: Int
  /// The telemetry item type name, e.g. `Microsoft.ApplicationInsights.Request`.
  public let name: String
  /// UTC ISO-8601 timestamp with fractional seconds and a `Z` suffix, formatted
  /// deterministically regardless of host locale/timezone.
  public let time: String
  /// Sampling percentage in `0...100`; `100` means no sampling (FR-008).
  public let sampleRate: Double
  /// The instrumentation key routed to the `iKey` wire field. Secret on the wire
  /// only — never rendered into diagnostics or errors.
  public let instrumentationKey: String
  /// Part A tags applied to this item.
  public let tags: TelemetryTags
  /// The discriminated signal payload (`baseType` + `baseData`).
  let data: DataContainer

  init(
    name: String,
    time: String,
    sampleRate: Double,
    instrumentationKey: String,
    tags: TelemetryTags,
    data: DataContainer
  ) {
    self.version = 1
    self.name = name
    self.time = time
    self.sampleRate = sampleRate
    self.instrumentationKey = instrumentationKey
    self.tags = tags
    self.data = data
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case time
    case sampleRate
    case instrumentationKey = "iKey"
    case tags
    case data
  }

  public func encode(to encoder: any Encoder) throws {
    // `ver` is intentionally not encoded (omitted-on-wire default, D2). Keys are
    // written in a fixed order so the batch encoding is deterministic for the
    // golden round-trip tests (SC-004).
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(time, forKey: .time)
    try container.encode(sampleRate, forKey: .sampleRate)
    try container.encode(instrumentationKey, forKey: .instrumentationKey)
    try container.encode(tags, forKey: .tags)
    try container.encode(data, forKey: .data)
  }
}

/// The `data` object: a `baseType` discriminator plus the signal `baseData`
/// payload (FR-007, data-model §2a). Internal to the core — the public seam is
/// the `BaseData` protocol.
struct DataContainer: Sendable, Encodable {
  /// The Breeze discriminator, e.g. `"RequestData"`.
  let baseType: String
  /// The signal payload. Encodes as `{ "ver": 2, ... }` (the conforming type
  /// supplies `ver`).
  let baseData: any BaseData

  private enum CodingKeys: String, CodingKey {
    case baseType
    case baseData
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(baseType, forKey: .baseType)
    // Encode the existential payload into a nested encoder so it renders as the
    // `baseData` object.
    try baseData.encode(to: container.superEncoder(forKey: .baseData))
  }
}
