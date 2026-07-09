# Stout — Architecture & Scope

A **collector-free**, open-source Azure Monitor / Application Insights exporter for
**server-side Swift**. Goal: let a Swift service send traces, metrics, and logs
**directly** to Application Insights — no OpenTelemetry Collector, no Azure Monitor
Agent — the way the .NET / Java / Node / Python Azure Monitor distros do.

**This is a public OSS library. Security, stability, and quality are the #1
priorities at all times** — over speed or feature count. See §0.

Status: **design locked (B2 approach)**. Greenfield repo; nothing built yet.

---

## 0. Quality mandate (non-negotiable)

Because this is a public library that handles credentials and runs inside
customers' production services, every spec and every PR must uphold:

- **Security** — connection strings, instrumentation keys, and tokens are secrets:
  never logged, never included in error messages or our own telemetry. Validate
  and fail closed. Minimal, audited dependencies.
- **Stability** — Swift 6 strict concurrency (`Sendable`, no data races), graceful
  degradation (telemetry failures must never crash or block the host app),
  bounded memory (drop-on-overflow, never unbounded buffers), robust retry/backoff.
- **Quality** — high test coverage incl. the translation tables and failure paths,
  SemVer discipline, clear public API boundaries, documented behavior.

These are encoded in the Spec Kit **constitution** and repeated as non-functional
acceptance criteria in every spec.

---

## 1. Goal & non-goals

**Goal**
- Add a package, configure it with an Application Insights **connection string**,
  and get telemetry flowing to App Insights with no intermediary infrastructure.
- Be a first-class **backend for the Swift Server observability facades** so that
  existing instrumentation (Vapor, Hummingbird, gRPC-swift, etc.) lights up for
  free.
- Traces first, then logs, then metrics; Live Metrics and a convenience distro
  layer after.

**Non-goals (initially)**
- Statsbeat (Microsoft-internal usage telemetry).
- Client/mobile (iOS app) instrumentation — this targets **server-side Swift**
  (Linux + macOS). We do not use `open-telemetry/opentelemetry-swift` (the
  mobile-oriented API/SDK).
- Auto-instrumentation of specific frameworks — rides on top later; the exporter
  is the foundation.

---

## 2. Background — why this needs the "Breeze" schema

Application Insights' ingestion endpoint does **not** natively accept OTLP as a GA
path (native OTLP into Azure Monitor is **preview only** as of 2026 and is
collector/agent-mediated regardless). The GA, collector-free path is the
per-language **Azure Monitor exporter**, which translates telemetry into the legacy
**"Breeze"** schema and POSTs it to ingestion. Microsoft ships that for .NET, Java,
Node.js, and Python only — **not Swift**. So a collector-free Swift path *requires*
us to implement Breeze ourselves; there is no OTLP shortcut.

**Breeze transport, at a glance** (path confirmed against the .NET OTel exporter):
- Endpoint: `{IngestionEndpoint}/v2.1/track` (`IngestionEndpoint` from the
  connection string; default host `https://dc.services.visualstudio.com`). The
  modern `Azure.Monitor.OpenTelemetry.Exporter` uses **`/v2.1/track`**; `/v2/track`
  is the older classic-SDK path. Envelope `ver` = 1 (omitted on the wire by
  default); each `data.baseData.ver` = 2.
- HTTPS `POST`, `Content-Encoding: gzip`, `Content-Type: application/x-json-stream`
  (newline-delimited JSON envelopes).
- The connection string's `InstrumentationKey` becomes each envelope's `iKey`.
- Response body reports `itemsReceived` / `itemsAccepted` + per-item errors →
  drives partial-success handling and retry.

Connection string shape:
```
InstrumentationKey=<guid>;IngestionEndpoint=https://<region>.in.applicationinsights.azure.com/;LiveEndpoint=https://<region>.livediagnostics.monitor.azure.com/
```

---

## 3. The constraint that set our direction

`swift-otel` 1.x has all three signals GA and bridges the SSWG facades, but its
exporter protocols (`OTelSpanExporter` / `OTelMetricExporter` /
`OTelLogRecordExporter`) are **internal, not `public`** — there is no supported
third-party plug-in point. We evaluated upstreaming a PR to expose them, but
**deliberately rejected taking a dependency on another repo's merge queue and
release cadence** for the foundation of our library.

**Decision: don't build on swift-otel at all. Build directly on the Swift Server
Working Group observability facades** (Option B2 below), which are public, stable,
and explicitly designed for backends like ours to plug into.

---

## 4. Options & decision

