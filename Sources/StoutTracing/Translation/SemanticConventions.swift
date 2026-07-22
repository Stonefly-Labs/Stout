// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi

/// The OTel semantic-convention attribute keys this exporter reads, and a
/// **current-wins** lookup over them (data-model §5, mirrors the .NET
/// `ActivityTagsProcessor`).
///
/// OTel renamed many span attributes (e.g. `http.method` → `http.request.method`);
/// instrumentations in the wild emit either generation. For each concept we hold an
/// ordered precedence list — the **current** key first, then legacy fallbacks — and
/// resolve by scanning that list, not the attribute dictionary. Because the list
/// order (not dict iteration order) decides the winner, the result is deterministic
/// and attribute-order-independent (INV-3, research.md D-07).
enum SemanticConventions {
  // MARK: Individual wire keys

  static let httpRequestMethod = "http.request.method"
  static let httpMethodLegacy = "http.method"
  static let httpResponseStatusCode = "http.response.status_code"
  static let httpStatusCodeLegacy = "http.status_code"
  static let urlFull = "url.full"
  static let httpUrlLegacy = "http.url"
  static let urlScheme = "url.scheme"
  static let httpSchemeLegacy = "http.scheme"
  static let urlPath = "url.path"
  static let urlQuery = "url.query"
  static let httpTargetLegacy = "http.target"
  static let httpRoute = "http.route"
  static let serverAddress = "server.address"
  static let netPeerNameLegacy = "net.peer.name"
  static let httpHostLegacy = "http.host"
  static let serverPort = "server.port"
  static let netPeerPortLegacy = "net.peer.port"

  static let dbSystem = "db.system"
  static let dbNamespace = "db.namespace"
  static let dbNameLegacy = "db.name"
  static let dbQueryText = "db.query.text"
  static let dbStatementLegacy = "db.statement"

  static let rpcSystem = "rpc.system"
  static let rpcService = "rpc.service"
  static let rpcMethod = "rpc.method"
  static let rpcGrpcStatusCode = "rpc.grpc.status_code"

  static let messagingSystem = "messaging.system"
  static let messagingDestinationName = "messaging.destination.name"
  static let messagingDestinationLegacy = "messaging.destination"
  static let networkProtocolName = "network.protocol.name"

  static let peerService = "peer.service"

  // Exception span-event attributes (OTel `exception` event, data-model §1c).
  static let exceptionEventName = "exception"
  static let exceptionType = "exception.type"
  static let exceptionMessage = "exception.message"
  static let exceptionStacktrace = "exception.stacktrace"

  // MARK: Precedence lists (current first, then legacy)

  static let httpMethod = [httpRequestMethod, httpMethodLegacy]
  static let httpStatus = [httpResponseStatusCode, httpStatusCodeLegacy]
  static let urlFullKeys = [urlFull, httpUrlLegacy]
  static let scheme = [urlScheme, httpSchemeLegacy]
  static let pathKeys = [urlPath, httpTargetLegacy]
  static let host = [serverAddress, netPeerNameLegacy, httpHostLegacy]
  static let port = [serverPort, netPeerPortLegacy]
  static let dbName = [dbNamespace, dbNameLegacy]
  static let dbStatement = [dbQueryText, dbStatementLegacy]
  static let messagingDestination = [messagingDestinationName, messagingDestinationLegacy]

  // MARK: Current-wins lookup

  /// The first present attribute value across `keys`, scanned in order (current
  /// key first). Returns `nil` when none is set. Order-independent with respect to
  /// the attribute dictionary (INV-3).
  static func firstValue(
    in attributes: [String: AttributeValue], _ keys: [String]
  ) -> AttributeValue? {
    for key in keys {
      if let value = attributes[key] { return value }
    }
    return nil
  }

  /// Convenience: the winning value already stringified (data-model §0 rule).
  static func firstString(
    in attributes: [String: AttributeValue], _ keys: [String]
  ) -> String? {
    firstValue(in: attributes, keys).map(AttributeStringifier.string(from:))
  }

  /// The subset of `keys` actually present in `attributes` — the keys a mapper has
  /// consumed, so the orchestrator can strip them before carrying the remainder to
  /// `properties`.
  static func presentKeys(
    in attributes: [String: AttributeValue], _ keys: [String]
  ) -> [String] {
    keys.filter { attributes[$0] != nil }
  }
}
