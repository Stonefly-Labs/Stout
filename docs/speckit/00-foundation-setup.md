# Phase 0 — Foundation Setup (checklist)

This is NOT a `/speckit.specify` prompt — Phase 0 is repo scaffolding, not a
behavioral feature. It's the concrete setup that must exist before
`/speckit.implement` produces code, captured with the same rigor the
[constitution](constitution.md) demands. See `design.md §9` (Phase 0) and `§5`
(module layout).

Legend: ☐ = to do · **[CONFIRM]** = a decision the maintainer should sign off ·
**[PLAN]** = deliberately deferred to `/speckit.plan`.

---

## 1. Package identity & manifest

- ☑ **`Package.swift`**, `swift-tools-version:6.0`, `swiftLanguageModes: [.v6]`,
  strict concurrency **complete**.
- ☑ Platforms: `.iOS(.v13)`, `.macOS(.v12)`, `.watchOS(.v6)`, `.tvOS(.v13)`,
  `.visionOS(.v1)` for Apple platforms; Linux supported implicitly. The floor
  tracks what `opentelemetry-swift` supports — Stout is a cross-platform exporter,
  NOT server-only. **(decided — D7)**
- ☑ Package name `stout`; products & modules `Stout*` (below). **(decided — D5)**

## 2. Module graph (targets)

Mirrors `design.md §5`. Each library target has a sibling `…Tests` target.

| Target | Kind | Depends on | Notes |
|---|---|---|---|
| `StoutCore` | library | `OpenTelemetrySdk`, async-http-client **(Linux only, conditional)** | config/secrets, Breeze envelope model, OTel→Breeze translation, resource, transport (URLSession on Apple / AHC on Linux) |
| `StoutTracing` | library | Core, `OpenTelemetrySdk` | `SpanExporter` implementation |
| `StoutLogging` | library | Core, `OpenTelemetrySdk` | `LogRecordExporter` implementation |
| `StoutMetrics` | library | Core, `OpenTelemetrySdk` | `MetricExporter` implementation |
| `StoutLiveMetrics` | library | Core | QuickPulse channel (separate) |
| `Stout` | library | Tracing, Logging, Metrics | umbrella: configure OTel providers + register exporters |
| `StoutServiceLifecycle` | library | `Stout`, swift-service-lifecycle | **optional additive target (D3)** — the ONLY place swift-service-lifecycle is a dependency; server-side only |

¹ Internal diagnostics use `os.Logger` on Apple / a minimal fallback — **not**
swift-log (dropped with the SSWG facades, D8).

- ☐ Products: expose `Stout` (umbrella) + each signal module + the optional
  `StoutServiceLifecycle` as separate products so consumers pay only for
  what they import.

## 3. Dependencies (pins)

- ☑ `open-telemetry/opentelemetry-swift-core` (`from: "2.5.0"`; resolves to 2.5.1)
  — products `OpenTelemetryApi` + `OpenTelemetrySdk`. This is the minimal split-out
  **core** package; it carries the public `SpanExporter`/`MetricExporter`/
  `LogRecordExporter` protocols and the `SpanData`/`ReadableLogRecord`/`MetricData`
  types, and pulls **no** OTLP/gRPC/protobuf (its only transitive dep is
  swift-atomics). StoutCore + the three signal modules depend on `OpenTelemetrySdk`.
- ☑ `swift-server/async-http-client` — **Linux-only**, attached to `StoutCore`
  conditionally via `condition: .when(platforms: [.linux])`. Apple platforms use
  URLSession (Foundation) with no package dependency (D9).
- ☑ `swift-server/swift-service-lifecycle` — **only** for the optional
  `StoutServiceLifecycle` target.
- ✂️ **Removed:** `apple/swift-log`, `apple/swift-metrics`,
  `apple/swift-distributed-tracing` — dropped with the SSWG facades (D8). Internal
  diagnostics use `os.Logger`/a minimal fallback, not swift-log.
- ☐ **[PLAN]** gzip strategy — system `zlib` via a C target vs a Swift compression
  package. Needed by Core transport; decide in spec 01's plan.
