// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import StoutCore

/// The Breeze `RemoteDependencyData` payload — an outbound call the app made
/// (`.client`/`.producer`/`.internal`/unspecified spans), telemetry name
/// `Microsoft.ApplicationInsights.RemoteDependency` (data-model §1b).
///
/// Encodes `"ver": 2` first; optional `target`/`data` are omitted when `nil`.
struct RemoteDependencyData: BaseData {
  static let baseType = "RemoteDependencyData"

  /// Breeze schema version — always `2`.
  let ver: Int
  /// Item id — the span id (16-hex).
  let id: String
  /// Dependency name — the span name.
  let name: String
  /// Elapsed time as Breeze `d.hh:mm:ss.fffffff`.
  let duration: String
  /// Protocol status string (HTTP/gRPC/DB), else `"0"`.
  let resultCode: String
  /// Success predicate outcome (dependency-side rule).
  let success: Bool
  /// Dependency category: `HTTP` / `SQL` / `db.system` / messaging system /
  /// `GRPC` / `InProc`.
  let type: String
  /// Dependency target — host[:port], DB server, or messaging destination.
  let target: String?
  /// Dependency detail — full URL, DB statement, or destination.
  let data: String?
  /// Unmapped span attributes and links, stringified.
  let properties: [String: String]

  init(
    id: String,
    name: String,
    duration: String,
    resultCode: String,
    success: Bool,
    type: String,
    target: String? = nil,
    data: String? = nil,
    properties: [String: String] = [:]
  ) {
    self.ver = 2
    self.id = id
    self.name = name
    self.duration = duration
    self.resultCode = resultCode
    self.success = success
    self.type = type
    self.target = target
    self.data = data
    self.properties = properties
  }

  private enum CodingKeys: String, CodingKey {
    case ver, id, name, duration, resultCode, success, type, target, data, properties
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ver, forKey: .ver)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(duration, forKey: .duration)
    try container.encode(resultCode, forKey: .resultCode)
    try container.encode(success, forKey: .success)
    try container.encode(type, forKey: .type)
    try container.encodeIfPresent(target, forKey: .target)
    try container.encodeIfPresent(data, forKey: .data)
    try container.encode(properties, forKey: .properties)
  }
}