| Option | What | Collector-free? | External-repo entanglement | Decision |
|---|---|---|---|---|
| A | swift-otel OTLP/HTTP → OTel Collector w/ Azure Monitor exporter | ❌ | — | **rejected** (violates core goal) |
| B1 | Upstream PR to make swift-otel exporter protocols public | ✅ | depends on their merge/release | **rejected** (don't want the dependency) |
| **B2** | **Implement the SSWG facades directly; translate to Breeze; own the SDK layer** | ✅ | **none** | **CHOSEN** |
| C | Vendor/fork swift-otel (copy under Apache-2.0, make protocols public locally) | ✅ | carry vendored code | fallback accelerator only |

**Why B2.** `swift-log`, `swift-metrics`, and `swift-distributed-tracing` are the
SSWG facade APIs; backends implement them and get bootstrapped at startup.
swift-otel is just one backend — **we become another.** That's the intended
extension model, not a hack. Every dependency is a stable 1.0 SSWG facade; we own
100% of the stack; and the existing instrumentation ecosystem emits into these
facades already, so consumers get telemetry without touching our internals.

**Cost we accept:** we re-own the SDK layer that swift-otel would have given us —
batching, the export loop, resource detection, and trace-context propagation. That
is deliberate, bounded work (see §5) and the price of zero external entanglement.
Option **C** (vendor a slice of swift-otel's batch processor under its Apache-2.0
license, with attribution) stays on the table purely as an accelerator if we want
to skip re-writing the batch loop — but the default is to own it.

---

## 5. Architecture (B2)

```
   Vapor / Hummingbird / gRPC-swift / app code
                    │  emit via
   swift-distributed-tracing   swift-metrics   swift-log     ← public SSWG facades
                    │  we implement the backend protocols
   ┌──────────────────────────────────────────────────────────────┐
   │  Stout                                                         │
   │                                                                │
   │  Tracer          MetricsFactory      LogHandler   ← facade adapters (we own)
   │      \                |                 /                      │
   │       └──── telemetry item buffer ─────┘                      │
   │                    │                                          │
   │   generic batch processor (size/interval flush, bounded,      │
   │   drop-on-overflow)  +  resource detection (cloud role/instance)│
   │                    │                                          │
   │   translation: OTel/facade data → Breeze envelopes            │
   │                    │                                          │
   │   transport: gzip newline-JSON → POST {IngestionEndpoint}/v2.1/track│
   │            + connection-string parse + secret handling        │
   │            + partial-success + retry/backoff (+ offline store later)│
   └──────────────────────────────────────────────────────────────┘
                    │
        Application Insights ingestion (Breeze)
```

**We own, and must build:**
1. **Config & secrets** — connection string parser → ingestion endpoint, iKey,
   live endpoint, region. Secret-safe (never logged).
2. **Breeze envelope model** — `Codable` structs: envelope (Part A tags) + each
   `baseData` (`RequestData`, `RemoteDependencyData`, `ExceptionData`,
   `MessageData`, `MetricData`), newline-delimited JSON encoder, schema constants.
3. **Generic telemetry pipeline** — `Sendable` buffer, batch processor (flush on
   size or interval), export loop, **bounded with drop-on-overflow** so a slow
   endpoint can never OOM or block the host.
4. **Resource detection** — `service.name`/`service.namespace` → `ai.cloud.role`,
   `service.instance.id`/`host.name` → `ai.cloud.roleInstance`, SDK version tag.
5. **Facade adapters** — `Tracer` (swift-distributed-tracing, incl. W3C
   traceparent inject/extract), `MetricsFactory` (swift-metrics), `LogHandler`
   (swift-log).
6. **Translation** — the fiddly core; see §6.
7. **Transport & reliability** — async HTTP (`async-http-client` on Linux), gzip,
   POST, partial-success parsing, `Retry-After`/backoff; disk-backed offline store
   and ingestion sampling as later hardening.

**Proposed modules:** `StoutCore` (config, envelope model, pipeline,
resource, transport) · `StoutTracing` · `StoutLogging` ·
`StoutMetrics` · `StoutLiveMetrics` · `Stout` (distro
convenience bootstrap).

---

## 6. The translation table (where the time goes)

Port the *logic* from the MIT-licensed .NET exporter (§8) — not the code.

**Span kind → envelope type:** `.server`/`.consumer` → `RequestData`;
`.client`/`.producer`/`.internal` → `RemoteDependencyData`.

**Part A tags:** `ai.operation.id` ← trace ID; `ai.operation.parentId` ← parent
span ID; `ai.cloud.role` ← service name/namespace; `ai.cloud.roleInstance` ←
instance/host; `ai.internal.sdkVersion` ← `stout:<version>`.

**RequestData (server):** id←spanId, name, duration, responseCode (from
`http.response.status_code`/`rpc.grpc.status_code`), success, url, source;
attributes → properties.

**RemoteDependencyData (client):** id, name, duration, resultCode, success, data
(`http.url`/`db.statement`), target (host/`db.name`/`peer.service`), type
(HTTP/SQL/`db.system`/queue).

**Span events:** `exception` event → `ExceptionData`; others → `MessageData`.
**Logs:** `LogHandler` records → `MessageData` (or `ExceptionData`); severity
mapping; correlate to active span. **Metrics:** → `MetricData` (value/count/min/max
for histograms); dimensions → properties.

**Sampling:** App Insights fixed-rate ingestion sampling via envelope `sampleRate`
+ `itemCount`. Defer past traces MVP, but carry `sampleRate` in the model from day 1.

---

## 7. Live Metrics (QuickPulse) — feasible, but a separate later phase

**Verdict: worth doing, not a shite idea — but it is NOT an OTel/OTLP feature.** It
is a proprietary Azure Monitor side-channel (**QuickPulse**), implemented alongside
(not through) the OTel pipeline. You cannot stream it via OTLP.

- **Fully separate from Breeze:** own endpoint (`LiveEndpoint` →
  `livediagnostics.monitor.azure.com`), own data model (`MonitoringDataPoint`,
  `DocumentIngress`), own HTTP pipeline. Shares only the connection string.
- **Stateful bidirectional protocol:** `/ping?ikey=…` polls "is anyone watching?"
  (service answers via `x-ms-qps-subscribed` header); if subscribed, transition to
  `/post` streaming ~1s samples; back off to ping when the blade closes. Plus
  server-driven control headers (endpoint redirect, polling-interval hint) and
  ETag-gated config sync.
- **Not publicly documented** — the wire contract must be lifted from the
  MIT-licensed .NET sources (`Azure.Monitor.OpenTelemetry.LiveMetrics`, and the
  legacy `ApplicationInsights-dotnet-server` QuickPulse code for the filtering DSL).
- **Effort: ~2–3× the core trace exporter,** skewed toward fiddly protocol
  reverse-engineering + a client-side **filtering DSL** (parse
  `CollectionConfigurationInfo` → evaluate `DerivedMetricInfo` filters locally).
- **Phasing decision:** its own spec, sequenced **after** traces/logs/metrics. A
  v1 implements the ping/post state machine + metrics-only `MonitoringDataPoint`
  and **defers the filtering DSL** (degrades gracefully — just can't honor
  portal-side custom filters). Plan for **Entra token auth** on the control channel
  (API-key auth for Live Metrics is being retired).

---

## 8. Reference: the .NET exporter (MIT — safe to study & port)

Repo `Azure/azure-sdk-for-net`. **MIT-licensed**, so we read it and reimplement the
logic (different language; the value is the algorithm + schema constants).

- Breeze exporter: `sdk/monitor/Azure.Monitor.OpenTelemetry.Exporter` —
  `src/Internals/TraceHelper.cs` (span → item),
  `ActivityExtensions.cs` / `ActivityTagsProcessor.cs` (tags → Part B/C),
  `SchemaConstants.cs` (schema constants **and the exact `/track` path**).
- Live Metrics: `sdk/monitor/Azure.Monitor.OpenTelemetry.LiveMetrics` (tag
  `…LiveMetrics_1.0.0-beta.3`); legacy filtering DSL in
  `microsoft/ApplicationInsights-dotnet-server` → `.../QuickPulse/`.

---

## 9. Phased plan

- **Phase 0 — Package skeleton.** SwiftPM package, module layout (§5), CI (Linux +
  macOS, Swift 6), lint/format, license, security policy, contribution guide.
- **Phase 1 — Core + Traces MVP.** Config/secrets, envelope model, pipeline,
  resource, transport + basic retry (**core**); `Tracer` + span→Request/Dependency
  translation + traceparent propagation (**traces**). Success: a Swift service's
  spans appear in App Insights with correct request/dependency correlation.
- **Phase 2 — Logs.** `LogHandler` → Message/Exception, severity, span correlation.
- **Phase 3 — Metrics.** `MetricsFactory` → `MetricData`, histograms/dimensions.
- **Phase 4 — Hardening.** Partial-success, `Retry-After`/backoff, disk-backed
  offline store, ingestion sampling, Entra/AAD auth.
- **Phase 5 — Live Metrics.** QuickPulse ping/post + metrics-only v1 (defer DSL).
- **Phase 6 — Distro convenience layer.** One-call bootstrap from a connection
  string; optional Vapor/Hummingbird middleware.
- **Deferred / maybe-never:** statsbeat, the Live Metrics filtering DSL.

**Effort:** Core+Traces MVP ~1–2 weeks focused. Full multi-signal parity with
hardening ~a couple of months. Live Metrics adds ~2–3× the core exporter on its
own timeline. Plus ongoing maintenance to track OTel semantic-convention drift.

---

## 10. Risks & open questions

- **We own the SDK layer** (batching/resource/propagation) — bounded but real;
  Option C (vendor a swift-otel slice) is the escape hatch if the batch loop drags.
- ~~`/v2/track` vs `/v2.1/track`~~ — **resolved: `/v2.1/track`** (see §12).
- **Swift 6.1 toolchain** — confirm CI/build environment.
- **Semantic-convention drift** — the span→Breeze mapping tracks evolving OTel
  HTTP/DB/messaging conventions.
- **Live Metrics protocol is undocumented** — lifted from MIT .NET source; carries
  maintenance risk if the internal contract changes.
- **`async-http-client` dependency** — confirm acceptable as the one runtime dep.

---

## 11. Resolved design decisions (interview log)

Decisions taken with the maintainer, binding on the specs below:

- **D1 — Lifecycle / shutdown contract.** Exporters are independently-constructable,
  injectable objects (for DI and testability); the global `bootstrap()` is a thin
  layer on top. `shutdown()` follows **drain-and-go-inert**: flush all buffered
  telemetry, stop export loops, close the HTTP client; the (un-removable) installed
  handlers become safe no-ops. Post-shutdown emission is **dropped after a single
  rate-limited warning** via the library's internal diagnostics channel — never the
  user telemetry pipeline, never any payload. (Forced by the SSWG facades'
  once-only, irreversible `bootstrap`.)
- **D2 — Ingestion path.** `POST {IngestionEndpoint}/v2.1/track`; envelope `ver` = 1
  (omitted on wire), `data.baseData.ver` = 2. Matches the .NET OTel exporter.
- **D3 — ServiceLifecycle.** Shipped as an **optional additive target**
  (e.g. `StoutServiceLifecycle`), never a core dependency. Core offers
  dependency-free graceful shutdown (D1); the target adds ordered start/stop for
  swift-service-lifecycle users who opt in.
- **D4 — Metrics semantics.** Export uses **delta** values per flush (dictated by
  App Insights' sum-aggregation of interval data; cumulative would double-count).
  **Idle counters emit nothing by default** (no data point when unchanged),
  configurable to emit zeros. Dimension **cardinality is bounded by an overflow
  bucket**: past a configurable per-metric cap, new dimension combinations fold into
  a single `{otel.metric.overflow = true}` series — preserving correct grand totals,
  sacrificing only the tail's per-dimension breakdown — with a rate-limited warning.
  Aligns with OpenTelemetry's cardinality-limit design.
- **D5 — Naming & license.** Library renamed to **Stout** (package `stout`; modules
  `Stout`/`StoutCore`/`StoutTracing`/`StoutLogging`/`StoutMetrics`/`StoutLiveMetrics`/`StoutServiceLifecycle`).
  Licensed **Apache-2.0**. Published under the **Stonefly Labs** GitHub org.
- **D6 — CI runner (interim).** CI runs on a **self-hosted** GitHub Actions runner
  for now (`runs-on: [self-hosted]`); GitHub-hosted Linux+macOS matrix and Linux
  coverage to be added once runners are available.

## 12. Sources

- swift-otel: https://github.com/swift-otel/swift-otel
- SSWG facades: https://github.com/apple/swift-log · https://github.com/apple/swift-metrics · https://github.com/apple/swift-distributed-tracing
- App Insights OTel enablement: https://learn.microsoft.com/en-us/azure/azure-monitor/app/opentelemetry-enable
- OTLP-into-Azure-Monitor status (preview): https://learn.microsoft.com/en-us/azure/azure-monitor/containers/opentelemetry-summary
- Breeze endpoint protocol: https://github.com/MohanGsk/ApplicationInsights-Home/blob/master/EndpointSpecs/ENDPOINT-PROTOCOL.md
- .NET Breeze exporter (MIT): https://github.com/Azure/azure-sdk-for-net/tree/main/sdk/monitor/Azure.Monitor.OpenTelemetry.Exporter/src/Internals
- Live Metrics / Live Stream: https://learn.microsoft.com/en-us/azure/azure-monitor/app/live-stream
- .NET Live Metrics (MIT): https://github.com/Azure/azure-sdk-for-net/tree/Azure.Monitor.OpenTelemetry.LiveMetrics_1.0.0-beta.3/sdk/monitor/Azure.Monitor.OpenTelemetry.LiveMetrics
