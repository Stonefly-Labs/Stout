# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**Stout** is a **collector-free** Azure Monitor / Application Insights telemetry
**exporter for `opentelemetry-swift`** (the OpenTelemetry Swift SDK). It runs
everywhere `opentelemetry-swift` runs — **iOS, macOS, watchOS, tvOS (+ visionOS),
and Linux** — not server-side only. It lets a Swift app or service send traces,
metrics, and logs **directly** to Application Insights — no OpenTelemetry
Collector, no Azure Monitor Agent — the same model as the .NET
`Azure.Monitor.OpenTelemetry.Exporter`.

The front door is `opentelemetry-swift`: consumers instrument their app with the
OpenTelemetry Swift SDK, and Stout implements its **public**
`SpanExporter` / `MetricExporter` / `LogRecordExporter` protocols and translates the
OTel data to the Application Insights **"Breeze"** schema. Swift 6.

Public OSS library, **Apache-2.0**, at `Stonefly-Labs/Stout`. Pre-release: Phase 0
(scaffold) is done and being re-platformed for iOS + all-Apple + Linux; feature work
runs through Spec Kit.

## Prime directive

**Security, stability, and quality are the #1 priorities at all times — over speed
or feature count.** This is a public library that handles credentials and runs
inside customers' apps and production services — including **on end-user devices**.
Non-negotiable:

- **Secrets** (connection strings, instrumentation keys, Entra tokens) are NEVER
  logged, NEVER in error messages, NEVER in the library's own self-diagnostics or
  telemetry. Validate and **fail closed**. HTTPS-only endpoints.
- **Do no harm to the host**: telemetry failures must never crash, block, or degrade
  the host app. **Bounded** memory & disk (drop/evict-on-overflow, never unbounded).
  Robust retry/backoff/circuit-breaking.
- **Swift 6 strict concurrency**: `Sendable`, no data races.
- **Quality**: high test coverage incl. translation tables and failure paths;
  SemVer; clear public API boundaries; documented behavior.

Full governing principles: `docs/speckit/constitution.md`. Every PR must uphold them.

## Architecture — exporter for opentelemetry-swift (D8; full detail in `docs/design.md`)

We build **on `opentelemetry-swift`** (the OpenTelemetry Swift SDK), implementing its
**public** exporter protocols — the same model as .NET's
`Azure.Monitor.OpenTelemetry.Exporter`:

- Front door: the consumer instruments with `opentelemetry-swift`
  (`TracerProvider` / `LoggerProvider` / `MeterProvider`) and registers Stout's
  exporters. `opentelemetry-swift` supplies the on-device Darwin instrumentations
  (URLSession HTTP spans, MetricKit, NetworkStatus, sessions); server users add
  their own. Stout is the **exporter**, not an instrumentation library.
- Exporters we implement: `SpanExporter`, `MetricExporter`, `LogRecordExporter`
  (all public in `opentelemetry-swift`) — no forking, no internal-API wall.
- We own: resource detection, the export pipeline, and transport.
- We translate OTel data (`SpanData` / `ReadableLogRecord` / `MetricData`) →
  Application Insights **"Breeze"** envelopes → gzip newline-JSON →
  `POST {IngestionEndpoint}/v2.1/track`.

> This **supersedes the earlier "B2 / SSWG-facades" design** (implementing
> `swift-log` / `swift-metrics` / `swift-distributed-tracing` backends for a
> server-only lib) — those facades don't fit iOS. See `design.md` §3, §11 D8.
> Do NOT reintroduce the swift-log/metrics/distributed-tracing facade dependencies.
> Trade-off (accepted): in `opentelemetry-swift`, Traces are Stable but Logs/Metrics
> are Beta/Development — we phase **traces-first** and knowingly ride the beta APIs.

Key facts:
- Breeze envelope `ver` = 1 (omitted on wire); each `data.baseData.ver` = 2.
- Connection string supplies `InstrumentationKey` (→ envelope `iKey`),
  `IngestionEndpoint`, `LiveEndpoint`.
- **Live Metrics is NOT OTel** — it's the proprietary **QuickPulse** channel
  (separate endpoint/protocol/data model). See `design.md §7`.
- Port mapping **logic** (not code — different language) from the MIT-licensed .NET
  exporter: `Azure/azure-sdk-for-net` →
  `sdk/monitor/Azure.Monitor.OpenTelemetry.Exporter/src/Internals/`.

## Module graph

