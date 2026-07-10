# Stout — Architecture & Scope

A **collector-free** Azure Monitor / Application Insights telemetry exporter for
Swift, built as an exporter for the **OpenTelemetry Swift SDK
(`opentelemetry-swift`)**. It lets a Swift app — **iOS, macOS, watchOS, tvOS, or a
Linux/macOS server** — send OpenTelemetry traces, metrics, and logs **directly** to
Application Insights (no OpenTelemetry Collector, no Azure Monitor Agent), mirroring
the capabilities of the .NET `Azure.Monitor.OpenTelemetry.Exporter`.

**This is a public OSS library. Security, stability, and quality are the #1
priorities at all times** — over speed or feature count. See §0.

Status: **design locked (opentelemetry-swift exporter approach).** Greenfield;
Phase 0 scaffold done, now being re-platformed for iOS + all-Apple + Linux.

---

## 0. Quality mandate (non-negotiable)

Because this is a public library that handles credentials and runs inside
customers' apps and production services (including **on end-user devices**), every
spec and PR must uphold:

- **Security** — connection strings, instrumentation keys, and tokens are secrets:
  never logged, never in error messages or our own telemetry. Validate and fail
  closed. HTTPS-only. Minimal, audited dependencies.
- **Stability** — Swift 6 strict concurrency (`Sendable`, no data races); telemetry
  failures must never crash, block, or degrade the host app; bounded memory & disk
  (drop/evict-on-overflow, never unbounded); robust retry/backoff.
- **Quality** — high test coverage incl. translation tables and failure paths;
  SemVer; clear public API boundaries; documented behavior.

Governing principles: `docs/speckit/constitution.md`. Every PR must uphold them.

---

## 1. Goal & non-goals

**Goal**
- Add a package, register Stout's exporters with the OpenTelemetry Swift SDK,
  configure a connection string, and get telemetry flowing to App Insights with no
  intermediary infrastructure — **the same model as .NET's Azure Monitor exporter.**
- Run everywhere `opentelemetry-swift` runs: **iOS 13+, macOS 12+, watchOS, tvOS,
  visionOS, and Linux.**
- Traces, logs, and metrics (all three are required); optional Live Metrics.

**Non-goals (initially)**
- Statsbeat (Microsoft-internal usage telemetry).
- Building instrumentation ourselves — `opentelemetry-swift` already ships the
  on-device Darwin instrumentations (URLSession auto HTTP spans, MetricKit,
  NetworkStatus, sessions) and server users add their own. Stout is the **exporter**,
  not an instrumentation library.
- Crash reporting (lives in vendor OTel distros, not core).

---

## 2. Background — why this needs the "Breeze" schema

Application Insights' ingestion endpoint does not natively accept OTLP as a GA path
(native OTLP is preview and gateway-mediated). The collector-free path is to
translate telemetry into the legacy **"Breeze"** schema and POST it to ingestion —
exactly what the per-language Azure Monitor exporters do. Microsoft ships that for
.NET, Java, Node.js, and Python only — **not Swift**, and there is **no maintained
Swift library** that POSTs to Breeze (Microsoft's old Obj-C `ApplicationInsights-iOS`
was archived in 2022). That gap is Stout's niche.

**Why direct-to-Breeze instead of OTLP→gateway (Microsoft's current *mobile*
suggestion):** the gateway path lands data in the newer OTel tables
(`OTelSpans`/`OTelLogs`), whereas Breeze lands in the **classic tables**
(`requests`/`dependencies`/`traces`/`exceptions`/`customMetrics`) that preserve the
familiar App Insights UX — and it needs **no gateway to run**. That's the whole
value proposition.

**Breeze transport, at a glance** (path confirmed against the .NET OTel exporter):
- Endpoint: `{IngestionEndpoint}/v2.1/track` (from the connection string; default
  host `https://dc.services.visualstudio.com`). Envelope `ver` = 1 (omitted on the
  wire); each `data.baseData.ver` = 2.
- HTTPS `POST`, `Content-Encoding: gzip`, `Content-Type: application/x-json-stream`
  (newline-delimited JSON envelopes).
- `InstrumentationKey` → each envelope's `iKey`.
- Response body reports `itemsReceived` / `itemsAccepted` + per-item errors →
  partial-success handling and retry.

Connection string shape:
```
InstrumentationKey=<guid>;IngestionEndpoint=https://<region>.in.applicationinsights.azure.com/;LiveEndpoint=https://<region>.livediagnostics.monitor.azure.com/
```

---

## 3. The direction — an exporter for opentelemetry-swift

