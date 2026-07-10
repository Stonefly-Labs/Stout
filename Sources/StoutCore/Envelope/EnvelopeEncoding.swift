// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Deterministic Breeze timestamp formatting (FR-009, research R4).
///
/// Produces UTC ISO-8601 with millisecond fractional seconds and a `Z` suffix,
/// e.g. `2026-07-09T14:12:03.412Z`. The value is built from a fixed Gregorian /
/// UTC / POSIX calendar and manual formatting so it is byte-identical regardless
/// of host locale or timezone, and identical between Darwin Foundation and
/// swift-corelibs-foundation.
enum BreezeTimestamp {
  private static let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    // Force-unwrap avoided: fall back to the always-valid GMT constant.
    calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }()

  static func string(from date: Date) -> String {
    let interval = date.timeIntervalSince1970
    var wholeSeconds = interval.rounded(.down)
    var milliseconds = Int(((interval - wholeSeconds) * 1000).rounded())
    if milliseconds >= 1000 {
      wholeSeconds += 1
      milliseconds -= 1000
    }
    let components = utcCalendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: Date(timeIntervalSince1970: wholeSeconds)
    )
    return String(
      format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0,
      components.hour ?? 0,
      components.minute ?? 0,
      components.second ?? 0,
      milliseconds
    )
  }
}

/// Encodes a batch of envelopes into the Breeze newline-delimited JSON body
/// (FR-009): one single-line JSON object per envelope, `\n`-separated, ready to
/// be gzip-compressed for `POST /v2.1/track`.
enum EnvelopeEncoding {
  /// A shared encoder configured for deterministic, compact output.
  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    // `.sortedKeys` makes the byte output deterministic (required for the golden
    // round-trip tests, SC-004); slash escaping is disabled for cleaner URLs in
    // tag values. JSONEncoder emits compact single-line JSON by default.
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  /// Encode `envelopes` as newline-delimited JSON. Exactly `N` envelopes produce
  /// `N` single-line JSON objects joined by `\n` (no trailing newline).
  static func encodeBatch(
    _ envelopes: [Envelope],
    encoder: JSONEncoder = EnvelopeEncoding.makeEncoder()
  ) throws -> Data {
    var body = Data()
    for (index, envelope) in envelopes.enumerated() {
      if index > 0 {
        body.append(0x0A)  // '\n'
      }
      body.append(try encoder.encode(envelope))
    }
    return body
  }
}
