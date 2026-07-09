// swift-tools-version:6.0
//
// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
  name: "stout",
  // Server-side only: macOS floor for Apple platforms; Linux supported implicitly.
  // No iOS/tvOS/watchOS — this is not a mobile SDK.
  platforms: [
    .macOS(.v13)
  ],
  products: [
    // Umbrella distro — one-call bootstrap over all signal modules.
    .library(name: "Stout", targets: ["Stout"]),
    // Individual signal modules so consumers import only what they need.
    .library(name: "StoutCore", targets: ["StoutCore"]),
    .library(name: "StoutTracing", targets: ["StoutTracing"]),
    .library(name: "StoutLogging", targets: ["StoutLogging"]),
    .library(name: "StoutMetrics", targets: ["StoutMetrics"]),
    .library(name: "StoutLiveMetrics", targets: ["StoutLiveMetrics"]),
    // Optional additive target (design D3) — swift-service-lifecycle integration.
    .library(name: "StoutServiceLifecycle", targets: ["StoutServiceLifecycle"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
    .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.1.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
  ],
  targets: [
    // MARK: - Core
    .target(
      name: "StoutCore",
      dependencies: [
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        // swift-log here is for the library's INTERNAL diagnostics only,
        // never the user's telemetry pipeline (design D1).
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    // MARK: - Signal modules
    .target(
      name: "StoutTracing",
      dependencies: [
        "StoutCore",
        .product(name: "Tracing", package: "swift-distributed-tracing"),
      ]
    ),
    .target(
      name: "StoutLogging",
      dependencies: [
        "StoutCore",
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .target(
      name: "StoutMetrics",
      dependencies: [
        "StoutCore",
        .product(name: "Metrics", package: "swift-metrics"),
      ]
    ),
    .target(
      name: "StoutLiveMetrics",
      dependencies: [
        "StoutCore"
      ]
    ),
    // MARK: - Umbrella distro
    .target(
      name: "Stout",
      dependencies: [
        "StoutTracing",
        "StoutLogging",
        "StoutMetrics",
        "StoutLiveMetrics",
      ]
    ),
    // MARK: - Optional ServiceLifecycle integration (design D3)
    // The ONLY target that depends on swift-service-lifecycle.
    .target(
      name: "StoutServiceLifecycle",
      dependencies: [
        "Stout",
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
      ]
    ),
    // MARK: - Tests
    .testTarget(name: "StoutCoreTests", dependencies: ["StoutCore"]),
    .testTarget(name: "StoutTracingTests", dependencies: ["StoutTracing"]),
    .testTarget(name: "StoutLoggingTests", dependencies: ["StoutLogging"]),
    .testTarget(name: "StoutMetricsTests", dependencies: ["StoutMetrics"]),
    .testTarget(name: "StoutLiveMetricsTests", dependencies: ["StoutLiveMetrics"]),
    .testTarget(name: "StoutTests", dependencies: ["Stout"]),
    .testTarget(name: "StoutServiceLifecycleTests", dependencies: ["StoutServiceLifecycle"]),
  ],
  swiftLanguageModes: [.v6]
)
