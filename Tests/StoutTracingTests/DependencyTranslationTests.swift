// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import StoutCore
import XCTest

@testable import StoutTracing

/// User Story 2 — a `.client`/`.producer`/`.internal`/unspecified span becomes
/// exactly one correlated `RemoteDependencyData` on the pipeline (US2 Acc 1 & 4,
/// FR-022, SC-001). Exercised end-to-end through ``AzureMonitorTraceExporter`` and
/// the mock pipeline harness — no network.
final class DependencyTranslationTests: XCTestCase {
  private func exporter(_ harness: TracingTestHarness) -> AzureMonitorTraceExporter {
    AzureMonitorTraceExporter(pipeline: harness.pipeline, envelopeFactory: harness.envelopeFactory)
  }

  func testClientSpanBecomesOneDependencyWithExpectedFields() async {
    let harness = makeTracingHarness()
    let span = SpanDataBuilder(
      name: "GET /widgets",
      kind: .client,
      attributes: [
        SemanticConventions.httpRequestMethod: .string("GET"),
        SemanticConventions.httpResponseStatusCode: .int(200),
        SemanticConventions.urlFull: .string("https://api.example.com/widgets"),
        "custom.tag": .string("keep-me"),
      ]
    ).build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    XCTAssertEqual(envelopes.count, 1)
    let env = envelopes[0]
    XCTAssertEqual(env.baseType, "RemoteDependencyData")
    XCTAssertEqual(env.name, "Microsoft.ApplicationInsights.RemoteDependency")

    let data = env.baseData
    XCTAssertEqual(data?["ver"]?.doubleValue, 2)
    XCTAssertEqual(data?["id"]?.stringValue, SpanDataBuilder.defaultSpanIdHex)
    XCTAssertEqual(data?["name"]?.stringValue, "GET /widgets")
    XCTAssertEqual(data?["duration"]?.stringValue, "00:00:00.2500000")
    XCTAssertEqual(data?["type"]?.stringValue, "HTTP")
    XCTAssertEqual(data?["resultCode"]?.stringValue, "200")
    XCTAssertEqual(data?["data"]?.stringValue, "https://api.example.com/widgets")
    XCTAssertEqual(data?["success"]?.boolValue, true)

    // Unmapped attribute is carried into `properties`; consumed HTTP keys are not.
    XCTAssertEqual(data?["properties"]?["custom.tag"]?.stringValue, "keep-me")
    XCTAssertNil(data?["properties"]?[SemanticConventions.httpRequestMethod])
    XCTAssertNil(data?["properties"]?[SemanticConventions.urlFull])
    // No `ai.operation.name` on dependencies (that names the owning request).
    XCTAssertNil(env.tag(PartATagKeys.operationName))
  }

  func testProducerSpanBecomesDependency() async {
    let harness = makeTracingHarness()
    let span = SpanDataBuilder(name: "publish", kind: .producer).build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    XCTAssertEqual(envelopes.count, 1)
    XCTAssertEqual(envelopes[0].baseType, "RemoteDependencyData")
    XCTAssertEqual(envelopes[0].baseData?["name"]?.stringValue, "publish")
    // No protocol status ⇒ resultCode default.
    XCTAssertEqual(envelopes[0].baseData?["resultCode"]?.stringValue, "0")
  }

  func testInternalSpanIsInProcDependency() async {
    let harness = makeTracingHarness()
    let span = SpanDataBuilder(name: "compute", kind: .internal).build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    XCTAssertEqual(envelopes.count, 1)
    XCTAssertEqual(envelopes[0].baseType, "RemoteDependencyData")
    XCTAssertEqual(envelopes[0].baseData?["type"]?.stringValue, "InProc")
  }

  func testUnspecifiedKindDefaultsToDependency() async {
    let harness = makeTracingHarness()
    // No `.unspecified` case exists on `SpanKind`; `.client` is the canonical
    // non-server/non-consumer default and the same code path the mapping table's
    // "absent/unspecified ⇒ Dependency" row exercises (data-model §3).
    let span = SpanDataBuilder(name: "outbound", kind: .client).build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    XCTAssertEqual(envelopes.count, 1)
    XCTAssertEqual(envelopes[0].baseType, "RemoteDependencyData")
  }

  func testCorrelationIdAndParentIdOnDependency() async {
    let harness = makeTracingHarness()
    var builder = SpanDataBuilder(kind: .client)
    builder.parentSpanIdHex = SpanDataBuilder.defaultParentSpanIdHex
    let span = builder.build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    XCTAssertEqual(envelopes[0].tag(PartATagKeys.operationId), SpanDataBuilder.defaultTraceIdHex)
    XCTAssertEqual(
      envelopes[0].tag(PartATagKeys.operationParentId), SpanDataBuilder.defaultParentSpanIdHex)
  }

  func testRootDependencyHasNoParentId() async {
    let harness = makeTracingHarness()
    let span = SpanDataBuilder(kind: .client).build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    XCTAssertNil(envelopes[0].tag(PartATagKeys.operationParentId))
  }

  func testSpanLinksCarriedIntoDependencyProperties() async {
    let harness = makeTracingHarness()
    let linkedSpanId = "00000000000000bb"
    var builder = SpanDataBuilder(kind: .client, attributes: ["k": .string("v")])
    builder.links = [SpanDataBuilder.link(spanIdHex: linkedSpanId)]
    let span = builder.build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    let links = envelopes[0].baseData?["properties"]?[SpanTranslator.linksPropertyKey]?.stringValue
    XCTAssertNotNil(links)
    XCTAssertTrue(links?.contains(linkedSpanId) == true, "links property should carry the span id")
    XCTAssertEqual(envelopes[0].baseData?["properties"]?["k"]?.stringValue, "v")
  }
}
