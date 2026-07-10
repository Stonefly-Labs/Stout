// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import OpenTelemetrySdk

/// Derives the resource-level Application Insights **Part A** tags once, from the
/// OpenTelemetry `Resource` (plus the library's own SDK version), for the
/// `EnvelopeFactory` to stamp onto every envelope (FR-018–FR-022, Acc #10).
///
/// The role/version mapping mirrors the .NET Azure Monitor exporter
/// (`ResourceExtensions.CreateAzureMonitorResource`) so a Swift app and a .NET
/// service reporting the same `service.*` attributes land under the same
/// `cloud_RoleName` in Application Insights:
///
/// - `ai.cloud.role` ← `"[{service.namespace}]/{service.name}"` when a namespace is
///   present (bracketed namespace, `/` separator — the exact .NET form), otherwise
///   just `service.name`. Omitted when no service name is available.
/// - `ai.cloud.roleInstance` ← `service.instance.id`, falling back to the OTel
///   `host.name` resource attribute (per this spec's FR-020).
/// - `ai.internal.sdkVersion` ← `stout:<version>` (always).
/// - On-device (when the OTel resource carries them): `ai.application.ver` ←
///   `service.version`; `ai.device.*` ← `device.*` / `os.*`.
///
/// Two deliberate divergences from the server-only .NET exporter, both driven by
/// this spec: (1) roleInstance falls back to the `host.name` *resource attribute*
/// rather than a live `gethostname()` syscall — keeping this a pure, testable
/// mapping; live host/instance identity is expected to arrive via the OTel
/// `Resource` detectors or an explicit override. (2) `ai.device.*` are mapped from
/// the OTel `device.*`/`os.*` resource attributes because Stout runs on-device;
/// .NET (server-side) does not populate these from the Resource (FR-020, Acc #10).
///
/// **Explicit overrides beat detection** (FR-022): any tag supplied in `overrides`
/// replaces the detected value for the same key. The result is computed once and is
/// immutable.
public enum ResourceDetector {
  /// Compute the resource-level Part A tags.
  ///
  /// - Parameters:
  ///   - resource: the OpenTelemetry `Resource` whose attributes are mapped. Pass
  ///     `Resource()` (the SDK default) or a resource with detected/explicit
  ///     attributes.
  ///   - overrides: tags that take precedence over detection (FR-022). Empty by
  ///     default.
  /// - Returns: the merged, immutable resource `TelemetryTags`.
  public static func detect(
    resource: Resource,
    overrides: TelemetryTags = TelemetryTags()
  ) -> TelemetryTags {
    var tags = TelemetryTags()

    // Always stamp our own SDK identity (FR-021).
    tags[PartATagKeys.internalSdkVersion] = StoutVersion.sdkVersion

    // ai.cloud.role / ai.cloud.roleInstance (FR-019/FR-020).
    if let role = cloudRole(from: resource) {
      tags[PartATagKeys.cloudRole] = role
    }
    if let instance = cloudRoleInstance(from: resource) {
      tags[PartATagKeys.cloudRoleInstance] = instance
    }

    // On-device device/app tags — emitted only when the resource carries them, so
    // this is a no-op on servers that don't set device/os attributes (FR-020).
    if let appVersion = string(resource, .serviceVersion) {
      tags[PartATagKeys.applicationVersion] = appVersion
    }
    if let deviceId = string(resource, .deviceId) {
      tags[PartATagKeys.deviceId] = deviceId
    }
    let model = string(resource, .deviceModelName) ?? string(resource, .deviceModelIdentifier)
    if let model {
      tags[PartATagKeys.deviceModel] = model
    }
    if let manufacturer = string(resource, .deviceManufacturer) {
      tags[PartATagKeys.deviceOEMName] = manufacturer
    }
    if let osVersion = osVersion(from: resource) {
      tags[PartATagKeys.deviceOSVersion] = osVersion
    }

    // Explicit overrides win over everything detected above (FR-022).
    return overrides.merging(over: tags)
  }

  // MARK: - Mapping helpers

  /// `ai.cloud.role`: `"[{namespace}]/{name}"` when a namespace is present (the exact
  /// .NET form — bracketed namespace, `/` separator), else the bare `service.name`.
  /// Returns `nil` when no service name is available so the tag is omitted rather
  /// than emitted empty.
  private static func cloudRole(from resource: Resource) -> String? {
    guard let name = string(resource, .serviceName) else { return nil }
    if let namespace = string(resource, .serviceNamespace), !namespace.isEmpty {
      return "[\(namespace)]/\(name)"
    }
    return name
  }

  /// `ai.cloud.roleInstance`: `service.instance.id`, falling back to `host.name`.
  private static func cloudRoleInstance(from resource: Resource) -> String? {
    string(resource, .serviceInstanceId) ?? string(resource, .hostName)
  }

  /// `ai.device.osVersion`: prefer `os.version`; if absent, fall back to the
  /// human-readable `os.description`.
  private static func osVersion(from resource: Resource) -> String? {
    string(resource, .osVersion) ?? string(resource, .osDescription)
  }

  /// Read a single string-valued attribute by its semantic-convention key,
  /// ignoring empty strings and non-string values.
  private static func string(_ resource: Resource, _ key: ResourceAttributes) -> String? {
    guard case .string(let value)? = resource.attributes[key.rawValue], !value.isEmpty else {
      return nil
    }
    return value
  }
}
