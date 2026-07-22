// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import XCTest

@testable import StoutCore
@testable import StoutTracing

/// User Story 6 — the exporter is safe to call concurrently from many tasks
/// (FR-027, SC-010). `AzureMonitorTraceExporter` stores only an immutable
/// `EnvelopeFactory` and an actor-isolated `ExportPipeline`, so concurrent
/// `export(...)` calls translate in parallel and hand off race-free; nothing is
/// lost or double-counted. Run under the Thread Sanitizer (`swift test --sanitize=thread`)
/// this also proves there is no data race on the host's calling path.
final class ConcurrencyTests: XCTestCase {
  private func exporter(_ harness: TracingTestHarness) -> AzureMonitorTraceExporter {
    AzureMonitorTraceExporter(pipeline: harness.pipeline, envelopeFactory: harness.envelopeFactory)
  }

  func testConcurrentExportsAreRaceFreeAndLoseNothing() async {
    let harness = makeTracingHarness()
    let exp = exporter(harness)
    let count = 200

    // Fan out `export(...)` across many concurrent tasks, each with a distinct span
    // id so every item is individually accounted for.
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<count {
        group.addTask {
          var builder = SpanDataBuilder(kind: .server, attributes: ["i": .int(index)])
          builder.spanIdHex = String(format: "%016x", index + 1)
          _ = await exp.export(spans: [builder.build()], explicitTimeout: nil)
        }
      }
    }

    // Every span is translated and forwarded exactly once — no loss, no duplication,
    // no drop (the buffer capacity comfortably exceeds `count`).
    let envelopes = await harness.envelopes(atLeast: count)
    XCTAssertEqual(envelopes.count, count)
    XCTAssertTrue(envelopes.allSatisfy { $0.baseType == "RequestData" })

    // Each span carries a distinct id, so the Request `id`s recovered from the wire
    // must be exactly `count` distinct values — nothing merged, nothing duplicated.
    let ids = Set(envelopes.compactMap { $0.baseData?["id"]?.stringValue })
    XCTAssertEqual(ids.count, count, "each concurrent span should map to a distinct item id")
    let dropped = await harness.pipeline.droppedCount
    XCTAssertEqual(dropped, 0)
  }

  func testConcurrentExportsThenFlushDrainsEverything() async {
    // A long interval and large batch park every concurrent submit in the buffer,
    // so a single explicit `flush()` after they have all enqueued must forward the
    // whole set — proving concurrent submits and an explicit drain compose safely.
    let harness = makeTracingHarness(
      configuration: ExporterConfiguration(flushInterval: 60, maxBatchSize: 200))
    let exp = exporter(harness)
    let count = 100

    await withTaskGroup(of: Void.self) { group in
      for index in 0..<count {
        group.addTask {
          var builder = SpanDataBuilder(kind: .server)
          builder.spanIdHex = String(format: "%016x", index + 1)
          _ = await exp.export(spans: [builder.build()], explicitTimeout: nil)
        }
      }
    }

    // Wait for the fire-and-forget enqueues to land, then drain in one flush.
    await harness.waitForBuffered(atLeast: count)
    _ = await exp.flush(explicitTimeout: nil)

    let envelopes = await harness.envelopes(atLeast: count)
    XCTAssertEqual(envelopes.count, count)
    let dropped = await harness.pipeline.droppedCount
    XCTAssertEqual(dropped, 0)
    let remaining = await harness.pipeline.bufferedCount
    XCTAssertEqual(remaining, 0)
  }
}
