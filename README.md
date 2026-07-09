# Stout

> Collector-free Azure Monitor / Application Insights exporter for server-side Swift

Stout lets a server-side Swift service send **traces, logs, and metrics directly**
to Azure Monitor / Application Insights — no OpenTelemetry Collector and no Azure
Monitor Agent in between. It plugs into the Swift Server Working Group observability
facades ([swift-log](https://github.com/apple/swift-log),
[swift-metrics](https://github.com/apple/swift-metrics), and
[swift-distributed-tracing](https://github.com/apple/swift-distributed-tracing)),
so existing instrumentation (Vapor, Hummingbird, gRPC-swift, …) lights up for free,
and translates telemetry into Application Insights' "Breeze" ingestion schema.

## Status

**Pre-release — work in progress.** This is Phase 0 scaffolding: the module graph
compiles, but no telemetry is exported yet. APIs are unstable and will change before
1.0. Not ready for production use. Follow along via [`docs/`](docs/).

## Planned features

- **Traces** — a `swift-distributed-tracing` backend mapping spans to Application
  Insights request/dependency telemetry, with W3C `traceparent` propagation.
- **Logs** — a `swift-log` `LogHandler` mapping log records to message/exception
  telemetry with span correlation.
- **Metrics** — a `swift-metrics` `MetricsFactory` mapping counters, gauges, and
  histograms to Application Insights metric telemetry.
- **Live Metrics** — the Azure Monitor QuickPulse live-stream side-channel.
- **Distro** — a one-call bootstrap from an Application Insights connection string,
  plus an optional [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle)
  integration.

## Installation

Add Stout to your `Package.swift`:

```swift
dependencies: [
  // NOTE: the GitHub org slug is a placeholder and may be adjusted.
  .package(url: "https://github.com/StoneflyLabs/stout.git", from: "0.1.0")
]
```

Then depend on the modules you need — for example the umbrella distro:

```swift
.target(
  name: "MyServer",
  dependencies: [
    .product(name: "Stout", package: "stout")
  ]
)
```

You can also import only individual signal modules (`StoutTracing`, `StoutLogging`,
`StoutMetrics`, `StoutLiveMetrics`) or the base `StoutCore`, and add
`StoutServiceLifecycle` if you use swift-service-lifecycle — so you pay only for
what you import.

## Platform support

- **macOS 13+** (Apple platforms)
- **Linux** (the primary server target)

This is a server-side library: there is no iOS / tvOS / watchOS support.

## Documentation

- [Architecture & scope](docs/design.md)
- [Spec Kit foundation & specs](docs/speckit/)

## License

Stout is licensed under the [Apache License 2.0](LICENSE). Copyright 2026 Stonefly
Labs.