Common deps: `OpenTelemetrySdk` (from `opentelemetry-swift`, for the exporter
protocols + `SpanData`/`ReadableLogRecord`/`MetricData`), and the transport split —
**URLSession** (Foundation) on Apple, **async-http-client** on Linux only
(conditional). No swift-log/metrics/distributed-tracing facades.

| Module | Role | Key deps |
|---|---|---|
| `StoutCore` | config/secrets, Breeze envelope model, shared translation, transport abstraction, resource detection, internal diagnostics | `OpenTelemetrySdk`; URLSession (Foundation); `async-http-client` (Linux only, conditional) |
| `StoutTracing` | `SpanExporter` → Request/Dependency/Exception translation | `StoutCore`, `OpenTelemetrySdk` |
| `StoutLogging` | `LogRecordExporter` → Message/Exception + trace correlation | `StoutCore`, `OpenTelemetrySdk` |
| `StoutMetrics` | `MetricExporter` → MetricData | `StoutCore`, `OpenTelemetrySdk` |
| `StoutLiveMetrics` | QuickPulse real-time channel (separate) | `StoutCore` |
| `Stout` | umbrella: configure the OTel providers + register Stout exporters from a connection string | the three + core |
| `StoutServiceLifecycle` | optional additive **server-side** target — the ONLY place swift-service-lifecycle is a dependency (iOS uses app-lifecycle hooks) |

## Locked decisions

`docs/design.md §11` (D1–D9): D1 drain-and-go-inert shutdown (exporters go inert,
post-shutdown emit dropped after one internal-diagnostics warning); D2 `/v2.1/track`;
D3 ServiceLifecycle optional-only (server-side; iOS uses app lifecycle); D4 delta
metrics + idle-emit-nothing + overflow-bucket cardinality; D5 name/license/org;
D6 self-hosted CI interim (must add iOS-simulator + Linux legs); **D7 platforms —
iOS + macOS + watchOS + tvOS (+ visionOS) + Linux, not server-only**; **D8 SDK —
build on `opentelemetry-swift`, implement its public
`SpanExporter`/`MetricExporter`/`LogRecordExporter`, translate to Breeze; supersedes
B2 (SSWG facades)**; **D9 transport — one `Sendable` abstraction: URLSession on
Apple, async-http-client on Linux (`#if canImport(FoundationNetworking)`); we gzip
request bodies; background upload Apple-only**.

## Development workflow — Spec Kit (commands are **hyphenated**)

`/speckit-constitution` → `/speckit-specify` → `/speckit-clarify` → `/speckit-plan`
→ `/speckit-tasks` → `/speckit-implement`. Specs are in `docs/speckit/specs/` and go
**in order 01 → 07** (core first — everything builds on it). Phase 0 checklist:
`docs/speckit/00-foundation-setup.md`. Remaining `[NEEDS CLARIFICATION]` markers in
specs are intended tunables for `/speckit-clarify`.

## Build / test / lint

```sh
swift build
swift test
swift format lint --strict --recursive Sources Tests   # must pass; 2-space indent
```

Tests currently use XCTest. Targets Swift tools 6.0, language mode v6, strict
concurrency complete. **Testing must cover the iOS Simulator AND Linux**, not just
macOS — platform-specific transport (URLSession vs async-http-client) and Foundation
differences are real.

## Git & CI

- `main` is **protected** — no direct pushes. Flow: branch → PR → CI green → merge
  (0 approvals; you can self-merge). Linear history; no force-push/deletion.
- Required checks: **Build & Test** + **Lint (swift-format)**; branch must be
  up to date.
- CI runs on a **self-hosted** runner (interim, macOS-only for now). It **must add
  iOS-simulator + Linux legs** — macOS alone is insufficient. iOS matters (the whole
  point is on-device) and Linux matters (Glibc, swift-corelibs-foundation,
  async-http-client transport differences).
- End commit messages with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

## Gotchas

- Do not reintroduce a collector or a gateway — collector-free (direct-to-Breeze) is
  the entire point. (We DO depend on `opentelemetry-swift` for its exporter
  protocols; we do NOT reintroduce the swift-log/metrics/distributed-tracing
  facades.)
- Don't conflate the Azure service names ("Azure Monitor", "Application Insights")
  with our `Stout*` modules, or the .NET reference types.
- The transport gzip strategy is still open (`[PLAN]` in spec 01): system `zlib` vs
  a Swift compression package.
- `.claude/settings.local.json` is gitignored (local/secrets) — never commit it.
