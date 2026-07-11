// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Formats a span's elapsed time (`endTime − startTime`) as the Breeze `duration`
/// string, matching .NET's `TimeSpan.ToString("c", InvariantCulture)` — the exact
/// form the Azure Monitor exporter emits (research.md; .NET reference confirmed).
///
/// Shape: `[d.]hh:mm:ss[.fffffff]`
/// - the day group (`d.`) is present **only** when there is a whole-day component;
/// - hours/minutes/seconds are always two digits;
/// - the fractional group is padded to 7 digits (100 ns ticks) when non-zero and
///   omitted entirely when the fraction is zero.
///
/// Stout hardens two edges over the raw .NET call (mapping contract Determinism
/// notes; do-no-harm):
/// - a **zero or negative** span clamps to `"00:00:00"` (never a negative string,
///   never a crash);
/// - a span of **≥ 1000 days** clamps to `"999.23:59:59.9999999"` (the .NET
///   `SchemaConstants.Duration_MaxValue` upper bound), so the field is always bounded.
enum BreezeDuration {
  private static let ticksPerSecond: Int64 = 10_000_000
  private static let ticksPerMinute = ticksPerSecond * 60
  private static let ticksPerHour = ticksPerMinute * 60
  private static let ticksPerDay = ticksPerHour * 24
  private static let maxTicks = ticksPerDay * 1000  // .NET clamps at 1000 days.
  private static let maxValue = "999.23:59:59.9999999"

  /// Format the interval between `start` and `end`.
  static func string(from start: Date, to end: Date) -> String {
    let seconds = end.timeIntervalSince(start)
    // Clamp non-positive spans to zero (never emit a negative duration).
    guard seconds > 0 else { return "00:00:00" }

    let ticks = Int64((seconds * Double(ticksPerSecond)).rounded())
    guard ticks > 0 else { return "00:00:00" }
    guard ticks < maxTicks else { return maxValue }

    let days = ticks / ticksPerDay
    var remainder = ticks % ticksPerDay
    let hours = remainder / ticksPerHour
    remainder %= ticksPerHour
    let minutes = remainder / ticksPerMinute
    remainder %= ticksPerMinute
    let secs = remainder / ticksPerSecond
    let fraction = remainder % ticksPerSecond

    var result = ""
    if days > 0 { result += "\(days)." }
    result += pad2(hours) + ":" + pad2(minutes) + ":" + pad2(secs)
    if fraction > 0 {
      result += "." + pad7(fraction)
    }
    return result
  }

  private static func pad2(_ value: Int64) -> String {
    value < 10 ? "0\(value)" : "\(value)"
  }

  private static func pad7(_ value: Int64) -> String {
    let digits = "\(value)"
    return String(repeating: "0", count: max(0, 7 - digits.count)) + digits
  }
}
