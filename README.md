# Stout

> Collector-free Azure Monitor / Application Insights exporter for
> [opentelemetry-swift](https://github.com/open-telemetry/opentelemetry-swift) — for
> iOS, macOS, watchOS, tvOS, and Linux

Stout lets a Swift app or service send **traces, logs, and metrics directly** to
Azure Monitor / Application Insights — no OpenTelemetry Collector and no Azure
Monitor Agent in between. It is an **exporter for the OpenTelemetry Swift SDK**
([opentelemetry-swift](https://github.com/open-telemetry/opentelemetry-swift)):
you instrument your app with `opentelemetry-swift`, register Stout's exporters, and
your existing OTel instrumentation (URLSession HTTP spans, MetricKit, Vapor,
Hummingbird, gRPC-swift, …) lights up for free. Stout implements
`opentelemetry-swift`'s public `SpanExporter` / `MetricExporter` / `LogRecordExporter`
and translates the telemetry into Application Insights' "Breeze" ingestion schema —
the same model as .NET's `Azure.Monitor.OpenTelemetry.Exporter`.

## Status

**Pre-release — work in progress.** APIs are unstable and will change before 1.0.
Not ready for production use. Follow along via [`docs/`](docs/).

The **core ingestion foundation** (spec 01) is built and tested in `StoutCore`:
connection-string parsing and validation (fail-closed, HTTPS-only, secrets never
logged), the Breeze envelope model, a bounded drop-on-overflow export pipeline with
reliable retry/backoff and partial-success handling, gzip newline-JSON transport
(`URLSession` on Apple, async-http-client on Linux), drain-and-go-inert shutdown, and
resource detection into Part A tags. The consumer-facing **signal exporters** that
plug into an `opentelemetry-swift` provider — `SpanExporter` (traces),
`LogRecordExporter` (logs), `MetricExporter` (metrics) — are next; until they land you
cannot yet register Stout with a `TracerProvider`/`LoggerProvider`/`MeterProvider`.

## Planned features

- **Traces** — a `SpanExporter` mapping OTel spans to Application Insights
  request/dependency/exception telemetry, with trace correlation.
- **Logs** — a `LogRecordExporter` mapping OTel log records to message/exception
  telemetry with span correlation.
- **Metrics** — a `MetricExporter` mapping OTel counters, gauges, and histograms to
  Application Insights metric telemetry.
- **Live Metrics** — the Azure Monitor QuickPulse live-stream side-channel.
- **Distro** — a one-call bootstrap that configures the `opentelemetry-swift`
  providers and registers Stout's exporters from an Application Insights connection
  string, plus an optional server-side
  [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle)
  integration.

## Installation

Add Stout to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/Stonefly-Labs/Stout.git", from: "0.1.0")
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

Stout runs everywhere `opentelemetry-swift` runs:

- **iOS 13+**
- **macOS 12+**
- **watchOS**
- **tvOS**
- **visionOS**
- **Linux**

On Apple platforms the transport uses `URLSession`; on Linux it uses
[async-http-client](https://github.com/swift-server/async-http-client).

## Documentation

- [Architecture & scope](docs/design.md)
- [Spec Kit foundation & specs](docs/speckit/)

## License

Stout is licensed under the [Apache License 2.0](LICENSE). Copyright 2026 Stonefly
Labs.
