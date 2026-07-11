// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

/// A cross-cutting security sweep (T035; SC-002, FR-028, Constitution I): no
/// connection string, instrumentation key, or auth token may appear in any error
/// description, self-diagnostic, or debug/`description` output on **any** path.
///
/// Secrets ride the wire (the `iKey` envelope field, HTTPS bodies) by design; this
/// suite proves they never escape through the library's *observability* surfaces,
/// which a host is free to log. Every scenario binds real components to the
/// sentinels below and asserts the sentinels never surface.
final class SecretRedactionTests: XCTestCase {
  // MARK: Sentinels — recognizable, secret-shaped values.

  /// A well-formed GUID so it survives `ConnectionConfiguration` validation and is
  /// carried as the real instrumentation key throughout the pipeline.
  private let secretIKey = "abcdef01-2345-6789-abcd-ef0123456789"
  /// A token-shaped secret smuggled through a retained connection-string field and
  /// through endpoint userinfo, to catch either leaking verbatim.
  private let secretToken = "SENTINEL-tok-eyJ0eXAiOiJKV1QifQ-do-not-log"

  /// A full connection string carrying both sentinels.
  private var secretConnectionString: String {
    "InstrumentationKey=\(secretIKey)"
      + ";IngestionEndpoint=https://dc.example.com/"
      + ";AADAudience=\(secretToken)"
  }

  /// Assert `text` contains neither sentinel (case-insensitively — logging sinks
  /// and reflection may re-case).
  private func assertSecretFree(
    _ text: String,
    _ context: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let haystack = text.lowercased()
    XCTAssertFalse(
      haystack.contains(secretIKey.lowercased()),
      "\(context) leaked the instrumentation key: \(text)", file: file, line: line)
    XCTAssertFalse(
      haystack.contains(secretToken.lowercased()),
      "\(context) leaked the auth token: \(text)", file: file, line: line)
  }

  // MARK: - Connection-string errors

  /// Every `ConnectionStringError` — both the enumerated cases and ones thrown from
  /// real secret-bearing input — renders without echoing the offending value.
  func testConnectionStringErrorsAreSecretFree() {
    // Enumerated cases carrying a field/key name must not be fed a secret; the
    // constructed cases below stand in for the developer-authored surface.
    let cases: [ConnectionStringError] = [
      .empty,
      .missingInstrumentationKey,
      .malformedInstrumentationKey,
      .missingOrMalformedEndpoint(field: "IngestionEndpoint"),
      .nonHTTPSEndpoint(field: "IngestionEndpoint"),
      .duplicateKey("InstrumentationKey"),
    ]
    for error in cases {
      assertSecretFree(error.description, "ConnectionStringError.\(error)")
      assertSecretFree("\(error)", "ConnectionStringError interpolation")
    }

    // Now drive real throws from input that embeds the sentinels, and assert the
    // resulting error never carries them.
    assertThrowsSecretFree(
      "InstrumentationKey=\(secretIKey)-not-a-guid", context: "malformed iKey")
    assertThrowsSecretFree(
      "InstrumentationKey=\(secretIKey)"
        + ";IngestionEndpoint=http://user:\(secretToken)@evil.example.com/",
      context: "non-HTTPS endpoint with userinfo")
    assertThrowsSecretFree(
      "InstrumentationKey=\(secretIKey);IngestionEndpoint=not a url",
      context: "malformed endpoint")
  }

