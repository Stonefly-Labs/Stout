// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import StoutCore

/// The Breeze `RequestData` payload — an incoming request the app handled
/// (`.server`/`.consumer` spans), telemetry name
/// `Microsoft.ApplicationInsights.Request` (data-model §1a).
///
/// Encodes `"ver": 2` first, then the request fields; optional fields are omitted
/// when `nil` so the wire body carries only what applies. Correlation ids live in
/// the surrounding envelope's Part A tags, not here.
struct RequestData: BaseData {
  static let baseType = "RequestData"

  /// Breeze schema version — always `2`.
  let ver: Int
  /// Item id — the span id (16-hex).
  let id: String
  /// Request name — route/method-derived HTTP name, else the span name.
  let name: String
  /// Elapsed time as Breeze `d.hh:mm:ss.fffffff`.
  let duration: String
  /// Protocol status string (HTTP/gRPC), else `"0"`.
  let responseCode: String
  /// Success predicate outcome (server-side rule).
  let success: Bool
  /// Reconstructed request URL, when derivable from HTTP attributes.
  let url: String?
  /// Originating identity for messaging/correlation consumers, else absent.
  let source: String?
  /// Unmapped span attributes and links, stringified.
  let properties: [String: String]

  init(
    id: String,
    name: String,
    duration: String,
    responseCode: String,
    success: Bool,
    url: String? = nil,
    source: String? = nil,
    properties: [String: String] = [:]
  ) {
    self.ver = 2
    self.id = id
    self.name = name
    self.duration = duration
    self.responseCode = responseCode
    self.success = success
    self.url = url
    self.source = source
    self.properties = properties
  }

  private enum CodingKeys: String, CodingKey {
    case ver, id, name, duration, responseCode, success, url, source, properties
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    // `ver` first so the payload reads `{ "ver": 2, ... }` (BaseData contract).
    try container.encode(ver, forKey: .ver)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(duration, forKey: .duration)
    try container.encode(responseCode, forKey: .responseCode)
    try container.encode(success, forKey: .success)
    try container.encodeIfPresent(url, forKey: .url)
    try container.encodeIfPresent(source, forKey: .source)
    // Always emit `properties` (Breeze expects the object, empty when none).
    try container.encode(properties, forKey: .properties)
  }
}
