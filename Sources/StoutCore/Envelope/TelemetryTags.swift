// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

/// The Breeze **Part A** tag dictionary applied to every envelope (FR-018–FR-021).
///
/// Part A tags are the cross-cutting context attributes Application Insights
/// understands by well-known key — `ai.cloud.role`, `ai.cloud.roleInstance`,
/// `ai.internal.sdkVersion`, the `ai.device.*` family, and so on. The core
/// derives a resource-level set once (see `ResourceDetector`) and merges any
/// per-item signal tags over it.
///
/// On the wire this serializes as a flat JSON object of string keys to string
/// values.
public struct TelemetryTags: Sendable, Encodable, Equatable {
  /// The backing key/value store. Keys are Breeze `ai.*` tag names.
  public private(set) var storage: [String: String]

  /// Create a tag set from a raw key/value map (default empty).
  public init(_ storage: [String: String] = [:]) {
    self.storage = storage
  }

  /// Read or write a single tag. Setting `nil` removes the key.
  public subscript(key: String) -> String? {
    get { storage[key] }
    set { storage[key] = newValue }
  }

  /// `true` when no tags are present.
  public var isEmpty: Bool { storage.isEmpty }

  /// Return a copy of `base` with `self`'s tags layered on top: on a key
  /// conflict, `self` (the more specific, per-item tags) wins over `base` (the
  /// shared resource tags) — the documented merge rule from data-model §3.
  public func merging(over base: TelemetryTags) -> TelemetryTags {
    TelemetryTags(base.storage.merging(storage) { _, mine in mine })
  }

  public func encode(to encoder: any Encoder) throws {
    // A `[String: String]` encodes as a JSON object keyed by its strings, which
    // is exactly the Breeze `tags` shape.
    try storage.encode(to: encoder)
  }
}
