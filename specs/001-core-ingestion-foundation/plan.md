# Implementation Plan: Core Ingestion Foundation

**Branch**: `001-core-ingestion-foundation` | **Date**: 2026-07-09 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/001-core-ingestion-foundation/spec.md`

## Summary

Build the signal-agnostic substrate every Stout exporter depends on: connection-string config +
secrets, the Breeze envelope framework with a `baseData` extension seam, a bounded async
buffer→batch→gzip→POST pipeline with drain-and-go-inert shutdown, resource→Part A tag detection, and a
`Sendable` HTTP transport abstraction (URLSession on Apple, async-http-client on Linux). Technical
approach is fixed by the resolved research: **one code path for gzip via system zlib** (no new SPM
dependency), an **actor-isolated pipeline** with a `nonisolated` non-blocking submit, and the
**`opentelemetry-swift-core`** package for the `Resource` type only (signal exporter protocols belong
to specs 02–04). All wire/retry behavior mirrors the MIT-licensed .NET exporter.

## Technical Context

**Language/Version**: Swift 6 (tools 6.0, language mode v6, strict concurrency complete)

**Primary Dependencies**: `opentelemetry-swift-core` (`OpenTelemetrySdk`/`OpenTelemetryApi`, `from:
2.5.0`) for the `Resource` data type; `async-http-client` (`from: 1.21.0`, **Linux-only**,
conditional); **system zlib** (Apple SDK `zlib` module / Linux `.systemLibrary` — no SPM package);
Foundation/URLSession (Apple).

**Storage**: N/A for this feature (in-memory bounded buffer only; durable disk-backed store is a later
hardening spec, out of scope).

**Testing**: XCTest. Must run on **an Apple platform (iOS Simulator / macOS) AND Linux** — both
transport backends and Foundation differences exercised (FR/SC-007, constitution IV).

**Target Platform**: iOS 13+, macOS 12+, watchOS 6+, tvOS 13+, visionOS 1+, and Linux (Glibc,
swift-corelibs-foundation) — per `Package.swift` and design D7.

**Project Type**: Swift library (SwiftPM multi-module package). This feature is entirely within the
`StoutCore` target (+ a Linux-only `CZlib` systemLibrary target).

**Performance Goals**: `submit` returns without awaiting network I/O in 100% of cases (SC-001);
bounded memory ≤ configured buffer capacity under sustained overload (SC-003); flush on size (512) or
interval (5 s).

**Constraints**: No `fatalError`/`try!`/force-unwrap/blocking-I/O on host-reachable paths
(constitution II); bounded memory & retry (no unbounded growth anywhere); Sendable-clean, zero
data-race warnings (constitution III); secrets never logged/surfaced (constitution I); HTTPS-only.

**Scale/Scope**: One SwiftPM target's worth of code (~10–15 source files) + a matching XCTest suite;
default buffer 2048 items; batches ≤512.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution v1.0.0. This feature is the credential-handling, host-embedded core — the principles bite
hardest here. Gates:

| Principle | Gate for this feature | Status |
|---|---|---|
| **I. Security-First** (NON-NEG) | Secrets (conn string, iKey, tokens) never logged/in errors/in diagnostics; redacting debug output; validate + fail closed; HTTPS-only; deps limited to OTel-core + async-http-client(Linux) + system zlib (no new package). | ✅ PASS — FR-028/029/032; `ConnectionStringError` is secret-free by construction; zlib adds no package (R1). |
| **II. Resilience & Do-No-Harm** (NON-NEG) | No crash/block/unbounded wait on host paths; bounded buffer w/ drop-on-overflow; bounded in-memory retry; drain-and-go-inert; telemetry loss preferred over host impact. | ✅ PASS — FR-012/014/015/016/031; actor pipeline w/ nonisolated submit (R5); no `fatalError`/`try!`. |
| **III. Concurrency Safety** (NON-NEG) | All boundary-crossing types `Sendable`; actor-guarded mutable state; no `@unchecked` without justification; builds under strict concurrency on Apple + Linux. | ✅ PASS — FR-030; actor model (R5); zlib contained in a sync value-type fn. |
| **IV. Quality & Testing** | Tests for parsing (all invalid variants), envelope/newline-JSON wire correctness, gzip round-trip, flush-on-size/interval, drop-on-overflow accounting, shutdown, tag mapping/override, every transport failure path; CI green on Linux + Apple; public API documented. | ✅ PASS — SC-001..007; failure-path + golden tests planned (see quickstart). |
| **V. API Stewardship** | Explicit public/internal boundary; SemVer; non-consumer types stay non-public. | ✅ PASS — FR-033; contracts/public-api.md defines the surface. |
| **VI. Fidelity** | Breeze envelope structure/iKey/path/sampleRate + retry/endpoint/role-name behavior verified against the MIT .NET reference; golden/round-trip tests. | ✅ PASS — Clarifications confirmed vs .NET; contracts/ingestion-wire.md + golden tests. |
| **VII. OSS Governance** | Apache-2.0; correct attribution; self-diagnostics never leak customer data/secrets. | ✅ PASS — FR-028; zlib is system lib (no vendoring); diagnostics channel is secret-free (data-model §10). |

**Result: PASS — no violations, Complexity Tracking not required.** Re-checked post-design (Phase 1):
still PASS — the actor + system-zlib + transport-protocol design introduces no principle conflict and
no new dependency.

## Project Structure

### Documentation (this feature)

```text
specs/001-core-ingestion-foundation/
├── plan.md              # This file
├── spec.md              # Feature spec (+ Clarifications)
├── research.md          # Phase 0 — decisions (gzip, OTel surface, transport, encoding, concurrency)
├── data-model.md        # Phase 1 — entities
├── quickstart.md        # Phase 1 — validation/run guide
├── contracts/           # Phase 1 — API + wire contracts
│   ├── public-api.md
│   ├── transport.md
│   └── ingestion-wire.md
└── checklists/
    └── requirements.md  # Spec quality checklist (16/16)
