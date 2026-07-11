// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import StoutCore

/// The Breeze `ExceptionData` payload — derived from an `exception` span event,
/// telemetry name `Microsoft.ApplicationInsights.Exception` (data-model §1c).
///
/// Carries one `ExceptionDetails` entry. Emitted only when both `exception.type`
/// and `exception.message` are present (the .NET drop rule, research.md D-08);
/// this type does not enforce that — `EventMapping` does — it just models the wire
/// shape. Encodes `"ver": 2` first.
struct ExceptionData: BaseData {
  static let baseType = "ExceptionData"

  /// One exception occurrence (Breeze `ExceptionDetails`).
  struct Details: Sendable, Encodable {
    /// Exception type name (`exception.type`).
    let typeName: String
    /// Exception message (`exception.message`).
    let message: String
    /// Whether a full stack trace is present.
    let hasFullStack: Bool
    /// The stack trace (`exception.stacktrace`), when present.
    let stack: String?

    private enum CodingKeys: String, CodingKey {
      case typeName, message, hasFullStack, stack
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(typeName, forKey: .typeName)
      try container.encode(message, forKey: .message)
      try container.encode(hasFullStack, forKey: .hasFullStack)
      try container.encodeIfPresent(stack, forKey: .stack)
    }
  }

  /// Breeze schema version — always `2`.
  let ver: Int
  /// The exception occurrences (always one for a single `exception` event).
  let exceptions: [Details]
  /// Remaining event attributes, stringified.
  let properties: [String: String]

  init(exceptions: [Details], properties: [String: String] = [:]) {
    self.ver = 2
    self.exceptions = exceptions
    self.properties = properties
  }

  private enum CodingKeys: String, CodingKey {
    case ver, exceptions, properties
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ver, forKey: .ver)
    try container.encode(exceptions, forKey: .exceptions)
    try container.encode(properties, forKey: .properties)
  }
}
