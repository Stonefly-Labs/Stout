// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The parsed Application Insights ingestion result used to detect partial
/// success and classify per-item outcomes (FR-024).
///
/// Parsing is **tolerant by design**: an empty, non-JSON, or otherwise malformed
/// body yields `nil` from ``parse(_:)`` rather than throwing, so a garbage
/// response can never crash or fault the pipeline (FR-031). A present-but-partial
/// object is read best-effort — missing counts default to `0`, and only
/// well-formed per-item errors are retained.
///
/// - Important: `ItemError.message` is service-authored text about a rejected
///   item; it MUST NOT be re-logged verbatim onto any diagnostic path, since it
///   could echo payload content (FR-025/FR-028).
public struct IngestionResponse: Sendable, Equatable {
  /// A single per-item rejection from the `errors` array.
  public struct ItemError: Sendable, Equatable {
    /// Zero-based index of the offending item within the submitted batch.
    public let index: Int
    /// HTTP-style status code for this specific item (e.g. `429`, `400`).
    public let statusCode: Int
    /// Service-authored message. Never re-log verbatim (FR-025/FR-028).
    public let message: String

    public init(index: Int, statusCode: Int, message: String) {
      self.index = index
      self.statusCode = statusCode
      self.message = message
    }
  }

  /// Total items the service received.
  public let itemsReceived: Int
  /// Subset the service accepted; `< itemsReceived` implies partial success.
  public let itemsAccepted: Int
  /// Per-item rejections; empty when everything received was accepted.
  public let errors: [ItemError]

  public init(itemsReceived: Int, itemsAccepted: Int, errors: [ItemError]) {
    self.itemsReceived = itemsReceived
    self.itemsAccepted = itemsAccepted
    self.errors = errors
  }

  /// Parse an ingestion response body. Returns `nil` for an empty, non-object,
  /// or unparseable body (non-fatal — the caller classifies the missing result).
  ///
  /// Uses lenient extraction rather than strict `Codable` decoding so a
  /// well-formed-but-incomplete object still yields a usable value instead of an
  /// error.
  public static func parse(_ body: Data) -> IngestionResponse? {
    guard !body.isEmpty,
      let root = try? JSONSerialization.jsonObject(with: body),
      let object = root as? [String: Any]
    else {
      return nil
    }

    let received = (object["itemsReceived"] as? NSNumber)?.intValue ?? 0
    let accepted = (object["itemsAccepted"] as? NSNumber)?.intValue ?? 0
    let rawErrors = object["errors"] as? [[String: Any]] ?? []
    let errors = rawErrors.compactMap { entry -> ItemError? in
      guard
        let index = (entry["index"] as? NSNumber)?.intValue,
        let statusCode = (entry["statusCode"] as? NSNumber)?.intValue
      else {
        return nil
      }
      let message = entry["message"] as? String ?? ""
      return ItemError(index: index, statusCode: statusCode, message: message)
    }
    return IngestionResponse(itemsReceived: received, itemsAccepted: accepted, errors: errors)
  }
}
