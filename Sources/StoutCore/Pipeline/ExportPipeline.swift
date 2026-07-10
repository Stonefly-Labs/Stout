// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The signal-agnostic export pipeline: a bounded, actor-isolated buffer that
/// batches envelopes and ships them to Application Insights ingestion
/// (FR-011–FR-014).
///
/// Submitting is non-blocking and never touches the host's calling path with
/// network I/O (SC-001): `submit(_:)` hands the envelope to the actor and returns
/// immediately. The actor batches on size (`maxBatchSize`) or a periodic
/// interval (`flushInterval`), encodes the batch to newline-delimited JSON, gzips
/// it, and POSTs it via the injected `Transport`. A `200` is success.
///
/// - Important: The pipeline owns a background flush loop; call `shutdown()` when
///   done so it stops and any client is released. Reliable retry (US4) and the
///   full drain-and-go-inert lifecycle with the single post-shutdown warning
///   (US5) extend this type in later work.
public actor ExportPipeline {
  private let configuration: ExporterConfiguration
  private let trackURL: URL
  private let transport: any Transport
  private let diagnostics: any Diagnostics

  private var buffer: [Envelope] = []
  private var droppedCountStorage: UInt64 = 0
  private var isSending = false
  private var flushTask: Task<Void, Never>?

  private enum State {
    case running
    case draining
    case inert
  }
  private var state: State = .running

  private static let requestHeaders = [
    "Content-Type": "application/x-json-stream",
    "Content-Encoding": "gzip",
  ]

  /// Create a pipeline.
  ///
  /// - Parameters:
  ///   - configuration: buffer/flush/retry tuning (defaults are safe).
  ///   - ingestionEndpoint: the base ingestion endpoint URL; the pipeline
  ///     composes `{endpoint}/v2.1/track`. A plain URL (not a
  ///     `ConnectionConfiguration`) keeps the pipeline testable without US1.
  ///   - transport: the HTTP transport (injected; a mock in tests).
  ///   - diagnostics: the secret-free self-diagnostics sink.
  public init(
    configuration: ExporterConfiguration = ExporterConfiguration(),
    ingestionEndpoint: URL,
    transport: any Transport,
    diagnostics: any Diagnostics
  ) {
    self.configuration = configuration
    self.trackURL = IngestionPath.trackURL(for: ingestionEndpoint)
    self.transport = transport
    self.diagnostics = diagnostics
  }

  /// The number of envelopes dropped so far (overflow or post-shutdown), for
  /// diagnostics and tests (FR-014, SC-003).
  public var droppedCount: UInt64 { droppedCountStorage }

  /// Submit an envelope for export. Non-blocking and never throws into the host:
  /// it hands off to the actor and returns immediately. Dropped on overflow or
  /// once inert (FR-012/FR-014).
  public nonisolated func submit(_ envelope: Envelope) {
    Task { await self.enqueue(envelope) }
  }

  /// Force a flush of everything currently buffered (awaits the send). Primarily
  /// for tests and explicit-flush callers.
  public func flushNow() async {
    await flush()
  }

  /// Stop the flush loop, drain best-effort, and release the transport. Idempotent.
  ///
  /// This is the minimal lifecycle needed by the MVP; US5 replaces it with the
  /// full drain-and-go-inert state machine (bounded timeout + single warning).
  public func shutdown() async {
    guard state == .running else { return }
    state = .draining
    flushTask?.cancel()
    flushTask = nil
    await drainRemaining()
    await transport.shutdown()
    state = .inert
  }

  // MARK: - Actor-isolated internals

  private func enqueue(_ envelope: Envelope) async {
    guard state == .running else {
      // Post-shutdown submit: drop. The single rate-limited warning is US5.
      droppedCountStorage &+= 1
      return
    }
    guard buffer.count < configuration.bufferCapacity else {
      // Bounded buffer: drop-on-overflow (FR-014, SC-003). Never block the caller,
      // never grow past capacity. `droppedCount` is the authoritative accounting;
      // a secret-free `bufferOverflow` diagnostic surfaces the loss carrying only a
      // magnitude — no connection string, iKey, or payload (FR-016/FR-028/FR-031).
      droppedCountStorage &+= 1
      diagnostics.report(
        DiagnosticEvent(severity: .warning, code: .bufferOverflow, itemCount: 1))
      return
    }
    buffer.append(envelope)
    ensureFlushLoopStarted()
    if buffer.count >= configuration.maxBatchSize {
      await flush()
    }
  }

  private func ensureFlushLoopStarted() {
    guard flushTask == nil, state == .running else { return }
    flushTask = Task { await self.runFlushLoop() }
  }

  private func runFlushLoop() async {
    let nanos = UInt64((configuration.flushInterval * 1_000_000_000).rounded())
    while state == .running {
      try? await Task.sleep(nanoseconds: nanos)
      guard state == .running else { break }
      await flush()
    }
  }

  private func flush() async {
    guard state != .inert, !isSending, !buffer.isEmpty else { return }
    isSending = true
    let batch = Array(buffer.prefix(configuration.maxBatchSize))
    buffer.removeFirst(batch.count)
    await send(batch)
    isSending = false
    // A full batch may have re-accumulated during the send (actor reentrancy);
    // keep draining so backlog doesn't wait for the next interval.
    if state == .running, buffer.count >= configuration.maxBatchSize {
      await flush()
    }
  }

  private func drainRemaining() async {
    isSending = false
    while !buffer.isEmpty {
      let batch = Array(buffer.prefix(configuration.maxBatchSize))
      buffer.removeFirst(batch.count)
      await send(batch)
    }
  }

  private func send(_ batch: [Envelope]) async {
    guard !batch.isEmpty else { return }
    do {
      let body = try EnvelopeEncoding.encodeBatch(batch)
      let compressed = try gzip([UInt8](body))
      let request = TransportRequest(
        url: trackURL,
        method: "POST",
        headers: Self.requestHeaders,
        body: Data(compressed)
      )
      let response = try await transport.send(request)
      if response.statusCode == 200 {
        return  // fully accepted
      }
      // Non-200: retry/partial-success classification is US4. For the MVP spine
      // the batch is dropped with secret-free accounting.
      droppedCountStorage &+= UInt64(batch.count)
      diagnostics.report(
        DiagnosticEvent(
          severity: .warning,
          code: .ingestionRejected,
          itemCount: UInt64(batch.count)
        )
      )
    } catch {
      // Encoding/compression/transport failure: never propagate to the host
      // (FR-031). Retry is US4; for now the batch is dropped.
      droppedCountStorage &+= UInt64(batch.count)
      diagnostics.report(
        DiagnosticEvent(severity: .warning, code: .transportFailure)
      )
    }
  }
}
