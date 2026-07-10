// swift-tools-version:6.0
//
// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

// On Linux, StoutCore gzips request bodies through the system zlib (`zlib1g`)
// via a `.systemLibrary` shim target (see Sources/CZlib). On Apple platforms the
// SDK already vends a `zlib` module, so no extra target is needed there. Keeping
// the target and dependency Linux-only avoids an Apple-side modulemap clash.
#if os(Linux)
let cZlibTargets: [Target] = [
  .systemLibrary(
    name: "CZlib",
    pkgConfig: "zlib",
    providers: [.apt(["zlib1g-dev"])]
  )
]
let cZlibDependencies: [Target.Dependency] = ["CZlib"]
#else
let cZlibTargets: [Target] = []
let cZlibDependencies: [Target.Dependency] = []
#endif

let package = Package(
  name: "stout",
  // Cross-platform: Stout is an exporter for opentelemetry-swift (design D7/D8),
  // so the platform floor tracks what opentelemetry-swift supports — iOS, macOS,
  // watchOS, tvOS (+ visionOS) and Linux. This is NOT a server-only library.
  platforms: [
    .iOS(.v13),
    .macOS(.v12),
    .watchOS(.v6),
    .tvOS(.v13),
    .visionOS(.v1),
  ],
  products: [
    // Umbrella distro — configures the OTel providers + registers Stout exporters.
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
    // OpenTelemetry Swift SDK — the minimal split-out core package
    // (open-telemetry/opentelemetry-swift-core). It exposes the public
    // OpenTelemetryApi + OpenTelemetrySdk products that carry the
    // SpanExporter / MetricExporter / LogRecordExporter protocols and the
    // SpanData / ReadableLogRecord / MetricData types we translate to Breeze.
    // Using the -core package avoids pulling OTLP / gRPC / protobuf.
    .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", from: "2.5.0"),
    // Transport on Linux only — Apple platforms use URLSession (Foundation), no dep.
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    // Optional server-side graceful shutdown — StoutServiceLifecycle target only.
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
  ],
  targets: [
    // MARK: - Core
    .target(
      name: "StoutCore",
      dependencies: [
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
        // Linux transport only — on Apple platforms StoutCore uses URLSession.
        .product(
          name: "AsyncHTTPClient",
          package: "async-http-client",
          condition: .when(platforms: [.linux])
        ),
      ] + cZlibDependencies
    ),
    // MARK: - Signal modules (implement the public OTel exporter protocols)
    .target(
      name: "StoutTracing",
      dependencies: [
        "StoutCore",
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
      ]
    ),
    .target(
      name: "StoutLogging",
      dependencies: [
        "StoutCore",
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
      ]
    ),
    .target(
      name: "StoutMetrics",
      dependencies: [
        "StoutCore",
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
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
      ]
    ),
    // MARK: - Optional ServiceLifecycle integration (design D3)
    // The ONLY target that depends on swift-service-lifecycle. Server-side use;
    // iOS/Apple apps use app-lifecycle hooks instead.
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
  ] + cZlibTargets,
  swiftLanguageModes: [.v6]
)
