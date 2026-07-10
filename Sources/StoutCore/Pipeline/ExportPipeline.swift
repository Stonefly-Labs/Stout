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
/// Failures are classified and retried with a bounded, in-memory budget: a
/// retriable whole-response status (or a thrown delivery error) resends the batch
/// after `Retry-After` or full-jitter backoff; a `206` resends only the retriable
/// per-item survivors; everything else is dropped with secret-free diagnostics
/// (US4, FR-024–FR-027).
///
/// - Important: The pipeline owns a background flush loop; call `shutdown()` when
///   done so it stops and any client is released. The full drain-and-go-inert
///   lifecycle with the single post-shutdown warning (US5) extends this type in
///   later work.
public actor ExportPipeline {
  private let configuration: ExporterConfiguration
  private let trackURL: URL
  private let transport: any Transport
  private let diagnostics: any Diagnostics
  private let retryPolicy: RetryPolicy
  private var randomGenerator = SystemRandomNumberGenerator()

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
    self.retryPolicy = RetryPolicy(configuration: configuration)
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

  /// The classified outcome of a single POST attempt.
  private enum SendOutcome {
    /// `200` — the whole batch was accepted.
    case success
    /// A retriable whole-response status, timeout, or connection error — resend
    /// the current `pending` batch after a delay.
    case retriableWhole
    /// A non-retriable whole-response status — drop the batch permanently.
    case permanentWhole
    /// `206` partial success — resend `retriable` survivors; `droppedCount`
    /// errored items are non-retriable and dropped.
    case partial(retriable: [Envelope], droppedCount: Int)
  }

  /// Encode, compress, POST, and classify — retrying retriable failures with a
  /// bounded, in-memory budget (FR-025/FR-026/FR-027). Never throws into the host
  /// and never grows retry state past one batch (FR-031).
  private func send(_ batch: [Envelope]) async {
    guard !batch.isEmpty else { return }
    var pending = batch
    var attempt = 0

    while !pending.isEmpty {
      let body: Data
      do {
        body = Data(try gzip([UInt8](try EnvelopeEncoding.encodeBatch(pending))))
      } catch {
        // Encoding/compression failure: unrecoverable and content-independent —
        // drop without a retry (retrying re-fails identically). Secret-free.
        dropPermanently(pending.count, code: .transportFailure)
        return
      }

      let request = TransportRequest(
        url: trackURL, method: "POST", headers: Self.requestHeaders, body: body)
      let response = try? await transport.send(request)
      // A thrown/absent response is a delivery failure → retriable whole (FR-025).
      let outcome = response.map { classify($0, pending: pending) } ?? .retriableWhole
      let retryAfterHeader = response.flatMap { Self.header("Retry-After", in: $0.headers) }

      switch outcome {
      case .success:
        return
      case .permanentWhole:
        dropPermanently(pending.count, code: .permanentDrop)
        return
      case .partial(let retriable, let droppedCount):
        if droppedCount > 0 { dropPermanently(droppedCount, code: .permanentDrop) }
        pending = retriable
        if pending.isEmpty { return }
      case .retriableWhole:
        break  // resend the whole `pending` batch
      }

      // Reached only when `pending` still needs delivery. Enforce the bounded
      // in-memory attempt budget; on exhaustion, drop what's left secret-free.
      guard retryPolicy.canRetry(afterAttempt: attempt) else {
        dropPermanently(pending.count, code: .permanentDrop)
        return
      }
      let delay =
        retryPolicy.retryAfterDelay(headerValue: retryAfterHeader, now: Date())
        ?? retryPolicy.jitteredDelay(forAttempt: attempt, using: &randomGenerator)
      if delay > 0 {
        try? await Task.sleep(nanoseconds: UInt64((delay * 1_000_000_000).rounded()))
      }
      // If shutdown began during the backoff, stop retrying and drop the
      // remainder — the best-effort drain must not hang (refined in US5).
      guard state == .running else {
        dropPermanently(pending.count, code: .permanentDrop)
        return
      }
      attempt += 1
    }
  }

  /// Classify one HTTP response against the current `pending` batch.
  private func classify(_ response: TransportResponse, pending: [Envelope]) -> SendOutcome {
    switch response.statusCode {
    case 200:
      return .success
    case 206:
      guard let parsed = IngestionResponse.parse(response.body) else {
        // A `206` we cannot parse: we can't tell which items to keep, so resend
        // the whole batch (bounded by the attempt budget) rather than lose all.
        return .retriableWhole
      }
      var retriable: [Envelope] = []
      var droppedCount = 0
      for error in parsed.errors {
        guard error.index >= 0, error.index < pending.count else { continue }
        if retryPolicy.isPerItemRetriable(error.statusCode) {
          retriable.append(pending[error.index])
        } else {
          droppedCount += 1
        }
      }
      return .partial(retriable: retriable, droppedCount: droppedCount)
    default:
      return retryPolicy.isWholeResponseRetriable(response.statusCode)
        ? .retriableWhole : .permanentWhole
    }
  }

  /// Account for `count` permanently dropped items and surface a secret-free
  /// diagnostic carrying only the magnitude (FR-025/FR-028/FR-031).
  private func dropPermanently(_ count: Int, code: DiagnosticEvent.Code) {
    guard count > 0 else { return }
    droppedCountStorage &+= UInt64(count)
    diagnostics.report(
      DiagnosticEvent(severity: .warning, code: code, itemCount: UInt64(count)))
  }

  /// Case-insensitive header lookup (HTTP header names are case-insensitive).
  private static func header(_ name: String, in headers: [String: String]) -> String? {
    if let exact = headers[name] { return exact }
    let lowered = name.lowercased()
    return headers.first { $0.key.lowercased() == lowered }?.value
  }
}
