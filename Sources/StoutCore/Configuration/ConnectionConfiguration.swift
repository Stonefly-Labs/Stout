// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Thrown when an Application Insights connection string cannot be parsed or
/// validated. Its `description` NEVER contains secret material — no
/// instrumentation key value, no full connection string — only field names and
/// enumerated reasons (FR-028, Constitution I).
public enum ConnectionStringError: Error, Sendable, Equatable, CustomStringConvertible {
  /// The connection string was empty or whitespace-only.
  case empty
  /// No `InstrumentationKey` field was present.
  case missingInstrumentationKey
  /// The `InstrumentationKey` value was not a well-formed GUID. The invalid
  /// value is deliberately NOT included (it is secret).
  case malformedInstrumentationKey
  /// An endpoint field was absent-but-required or not a valid absolute URL. Only
  /// the field name is reported.
  case missingOrMalformedEndpoint(field: String)
  /// An endpoint field used a non-HTTPS scheme. Only the field name is reported;
  /// the URL (which may carry userinfo) is not.
  case nonHTTPSEndpoint(field: String)
  /// The same key appeared more than once. Only the key name (not a secret) is
  /// reported.
  case duplicateKey(String)

  public var description: String {
    switch self {
    case .empty:
      return "Connection string is empty."
    case .missingInstrumentationKey:
      return "Connection string is missing the required InstrumentationKey field."
    case .malformedInstrumentationKey:
      return "Connection string InstrumentationKey is not a well-formed GUID."
    case .missingOrMalformedEndpoint(let field):
      return "Connection string \(field) is not a valid absolute URL."
    case .nonHTTPSEndpoint(let field):
      return "Connection string \(field) must use HTTPS."
    case .duplicateKey(let key):
      return "Connection string contains a duplicate key: \(key)."
    }
  }
}

/// The validated result of parsing an Application Insights connection string
/// (FR-001–FR-005).
///
/// Parsing is **fail-closed**: any structural problem, a malformed GUID, or a
/// non-HTTPS/relative endpoint throws a secret-free `ConnectionStringError`
/// rather than yielding a partially-valid configuration.
///
/// - Note on fidelity: the .NET reference does not GUID-validate the key and
///   permits any URL scheme on an explicit endpoint. Stout deliberately
///   hardens both — GUID validation (FR-003) and HTTPS-only endpoints (FR-029) —
///   per the security-first prime directive.
/// - Warning: `instrumentationKey` is secret. It is accessible so the exporter
///   can stamp envelopes, but is `<redacted>` in this type's description and must
///   never be logged.
public struct ConnectionConfiguration: Sendable {
  /// The validated GUID instrumentation key. **Secret** — routed to the `iKey`
  /// wire field; never rendered in logs, errors, or diagnostics.
  public let instrumentationKey: String
  /// The resolved, HTTPS, absolute ingestion endpoint, normalized without a
  /// trailing slash. Compose the track URL via `trackURL`.
  public let ingestionEndpoint: URL
  /// The optional Live Metrics endpoint, retained for spec 06; not consumed here.
  public let liveEndpoint: URL?
  /// The optional endpoint suffix supplied in the connection string, if any.
  public let endpointSuffix: String?
  /// Optional auth/region fields (e.g. `AADAudience`, `Location`) retained
  /// verbatim for later specs. Never logged.
  public let retainedFields: [String: String]

  /// The full ingestion track URL, `{ingestionEndpoint}/v2.1/track`.
  public var trackURL: URL { IngestionPath.trackURL(for: ingestionEndpoint) }

  /// The default public-cloud ingestion endpoint used when the connection string
  /// supplies neither an explicit endpoint nor a suffix (FR-004).
  static let defaultIngestionEndpoint = "https://dc.services.visualstudio.com/"
  /// The ingestion host prefix used when composing an endpoint from a suffix.
  private static let ingestionPrefix = "dc"

  private static let recognizedKeys: Set<String> = [
    "instrumentationkey", "ingestionendpoint", "liveendpoint", "endpointsuffix",
  ]

  /// Parse and validate a connection string. Throws `ConnectionStringError` on
  /// any invalid input (fail-closed).
  public init(connectionString: String) throws {
    let trimmed = connectionString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ConnectionStringError.empty }

    // Tokenize: ';'-separated, first '=' splits key/value, both sides trimmed,
    // keys matched case-insensitively, duplicate keys rejected (mirrors .NET).
    var lowerMap: [String: String] = [:]
    var retained: [String: String] = [:]
    var seenKeys: Set<String> = []

