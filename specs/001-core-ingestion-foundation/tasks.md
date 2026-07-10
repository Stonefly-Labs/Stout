---

description: "Task list for Core Ingestion Foundation"
---

# Tasks: Core Ingestion Foundation

**Input**: Design documents from `specs/001-core-ingestion-foundation/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: INCLUDED — the spec's Quality non-functional requirement and Constitution Principle IV
mandate high coverage of the translation tables and every failure path, and each Acceptance Criterion
is test-shaped. Tests are written before implementation within each story.

**Organization**: Tasks are grouped by user story. All work is in the `StoutCore` target (+ a
Linux-only `CZlib` systemLibrary target). Signal modules (`StoutTracing`/`Logging`/`Metrics`/…) are
out of scope for this feature and untouched.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: US1–US6 (maps to spec.md user stories)
- All paths are repo-root-relative.

## Path Conventions

Swift library (SwiftPM). Sources in `Sources/StoutCore/`, tests in `Tests/StoutCoreTests/`, manifest
`Package.swift`, Linux zlib shim in `Sources/CZlib/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Manifest wiring and target skeleton so every later task compiles.

- [X] T001 Add a Linux-only `CZlib` `.systemLibrary` target to `Package.swift` (`pkgConfig: "zlib"`, `providers: [.apt(["zlib1g-dev"])]`, appended under `#if os(Linux)`), add it to `StoutCore`'s dependencies under a `#if os(Linux)` guard, and create `Sources/CZlib/module.modulemap` (`module CZlib [system] { header "shim.h" link "z" export * }`) and `Sources/CZlib/shim.h` (`#include <zlib.h>`) per research.md R1.
- [X] T002 Create the `StoutCore` source subdirectory layout (`Configuration/`, `Envelope/`, `Resource/`, `Pipeline/`, `Transport/`, `Compression/`, `Ingestion/`, `Diagnostics/`) and remove the placeholder `Sources/StoutCore/StoutCore.swift` once a real type exists; ensure `Tests/StoutCoreTests/` is ready.
- [X] T003 [P] Confirm baseline gates green before feature work: `swift build`, `swift test`, `swift format lint --strict --recursive Sources Tests`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared `Sendable` types every user story depends on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T004 [P] Define the secret-free `Diagnostics` protocol + `DiagnosticEvent` (carries no secrets/payload) in `Sources/StoutCore/Diagnostics/Diagnostics.swift` (FR-016/FR-028; data-model §10).
- [X] T005 [P] Define the `TelemetryTags` Part A model (`Sendable`, `Encodable`) in `Sources/StoutCore/Envelope/TelemetryTags.swift` (data-model §3).
- [X] T006 [P] Define the `BaseData` extension-seam protocol (`Sendable & Encodable`, `static var baseType`) in `Sources/StoutCore/Envelope/BaseData.swift` (FR-007; contracts/public-api.md).
- [X] T007 Define `Envelope` + `DataContainer` (`Encodable`; envelope `ver`=1 omitted on wire, `baseData.ver`=2, `sampleRate` default 100) in `Sources/StoutCore/Envelope/Envelope.swift` (FR-006/FR-008; depends on T005, T006).
- [X] T008 [P] Define `ExporterConfiguration` with documented .NET/OTel-aligned defaults (buffer 2048, flush 5s, batch 512, shutdown 30s, maxRetryAttempts 3, maxRetryDelay 60s) in `Sources/StoutCore/Pipeline/ExporterConfiguration.swift` (FR-017; research.md R1 clarifications).
- [X] T009 [P] Define the `Sendable` `Transport` protocol + `TransportRequest`/`TransportResponse` value types in `Sources/StoutCore/Transport/Transport.swift` (FR-022/FR-023; contracts/transport.md).

**Checkpoint**: Shared types compile `Sendable`-clean on Apple + Linux; user stories can begin.

---

## Phase 3: User Story 1 - Configure the exporter from a connection string (Priority: P1) 🎯 MVP

**Goal**: Parse + validate an Application Insights connection string into a usable, secret-safe config, or fail closed with a secret-free error.

**Independent Test**: Feed valid + every invalid connection-string variant; assert parsed values / matching error, endpoint precedence, and that no error text contains a secret. No network.

### Tests for User Story 1

