# Implementation Plan: Distributed Tracing Exporter

**Branch**: `feat/spec02-distributed-tracing` | **Date**: 2026-07-10 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/002-distributed-tracing/spec.md`

## Summary

Implement `opentelemetry-swift`'s public `SpanExporter` protocol as an Azure Monitor
exporter in the `StoutTracing` module. Finished `SpanData` is translated by a pure,
table-driven mapper into Breeze telemetry — `RequestData` (server/consumer),
`RemoteDependencyData` (client/producer/internal/unspecified), plus derived
`ExceptionData`/`MessageData` from span events — stamped into an `Envelope` by spec 01's
`EnvelopeFactory` and handed to spec 01's bounded, drop-on-overflow `ExportPipeline`.
Correlation ids (`ai.operation.id` ← trace id, `ai.operation.parentId` ← parent/owning
span id, item `id` ← span id) are mapped byte-for-byte in canonical W3C hex. The exporter
is an independently-constructable `final class` (the protocol requires `AnyObject`),
`Sendable`, non-blocking on `export(...)`, and goes inert once the pipeline shuts down.
Propagation, batching, sampling decisions, and span lifecycle stay owned by the SDK; Stout
is a terminal exporter. All translation is consumed by spec 01 primitives — nothing from
spec 01 is redefined.

## Technical Context

**Language/Version**: Swift 6 (tools 6.0, language mode v6, strict concurrency complete)

**Primary Dependencies**: `opentelemetry-swift-core` **2.5.1** (pinned) — `OpenTelemetrySdk`
(`SpanExporter`, `SpanData`, `SpanData.Event`, `SpanData.Link`, `SpanExporterResultCode`,
`Resource`) and `OpenTelemetryApi` (`SpanKind`, `Status`, `TraceId`, `SpanId`,
`AttributeValue`). Internal: `StoutCore` (spec 01) — `EnvelopeFactory`, `Envelope`,
`BaseData`, `TelemetryTags`, `PartATagKeys`, `ExportPipeline`, `Diagnostics`,
`ResourceDetector`, `StoutVersion`. No new third-party runtime dependency.

**Storage**: N/A (translation is pure; the pipeline owns the bounded in-memory buffer).

**Testing**: XCTest — `Tests/StoutTracingTests`. Table-driven translation goldens + failure
/edge paths; a mock `Transport`/`Diagnostics` and a hand-built-`SpanData` path exercise the
exporter with no live `TracerProvider` and no network.

**Target Platform**: iOS 13+, macOS 12+, watchOS 6+, tvOS 13+, visionOS 1+, and Linux
(D7). Translation is platform-agnostic; no per-platform code in this feature.

**Project Type**: Single Swift package, multi-module library. This feature fills the
`StoutTracing` target (currently a placeholder `enum`).

**Performance Goals**: `export(...)` returns promptly without blocking on network I/O or a
full buffer; translation is O(attributes + events + links) per span, allocation-modest.
No fixed latency SLO — the constraint is "never back-pressure or block the host."

**Constraints**: Non-blocking on the SDK's export path (hand off to the actor pipeline and
return); bounded memory (no buffers introduced here — overflow is spec 01's drop-on-overflow);
`Sendable`-clean under Swift 6 strict concurrency; pure/deterministic mapping (identical
input → identical output); secrets never logged; translation never throws into the host.

**Scale/Scope**: ~4 Breeze `baseData` types, one span-kind table, HTTP/DB/RPC/messaging
semantic-convention mapping tables (current + legacy keys), one `SpanExporter` conformance,
one thin provider-registration convenience. 29 FRs, 10 success criteria.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | How this feature complies | Enforced by |
|---|---|---|
| **I. Security-First** | No secrets in this feature's path; span attributes forwarded to `properties` are customer data and are never logged (FR-025). Diagnostics channel is secret-free by construction (spec 01). No new config surface; invalid config fails closed upstream (spec 01). | FR-025, SC-008; redaction tests |
| **II. Resilience & Do-No-Harm** | `export(...)` is non-blocking and never throws into the host; translation errors/malformed attributes degrade to best-effort/drop (FR-004/FR-026). No new buffers — over-capacity items are dropped by spec 01's bounded pipeline. Post-shutdown export is a safe no-op (FR-005). | FR-004/005/026, SC-009; load + shutdown tests |
| **III. Concurrency Safety** | Exporter is a `Sendable final class` holding only `Sendable` immutables (`EnvelopeFactory` value + `ExportPipeline` actor); concurrent `export(...)` is safe; no shared mutable state added. Mapper is a pure, stateless, `Sendable` function set. | FR-027, SC-010; strict-concurrency build, swift6-concurrency-auditor |
| **IV. Quality & Testing** | Table-driven goldens for the full span-kind matrix and HTTP/DB/RPC/messaging suites (current + legacy keys), plus failure/edge paths; runs on an Apple platform + Linux. Public API doc-commented. | SC-001..010; CI (macOS/iOS-sim/Linux), failure-path-test-author |
| **V. API Stewardship** | Public surface = the exporter type + a thin registration helper + the Breeze payload types; internal mapping stays non-`public`. SemVer; mapping/ownership/unknown-kind behavior documented (FR-029). | FR-029 |
| **VI. Fidelity** | Mapping mirrors the .NET Azure Monitor exporter (`TraceHelper`/`ActivityExtensions`/`ActivityTagsProcessor`): span-kind table, success predicate, type/target/data, current-over-legacy key precedence — verified in research.md and golden tests. | FR-006/011/013–018, SC-003 |
| **VII. OSS Governance** | Apache-2.0 headers on new files; ported *logic* (not code) from the MIT .NET reference is attributed in research.md. Self-diagnostics never leak customer data. | file headers, research.md attribution |

**Gate result**: PASS. No violations; Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/002-distributed-tracing/
├── plan.md              # This file (/speckit-plan output)
├── research.md          # Phase 0 output — .NET-parity decisions, SDK-shape bindings
├── data-model.md        # Phase 1 output — Breeze payloads + mapping tables
├── quickstart.md        # Phase 1 output — validation scenarios
├── contracts/           # Phase 1 output — SpanExporter + translation contracts
│   ├── span-exporter.md
│   └── span-to-breeze-mapping.md
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

The feature is contained in the existing `StoutTracing` target; no new module, product,
or dependency is added to `Package.swift`.

```text
Sources/StoutTracing/
├── StoutTracing.swift                 # (existing placeholder → module doc / namespace)
├── AzureMonitorTraceExporter.swift    # SpanExporter conformance (final class, Sendable)
├── TraceExporterRegistration.swift    # thin helper: build exporter from spec-01 pipeline + factory
├── Model/
│   ├── RequestData.swift              # BaseData — server/consumer
│   ├── RemoteDependencyData.swift     # BaseData — client/producer/internal
│   ├── ExceptionData.swift            # BaseData — from `exception` span events
│   └── MessageData.swift              # BaseData — from non-exception span events
└── Translation/
    ├── SpanTranslator.swift           # pure SpanData -> [Envelope] orchestration
    ├── SpanKindMapping.swift          # SpanKind -> envelope-type table (+ unspecified default)
    ├── CorrelationMapping.swift       # trace/span/parent ids -> ai.operation.* (shared contract, FR-024)
    ├── SuccessPredicate.swift         # .NET TraceHelper success/resultCode logic
    ├── SemanticConventions.swift      # current+legacy attribute keys, current-wins precedence
    ├── HTTPMapping.swift              # url/target/responseCode/name from HTTP conventions
    ├── DBMapping.swift                # type/target/data from DB conventions
    ├── RPCMapping.swift               # gRPC/RPC type/target/data/status
    ├── MessagingMapping.swift         # producer/consumer type/target/data + RequestData.source
    ├── EventMapping.swift             # span events -> Exception/Message items
    └── BreezeDuration.swift           # (end-start) -> Breeze "d.hh:mm:ss.fffffff" string

