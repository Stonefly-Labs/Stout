// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

/// The library's own version, and the single source of truth for the
/// `ai.internal.sdkVersion` Part A tag (`stout:<version>`, FR-021).
///
/// - Important: This is the ONE place the version is written. The release process
///   (`/cut-release`) bumps `current` in lockstep with the package's SemVer tag, so
///   the `stout:<version>` string ingestion sees always matches the released
///   package. Pre-1.0: the API surface may change between minor versions.
public enum StoutVersion {
  /// The current library version (SemVer). Pre-release.
  public static let current = "0.1.0"

  /// The `ai.internal.sdkVersion` value: `stout:<version>` (FR-021).
  public static var sdkVersion: String { "stout:\(current)" }
}
