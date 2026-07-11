// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

// `@testable` is used only to reach the core's internal `gunzip` so the harness can
// decompress the exact wire body the pipeline produced. Everything else consumed
// here (`Transport`, `Envelope`, `ExportPipeline`, `EnvelopeFactory`,
// `Diagnostics`) is public API.
@testable import StoutCore

// MARK: - Capturing transport

/// A recording `Transport` that captures every request the real `ExportPipeline`
/// sends and answers with a fixed status (default `200`), so the exporter can be
/// exercised end-to-end through the genuine pipeline — encode → gzip → POST — with
/// **no network**. Submitted `Envelope`s are recovered by decompressing the
/// captured bodies (see ``capturedEnvelopes()``).
actor CapturingTransport: Transport {
  private(set) var requests: [TransportRequest] = []
  private(set) var shutdownCalled = false
  private let statusCode: Int

  /// - Parameter statusCode: the status returned for every send (default `200`,
  ///   i.e. the whole batch is accepted). Use a retriable/permanent code to drive
  ///   the pipeline's failure paths.
  init(statusCode: Int = 200) {
    self.statusCode = statusCode
  }

  func send(_ request: TransportRequest) async throws -> TransportResponse {
    requests.append(request)
    return TransportResponse(statusCode: statusCode, headers: [:], body: Data())
  }

  func shutdown() async {
    shutdownCalled = true
  }

  /// Number of POSTs captured so far — used to synchronize on the fire-and-forget
  /// `submit(_:)` path.
  var requestCount: Int { requests.count }

  /// Every envelope captured across all requests, decompressed and parsed. Order
  /// is submission order (the pipeline preserves batch order).
  func capturedEnvelopes() -> [CapturedEnvelope] {
    let decoder = JSONDecoder()
    return requests.flatMap { request -> [CapturedEnvelope] in
      guard
        let inflated = try? gunzip([UInt8](request.body)),
        let text = String(bytes: inflated, encoding: .utf8)
      else { return [] }
      return
        text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { line in
          guard
            let data = line.data(using: .utf8),
            let value = try? decoder.decode(JSONValue.self, from: data)
          else { return nil }
          return CapturedEnvelope(raw: value)
        }
    }
  }
}

// MARK: - Recording diagnostics

/// A thread-safe `Diagnostics` sink that records events for assertions (mirrors the
/// core test-support sink; duplicated here because test support is not shared
/// across modules).
final class RecordingDiagnostics: Diagnostics, @unchecked Sendable {
  // @unchecked is justified: all mutable state is guarded by `lock`. Test-only.
  private let lock = NSLock()
  private var storage: [DiagnosticEvent] = []

  func report(_ event: DiagnosticEvent) {
    lock.lock()
    storage.append(event)
    lock.unlock()
  }

  var events: [DiagnosticEvent] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

// MARK: - Parsed envelope

/// A `Sendable`, structurally-typed view of one captured Breeze envelope. Keeps the
/// harness free of `[String: Any]` (which is not `Sendable`) so it composes cleanly
/// with the actor-isolated transport under Swift 6 strict concurrency.
struct CapturedEnvelope: Sendable {
  let raw: JSONValue

  var name: String? { raw["name"]?.stringValue }
  var time: String? { raw["time"]?.stringValue }
  var sampleRate: Double? { raw["sampleRate"]?.doubleValue }
  var instrumentationKey: String? { raw["iKey"]?.stringValue }
  /// Part A tags as a nested object (e.g. `ai.operation.id`).
  var tags: JSONValue? { raw["tags"] }
  /// The Breeze discriminator, e.g. `"RequestData"`.
  var baseType: String? { raw["data"]?["baseType"]?.stringValue }
  /// The Part B/C payload object.
  var baseData: JSONValue? { raw["data"]?["baseData"] }

  /// Convenience: look up a single Part A tag value.
  func tag(_ key: String) -> String? { tags?[key]?.stringValue }
}

/// A minimal, `Sendable`, `Equatable` JSON tree for test assertions.
///
/// Decoded with `JSONDecoder` (not `JSONSerialization`) so Bool/Double/String are
/// distinguished natively and portably — `JSONSerialization`'s `NSNumber` bridging
/// needs CoreFoundation's `kCFBoolean*`, which does not exist in
/// swift-corelibs-foundation on Linux.
enum JSONValue: Sendable, Equatable, Decodable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    // Order matters: probe `Bool` before `Double` (a JSON boolean must not be read
    // as a number), and `nil` first so JSON `null` is not mis-typed.
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value"))
    }
  }

  var stringValue: String? {
    if case .string(let value) = self { return value } else { return nil }
  }
  var doubleValue: Double? {
    if case .number(let value) = self { return value } else { return nil }
  }
  var boolValue: Bool? { if case .bool(let value) = self { return value } else { return nil } }
  var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value } else { return nil }
  }
  var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value } else { return nil }
  }

  /// Object member access (`env.baseData?["responseCode"]`).
  subscript(key: String) -> JSONValue? { objectValue?[key] }
  /// Array element access.
  subscript(index: Int) -> JSONValue? {
    guard let array = arrayValue, array.indices.contains(index) else { return nil }
    return array[index]
  }
}

// MARK: - Harness

/// Bundles a real `ExportPipeline` wired to a `CapturingTransport` and a
/// `RecordingDiagnostics`, plus the `EnvelopeFactory` the exporter will be built
/// with (spec 02 T026). Later suites construct the exporter with
/// `harness.pipeline` / `harness.envelopeFactory`, `export(...)` a hand-built span,
/// then await `harness.envelopes(atLeast:)` to assert the wire result.
struct TracingTestHarness {
  let pipeline: ExportPipeline
  let transport: CapturingTransport
  let diagnostics: RecordingDiagnostics
  let envelopeFactory: EnvelopeFactory
}

/// Build a harness. The pipeline flushes on every submit (`maxBatchSize == 1`) with
/// a short flush interval so captured envelopes appear promptly in tests, and uses
/// a dummy HTTPS ingestion endpoint that is never actually reached.
func makeTracingHarness(
  instrumentationKey: String = "00000000-0000-0000-0000-000000000000",
  resourceTags: TelemetryTags = TelemetryTags(),
  transport: CapturingTransport = CapturingTransport(),
  configuration: ExporterConfiguration = ExporterConfiguration(
    flushInterval: 0.02, maxBatchSize: 1)
) -> TracingTestHarness {
  let diagnostics = RecordingDiagnostics()
  let pipeline = ExportPipeline(
    configuration: configuration,
    ingestionEndpoint: URL(string: "https://ingestion.test.invalid/")!,
    transport: transport,
    diagnostics: diagnostics)
  let envelopeFactory = EnvelopeFactory(
    instrumentationKey: instrumentationKey, resourceTags: resourceTags)
  return TracingTestHarness(
    pipeline: pipeline,
    transport: transport,
    diagnostics: diagnostics,
    envelopeFactory: envelopeFactory)
}

extension TracingTestHarness {
  /// Poll until at least `count` envelopes have been captured (submission is
  /// fire-and-forget), then return all captured envelopes.
  func envelopes(
    atLeast count: Int,
    timeout: TimeInterval = 2.0,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async -> [CapturedEnvelope] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await transport.requestCount >= count,
        await transport.capturedEnvelopes().count >= count
      {
        return await transport.capturedEnvelopes()
      }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    let final = await transport.capturedEnvelopes()
    XCTAssertGreaterThanOrEqual(
      final.count, count, "timed out waiting for \(count) envelope(s)", file: file, line: line)
    return final
  }
}