- [X] T010 [P] [US1] Write `ConnectionStringTests` in `Tests/StoutCoreTests/ConnectionStringTests.swift`: valid string → correct GUID iKey + normalized ingestion/live endpoints + well-formed `{endpoint}/v2.1/track`; case-insensitive keys; optional fields retained; each invalid variant (missing iKey, malformed GUID, non-HTTPS, malformed URL, duplicate key, empty) → matching `ConnectionStringError` whose `description` contains NO secret; endpoint precedence explicit → suffix `https://[loc.]dc.{suffix}` → default `https://dc.services.visualstudio.com/` (Acc #1/#2/#11; FR-001–005/028/029).

### Implementation for User Story 1

- [X] T011 [US1] Implement `ConnectionConfiguration` (parse, validate GUID + HTTPS-only endpoints, normalize trailing slashes, endpoint precedence, retain optional fields) + secret-free `ConnectionStringError` + redacting debug description in `Sources/StoutCore/Configuration/ConnectionConfiguration.swift` (FR-001–005/028/029; make T010 pass).

**Checkpoint**: Connection-string config is fully functional and testable on its own.

---

## Phase 4: User Story 2 - Buffer, encode, and export a batch to ingestion (Priority: P1) 🎯 MVP

**Goal**: The pipeline spine — non-blocking submit → bounded buffer → flush on size/interval → newline-JSON → core-gzipped → POST `/v2.1/track` → 200 = success.

**Independent Test**: Submit N envelopes against a mock `Transport`; assert non-blocking submit, dual flush triggers, exactly-N `\n`-JSON lines with Breeze fields/timestamps, gzip body + correct headers/path, and 200 → success. No network.

### Tests for User Story 2

- [X] T012 [P] [US2] `EnvelopeEncodingTests` in `Tests/StoutCoreTests/EnvelopeEncodingTests.swift`: N envelopes → exactly N `\n`-delimited single-line JSON objects; Breeze field names; `time` = UTC ISO-8601 fractional `Z` regardless of TZ/locale; envelope `ver` omitted; `baseData.ver`=2 (Acc #3; FR-006/009; SC-004).
- [X] T013 [P] [US2] `GzipRoundTripTests` in `Tests/StoutCoreTests/GzipRoundTripTests.swift`: gzip(body) → decompress → identical bytes; valid gzip header/trailer; runs on Apple + Linux (Acc #3; FR-010; SC-004).
- [X] T014 [P] [US2] `PipelineFlushTests` in `Tests/StoutCoreTests/PipelineFlushTests.swift`: submit returns without awaiting network; flush when batch hits 512 AND, separately, when the 5s interval elapses with a partial batch (Acc #4; FR-012/013; SC-001).
- [X] T015 [P] [US2] `TransportContractTests` in `Tests/StoutCoreTests/TransportContractTests.swift` with a mock `Transport`: POST `{endpoint}/v2.1/track`, `Content-Type: application/x-json-stream`, `Content-Encoding: gzip`, gzip body; 200 → success (Acc #7; FR-022/023).
- [X] T040 [P] [US2] `ConcurrentProducersTests` in `Tests/StoutCoreTests/ConcurrentProducersTests.swift`: many tasks submitting concurrently (below capacity) → buffer never corrupts, no races, all items enqueued and eventually flushed; run under Swift 6 strict concurrency (spec Edge Case "concurrent producers"; FR-012; addresses analysis C2). At-capacity concurrent behavior is covered by T022.

### Implementation for User Story 2

- [X] T016 [P] [US2] Implement the system-zlib `gzip(_:) throws -> [UInt8]` wrapper (`deflateInit2_` with `windowBits = MAX_WBITS + 16`, `Z_FINISH` loop, `deflateEnd`; import `zlib` on Apple / `CZlib` on Linux) in `Sources/StoutCore/Compression/Gzip.swift` (FR-010; research.md R1; make T013 pass).
- [X] T017 [US2] Implement the batch encoder — single-line JSON per envelope + deterministic UTC ISO-8601 fractional `Z` timestamp formatting + `\n`-join — in `Sources/StoutCore/Envelope/Envelope.swift` (or an `EnvelopeEncoding.swift`) (FR-009; depends on T007; make T012 pass).
- [X] T018 [US2] Implement `EnvelopeFactory` — **init takes `instrumentationKey: String` + `TelemetryTags`, NOT `ConnectionConfiguration`** (so US2 needs no US1 code) — stamping `ver`/`name`/`time`/`sampleRate`/`iKey`/`tags` around a caller `baseType`+`baseData` in `Sources/StoutCore/Envelope/EnvelopeFactory.swift` (FR-007; addresses analysis I1; depends on T007, T005).
- [X] T019 [P] [US2] Implement `URLSessionTransport` (Apple, `#if !canImport(FoundationNetworking)`) in `Sources/StoutCore/Transport/URLSessionTransport.swift` (FR-022; depends on T009).
- [X] T020 [P] [US2] Implement `AsyncHTTPClientTransport` (Linux, `#if canImport(FoundationNetworking)`) in `Sources/StoutCore/Transport/AsyncHTTPClientTransport.swift` (FR-022; depends on T009).
- [X] T021 [US2] Implement the `ExportPipeline` actor — **init takes `ingestionEndpoint: URL`** (a plain URL, decoupled from US1), bounded buffer, `nonisolated` non-blocking `submit`, async flush loop (size + interval triggers), gzip via T016, encode via T017, POST via injected `Transport` to `{ingestionEndpoint}/v2.1/track`, treat 200 as success — in `Sources/StoutCore/Pipeline/ExportPipeline.swift` (FR-011–013/023; research.md R5; addresses analysis I1; depends on T007, T008, T009, T016, T017; make T014/T015 pass).

**Checkpoint**: With US1 + US2 complete, the exporter core can carry a batch end-to-end — this is the MVP.

---

## Phase 5: User Story 3 - Survive backpressure without harming the host (Priority: P2)

**Goal**: Bounded buffer with drop-on-overflow + dropped-item accounting; never block, never OOM.

**Independent Test**: With a stalled mock transport, submit past capacity; assert submits never block, memory stays ≤ capacity, and `droppedCount` increments by exactly the overflow count.

### Tests for User Story 3

- [X] T022 [P] [US3] `OverflowTests` in `Tests/StoutCoreTests/OverflowTests.swift`: at capacity → further submits dropped (not blocked), `droppedCount` increments by exactly the overflow count, memory bounded to capacity; no unbounded growth in retry state (Acc #5; FR-014; SC-003).

### Implementation for User Story 3

- [X] T023 [US3] Enforce hard buffer capacity with drop-on-overflow + `droppedCount` (with secret-free diagnostics accounting via T004) in `Sources/StoutCore/Pipeline/ExportPipeline.swift` (FR-014; extends T021; make T022 pass).

**Checkpoint**: Pipeline is do-no-harm under sustained overload.

---

## Phase 6: User Story 4 - Deliver reliably through transient failures (Priority: P2)

**Goal**: Parse partial-success, classify retriable vs non-retriable, honor `Retry-After` else bounded exponential backoff+jitter; drop permanents secret-free.

**Independent Test**: Drive the parser + classifier with canned responses (206 partial, 429/503 ± `Retry-After`, 400/402/404, 401/403); assert which items retry, the delays, and secret-free drops.

### Tests for User Story 4

- [ ] T024 [P] [US4] `IngestionResponseTests` in `Tests/StoutCoreTests/IngestionResponseTests.swift`: parse `itemsReceived`/`itemsAccepted`/per-item `errors`; empty/non-JSON/malformed body → non-fatal, no crash (Acc #8; FR-024).
- [ ] T025 [P] [US4] `RetryClassificationTests` in `Tests/StoutCoreTests/RetryClassificationTests.swift`: whole-response retriable `{408,429,439,401,403,500,502,503,504}`; 206 per-item retriable `{408,429,439,500,503}` (others dropped); `400/402/404` never retried; `401/403` retried then exhausted; `Retry-After` (delta-seconds + HTTP-date) honored; else full-jitter backoff `random(0, min(60s, 1s × 2^attempt))` bounded to 3 attempts / 60s (Acc #8/#9; FR-025/026/027).
- [ ] T041 [P] [US4] `HostIsolationTests` in `Tests/StoutCoreTests/HostIsolationTests.swift`: a mock `Transport` that throws, plus malformed/garbage response bodies → `submit` never throws or blocks, the pipeline never crashes, failures surface ONLY via `Diagnostics`, and retriable errors exhaust the bounded budget then drop (spec Edge Case; FR-031; addresses analysis C1 — the consolidated do-no-harm assertion for Constitution Principle II).

### Implementation for User Story 4

- [ ] T026 [P] [US4] Implement `IngestionResponse` parsing (`itemsReceived`/`itemsAccepted`/`errors[index,statusCode,message]`, malformed-body tolerant) in `Sources/StoutCore/Ingestion/IngestionResponse.swift` (FR-024; make T024 pass).
- [ ] T027 [US4] Implement `RetryPolicy` — status classification (mirror .NET sets), `Retry-After` parsing (delta-seconds + HTTP-date), and **full-jitter exponential backoff `delay = random(0, min(maxRetryDelay, 1s × 2^attempt))`** bounded by `maxRetryAttempts` (3) / `maxRetryDelay` (60s) — in `Sources/StoutCore/Pipeline/RetryPolicy.swift` (FR-025/026/027; addresses analysis A1; depends on T026; make T025 pass).
- [ ] T028 [US4] Wire `RetryPolicy` into the `ExportPipeline` export loop: retry retriable items (in-memory, bounded), re-queue 206 partial-success survivors, drop permanents with secret-free diagnostics in `Sources/StoutCore/Pipeline/ExportPipeline.swift` (FR-025; extends T021; depends on T027).

**Checkpoint**: Delivery is reliable and bounded under transient ingestion failures.

---

## Phase 7: User Story 5 - Drain and go inert on shutdown (Priority: P2)

**Goal**: Graceful drain-and-go-inert (D1) — flush ≤ timeout, await in-flight, close client, idempotent; post-shutdown submits dropped with exactly one rate-limited warning.

**Independent Test**: Enqueue, `shutdown()` against a mock; assert pending flush ≤ timeout, no hang, second shutdown no-op, post-shutdown submits dropped with exactly one diagnostics warning (no payload).

### Tests for User Story 5

- [ ] T029 [P] [US5] `ShutdownTests` in `Tests/StoutCoreTests/ShutdownTests.swift`: pending flushed ≤ 30s timeout, in-flight completes, client closed, no hang; **`shutdown()` invoked while a retry backoff is pending still completes within the timeout** (spec Edge Case; addresses analysis U1); 2nd `shutdown()` = no-op; post-shutdown submit dropped without crash/block; exactly ONE rate-limited internal-diagnostics warning with no payload (Acc #6; FR-015/016; SC-005).

### Implementation for User Story 5

- [ ] T030 [US5] Add the lifecycle state machine (`running`/`draining`/`inert`) + idempotent `shutdown()` (stop accepting, best-effort flush ≤ `shutdownDrainTimeout`, await in-flight, close transport) + single rate-limited post-shutdown warning via `Diagnostics` in `Sources/StoutCore/Pipeline/ExportPipeline.swift` (FR-015/016; extends T021; make T029 pass).

**Checkpoint**: Lifecycle is safe at exit; no host hang, no data loss beyond the timeout.

---

## Phase 8: User Story 6 - Populate cloud role, instance, and device tags (Priority: P3)

**Goal**: Map OTel resource attributes (+ cheap platform detection) once to Part A tags, with explicit overrides beating detection; stamp every envelope.

**Independent Test**: Provide resource attrs + overrides; assert `ai.cloud.role`/`roleInstance`/`sdkVersion`/device tags and override-beats-detection. No network.

### Tests for User Story 6

- [ ] T031 [P] [US6] `ResourceTagsTests` in `Tests/StoutCoreTests/ResourceTagsTests.swift`: `ai.cloud.role` = `[ns]/name` when namespace present else `name`; `ai.cloud.roleInstance` = `service.instance.id` else host name; `ai.internal.sdkVersion` = `stout:<version>`; on-device `ai.device.*`/`ai.application.ver` when available; explicit override beats detection (Acc #10; FR-018–021).

### Implementation for User Story 6

- [ ] T032 [US6] Implement `ResourceDetector.makeTags` — role-name composition (bracketed namespace), roleInstance fallback, `stout:<version>` sdkVersion, Apple device/app tags, override precedence, computed once — in `Sources/StoutCore/Resource/ResourceDetector.swift` (FR-018–021; depends on T005; make T031 pass).
- [ ] T033 [US6] Feed the computed resource tags into `EnvelopeFactory` so every envelope's `tags` is stamped (merged with per-item tags) in `Sources/StoutCore/Envelope/EnvelopeFactory.swift` (FR-021; depends on T018, T032).

**Checkpoint**: Every envelope carries correct role/instance/device attribution.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Constitution gates that span all stories.

- [ ] T034 [P] Add doc comments to every public API to match `contracts/public-api.md` (Constitution IV/V; FR-033).
- [ ] T035 Add a secret-safety test sweep in `Tests/StoutCoreTests/SecretRedactionTests.swift` asserting no connection string / iKey / token appears in any error, diagnostic, or debug output across all paths (SC-002; FR-028) — pairs with a `secret-safety-sentinel` review.
- [ ] T036 Run a Swift 6 strict-concurrency audit: build `StoutCore` on an Apple platform AND Linux with zero data-race warnings, no `@unchecked Sendable` without justification (Acc #12; FR-030; SC-007) — pairs with a `swift6-concurrency-auditor` review.
- [ ] T037 [P] Run `swift format lint --strict --recursive Sources Tests` and fix violations (2-space indent).
- [ ] T038 Execute the `quickstart.md` validation scenarios (1–13) on BOTH an Apple platform (iOS Simulator / macOS) and Linux; record results.
- [ ] T039 [P] Update `README.md` / `Sources/StoutCore` summary doc to reflect the shipped core surface.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: depends on Setup — BLOCKS all user stories.
- **User Stories (Phase 3–8)**: all depend on Foundational.
  - **US1 (P1)** is fully self-contained (only needs `ConnectionStringError`; no foundational type) and may run in parallel with US2.
  - **US2 (P1)** depends on foundational T007/T008/T009 + its own T016/T017. Per analysis I1,
    `EnvelopeFactory` (T018) takes `iKey: String` and `ExportPipeline` (T021) takes
    `ingestionEndpoint: URL` — both primitives — so US2 has **no code dependency on US1** and the
    US1 ∥ US2 parallelism above is real (US1 merely *produces* those primitives at runtime).
  - **US3, US4, US5** each extend the `ExportPipeline.swift` file created in **US2 (T021)** — they depend on T021 and, sharing that file, run sequentially (not `[P]`) relative to each other even though each is independently *testable*.
  - **US6 (P3)** depends on foundational T005 and (for T033) US2's T018.
- **Polish (Phase 9)**: after the desired stories are complete.

### Within Each User Story

- Tests are written first and fail before implementation.
- Foundational types before pipeline; pipeline (US2) before its extensions (US3/4/5).

### Parallel Opportunities

- Setup: T003 after T001/T002.
- Foundational: **T004, T005, T006, T008, T009 in parallel**; T007 after T005+T006.
- US1 (T010→T011) can run fully in parallel with US2.
- US2 tests **T012, T013, T014, T015, T040 in parallel**; impl **T016, T019, T020 in parallel**, then T017/T018, then T021.
- US4 tests **T024, T025, T041 in parallel**; **T026 [P]** then T027 then T028.
- US6: T031 [P]; T032 then T033.
- Polish: T034, T037, T039 in parallel.

---

## Parallel Example: Foundational Phase

```bash
# After Setup, launch the independent foundational types together:
Task: "T004 Diagnostics protocol in Sources/StoutCore/Diagnostics/Diagnostics.swift"
Task: "T005 TelemetryTags in Sources/StoutCore/Envelope/TelemetryTags.swift"
Task: "T006 BaseData seam in Sources/StoutCore/Envelope/BaseData.swift"
Task: "T008 ExporterConfiguration in Sources/StoutCore/Pipeline/ExporterConfiguration.swift"
Task: "T009 Transport protocol in Sources/StoutCore/Transport/Transport.swift"
# Then T007 Envelope (needs T005 + T006).
```

## Parallel Example: User Story 2

```bash
# Tests first, in parallel:
Task: "T012 EnvelopeEncodingTests"; Task: "T013 GzipRoundTripTests"
Task: "T014 PipelineFlushTests"; Task: "T015 TransportContractTests"
# Independent implementation files in parallel:
Task: "T016 Gzip wrapper"; Task: "T019 URLSessionTransport"; Task: "T020 AsyncHTTPClientTransport"
# Then T017/T018 (envelope), then T021 (pipeline) ties them together.
```

---

## Implementation Strategy

### MVP scope

This feature's MVP is **US1 + US2 together** (both P1): parse the connection string AND carry a batch
to ingestion. US1 alone parses config but sends nothing; the two P1 stories are the smallest useful
increment. Sequence: Setup → Foundational → US1 ∥ US2 → **STOP and validate** the end-to-end path
against a mock ingestion endpoint.

### Incremental delivery

1. Setup + Foundational → shared types compile Sendable-clean.
2. US1 + US2 → MVP: config + buffered gzip POST → validate.
3. US3 → drop-on-overflow (do-no-harm).
4. US4 → reliable retry/partial-success.
5. US5 → drain-and-go-inert shutdown.
6. US6 → resource/device tag enrichment.
7. Polish → secret-safety, strict-concurrency, lint, quickstart on Apple + Linux.

### Notes

- `[P]` = different files, no incomplete dependencies.
- US3/US4/US5 modify the shared `ExportPipeline.swift`; keep them sequential to avoid conflicts, but
  each remains independently testable via its own test file.
- Commit after each task or logical group; run the three gates (`build`/`test`/`format lint`) before
  merge (main is protected).
