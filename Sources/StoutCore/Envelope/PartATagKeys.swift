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

  // MARK: Correlation (per-item; spec 02 distributed tracing)

  /// Operation (trace) correlation id → `ai.operation.id`. Every telemetry item
  /// in a span's tree carries the trace id here (data-model §2).
  public static let operationId = "ai.operation.id"
  /// Parent item correlation id → `ai.operation.parentId`. The owning span id for
  /// derived items, or the span's parent id for the span item — **absent** for a
  /// root span (data-model §2).
  public static let operationParentId = "ai.operation.parentId"
  /// Operation display name → `ai.operation.name`. The request name, set on
  /// server/consumer items for transaction search (.NET parity).
  public static let operationName = "ai.operation.name"
}
