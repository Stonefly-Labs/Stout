// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi

/// gRPC / RPC span derivation for `RemoteDependencyData` (data-model §5, FR-013–016).
///
/// This is a **deliberate enrichment beyond .NET** (research.md D-04): the .NET
/// exporter has no dedicated RPC mapping, but the spec requires gRPC
/// `type`/`target`/`data`/status handling, so Stout maps it explicitly. Pure and
/// deterministic; a span is an "RPC" span when it carries `rpc.system`, else `derive`
/// returns `nil` and the caller falls through to the next protocol mapper.
struct RPCMapping: Sendable {
  /// Dependency `type` — `"GRPC"` for gRPC, else the `rpc.system` value.
  let type: String
  /// Dependency `target` — the RPC server host `host[:port]`, else the service name.
  let target: String?
  /// Dependency `data` — `"{rpc.service}/{rpc.method}"`, the service alone, or `nil`.
  let data: String?
  /// Dependency `resultCode` — `rpc.grpc.status_code` as a string, when present.
  let resultCode: String?
  /// The semantic-convention keys this derivation consumed.
  let consumedKeys: [String]

  /// Derive RPC dependency fields, or `nil` when the span carries no `rpc.system`.
  static func derive(from attributes: [String: AttributeValue]) -> RPCMapping? {
    guard
      let system = SemanticConventions.firstString(in: attributes, [SemanticConventions.rpcSystem])
    else { return nil }

    let type = system.lowercased() == "grpc" ? "GRPC" : system

    let service = SemanticConventions.firstString(in: attributes, [SemanticConventions.rpcService])
    let method = SemanticConventions.firstString(in: attributes, [SemanticConventions.rpcMethod])
    let data = [service, method].compactMap { $0 }.joined(separator: "/")

    let host = SemanticConventions.firstString(in: attributes, SemanticConventions.host)
    let port = SemanticConventions.firstString(in: attributes, SemanticConventions.port)
    let hostTarget = host.map { host in port.map { "\(host):\($0)" } ?? host }
    let target = hostTarget ?? service

    let resultCode = SemanticConventions.firstString(
      in: attributes, [SemanticConventions.rpcGrpcStatusCode])

    var consumed = [SemanticConventions.rpcSystem]
    consumed += SemanticConventions.presentKeys(
      in: attributes,
      [
        SemanticConventions.rpcService, SemanticConventions.rpcMethod,
        SemanticConventions.rpcGrpcStatusCode,
      ] + SemanticConventions.host + SemanticConventions.port)

    return RPCMapping(
      type: type,
      target: target,
      data: data.isEmpty ? nil : data,
      resultCode: resultCode,
      consumedKeys: consumed)
  }
}
