// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi

/// Messaging span derivation (data-model §5, research.md D-04/D-05). Serves two
/// paths:
///
/// - **Producer** (`.producer` dependency): `type`/`target`/`data` for the
///   `RemoteDependencyData`.
/// - **Consumer** (`.consumer` request): the `RequestData.source` — the messaging
///   origin the message came from (FR-008).
///
/// A span is a "messaging" span when it carries `messaging.system`, else `derive`
/// returns `nil`. Pure and deterministic; the current key wins over its legacy alias
/// (INV-3).
struct MessagingMapping: Sendable {
  /// Dependency `type` — the `messaging.system` value.
  let type: String
  /// Dependency `target` — `"{host}/{destination}"`, the host, or the destination.
  let target: String?
  /// Dependency `data` — `"{protocol}://{host}/{destination}"` when a network
  /// protocol is known, else the destination.
  let data: String?
  /// Consumer `RequestData.source` — the same host/destination origin (FR-008).
  let source: String?
  /// The semantic-convention keys this derivation consumed.
  let consumedKeys: [String]

  /// Derive messaging fields, or `nil` when the span carries no `messaging.system`.
  static func derive(from attributes: [String: AttributeValue]) -> MessagingMapping? {
    guard
      let system = SemanticConventions.firstString(
        in: attributes, [SemanticConventions.messagingSystem])
    else { return nil }

    let host = SemanticConventions.firstString(in: attributes, SemanticConventions.host)
    let destination = SemanticConventions.firstString(
      in: attributes, SemanticConventions.messagingDestination)

    // host/destination origin shared by producer `target` and consumer `source`.
    let origin = originString(host: host, destination: destination)

    let data: String?
    if let host,
      let proto = SemanticConventions.firstString(
        in: attributes, [SemanticConventions.networkProtocolName])
    {
      data = "\(proto)://\(host)/\(destination ?? "")"
    } else {
      data = destination
    }

    var consumed = [SemanticConventions.messagingSystem]
    consumed += SemanticConventions.presentKeys(
      in: attributes,
      SemanticConventions.messagingDestination + SemanticConventions.host
        + SemanticConventions.port + [SemanticConventions.networkProtocolName])

    return MessagingMapping(
      type: system, target: origin, data: data, source: origin, consumedKeys: consumed)
  }

  /// `"{host}/{destination}"` when both are present, else whichever is present.
  private static func originString(host: String?, destination: String?) -> String? {
    switch (host, destination) {
    case (let host?, let destination?): return "\(host)/\(destination)"
    case (let host?, nil): return host
    case (nil, let destination?): return destination
    case (nil, nil): return nil
    }
  }
}
