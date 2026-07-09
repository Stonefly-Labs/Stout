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

- ☐ **`Package.swift`**, `swift-tools-version:6.0`, `swiftLanguageModes: [.v6]`,
  strict concurrency **complete**.
- ☑ Platforms: `.macOS(.v13)` for Apple platforms; Linux supported implicitly
  (server-side; no iOS/tvOS/watchOS — this is not a mobile SDK). **(decided)**
- ☑ Package name `stout`; products & modules `Stout*` (below). **(decided — D5)**

## 2. Module graph (targets)

Mirrors `design.md §5`. Each library target has a sibling `…Tests` target.

| Target | Kind | Depends on | Notes |
|---|---|---|---|
| `StoutCore` | library | async-http-client, swift-log¹, NIO | config, Breeze envelope model, pipeline, resource, transport |
| `StoutTracing` | library | Core, swift-distributed-tracing | `Tracer`/`Instrument` backend |
| `StoutLogging` | library | Core, swift-log | `LogHandler` backend |
| `StoutMetrics` | library | Core, swift-metrics | `MetricsFactory` backend |
| `StoutLiveMetrics` | library | Core | QuickPulse channel (separate) |
| `Stout` | library | Tracing, Logging, Metrics (+ LiveMetrics opt) | one-call distro bootstrap |
| `StoutServiceLifecycle` | library | `Stout`, swift-service-lifecycle | **optional additive target (D3)** — the ONLY place swift-service-lifecycle is a dependency |

¹ swift-log in Core is for the library's **internal diagnostics** channel (D1
warn-once), never the user's telemetry pipeline.

- ☐ Products: expose `Stout` (umbrella) + each signal module + the optional
  `StoutServiceLifecycle` as separate products so consumers pay only for
  what they import.

## 3. Dependencies (pins)

- ☐ `apple/swift-log`
- ☐ `apple/swift-metrics`
- ☐ `apple/swift-distributed-tracing`
- ☐ `swift-server/async-http-client`
- ☐ `swift-server/swift-service-lifecycle` — **only** for the optional target
- ☐ **[PLAN]** gzip strategy — system `zlib` via a C target vs a Swift compression
  package. Needed by Core transport; decide in spec 01's plan.
- Keep the dependency set **minimal and audited** (constitution). Every add is a
  reviewed decision.

## 4. CI (GitHub Actions)

- ☑ **Runner (interim — D6):** `runs-on: [self-hosted]` — the maintainer registers
  a self-hosted runner on the repo. CI stays red until that runner is online.
- ☑ **Jobs:** `swift build` + `swift test`; plus a lint gate
  `swift format lint --strict --recursive Sources Tests`.
- ☐ **[LATER]** Move to a GitHub-hosted **Linux + macOS** matrix (official
  `swift:6.x` images + `macos-14`) once runners are available — Linux coverage
  matters for a server-side lib. Optional Swift-6.1/nightly early-warning leg then.
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
2. **Apple platform floor** — macOS 13 ✅
3. **Swift tools floor** — 6.0, language mode v6 ✅
4. **Security contact** — GitHub private vulnerability reporting ✅
5. **GitHub** — `Stonefly-Labs/stout`, public, `main` ✅ (D5)
6. **CI** — self-hosted runner interim; hosted Linux+macOS matrix later ✅ (D6)

Still open (non-blocking): gzip strategy [PLAN, spec 01], `.github/` issue/PR
templates, branch protection (after runner is online).
