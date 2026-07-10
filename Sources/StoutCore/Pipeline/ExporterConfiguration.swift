// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Tuning knobs for the export pipeline, with safe defaults aligned to the .NET
/// Azure Monitor exporter and OpenTelemetry conventions (FR-017).
///
/// Every default is a documented, conservative value chosen so the exporter does
/// no harm to the host out of the box: a bounded buffer, periodic flushing, a
/// bounded shutdown drain, and a bounded in-memory retry budget.
///
/// - Note: Time intervals are expressed as `TimeInterval` (seconds) rather than
///   `Duration` so the type is available on the library's full platform floor
///   (iOS 13 / macOS 12 / watchOS 6 / tvOS 13), which predates `Duration`.
public struct ExporterConfiguration: Sendable {
  /// Hard cap on buffered items; submits past this are dropped (FR-014).
  /// Default `2048`.
  public var bufferCapacity: Int
  /// Maximum time a partial batch waits before being flushed. Default `5`
  /// seconds (FR-013).
  public var flushInterval: TimeInterval
  /// Maximum number of items sent in a single POST. Default `512` (FR-013).
  public var maxBatchSize: Int
  /// Upper bound on the best-effort drain performed at shutdown. Default `30`
  /// seconds (FR-015).
  public var shutdownDrainTimeout: TimeInterval
  /// Maximum in-memory retry attempts for a retriable failure. Default `3`
  /// (FR-026/FR-027).
  public var maxRetryAttempts: Int
  /// Ceiling on a single computed backoff delay. Default `60` seconds (FR-026).
  public var maxRetryDelay: TimeInterval

  /// Create a configuration. All parameters default to the documented,
  /// .NET/OTel-aligned values; override only what you need.
  public init(
    bufferCapacity: Int = 2048,
    flushInterval: TimeInterval = 5,
    maxBatchSize: Int = 512,
    shutdownDrainTimeout: TimeInterval = 30,
    maxRetryAttempts: Int = 3,
    maxRetryDelay: TimeInterval = 60
  ) {
    self.bufferCapacity = bufferCapacity
    self.flushInterval = flushInterval
    self.maxBatchSize = maxBatchSize
    self.shutdownDrainTimeout = shutdownDrainTimeout
    self.maxRetryAttempts = maxRetryAttempts
    self.maxRetryDelay = maxRetryDelay
  }
}