```

### Source Code (repository root)

This feature lives entirely in the existing `StoutCore` target, plus a new Linux-only `CZlib`
systemLibrary target. Sibling targets (`StoutTracing`/`Logging`/`Metrics`/`Stout`/…) already exist as
scaffolds and are untouched by this feature (they consume the seam in later specs).

```text
Sources/
├── StoutCore/                      # ← all feature work here
│   ├── Configuration/
│   │   └── ConnectionConfiguration.swift   # parse + validate + endpoint precedence (FR-001..005)
│   ├── Envelope/
│   │   ├── Envelope.swift                   # envelope + DataContainer (FR-006..009)
│   │   ├── BaseData.swift                   # extension seam (FR-007)
│   │   ├── EnvelopeFactory.swift            # Part A stamping (FR-007)
│   │   └── TelemetryTags.swift              # Part A tag model
│   ├── Resource/
│   │   └── ResourceDetector.swift           # resource → tags, override precedence (FR-018..021)
│   ├── Pipeline/
│   │   ├── ExportPipeline.swift             # actor buffer+loop+lifecycle (FR-011..017)
│   │   ├── ExporterConfiguration.swift      # tuning knobs + defaults (FR-017)
│   │   └── RetryPolicy.swift                # classification, Retry-After, backoff (FR-024..027)
│   ├── Transport/
│   │   ├── Transport.swift                  # Sendable protocol + request/response (FR-022/023)
│   │   ├── URLSessionTransport.swift        # #if !FoundationNetworking (Apple)
│   │   └── AsyncHTTPClientTransport.swift   # #if FoundationNetworking (Linux)
│   ├── Compression/
│   │   └── Gzip.swift                       # system-zlib wrapper, MAX_WBITS+16 (R1, FR-010)
│   ├── Ingestion/
│   │   └── IngestionResponse.swift          # itemsReceived/Accepted/errors parse (FR-024)
│   └── Diagnostics/
│       └── Diagnostics.swift                # secret-free internal channel (FR-016/028)
└── CZlib/                          # ← new, Linux-only systemLibrary target
    ├── module.modulemap                     # module CZlib [system] { header "shim.h" link "z" }
    └── shim.h                               # #include <zlib.h>

Tests/
└── StoutCoreTests/
    ├── ConnectionStringTests.swift          # valid + every invalid variant, secret-free (Acc #1/2/11)
    ├── EnvelopeEncodingTests.swift          # newline-JSON + field/timestamp wire correctness (Acc #3)
    ├── GzipRoundTripTests.swift             # compress/decompress identity (Acc #3, SC-004)
    ├── PipelineFlushTests.swift             # flush on size + on interval (Acc #4)
    ├── OverflowTests.swift                  # drop-on-overflow accounting (Acc #5, SC-003)
    ├── ShutdownTests.swift                  # drain-and-go-inert, idempotent, one warning (Acc #6)
    ├── ResourceTagsTests.swift              # role/instance/device tags + override precedence (Acc #10)
    ├── RetryClassificationTests.swift       # partial success, Retry-After, backoff, retriable set (Acc #8/9)
    └── TransportContractTests.swift         # mock transport: path/headers/body; 200=success (Acc #7)
```

**Structure Decision**: Single existing SwiftPM target (`StoutCore`) — no new product, matching the
locked module graph (CLAUDE.md / design §5). The only manifest change is appending a Linux-only
`CZlib` `.systemLibrary` target and adding it to `StoutCore`'s dependencies under a `#if os(Linux)`
guard (R1). Signal modules and the umbrella are out of scope and unchanged.

## Complexity Tracking

> No constitution violations — this section intentionally empty.
