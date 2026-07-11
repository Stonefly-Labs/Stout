// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi

/// The single, documented rule for turning an OTel `AttributeValue` into the
/// `String` that Breeze `properties` and stringified fields require (data-model §0).
///
/// Breeze `properties` is a flat `[String: String]` map and several Breeze fields
/// (`responseCode`, `target`, …) are strings, so every non-string attribute must
/// collapse to one deterministic representation. The rule, applied everywhere so
/// goldens are stable:
///
/// - `.string` → the raw value.
/// - `.bool` → `"true"` / `"false"`.
/// - `.int` → base-10 digits.
/// - `.double` → Swift's shortest round-trippable decimal (`String(Double)`).
/// - `.array` / deprecated `*Array` → each element stringified by this same rule,
///   comma-separated inside `[` … `]`.
/// - `.set` → its labels as `key=value` pairs, **sorted by key** (order-independent,
///   INV-8), comma-separated inside `[` … `]`.
enum AttributeStringifier {
  /// Convert one `AttributeValue` to its canonical Breeze string.
  static func string(from value: AttributeValue) -> String {
    switch value {
    case .string(let value):
      return value
    case .bool(let value):
      return value ? "true" : "false"
    case .int(let value):
      return String(value)
    case .double(let value):
      return String(value)
    case .stringArray(let values):
      return bracket(values.map { string(from: .string($0)) })
    case .boolArray(let values):
      return bracket(values.map { string(from: .bool($0)) })
    case .intArray(let values):
      return bracket(values.map { string(from: .int($0)) })
    case .doubleArray(let values):
      return bracket(values.map { string(from: .double($0)) })
    case .array(let array):
      return bracket(array.values.map { string(from: $0) })
    case .set(let set):
      // Sort by key so the rendering does not depend on dictionary iteration order.
      let pairs = set.labels.sorted { $0.key < $1.key }
        .map { "\($0.key)=\(string(from: $0.value))" }
      return bracket(pairs)
    }
  }

  private static func bracket(_ elements: [String]) -> String {
    "[" + elements.joined(separator: ", ") + "]"
  }
}
