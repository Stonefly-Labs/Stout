// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import StoutCore
import XCTest

@testable import StoutTracing

/// User Story 1 — a `.server`/`.consumer` span becomes exactly one correlated
/// `RequestData` on the pipeline (US1 Acc 1–4, FR-022, SC-001). Exercised
/// end-to-end through ``AzureMonitorTraceExporter`` and the mock pipeline harness —
/// no network.
final class RequestTranslationTests: XCTestCase {
  private func exporter(_ harness: TracingTestHarness) -> AzureMonitorTraceExporter {
    AzureMonitorTraceExporter(pipeline: harness.pipeline, envelopeFactory: harness.envelopeFactory)
  }

  func testServerSpanBecomesOneRequestWithExpectedFields() async {
    let harness = makeTracingHarness()
    let span = SpanDataBuilder(
      name: "ignored-when-route-present",
      kind: .server,
      attributes: [
        SemanticConventions.httpRequestMethod: .string("GET"),
        SemanticConventions.httpResponseStatusCode: .int(200),
        SemanticConventions.urlFull: .string("https://api.example.com/widgets/42"),
        SemanticConventions.httpRoute: .string("/widgets/{id}"),
        "custom.tag": .string("keep-me"),
      ]
    ).build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    XCTAssertEqual(envelopes.count, 1)
    let env = envelopes[0]
    XCTAssertEqual(env.baseType, "RequestData")
    XCTAssertEqual(env.name, "Microsoft.ApplicationInsights.Request")

    let data = env.baseData
    XCTAssertEqual(data?["ver"]?.doubleValue, 2)
    XCTAssertEqual(data?["id"]?.stringValue, SpanDataBuilder.defaultSpanIdHex)
    XCTAssertEqual(data?["name"]?.stringValue, "GET /widgets/{id}")
    XCTAssertEqual(data?["duration"]?.stringValue, "00:00:00.2500000")
    XCTAssertEqual(data?["responseCode"]?.stringValue, "200")
    XCTAssertEqual(data?["url"]?.stringValue, "https://api.example.com/widgets/42")
    XCTAssertEqual(data?["success"]?.boolValue, true)

    // Unmapped attribute is carried into `properties`; consumed HTTP keys are not.
    XCTAssertEqual(data?["properties"]?["custom.tag"]?.stringValue, "keep-me")
    XCTAssertNil(data?["properties"]?[SemanticConventions.httpRequestMethod])
    XCTAssertNil(data?["properties"]?[SemanticConventions.urlFull])

    // Correlation: operation id ← trace id; root span ⇒ no parentId.
    XCTAssertEqual(env.tag(PartATagKeys.operationId), SpanDataBuilder.defaultTraceIdHex)
    XCTAssertNil(env.tag(PartATagKeys.operationParentId))
    XCTAssertEqual(env.tag(PartATagKeys.operationName), "GET /widgets/{id}")
  }

  func testConsumerSpanBecomesRequest() async {
    let harness = makeTracingHarness()
    let span = SpanDataBuilder(name: "process-order", kind: .consumer).build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    XCTAssertEqual(envelopes.count, 1)
    XCTAssertEqual(envelopes[0].baseType, "RequestData")
    // No HTTP attributes ⇒ name falls back to the span name, responseCode default.
    XCTAssertEqual(envelopes[0].baseData?["name"]?.stringValue, "process-order")
    XCTAssertEqual(envelopes[0].baseData?["responseCode"]?.stringValue, "0")
  }

  func testChildRequestCarriesParentId() async {
    let harness = makeTracingHarness()
    var builder = SpanDataBuilder(kind: .server)
    builder.parentSpanIdHex = SpanDataBuilder.defaultParentSpanIdHex
    let span = builder.build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    XCTAssertEqual(
      envelopes[0].tag(PartATagKeys.operationParentId), SpanDataBuilder.defaultParentSpanIdHex)
  }

  func testSpanLinksCarriedIntoProperties() async {
    let harness = makeTracingHarness()
    let linkedSpanId = "00000000000000aa"
    var builder = SpanDataBuilder(kind: .server, attributes: ["k": .string("v")])
    builder.links = [SpanDataBuilder.link(spanIdHex: linkedSpanId)]
    let span = builder.build()

    _ = await exporter(harness).export(spans: [span], explicitTimeout: nil)
    let envelopes = await harness.envelopes(atLeast: 1)

    let links = envelopes[0].baseData?["properties"]?[SpanTranslator.linksPropertyKey]?.stringValue
    XCTAssertNotNil(links)
    XCTAssertTrue(links?.contains(linkedSpanId) == true, "links property should carry the span id")
    XCTAssertTrue(
      links?.contains(SpanDataBuilder.defaultTraceIdHex) == true,
      "links property should carry the operation id")
    // The regular attribute is still carried alongside the links.
    XCTAssertEqual(envelopes[0].baseData?["properties"]?["k"]?.stringValue, "v")
  }
}
