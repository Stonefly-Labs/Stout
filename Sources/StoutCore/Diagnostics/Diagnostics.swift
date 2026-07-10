// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

/// The library's internal self-diagnostics channel (FR-016, FR-028, FR-031).
///
/// This is **not** the user telemetry pipeline. It exists so the exporter can
/// surface its own operational events — dropped-item accounting, permanent-drop
/// notices, the single post-shutdown warning — without ever touching the host's
/// stability. Implementations must treat every event as advisory: never crash,
/// block, or throw back into the exporter.
///
/// - Important: A `DiagnosticEvent` carries **no** secrets and **no** telemetry
///   payload by construction (see `DiagnosticEvent`). Conformers may log or
///   forward events freely without risk of leaking a connection string,
///   instrumentation key, token, or customer data.
public protocol Diagnostics: Sendable {
  /// Report an operational event. Must not throw, block, or fault.
  func report(_ event: DiagnosticEvent)
}

/// A secret-free description of an internal exporter event.
///
/// Every field is either an enumerated, developer-authored constant (`code`,
/// `severity`) or a non-identifying count. The optional `message` is documented
/// as developer-authored static text only — callers MUST NOT interpolate
/// connection strings, instrumentation keys, tokens, URLs, or telemetry payload
/// into it (FR-028). This keeps the diagnostics channel leak-free by design.
public struct DiagnosticEvent: Sendable, Equatable {
  /// Relative importance of the event.
  public enum Severity: Sendable, Equatable {
    case info
    case warning
  }

  /// A stable, enumerated reason code. Extending this enum is the only way to
  /// introduce a new diagnostic, which keeps the channel free-form-text-free.
  public enum Code: String, Sendable, Equatable {
    /// The bounded buffer was full; item(s) were dropped on submit (FR-014).
    case bufferOverflow
    /// Item(s) were permanently dropped after a non-retriable ingestion result
    /// or an exhausted retry budget (FR-025/FR-027).
    case permanentDrop
    /// A submit arrived after shutdown and was dropped (emitted at most once,
    /// FR-016).
    case postShutdownSubmit
    /// The ingestion endpoint returned a non-success response (FR-024).
    case ingestionRejected
    /// The transport failed to deliver a request (timeout, connection error).
    case transportFailure
  }

  public var severity: Severity
  public var code: Code
  /// Count of items affected, when meaningful (e.g. dropped count). Never an
  /// identifier — just a magnitude.
  public var itemCount: UInt64?
  /// Optional developer-authored static text. MUST NOT contain secrets or
  /// telemetry payload (FR-028).
  public var message: String?

  public init(
    severity: Severity,
    code: Code,
    itemCount: UInt64? = nil,
    message: String? = nil
  ) {
    self.severity = severity
    self.code = code
    self.itemCount = itemCount
    self.message = message
  }
}