Stout is the Swift analog of .NET's `Azure.Monitor.OpenTelemetry.Exporter`: the
consumer instruments their app with the **OpenTelemetry Swift SDK**, registers
Stout's exporters, and telemetry goes to App Insights. Three reasons this is the
right foundation:

1. **It runs on iOS (the whole point).** `opentelemetry-swift` targets iOS 13+,
   macOS 12+, watchOS, tvOS, visionOS, and Linux — the one OTel Swift stack built
   for client/mobile *and* server.
2. **It matches the .NET capability set 1:1.** OTel traces/logs/metrics → an Azure
   Monitor exporter → Breeze. Same model you asked to mirror.
3. **Its exporter protocols are public.** `opentelemetry-swift` exposes public
   `SpanExporter` / `MetricExporter` / `LogRecordExporter` — we implement them
   directly. No forking, no internal-API wall.

> **Supersedes the earlier "B2 / SSWG-facades" decision.** We originally planned to
> implement `swift-log`/`swift-metrics`/`swift-distributed-tracing` backends for a
> *server-side* library. That approach doesn't fit iOS (those facades are
> server-centric with no on-device instrumentation ecosystem), so it is replaced by
> building on `opentelemetry-swift`. See §11 D8.

**Known trade-off (accepted):** in `opentelemetry-swift`, **Traces are Stable, but
Logs and Metrics are Beta/Development.** All three are required, and there is no
better stack. We build on it, phase **traces-first**, verify the current maturity
during spec 01's plan, and knowingly ride beta APIs for logs/metrics. See §10.

---

## 4. Options & decision

| Option | What | iOS? | Collector-free? | Decision |
|---|---|---|---|---|
| A | opentelemetry-swift → OTLP → Collector/gateway w/ azuremonitorexporter | ✅ | ❌ (needs gateway) | rejected (not collector-free; lands in OTel tables) |
| B2 (old) | Implement the SSWG facades directly (server-side) | ❌ | ✅ | **superseded** (no iOS fit) |
| **D8** | **Implement `opentelemetry-swift`'s exporter protocols; translate to Breeze** | ✅ | ✅ | **CHOSEN** |
| — | Direct native Stout API (like the archived Obj-C SDK), no OTel | ✅ | ✅ | rejected (you want .NET-OTel parity, not a bespoke API) |

**Why D8.** It is the only option that is collector-free, runs on iOS, matches the
.NET OTel capability set, preserves the classic App Insights tables, and plugs into
public protocols. The Breeze translation + transport we already designed is
SDK-agnostic and carries straight over.

---

## 5. Architecture

```
   App code (iOS / macOS / watchOS / tvOS / Linux server)
                    │  instruments with
        OpenTelemetry Swift SDK (opentelemetry-swift)
        TracerProvider · LoggerProvider · MeterProvider
                    │  we register our exporters
   ┌──────────────────────────────────────────────────────────────┐
   │  Stout                                                         │
   │                                                                │
   │  SpanExporter   LogRecordExporter   MetricExporter  ← we implement (public protocols)
   │        \              |                 /                      │
   │         └── translation: OTel data → Breeze envelopes ──┘      │
   │                    │  (SpanData / ReadableLogRecord / MetricData)  │
   │   resource → ai.cloud.role/roleInstance/device tags           │
   │                    │                                          │
   │   transport (Sendable, bounded): gzip newline-JSON →          │
   │     POST {IngestionEndpoint}/v2.1/track                       │
   │       • Apple  → URLSession                                   │
   │       • Linux  → async-http-client                            │
   │     + connection-string parse + secrets + partial-success     │
   │       + retry/backoff  (+ offline store, sampling later)      │
   └──────────────────────────────────────────────────────────────┘
                    │
        Application Insights ingestion (Breeze → classic tables)
```

**Modules:**

| Module | Role | Key deps |
|---|---|---|
| `StoutCore` | config/secrets, Breeze envelope model, shared translation, transport abstraction, resource detection, internal diagnostics | `OpenTelemetrySdk` (data types); URLSession (Foundation); `async-http-client` **(Linux only, conditional)** |
| `StoutTracing` | `SpanExporter` → RequestData/RemoteDependencyData/ExceptionData | `StoutCore`, `OpenTelemetrySdk` |
| `StoutLogging` | `LogRecordExporter` → MessageData/ExceptionData | `StoutCore`, `OpenTelemetrySdk` |
| `StoutMetrics` | `MetricExporter` → MetricData | `StoutCore`, `OpenTelemetrySdk` |
| `StoutLiveMetrics` | QuickPulse real-time channel (separate) | `StoutCore` |
| `Stout` | umbrella: configure the OTel providers + register Stout exporters from a connection string | the three + core |
| `StoutServiceLifecycle` | optional **server-side** graceful shutdown | `Stout`, `swift-service-lifecycle` (server only; iOS uses app lifecycle) |

