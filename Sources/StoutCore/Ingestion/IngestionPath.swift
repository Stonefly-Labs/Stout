// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The ingestion track path composition (`/v2.1/track`, design D2).
///
/// The connection-string parser yields only the base ingestion endpoint; the
/// `/v2.1/track` suffix is composed here so config and pipeline share one
/// definition and slash handling is consistent.
enum IngestionPath {
  /// The Breeze track path appended to the ingestion endpoint.
  static let track = "v2.1/track"

  /// Compose the full track URL for a (trailing-slash-normalized) ingestion
  /// endpoint. `appendingPathComponent` yields a single `/` join regardless of
  /// whether `base` ends in a slash.
  static func trackURL(for base: URL) -> URL {
    base.appendingPathComponent(track)
  }
}
