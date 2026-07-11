// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi

/// Shared HTTP-span derivation over current + legacy semantic-convention keys
/// (data-model §5), consumed by both the Request path (US1) and the Dependency path
/// (US2). Pure and deterministic: the current key wins over its legacy alias
/// regardless of attribute order (INV-3).
///
/// A span is "HTTP" when it carries any HTTP-specific signal (method, status, url,
/// scheme, target, route, or `http.host`). Generic keys like `server.address` alone
/// do **not** classify a span as HTTP — DB/RPC spans use them too — so `derive`
/// returns `nil` for a non-HTTP span and the caller falls through to the next
/// protocol mapper.
struct HTTPMapping: Sendable {
  /// HTTP request method (e.g. `GET`), when present.
  let method: String?
  /// Parsed HTTP status code, when present and numeric.
  let statusCode: Int?
  /// Route template (`http.route`), when present.
  let route: String?
  /// Full request URL — the explicit `url.full`/`http.url`, else reconstructed from
  /// scheme/host/port/path/query, else `nil`.
  let url: String?
  /// Dependency target — `host[:port]`, when a host is present.
  let target: String?
  /// The semantic-convention keys this derivation consumed (so the orchestrator can
  /// strip them before carrying the remaining attributes to `properties`).
  let consumedKeys: [String]

  /// The status code as a wire string, when present.
  var statusString: String? { statusCode.map(String.init) }

  /// A route/method-derived request name (`"GET /widgets/{id}"`, or just the route
  /// when no method), else `nil` so the caller falls back to the span name.
  var derivedName: String? {
    guard let route else { return nil }
    if let method { return "\(method) \(route)" }
    return route
  }

  /// The HTTP-specific keys whose presence marks a span as an HTTP span.
  private static let signalKeys: [String] =
    SemanticConventions.httpMethod + SemanticConventions.httpStatus
    + SemanticConventions.urlFullKeys + SemanticConventions.scheme
    + [
      SemanticConventions.httpTargetLegacy,
      SemanticConventions.httpRoute,
      SemanticConventions.httpHostLegacy,
    ]

  /// Derive HTTP fields from a span's attributes, or `nil` when the span carries no
  /// HTTP signal.
  static func derive(from attributes: [String: AttributeValue]) -> HTTPMapping? {
    let hasSignal = signalKeys.contains { attributes[$0] != nil }
    guard hasSignal else { return nil }

    let method = SemanticConventions.firstString(in: attributes, SemanticConventions.httpMethod)
    let statusCode = intValue(in: attributes, SemanticConventions.httpStatus)
    let route = attributes[SemanticConventions.httpRoute].map(AttributeStringifier.string(from:))

    let host = SemanticConventions.firstString(in: attributes, SemanticConventions.host)
    let port = SemanticConventions.firstString(in: attributes, SemanticConventions.port)
    let target = host.map { host in port.map { "\(host):\($0)" } ?? host }

    let url = resolveURL(in: attributes, host: host, port: port)

    // Every key we looked at that was actually present is consumed.
    var consumed = SemanticConventions.presentKeys(
      in: attributes,
      SemanticConventions.httpMethod + SemanticConventions.httpStatus
        + SemanticConventions.urlFullKeys + SemanticConventions.scheme
        + SemanticConventions.pathKeys + SemanticConventions.host + SemanticConventions.port)
    if attributes[SemanticConventions.httpRoute] != nil {
      consumed.append(SemanticConventions.httpRoute)
    }

    return HTTPMapping(
      method: method,
      statusCode: statusCode,
      route: route,
      url: url,
      target: target,
      consumedKeys: consumed)
  }

  /// The full URL: prefer an explicit `url.full`/`http.url`; otherwise reconstruct
  /// `scheme://host[:port]path?query` when a host is available.
  private static func resolveURL(
    in attributes: [String: AttributeValue], host: String?, port: String?
  ) -> String? {
    if let full = SemanticConventions.firstString(in: attributes, SemanticConventions.urlFullKeys) {
      return full
    }
    guard let host else { return nil }
    let scheme =
      SemanticConventions.firstString(in: attributes, SemanticConventions.scheme) ?? "https"
    let authority = port.map { "\(host):\($0)" } ?? host
    let path = SemanticConventions.firstString(in: attributes, SemanticConventions.pathKeys) ?? ""
    return "\(scheme)://\(authority)\(path)"
  }

  /// Read an integer-valued attribute across a precedence list. Accepts an `.int`
  /// directly and a `.string` that parses as an integer (some instrumentations send
  /// the status code as text).
  private static func intValue(
    in attributes: [String: AttributeValue], _ keys: [String]
  ) -> Int? {
    guard let value = SemanticConventions.firstValue(in: attributes, keys) else { return nil }
    switch value {
    case .int(let intValue): return intValue
    case .string(let text): return Int(text)
    default: return nil
    }
  }
}
