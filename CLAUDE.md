# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**Stout** is a **collector-free** Azure Monitor / Application Insights telemetry
exporter for **server-side Swift** (Linux + macOS, Swift 6). It lets a Swift
service send traces, metrics, and logs **directly** to Application Insights — no
OpenTelemetry Collector, no Azure Monitor Agent — the way the .NET/Java/Node/Python
Azure Monitor distros do.

Public OSS library, **Apache-2.0**, at `Stonefly-Labs/Stout`. Pre-release: Phase 0
(scaffold) is done; feature work runs through Spec Kit.

## Prime directive

**Security, stability, and quality are the #1 priorities at all times — over speed
or feature count.** This is a public library that handles credentials and runs in
customers' production services. Non-negotiable:

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

## Architecture — approach "B2" (full detail in `docs/design.md`)

We do **NOT** depend on swift-otel (its exporter protocols are internal/not public).
Instead we implement the **Swift Server Working Group observability facades directly**
and own the SDK layer:

- Backends we implement: `Tracer` (swift-distributed-tracing), `MetricsFactory`
  (swift-metrics), `LogHandler` (swift-log).
- We own: the batching pipeline, resource detection, and transport.
- We translate facade data → Application Insights **"Breeze"** envelopes → gzip
  newline-JSON → `POST {IngestionEndpoint}/v2.1/track`.

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

| Module | Role |
|---|---|
| `StoutCore` | config/secrets, Breeze envelope model, batch pipeline, resource detection, transport (deps: async-http-client; swift-log for internal diagnostics only) |
| `StoutTracing` | `Tracer` backend + span→Request/Dependency translation + W3C propagation |
| `StoutLogging` | `LogHandler` backend + Message/Exception + trace correlation |
| `StoutMetrics` | `MetricsFactory` backend → MetricData |
| `StoutLiveMetrics` | QuickPulse real-time channel (separate) |
| `Stout` | umbrella one-call distro bootstrap |
| `StoutServiceLifecycle` | optional additive target — the ONLY place swift-service-lifecycle is a dependency |

## Locked decisions

`docs/design.md §11` (D1–D6): D1 drain-and-go-inert shutdown (handlers go inert,
post-shutdown emit dropped after one internal-diagnostics warning); D2 `/v2.1/track`;
D3 ServiceLifecycle optional-only; D4 delta metrics + idle-emit-nothing +
overflow-bucket cardinality; D5 name/license/org; D6 self-hosted CI (interim).

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
concurrency complete.

## Git & CI

- `main` is **protected** — no direct pushes. Flow: branch → PR → CI green → merge
  (0 approvals; you can self-merge). Linear history; no force-push/deletion.
- Required checks: **Build & Test** + **Lint (swift-format)**; branch must be
  up to date.
- CI runs on a **self-hosted** runner (interim, macOS-only for now). **Linux
  coverage is a known TODO** and matters — this is a server-side lib (Glibc,
  swift-corelibs-foundation, NIO transport differences).
- End commit messages with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

## Gotchas

- Do not reintroduce a swift-otel dependency or a collector — collector-free is the
  entire point.
- Don't conflate the Azure service names ("Azure Monitor", "Application Insights")
  with our `Stout*` modules, or the .NET reference types.
- The transport gzip strategy is still open (`[PLAN]` in spec 01): system `zlib` vs
  a Swift compression package.
- `.claude/settings.local.json` is gitignored (local/secrets) — never commit it.
