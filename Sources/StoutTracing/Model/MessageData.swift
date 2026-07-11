// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import StoutCore

/// The Breeze `MessageData` payload — derived from a non-`exception` span event,
/// telemetry name `Microsoft.ApplicationInsights.Message` (data-model §1d).
///
/// Encodes `"ver": 2` first.
struct MessageData: BaseData {
  static let baseType = "MessageData"

  /// Breeze schema version — always `2`.
  let ver: Int
  /// The message text — the event name, or a `message` attribute when present.
  let message: String
  /// Event attributes, stringified.
  let properties: [String: String]

  init(message: String, properties: [String: String] = [:]) {
    self.ver = 2
    self.message = message
    self.properties = properties
  }

  private enum CodingKeys: String, CodingKey {
    case ver, message, properties
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ver, forKey: .ver)
    try container.encode(message, forKey: .message)
    try container.encode(properties, forKey: .properties)
  }
}
