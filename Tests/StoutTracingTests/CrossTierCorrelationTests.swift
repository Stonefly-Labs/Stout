// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import StoutCore
import XCTest

@testable import StoutTracing

/// User Story 3 — two SDK-correlated tiers render as one end-to-end transaction
/// (SC-005, US3 Acc 3). A caller `.client` span and a callee `.server` span whose
/// parent span id equals the caller's span id (as W3C propagation produces) must
/// share one `ai.operation.id`, and the callee's `ai.operation.parentId` must equal
/// the caller's item id — asserted on the wire through the mock pipeline, no network.
final class CrossTierCorrelationTests: XCTestCase {
  // Tier A (caller) is a root `.client` span; tier B (callee) is a `.server` span
  // whose parent is tier A's span, both under the same trace.
  private let sharedTraceIdHex = "0af7651916cd43dd8448eb211c80319c"
  private let callerSpanIdHex = "aaaaaaaaaaaaaaaa"
  private let calleeSpanIdHex = "bbbbbbbbbbbbbbbb"

  private func exporter(_ harness: TracingTestHarness) -> AzureMonitorTraceExporter {
    AzureMonitorTraceExporter(pipeline: harness.pipeline, envelopeFactory: harness.envelopeFactory)
  }

  func testTwoTiersShareOneOperationAndCalleeParentIsCallerItemId() async {
    let harness = makeTracingHarness()

    var caller = SpanDataBuilder(name: "GET /downstream", kind: .client)
    caller.traceIdHex = sharedTraceIdHex
    caller.spanIdHex = callerSpanIdHex
    // Tier A originates the trace: root span, no parent.

    var callee = SpanDataBuilder(name: "GET /downstream", kind: .server)
    callee.traceIdHex = sharedTraceIdHex
    callee.spanIdHex = calleeSpanIdHex
    callee.parentSpanIdHex = callerSpanIdHex

    let spans = [caller.build(), callee.build()]
    _ = await exporter(harness).export(spans: spans, explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 2)

    XCTAssertEqual(envelopes.count, 2)
    let dependency = try? XCTUnwrap(envelopes.first { $0.baseType == "RemoteDependencyData" })
    let request = try? XCTUnwrap(envelopes.first { $0.baseType == "RequestData" })
    guard let dependency = dependency ?? nil, let request = request ?? nil else {
      return XCTFail("expected one RequestData and one RemoteDependencyData")
    }

    // Both tiers belong to the same operation (transaction).
    XCTAssertEqual(dependency.tag(PartATagKeys.operationId), sharedTraceIdHex)
    XCTAssertEqual(request.tag(PartATagKeys.operationId), sharedTraceIdHex)

    // The caller's item id is its span id; the callee's parent id points back to it.
    XCTAssertEqual(dependency.baseData?["id"]?.stringValue, callerSpanIdHex)
    XCTAssertEqual(request.baseData?["id"]?.stringValue, calleeSpanIdHex)
    XCTAssertEqual(request.tag(PartATagKeys.operationParentId), callerSpanIdHex)

    // The caller is the trace root — its parent id is absent.
    XCTAssertNil(dependency.tag(PartATagKeys.operationParentId))
  }

  func testRootServerSpanHasAbsentParentIdOnTheWire() async {
    let harness = makeTracingHarness()
    // A `.server` span with no parent (the propagation entry point): its
    // `ai.operation.parentId` must be absent on the wire, not an empty string.
    let span = SpanDataBuilder(name: "GET /entry", kind: .server).build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    XCTAssertEqual(envelopes.count, 1)
    XCTAssertEqual(envelopes[0].tag(PartATagKeys.operationId), SpanDataBuilder.defaultTraceIdHex)
    XCTAssertNil(envelopes[0].tag(PartATagKeys.operationParentId))
    // `ai.operation.name` is set for server/consumer requests (transaction search).
    XCTAssertEqual(envelopes[0].tag(PartATagKeys.operationName), "GET /entry")
  }
}
