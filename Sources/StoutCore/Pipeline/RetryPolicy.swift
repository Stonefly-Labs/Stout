// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Status classification and bounded backoff scheduling for ingestion retries
/// (FR-025/FR-026/FR-027).
///
/// The status sets mirror the .NET Azure Monitor exporter exactly (the
/// "mirror .NET fully" clarification), so cross-SDK behavior is consistent. The
/// retry *transport*, however, is a deliberate divergence: Stout keeps all retry
/// state in-memory and bounded (`maxRetryAttempts` / `maxRetryDelay`) rather than
/// the .NET disk-backed timer, honoring the do-no-harm / bounded-memory mandate
/// (FR-027, Constitution II).
///
/// This type is a pure, `Sendable` value: it makes decisions and computes delays
/// but performs no I/O and holds no mutable state. The caller owns the randomness
/// source and the actual sleeping.
public struct RetryPolicy: Sendable {
  /// Whole-response statuses that trigger a retry of the entire batch, alongside
  /// timeouts and connection errors (surfaced as a thrown transport error).
  /// `439` is an Azure-specific throttling status.
  public static let wholeResponseRetriableStatuses: Set<Int> = [
    408, 429, 439, 401, 403, 500, 502, 503, 504,
  ]

  /// The narrower set of per-item statuses (inside a `206` partial success) that
  /// are worth re-sending; every other errored item is dropped.
  public static let perItemRetriableStatuses: Set<Int> = [408, 429, 439, 500, 503]

  /// Maximum number of retries after the initial attempt. Default `3`.
  public let maxRetryAttempts: Int
  /// Ceiling on any single computed backoff delay, in seconds. Default `60`.
  public let maxRetryDelay: TimeInterval
  /// Base delay for the exponential schedule, in seconds. Default `1`.
  public let baseDelay: TimeInterval

  /// Build a policy from the pipeline configuration.
  public init(configuration: ExporterConfiguration, baseDelay: TimeInterval = 1) {
    self.maxRetryAttempts = configuration.maxRetryAttempts
    self.maxRetryDelay = configuration.maxRetryDelay
    self.baseDelay = baseDelay
  }

  /// Whether a whole-response status should retry the entire batch.
  public func isWholeResponseRetriable(_ statusCode: Int) -> Bool {
    Self.wholeResponseRetriableStatuses.contains(statusCode)
  }

  /// Whether a per-item status (from a `206`) should be re-sent.
  public func isPerItemRetriable(_ statusCode: Int) -> Bool {
    Self.perItemRetriableStatuses.contains(statusCode)
  }

  /// Whether another retry is permitted given the number of retries already made
  /// (`0`-based: `attempt == 0` is the first retry).
  public func canRetry(afterAttempt attempt: Int) -> Bool {
    attempt < maxRetryAttempts
  }

  /// The deterministic upper bound for a retry's delay:
  /// `min(maxRetryDelay, baseDelay × 2^attempt)`. Exposed for testing the
  /// schedule independently of jitter.
  public func backoffCeiling(forAttempt attempt: Int) -> TimeInterval {
    let uncapped = baseDelay * pow(2, Double(max(0, attempt)))
    return min(maxRetryDelay, uncapped)
  }

  /// A full-jitter backoff delay in `0...backoffCeiling(forAttempt:)`
  /// (FR-026). The caller supplies the randomness source so the schedule is
  /// deterministically testable.
  public func jitteredDelay(
    forAttempt attempt: Int,
    using generator: inout some RandomNumberGenerator
  ) -> TimeInterval {
    let ceiling = backoffCeiling(forAttempt: attempt)
    guard ceiling > 0 else { return 0 }
    return TimeInterval.random(in: 0...ceiling, using: &generator)
  }

  /// Parse a `Retry-After` header value into a non-negative delay in seconds, or
  /// `nil` when absent/unparseable. Accepts both delta-seconds (`"120"`) and an
  /// HTTP-date (`"Wed, 21 Oct 2026 07:28:00 GMT"`), per RFC 7231. A past date
  /// yields `0` (retry immediately), never a negative delay.
  public func retryAfterDelay(headerValue: String?, now: Date) -> TimeInterval? {
    guard let raw = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else {
      return nil
    }
    if let seconds = Int(raw) {
      return max(0, TimeInterval(seconds))
    }
    // A local formatter keeps this `Sendable`-clean (DateFormatter is not
    // Sendable) at the cost of construction on the rare retry-after path.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let date = formatter.date(from: raw) {
      return max(0, date.timeIntervalSince(now))
    }
    return nil
  }
}