**Transport abstraction (D9):** one `Sendable` transport protocol with two
implementations selected via `#if canImport(FoundationNetworking)` — **URLSession**
on Apple platforms, **async-http-client** on Linux (Apple's own `swift-openapi`
uses exactly this split). We **gzip request bodies ourselves** in both (URLSession
does not auto-compress requests). Background/streaming upload stays Apple-only.

**Dropped from the old design:** the `swift-log` / `swift-metrics` /
`swift-distributed-tracing` dependencies (we no longer implement those facades).

---

## 6. The translation table (where the time goes)

Operates on `opentelemetry-swift`'s `SpanData` / `ReadableLogRecord` / `MetricData`.
Port the *logic* from the MIT-licensed .NET exporter (§8).

**Span kind → envelope type:** `.server`/`.consumer` → `RequestData`;
`.client`/`.producer`/`.internal` → `RemoteDependencyData`.

**Part A tags:** `ai.operation.id` ← trace ID; `ai.operation.parentId` ← parent
span ID; `ai.cloud.role`/`ai.cloud.roleInstance` ← resource; `ai.internal.sdkVersion`
← `stout:<version>`. On-device resource can also populate `ai.device.*` /
`ai.application.ver` when available.

**RequestData / RemoteDependencyData:** map OTel HTTP/DB/RPC/messaging semantic
conventions to name/target/type/resultCode/responseCode/success/url/data.
**Span events:** `exception` → `ExceptionData`; others → `MessageData`.
**Logs:** `ReadableLogRecord` → `MessageData` (or `ExceptionData`); severity mapping;
trace correlation. **Metrics:** `MetricData` → `MetricData` envelope
(value/count/min/max; sum/gauge/histogram); attributes → properties.

**Sampling:** App Insights fixed-rate ingestion sampling via envelope `sampleRate` +
`itemCount`. Carry `sampleRate` from day 1; policy in spec 05.

---

## 7. Live Metrics (QuickPulse) — feasible, separate later phase

Unchanged from prior analysis, and it works cross-platform (URLSession/AHC). **Not
OTel/OTLP** — a proprietary Azure Monitor side-channel (QuickPulse): own endpoint
(`LiveEndpoint` → `livediagnostics.monitor.azure.com`), own data model
(`MonitoringDataPoint`), stateful ping/post control channel. ~2–3× the core
exporter; its own spec (06), sequenced after traces/logs/metrics. v1 = ping/post
state machine + metrics-only, **deferring the client-side filtering DSL**. Plan for
Entra token auth. Reference: MIT .NET `Azure.Monitor.OpenTelemetry.LiveMetrics`.

---

## 8. Reference: the .NET exporter (MIT — safe to study & port)

`Azure/azure-sdk-for-net`, MIT. Breeze exporter:
`sdk/monitor/Azure.Monitor.OpenTelemetry.Exporter` — `src/Internals/TraceHelper.cs`
(span→item), `ActivityExtensions.cs`/`ActivityTagsProcessor.cs` (tags → Part B/C),
`SchemaConstants.cs` (constants + `/v2.1/track`). Live Metrics:
`sdk/monitor/Azure.Monitor.OpenTelemetry.LiveMetrics`; legacy filtering DSL in
`microsoft/ApplicationInsights-dotnet-server` `.../QuickPulse/`.

---

## 9. Phased plan

- **Phase 0 — Scaffold (re-platformed).** SwiftPM package with the module graph,
  **iOS/macOS/watchOS/tvOS + Linux** platforms, `opentelemetry-swift` dependency,
  conditional transport deps, CI (self-hosted interim; needs iOS-sim + Linux legs),
  governance files.
- **Phase 1 — Core + Traces exporter.** Config/secrets, envelope model, transport
  abstraction (URLSession/AHC) + gzip + basic retry, resource detection (**core**);
  `SpanExporter` + span→Request/Dependency translation (**traces**). Success: a
  Swift app's spans appear in App Insights with correct correlation.
- **Phase 2 — Logs exporter.** `LogRecordExporter` (rides beta OTel logs).
- **Phase 3 — Metrics exporter.** `MetricExporter` (rides beta OTel metrics).
- **Phase 4 — Hardening.** Partial-success, `Retry-After`/backoff, disk-backed
  offline store, ingestion sampling, Entra/AAD auth.