- Keep the dependency set **minimal and audited** (constitution). Every add is a
  reviewed decision.

## 4. CI (GitHub Actions)

- ☑ **Runner (interim — D6):** `runs-on: [self-hosted]` — the maintainer registers
  a self-hosted runner on the repo. CI stays red until that runner is online.
- ☑ **Jobs:** `swift build` + `swift test` (macOS); an **iOS-Simulator build leg**
  via `xcodebuild build -scheme Stout -destination 'generic/platform=iOS Simulator'`
  (generic destination, no booted simulator needed); plus a lint gate
  `swift format lint --strict --recursive Sources Tests`.
- ☐ **[TODO — outstanding] Linux leg:** macOS-alone is insufficient (D6/D7) — a
  cross-platform exporter must be tested on the iOS Simulator **and Linux**. Add a
  Linux job on official `swift:6.x` Docker images (Ubuntu Jammy + Noble) once a
  Linux runner / Docker is available, then a GitHub-hosted macOS + Linux matrix.
- ☐ **[PLAN, later phase]** API-breakage check (`--diagnose-api-breaking-changes`)
  once a baseline tag exists.

## 5. OSS governance files (constitution-mandated)

- ☑ **`LICENSE`** — **Apache-2.0 (decided — D5).** Copyright holder "Stonefly Labs".
- ☑ **`SECURITY.md`** — primary channel: **GitHub private vulnerability reporting**
  ("Security" → "Report a vulnerability"); no public issues for vulns. (An email
  contact can be added later if desired.)
- ☐ **`CONTRIBUTING.md`** — build/test/lint instructions, DCO/sign-off policy,
  review expectations, the "restate the constitution's NFRs in every PR" rule.
- ☐ **`CODE_OF_CONDUCT.md`** — Contributor Covenant.
- ☐ **`README.md`** — one-paragraph pitch, status (pre-release), quickstart stub,
  supported platforms, link to `docs/design.md`.
- ☐ **`.gitignore`** — Swift (`.build/`, `.swiftpm/`, `*.xcodeproj`, `DerivedData/`).
- ☐ **`.spi.yml`** — Swift Package Index manifest (discoverability) — optional but
  cheap.
- ☐ **[CONFIRM]** `.github/` issue + PR templates?

## 6. Repo & remote

- ☑ Remote: **`Stonefly-Labs/stout`**, **public**, default branch `main` (already
  created with GitHub boilerplate; scaffold layers on top of the initial commit).
- ☐ `git init` locally, layer scaffold on `origin/main`, commit, push.
- ☐ Enable branch protection on `main` (require CI + review) once the runner is up.

## 7. Definition of done for Phase 0

- `swift build` and `swift test` pass locally on macOS with an empty-but-wired
  module graph (each target compiles with a placeholder + one trivial test).
- CI is green on the self-hosted runner (Linux + macOS matrix to follow — D6).
- `swift-format lint --strict` passes.
- All governance files present.
- Repo pushed to GitHub with branch protection.

---

## Decisions — RESOLVED

1. **License** — Apache-2.0 ✅ (D5)
2. **Platforms** — iOS 13 / macOS 12 / watchOS 6 / tvOS 13 / visionOS 1 + Linux ✅ (D7)
3. **Swift tools floor** — 6.0, language mode v6 ✅
4. **Security contact** — GitHub private vulnerability reporting ✅
5. **GitHub** — `Stonefly-Labs/stout`, public, `main` ✅ (D5)
6. **CI** — self-hosted runner interim; macOS + iOS-Simulator legs today, Linux leg
   still TODO; hosted macOS+Linux matrix later ✅ (D6)
7. **SDK** — build on `opentelemetry-swift-core` (`OpenTelemetryApi`/`OpenTelemetrySdk`),
   implement its public exporter protocols; dropped swift-log/metrics/distributed-tracing ✅ (D8)
8. **Transport** — URLSession on Apple / async-http-client on Linux (conditional dep) ✅ (D9)

Still open (non-blocking): gzip strategy [PLAN, spec 01], `.github/` issue/PR
templates, branch protection (after runner is online).
