// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import OpenTelemetrySdk
import XCTest

@testable import StoutCore

/// US6 — resource detection: map the OpenTelemetry `Resource` to Part A tags with
/// the .NET-mirrored role/instance logic, on-device device/app tags, and
/// override-beats-detection precedence (Acc #10; FR-018–FR-022).
final class ResourceDetectorTests: XCTestCase {
  private func resource(_ attributes: [ResourceAttributes: String]) -> Resource {
    var mapped: [String: AttributeValue] = [:]
    for (key, value) in attributes { mapped[key.rawValue] = .string(value) }
    return Resource(attributes: mapped)
  }

  // MARK: sdkVersion (FR-021)

  func testSdkVersionAlwaysStamped() {
    let tags = ResourceDetector.detect(resource: Resource(attributes: [:]))
    XCTAssertEqual(tags[PartATagKeys.internalSdkVersion], StoutVersion.sdkVersion)
    XCTAssertTrue(
      tags[PartATagKeys.internalSdkVersion]?.hasPrefix("stout:") ?? false,
      "sdkVersion must be the stout:<version> form")
  }

  // MARK: ai.cloud.role composition (FR-019)

  func testRoleNameIsServiceNameWhenNoNamespace() {
    let tags = ResourceDetector.detect(resource: resource([.serviceName: "checkout"]))
    XCTAssertEqual(tags[PartATagKeys.cloudRole], "checkout")
  }

  func testRoleNameCombinesNamespaceAndName() {
    // Mirrors the .NET exporter exactly: bracketed namespace, `/` separator.
    let tags = ResourceDetector.detect(
      resource: resource([.serviceName: "checkout", .serviceNamespace: "shop"]))
    XCTAssertEqual(tags[PartATagKeys.cloudRole], "[shop]/checkout")
  }

  func testRoleNameOmittedWhenNoServiceName() {
    // Namespace alone can't form a role; the tag is omitted rather than emitted empty.
    let tags = ResourceDetector.detect(resource: resource([.serviceNamespace: "shop"]))
    XCTAssertNil(tags[PartATagKeys.cloudRole])
  }

  // MARK: ai.cloud.roleInstance fallback (FR-020)

  func testRoleInstancePrefersServiceInstanceId() {
    let tags = ResourceDetector.detect(
      resource: resource([.serviceInstanceId: "pod-7", .hostName: "node-1"]))
    XCTAssertEqual(tags[PartATagKeys.cloudRoleInstance], "pod-7")
  }

  func testRoleInstanceFallsBackToHostName() {
    let tags = ResourceDetector.detect(resource: resource([.hostName: "node-1"]))
    XCTAssertEqual(tags[PartATagKeys.cloudRoleInstance], "node-1")
  }

  func testRoleInstanceOmittedWhenNeitherPresent() {
    let tags = ResourceDetector.detect(resource: resource([.serviceName: "checkout"]))
    XCTAssertNil(tags[PartATagKeys.cloudRoleInstance])
  }

  // MARK: On-device device/app tags (FR-020, Acc #10)

  func testDeviceAndAppTagsMappedWhenPresent() {
    let tags = ResourceDetector.detect(
      resource: resource([
        .serviceVersion: "3.2.1",
        .deviceId: "device-abc",
        .deviceModelName: "iPhone 15 Pro",
        .deviceManufacturer: "Apple",
        .osVersion: "17.4",
      ]))
    XCTAssertEqual(tags[PartATagKeys.applicationVersion], "3.2.1")
    XCTAssertEqual(tags[PartATagKeys.deviceId], "device-abc")
    XCTAssertEqual(tags[PartATagKeys.deviceModel], "iPhone 15 Pro")
    XCTAssertEqual(tags[PartATagKeys.deviceOEMName], "Apple")
    XCTAssertEqual(tags[PartATagKeys.deviceOSVersion], "17.4")
  }

  func testDeviceModelFallsBackToIdentifier() {
    let tags = ResourceDetector.detect(resource: resource([.deviceModelIdentifier: "iPhone16,1"]))
    XCTAssertEqual(tags[PartATagKeys.deviceModel], "iPhone16,1")
  }

  func testServerResourceEmitsNoDeviceTags() {
    let tags = ResourceDetector.detect(
      resource: resource([.serviceName: "api", .hostName: "host-1"]))
    XCTAssertNil(tags[PartATagKeys.deviceId])
    XCTAssertNil(tags[PartATagKeys.deviceModel])
    XCTAssertNil(tags[PartATagKeys.applicationVersion])
    XCTAssertNil(tags[PartATagKeys.deviceOSVersion])
  }

  // MARK: Override precedence (FR-022)

  func testExplicitOverridesBeatDetection() {
    let overrides = TelemetryTags([
      PartATagKeys.cloudRole: "custom-role",
      PartATagKeys.cloudRoleInstance: "custom-instance",
    ])
    let tags = ResourceDetector.detect(
      resource: resource([
        .serviceName: "checkout", .serviceNamespace: "shop", .serviceInstanceId: "pod-7",
      ]),
      overrides: overrides)
    XCTAssertEqual(tags[PartATagKeys.cloudRole], "custom-role")
    XCTAssertEqual(tags[PartATagKeys.cloudRoleInstance], "custom-instance")
  }

  func testOverrideCanSetSdkVersionButDefaultOtherwise() {
    // Overrides only replace the keys they specify; untouched detected tags remain.
    let tags = ResourceDetector.detect(
      resource: resource([.serviceName: "checkout"]),
      overrides: TelemetryTags([PartATagKeys.cloudRoleInstance: "forced"]))
    XCTAssertEqual(tags[PartATagKeys.cloudRole], "checkout", "unrelated detected tags survive")
    XCTAssertEqual(tags[PartATagKeys.cloudRoleInstance], "forced")
    XCTAssertEqual(tags[PartATagKeys.internalSdkVersion], StoutVersion.sdkVersion)
  }

  // MARK: Secret-free (FR-016)

  func testNoConnectionStringMaterialLeaksIntoTags() {
    // Resource attributes never carry the connection string; confirm the detector
    // emits only ai.* keys and nothing resembling an iKey/secret.
    let tags = ResourceDetector.detect(resource: resource([.serviceName: "checkout"]))
    for key in tags.storage.keys {
      XCTAssertTrue(key.hasPrefix("ai."), "detector must only emit ai.* Part A tags, got \(key)")
    }
  }
}
