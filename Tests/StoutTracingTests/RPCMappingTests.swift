// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import XCTest

@testable import StoutTracing

/// User Story 2 — gRPC / RPC dependency mapping (FR-013–016, research.md D-04
/// enrichment). `type = "GRPC"`, `target`/`data` from `rpc.*`, `resultCode` from
/// `rpc.grpc.status_code`.
final class RPCMappingTests: XCTestCase {
  func testGrpcTypeTargetDataAndResultCode() {
    let rpc = RPCMapping.derive(from: [
      SemanticConventions.rpcSystem: .string("grpc"),
      SemanticConventions.rpcService: .string("myapp.Greeter"),
      SemanticConventions.rpcMethod: .string("SayHello"),
      SemanticConventions.rpcGrpcStatusCode: .int(0),
      SemanticConventions.serverAddress: .string("grpc.internal"),
      SemanticConventions.serverPort: .int(50051),
    ])

    XCTAssertEqual(rpc?.type, "GRPC")
    XCTAssertEqual(rpc?.target, "grpc.internal:50051")
    XCTAssertEqual(rpc?.data, "myapp.Greeter/SayHello")
    XCTAssertEqual(rpc?.resultCode, "0")
  }

  func testTargetFallsBackToServiceWhenNoHost() {
    let rpc = RPCMapping.derive(from: [
      SemanticConventions.rpcSystem: .string("grpc"),
      SemanticConventions.rpcService: .string("myapp.Greeter"),
    ])
    XCTAssertEqual(rpc?.target, "myapp.Greeter")
    XCTAssertEqual(rpc?.data, "myapp.Greeter")
  }

  func testNonGrpcRpcSystemKeepsItsValueAsType() {
    let rpc = RPCMapping.derive(from: [
      SemanticConventions.rpcSystem: .string("apache_dubbo")
    ])
    XCTAssertEqual(rpc?.type, "apache_dubbo")
  }

  func testNonRPCSpanReturnsNil() {
    XCTAssertNil(RPCMapping.derive(from: [SemanticConventions.serverAddress: .string("host")]))
  }

  func testResultCodeSurfacesOnDependency() {
    let span = SpanDataBuilder(
      kind: .client,
      attributes: [
        SemanticConventions.rpcSystem: .string("grpc"),
        SemanticConventions.rpcGrpcStatusCode: .int(5),
      ]
    ).build()

    let data = DependencyMapping.remoteDependencyData(for: span)
    XCTAssertEqual(data.type, "GRPC")
    XCTAssertEqual(data.resultCode, "5")
    // gRPC keys are consumed, not carried to properties.
    XCTAssertNil(data.properties[SemanticConventions.rpcSystem])
    XCTAssertNil(data.properties[SemanticConventions.rpcGrpcStatusCode])
  }
}
