// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenTelemetrySdk
import StoutCore

/// The Stout `SpanExporter` for Azure Monitor / Application Insights: it translates
/// each finished OpenTelemetry `SpanData` to the Application Insights **Breeze**
/// schema and hands it to the spec-01 export pipeline. Register it with a
/// `TracerProvider` via `BatchSpanProcessor` (provider bootstrap is spec 07; see
/// ``TraceExporterRegistration``).
///
/// ## Span-kind → envelope
///
/// | `SpanKind` | Breeze item |
/// |---|---|
/// | `.server` / `.consumer` | `RequestData` |
/// | `.client` / `.producer` / `.internal` / unspecified | `RemoteDependencyData` |
///
/// ## Correlation
///
/// The OpenTelemetry SDK owns propagation; by the time a `SpanData` reaches this
/// exporter its trace/span/parent ids are already resolved. The exporter only
/// **maps** them to `ai.operation.id` / `ai.operation.parentId` (byte-for-byte
/// lowercase hex) — it makes no correlation decision.
///
/// ## Behavior
///
/// - `export(spans:)` translates each span and submits every resulting envelope to
///   the pipeline. It is **non-blocking** — submission hands off to the pipeline
///   actor and returns immediately, never touching the host's calling path with
///   network I/O — and never throws into the host: a per-span translation failure
///   drops that span best-effort and continues.
/// - Unknown/unspecified span kinds map to a dependency (mirrors .NET).
/// - Malformed or unreconstructable attributes yield a best-effort item with the
///   remainder carried into `properties`; the exporter never crashes on bad input.
///
/// The exporter is `Sendable`: its only stored state is the injected pipeline (an
/// actor) and an immutable `EnvelopeFactory`.
public final class AzureMonitorTraceExporter: SpanExporter {
  private let pipeline: ExportPipeline
  private let envelopeFactory: EnvelopeFactory

  /// Create an exporter over a spec-01 assembled pipeline and envelope factory.
  ///
  /// - Parameters:
  ///   - pipeline: the bounded, actor-isolated export pipeline that batches,
  ///     compresses, and ships envelopes (owns transport/retry/buffering).
  ///   - envelopeFactory: stamps the shared Part A fields (iKey, resource tags)
  ///     around each translated payload. Resource tags are detected **once** at
  ///     registration and baked in here — never recomputed per span.
  public init(pipeline: ExportPipeline, envelopeFactory: EnvelopeFactory) {
    self.pipeline = pipeline
    self.envelopeFactory = envelopeFactory
  }

  // MARK: - Export

  /// Translate and submit each span. Returns `.success` once the items are handed
  /// off; non-blocking and race-free (safe to call concurrently from many tasks).
  @discardableResult
  public func export(spans: [SpanData], explicitTimeout: TimeInterval?)
    -> SpanExporterResultCode
  {
    submit(spans)
    return .success
  }

  /// Async form of ``export(spans:explicitTimeout:)``. Submission is fire-and-forget,
  /// so this mirrors the sync path and returns promptly.
  @discardableResult
  public func export(spans: [SpanData], explicitTimeout: TimeInterval?) async
    -> SpanExporterResultCode
  {
    submit(spans)
    return .success
  }

  /// Translate every span to envelopes and submit each to the pipeline. Pure
  /// translation plus a non-blocking actor hand-off — no throwing, no blocking.
  private func submit(_ spans: [SpanData]) {
    for span in spans {
      for envelope in SpanTranslator.translate(span, using: envelopeFactory) {
        pipeline.submit(envelope)
      }
    }
  }

  // MARK: - Flush

  /// Forward buffered items promptly. Kicks off a pipeline flush and returns without
  /// blocking the caller (the sync SDK path cannot await).
  @discardableResult
  public func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    let pipeline = pipeline
    Task { await pipeline.flushNow() }
    return .success
  }

  /// Async flush — awaits the pipeline drain so buffered items are forwarded before
  /// returning (nothing stranded, US6 Acc #1).
  @discardableResult
  public func flush(explicitTimeout: TimeInterval?) async -> SpanExporterResultCode {
    await pipeline.flushNow()
    return .success
  }

  // MARK: - Shutdown

  /// Shut down the pipeline (drain-and-go-inert, owned by spec 01). Idempotent. The
  /// sync path kicks off the async shutdown without blocking the host.
  public func shutdown(explicitTimeout: TimeInterval?) {
    let pipeline = pipeline
    Task { await pipeline.shutdown() }
  }

  /// Async shutdown — awaits the pipeline's bounded drain-and-go-inert. After it, the
  /// exporter is inert and further `export(...)` calls are safe no-op drops surfaced
  /// only via spec 01's rate-limited diagnostic.
  public func shutdown(explicitTimeout: TimeInterval?) async {
    await pipeline.shutdown()
  }
}