- **Phase 5 — Live Metrics.** QuickPulse ping/post + metrics-only v1.
- **Phase 6 — Distro convenience layer.** One-call provider setup from a connection
  string; optional web-framework middleware (server) and app-lifecycle hooks.

**Testing must cover iOS (simulator) AND Linux**, not just macOS — platform-specific
transport and Foundation differences are real.

---

## 10. Risks & open questions

- **opentelemetry-swift Logs/Metrics maturity** — Traces Stable, Logs/Metrics
  Beta/Development (accepted, §3). Verify current 2026 state in spec 01's plan;
  phase traces-first.
- **opentelemetry-swift package/product surface** — confirm exact package
  (`opentelemetry-swift` vs a split `-core`) and the `OpenTelemetryApi`/`Sdk`
  product names + exporter-protocol signatures during scaffolding (resolve & build).
- **Transport** — request-body gzip must be done by us on both backends; background
  URLSession is Apple-only; Linux URLSession (FoundationNetworking) is limited →
  async-http-client on Linux.
- **gzip strategy** — `[PLAN]` cross-platform: system `zlib` vs a Swift package.
- **Semantic-convention drift**; **Live Metrics protocol undocumented** (as before).
- **iOS constraints** — bounded on-device memory/disk; battery/network-aware
  batching; app-suspension flush.

---

## 11. Resolved design decisions (log)

Binding on the specs. D1–D6 unchanged from prior rounds; D7–D9 added for the
iOS/opentelemetry-swift pivot.

- **D1 — Lifecycle / shutdown.** Exporters are independently-constructable/injectable;
  shutdown = **drain-and-go-inert** (flush, stop loops, close client; handlers inert;
  post-shutdown emit dropped after one rate-limited internal-diagnostics warning).
- **D2 — Ingestion path.** `POST {IngestionEndpoint}/v2.1/track`; envelope `ver`=1,
  `baseData.ver`=2.
- **D3 — ServiceLifecycle.** Optional additive **server-side** target
  (`StoutServiceLifecycle`), never a core dependency; iOS uses app-lifecycle hooks.
- **D4 — Metrics semantics.** Delta values; idle counters emit nothing by default;
  cardinality bounded by an overflow bucket (`otel.metric.overflow=true`).
- **D5 — Naming & license.** **Stout**; package `stout`; modules `Stout*`;
  Apache-2.0; GitHub org **Stonefly-Labs** (`Stonefly-Labs/Stout`).
- **D6 — CI runner.** Self-hosted interim; hosted matrix later — and it **must add
  iOS-simulator + Linux legs** (macOS alone is insufficient).
- **D7 — Platforms.** **iOS + macOS + watchOS + tvOS (+ visionOS) + Linux.** Not
  server-only. Sets the platform floor to what `opentelemetry-swift` supports.
- **D8 — SDK / architecture.** Build on **`opentelemetry-swift`**, implementing its
  public `SpanExporter`/`MetricExporter`/`LogRecordExporter` and translating to
  Breeze. **Supersedes B2 (SSWG facades).** Drops swift-log/metrics/distributed-tracing
  deps. Accepts beta Logs/Metrics maturity.
- **D9 — Transport.** One `Sendable` transport abstraction: URLSession on Apple,
  async-http-client on Linux (`#if canImport(FoundationNetworking)`); we gzip request
  bodies; background upload Apple-only.

---

## 12. Sources

- opentelemetry-swift: https://github.com/open-telemetry/opentelemetry-swift · docs https://opentelemetry.io/docs/languages/swift/
- Cross-platform transport pattern (URLSession + async-http-client): https://github.com/apple/swift-openapi-urlsession · https://github.com/swift-server/async-http-client
- App Insights OTel enablement (supported languages): https://learn.microsoft.com/en-us/azure/azure-monitor/app/opentelemetry-enable
- App Center → Azure Monitor mobile migration: https://learn.microsoft.com/en-us/azure/azure-monitor/app/app-center-migration
- Breeze schema (baseData types + `ai.*` tags): https://github.com/microsoft/ApplicationInsights-dotnet/tree/master/BASE/Schema/PublicSchema
- .NET Breeze exporter (MIT): https://github.com/Azure/azure-sdk-for-net/tree/main/sdk/monitor/Azure.Monitor.OpenTelemetry.Exporter/src/Internals
- Archived Microsoft ApplicationInsights-iOS (precedent): https://github.com/microsoft/ApplicationInsights-iOS