    for segment in trimmed.split(separator: ";", omittingEmptySubsequences: true) {
      guard let equals = segment.firstIndex(of: "=") else { continue }
      let rawKey = segment[..<equals].trimmingCharacters(in: .whitespaces)
      let rawValue = segment[segment.index(after: equals)...]
        .trimmingCharacters(in: .whitespaces)
      guard !rawKey.isEmpty else { continue }

      let lowerKey = rawKey.lowercased()
      guard seenKeys.insert(lowerKey).inserted else {
        throw ConnectionStringError.duplicateKey(rawKey)
      }
      guard !rawValue.isEmpty else { continue }

      if Self.recognizedKeys.contains(lowerKey) {
        lowerMap[lowerKey] = rawValue
      } else {
        retained[rawKey] = rawValue
      }
    }

    // InstrumentationKey — required, GUID-validated (Stout hardening, FR-003).
    guard let iKey = lowerMap["instrumentationkey"] else {
      throw ConnectionStringError.missingInstrumentationKey
    }
    guard UUID(uuidString: iKey) != nil else {
      throw ConnectionStringError.malformedInstrumentationKey
    }
    self.instrumentationKey = iKey

    // Ingestion endpoint precedence: explicit → suffix-derived → default.
    let resolvedEndpoint: URL
    if let explicit = lowerMap["ingestionendpoint"] {
      resolvedEndpoint = try Self.validatedHTTPSURL(explicit, field: "IngestionEndpoint")
    } else if let suffix = lowerMap["endpointsuffix"] {
      let composed = Self.composeSuffixEndpoint(
        suffix: suffix,
        location: retained["Location"] ?? lowerMap["location"]
      )
      resolvedEndpoint = try Self.validatedHTTPSURL(composed, field: "EndpointSuffix")
    } else {
      // The default constant is well-formed; fall back defensively without a
      // force-unwrap (no fatalError on any path, Constitution II).
      resolvedEndpoint =
        URL(string: Self.defaultIngestionEndpoint)
        ?? URL(string: "https://dc.services.visualstudio.com")!
    }
    self.ingestionEndpoint = Self.normalized(resolvedEndpoint)

    if let live = lowerMap["liveendpoint"] {
      self.liveEndpoint = Self.normalized(
        try Self.validatedHTTPSURL(live, field: "LiveEndpoint"))
    } else {
      self.liveEndpoint = nil
    }

    self.endpointSuffix = lowerMap["endpointsuffix"]
    self.retainedFields = retained
  }

  /// Validate that `value` is an absolute HTTPS URL, throwing a field-scoped,
  /// secret-free error otherwise.
  private static func validatedHTTPSURL(_ value: String, field: String) throws -> URL {
    guard let url = URL(string: value), url.scheme != nil, url.host != nil else {
      throw ConnectionStringError.missingOrMalformedEndpoint(field: field)
    }
    guard url.scheme?.lowercased() == "https" else {
      throw ConnectionStringError.nonHTTPSEndpoint(field: field)
    }
    return url
  }

  /// Compose `https://[{location}.]dc.{suffix}` from a suffix and optional
  /// location (mirrors .NET `TryBuildUri`): the suffix is trimmed of whitespace
  /// and leading dots; a location is trimmed, stripped of a trailing dot, and
  /// used only if alphanumeric.
  private static func composeSuffixEndpoint(suffix: String, location: String?) -> String {
    let cleanSuffix = suffix.trimmingCharacters(in: .whitespaces)
      .drop(while: { $0 == "." })
    var host = ""
    if let location = location?.trimmingCharacters(in: .whitespaces),
      !location.isEmpty
    {
      let cleanLocation = location.hasSuffix(".") ? String(location.dropLast()) : location
      if cleanLocation.allSatisfy({ $0.isLetter || $0.isNumber }) {
        host += "\(cleanLocation)."
      }
    }
    host += "\(ingestionPrefix).\(cleanSuffix)"
    return "https://\(host)"
  }

  /// Normalize an endpoint to have no trailing slash so track-path composition is
  /// unambiguous.
  private static func normalized(_ url: URL) -> URL {
    let string = url.absoluteString
    guard string.hasSuffix("/") else { return url }
    return URL(string: String(string.dropLast())) ?? url
  }
}

extension ConnectionConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "ConnectionConfiguration(ingestionEndpoint: \(ingestionEndpoint.absoluteString), "
      + "instrumentationKey: <redacted>)"
  }

  public var debugDescription: String { description }
}