  private func assertThrowsSecretFree(
    _ connectionString: String,
    context: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      _ = try ConnectionConfiguration(connectionString: connectionString)
      XCTFail("expected \(context) to throw", file: file, line: line)
    } catch let error as ConnectionStringError {
      assertSecretFree(error.description, "\(context) error.description", file: file, line: line)
      assertSecretFree("\(error)", "\(context) error interpolation", file: file, line: line)
    } catch {
      XCTFail("unexpected error for \(context): \(error)", file: file, line: line)
    }
  }

  // MARK: - Configuration description

  /// `ConnectionConfiguration`'s `description`/`debugDescription` redact the key and
  /// never surface a retained secret field.
  func testConnectionConfigurationDescriptionRedactsSecrets() throws {
    let config = try ConnectionConfiguration(connectionString: secretConnectionString)

    // The key round-trips internally (needed to stamp envelopes)…
    XCTAssertEqual(config.instrumentationKey, secretIKey)
    // …but never renders in description output.
    XCTAssertTrue(config.description.contains("<redacted>"), "key should render redacted")
    assertSecretFree(config.description, "ConnectionConfiguration.description")
    assertSecretFree(config.debugDescription, "ConnectionConfiguration.debugDescription")
    assertSecretFree("\(config)", "ConnectionConfiguration interpolation")
  }

  // MARK: - Diagnostics across every drop path

  /// Drive the pipeline through overflow, permanent-drop, and post-shutdown drops
  /// with an instrumentation-key-bearing envelope factory, and assert not one
  /// recorded diagnostic echoes a secret. Also asserts each path was actually
  /// exercised, so the sweep can't pass vacuously.
  func testDiagnosticsAcrossAllDropPathsAreSecretFree() async throws {
    let config = try ConnectionConfiguration(connectionString: secretConnectionString)
    // The factory binds the *real* secret iKey; every envelope built here carries it.
    let factory = EnvelopeFactory(instrumentationKey: config.instrumentationKey)
    func envelope() -> Envelope {
      factory.makeEnvelope(
        name: "Microsoft.ApplicationInsights.Message",
        payload: TestData(message: "hello"),
        time: Date(timeIntervalSince1970: 0))
    }

    let diagnostics = RecordingDiagnostics()

    // --- Overflow: capacity 1, a large batch size + interval so nothing drains. ---
    let overflow = ExportPipeline(
      configuration: ExporterConfiguration(
        bufferCapacity: 1, flushInterval: 100, maxBatchSize: 1000),
      ingestionEndpoint: config.ingestionEndpoint,
      transport: MockTransport(statusCode: 200),
      diagnostics: diagnostics)
    for _ in 0..<8 { overflow.submit(envelope()) }
    await waitUntil { await overflow.droppedCount >= 5 }

    // --- Permanent drop: a non-retriable 400 discards the batch. ---
    let permanent = ExportPipeline(
      configuration: ExporterConfiguration(flushInterval: 100),
      ingestionEndpoint: config.ingestionEndpoint,
      transport: MockTransport(statusCode: 400),
      diagnostics: diagnostics)
    permanent.submit(envelope())
    await waitUntil { await permanent.bufferedCount == 1 }
    await permanent.flushNow()
    await waitUntil { await permanent.droppedCount >= 1 }

    // --- Post-shutdown submit: the single rate-limited warning. ---
    let inert = ExportPipeline(
      ingestionEndpoint: config.ingestionEndpoint,
      transport: MockTransport(statusCode: 200),
      diagnostics: diagnostics)
    await inert.shutdown()
    inert.submit(envelope())
    await waitUntil { await inert.droppedCount >= 1 }

    // Prove each path fired, so the assertion below isn't over an empty set.
    let codes = Set(diagnostics.events.map(\.code))
    XCTAssertTrue(codes.contains(.bufferOverflow), "overflow path did not fire")
    XCTAssertTrue(codes.contains(.permanentDrop), "permanent-drop path did not fire")
    XCTAssertTrue(codes.contains(.postShutdownSubmit), "post-shutdown path did not fire")

    // The sweep: no recorded diagnostic — reflected in full — carries a secret.
    for event in diagnostics.events {
      assertSecretFree("\(event)", "DiagnosticEvent \(event.code)")
      assertSecretFree(String(reflecting: event), "DiagnosticEvent reflection \(event.code)")
      if let message = event.message {
        assertSecretFree(message, "DiagnosticEvent.message \(event.code)")
      }
    }
  }
}
