// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

/// The well-known Application Insights **Part A** tag keys Stout writes (FR-018–
/// FR-021). Centralizing them keeps the exact `ai.*` wire strings in one place so
/// the resource mapping and any per-item signal tags agree byte-for-byte.
public enum PartATagKeys {
  /// Logical component / service name → `ai.cloud.role`.
  public static let cloudRole = "ai.cloud.role"
  /// Physical instance the role runs on → `ai.cloud.roleInstance`.
  public static let cloudRoleInstance = "ai.cloud.roleInstance"
  /// Exporter identity string `stout:<version>` → `ai.internal.sdkVersion`.
  public static let internalSdkVersion = "ai.internal.sdkVersion"
  /// Host application version/build → `ai.application.ver` (on-device).
  public static let applicationVersion = "ai.application.ver"
  /// Device identifier → `ai.device.id` (on-device).
  public static let deviceId = "ai.device.id"
  /// Device model → `ai.device.model` (on-device).
  public static let deviceModel = "ai.device.model"
  /// OS name/version → `ai.device.osVersion` (on-device).
  public static let deviceOSVersion = "ai.device.osVersion"
  /// Device manufacturer → `ai.device.oemName` (on-device).
  public static let deviceOEMName = "ai.device.oemName"
}