Tests/StoutTracingTests/
├── SpanKindMappingTests.swift
├── CorrelationMappingTests.swift      # byte-for-byte hex; root parentId absent; shared-rule (SC-007 stub)
├── RequestTranslationTests.swift
├── DependencyTranslationTests.swift
├── SuccessPredicateTests.swift        # HTTP server/client ranges, gRPC, DB, error status
├── SemanticConventionPrecedenceTests.swift  # current-over-legacy
├── HTTPMappingTests.swift / DBMappingTests.swift / RPCMappingTests.swift / MessagingMappingTests.swift
├── EventMappingTests.swift            # exception -> ExceptionData; other -> MessageData; links -> properties
├── ExporterLifecycleTests.swift       # flush forwards; post-shutdown export is a no-op drop
├── ConcurrencyTests.swift             # concurrent export(...) safe
└── Support/MockPipelineTransport.swift, SpanDataBuilder.swift  # hand-built SpanData, no TracerProvider
```

**Structure Decision**: Single package, all new code inside the existing `StoutTracing`
target and `Tests/StoutTracingTests`. Translation is split into small, pure, table-driven
files (one per protocol family) so goldens map 1:1 to a file and the mapper stays
side-effect-free and `Sendable`. The four Breeze `baseData` types live in `StoutTracing`
for this feature; `ExceptionData`/`MessageData` are shared in shape with spec 03 (Logs) —
promotion to a shared location is deferred to spec 03 and called out as a forward concern
(see research.md), not pre-built here. `CorrelationMapping` is written as the single
reusable rule spec 03 will import (FR-024) — it takes ids, not `SpanData`, so it carries no
trace-only assumptions.

## Complexity Tracking

> No constitution violations. No entries.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| — | — | — |
