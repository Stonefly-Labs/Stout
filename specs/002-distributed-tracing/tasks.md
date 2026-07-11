---
description: "Task list for Distributed Tracing Exporter (spec 02)"
---

# Tasks: Distributed Tracing Exporter

**Input**: Design documents from `/specs/002-distributed-tracing/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (all present)

**Tests**: INCLUDED. Constitution principle IV (high coverage incl. translation tables and
failure paths) and the spec's SC-001..010 make table-driven goldens + failure-path tests a
non-negotiable part of this feature, and plan.md enumerates the test files. Test tasks are
therefore first-class here.

**Organization**: Tasks are grouped by user story (spec.md priorities). Each story is an
independently testable increment against a hand-built `SpanData` and a mock pipeline — no
live `TracerProvider`, no network.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US6 (setup/foundational/polish carry no story label)
- All paths are repo-relative. Feature code lives in the existing `StoutTracing` target;
  no new module/product/dependency is added to `Package.swift` (plan.md Structure Decision).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Prepare the `StoutTracing` target and the test harness the whole feature uses.

- [X] T001 [P] Replace the placeholder `enum` in `Sources/StoutTracing/StoutTracing.swift` with the module namespace doc + Apache-2.0 SPDX header (state: exporter for `opentelemetry-swift`'s `SpanExporter`, translates `SpanData` → Breeze; consumes spec 01, redefines nothing).
- [X] T002 Confirm the `StoutTracing` target links `OpenTelemetrySdk` + `OpenTelemetryApi` (opentelemetry-swift-core 2.5.1, pinned) and `StoutCore` in `Package.swift`, and that `swift build` resolves them — no other dependency added.
- [X] T003 [P] Create `Tests/StoutTracingTests/Support/SpanDataBuilder.swift` — a hand-built `SpanData` factory (trace/span/parent ids, kind, start/end, attributes, status, events, links, resource) so every suite constructs spans with no `TracerProvider`.
- [X] T004 [P] Create `Tests/StoutTracingTests/Support/MockPipelineTransport.swift` — a capturing mock `Transport` + mock `Diagnostics` behind a real `ExportPipeline` (or a capturing pipeline seam) so submitted `Envelope`s are asserted with no network.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The pure, `Sendable`, table-driven building blocks every translation story shares —
Breeze payload types, correlation/kind/success rules, semantic-convention keys, and the shared
HTTP mapper. Nothing here is story-specific.

**⚠️ CRITICAL**: No user-story translation work can begin until this phase is complete.

- [X] T005 [P] Add `operationId` (`ai.operation.id`), `operationParentId` (`ai.operation.parentId`), and `operationName` (`ai.operation.name`) constants to `Sources/StoutCore/Envelope/PartATagKeys.swift` (data-model §2; the only StoutCore edit this feature makes).
- [X] T006 [P] `Sources/StoutTracing/Model/RequestData.swift` — `BaseData` conformer, `baseType = "RequestData"`, encodes `ver:2` first; fields `id/name/duration/responseCode/success/url?/source?/properties` (data-model §1a).
- [X] T007 [P] `Sources/StoutTracing/Model/RemoteDependencyData.swift` — `BaseData`, `baseType = "RemoteDependencyData"`, `ver:2`; fields `id/name/duration/resultCode/success/type/target?/data?/properties` (data-model §1b).
- [X] T008 [P] `Sources/StoutTracing/Model/ExceptionData.swift` — `BaseData`, `baseType = "ExceptionData"`, `ver:2`; `exceptions[].{typeName,message,hasFullStack,stack?}` + `properties` (data-model §1c).
- [X] T009 [P] `Sources/StoutTracing/Model/MessageData.swift` — `BaseData`, `baseType = "MessageData"`, `ver:2`; `message` + `properties` (data-model §1d).
- [X] T010 [P] `Sources/StoutTracing/Translation/BreezeDuration.swift` — `(endTime − startTime) → "d.hh:mm:ss.fffffff"`; zero/negative clamps to `0`, never crashes (mapping contract Determinism notes).
- [X] T011 [P] `Sources/StoutTracing/Translation/AttributeStringifier.swift` — single documented `AttributeValue → String` rule for `.string/.bool/.int/.double/.array/.set` (+ deprecated `*Array`), used for `properties` and stringified fields (data-model §0).
- [X] T012 [P] `Sources/StoutTracing/Translation/SemanticConventions.swift` — the current+legacy key table (data-model §5) with a current-wins lookup helper; deterministic, not attribute-order-dependent (INV-3, research.md D-07).
- [X] T013 [P] `Sources/StoutTracing/Translation/SpanKindMapping.swift` — `SpanKind → {Request | Dependency}` incl. unspecified→Dependency default (data-model §3, FR-006).
- [X] T014 [P] `Sources/StoutTracing/Translation/CorrelationMapping.swift` — the shared rule (FR-007/FR-024) operating on `TraceId`/`SpanId`/`SpanId?` (NOT `SpanData`, so spec 03 reuses it verbatim): `operationId ← traceId` (32-hex), item `id ← spanId` (16-hex), `parentId ← parentSpanId` absent-when-root; byte-for-byte lowercase hex.
- [X] T015 [P] `Sources/StoutTracing/Translation/SuccessPredicate.swift` — actual .NET `TraceHelper` logic (data-model §4, research.md D-03): error status ⇒ `success=false` always; Request unset-status HTTP ⇒ `code != 0 && code < 400` (4xx **and** 5xx fail); Dependency ⇒ `status != error` only (no code threshold); plus `responseCode`/`resultCode` derivation with `"0"` default.
- [X] T016 [P] `Sources/StoutTracing/Translation/HTTPMapping.swift` — shared HTTP derivation (url/target host[:port]/status/route-name) from current+legacy HTTP keys; consumed by US1 (Request) and US2 (Dependency).
- [X] T017 [P] `Tests/StoutTracingTests/BreezeDurationTests.swift` — duration formatting incl. zero/negative clamp and sub-second precision.
- [X] T018 [P] `Tests/StoutTracingTests/SemanticConventionPrecedenceTests.swift` — current-over-legacy precedence, order-independence (INV-3).
- [X] T019 [P] `Tests/StoutTracingTests/SpanKindMappingTests.swift` — full kind→type table incl. unspecified→Dependency (SC-001, FR-006).

**Checkpoint**: Building blocks compile clean under Swift 6 strict concurrency; foundational unit suites pass. User stories can now begin.

---

## Phase 3: User Story 1 — Register the exporter; a server request becomes a Request (Priority: P1) 🎯 MVP

**Goal**: A registered `SpanExporter` turns a finished `.server`/`.consumer` span into exactly one
`RequestData` handed to the spec 01 pipeline, with correct id/name/duration/responseCode/url/success.

**Independent Test**: Construct `AzureMonitorTraceExporter` standalone, `export([...])` a hand-built
`.server` `SpanData`, assert exactly one `RequestData` envelope with expected `id`, `name`,
`duration`, `responseCode`, `url`, `success` reaches the mock pipeline — no network.

### Tests for User Story 1 ⚠️ (write first, ensure they FAIL)

- [ ] T020 [P] [US1] `Tests/StoutTracingTests/RequestTranslationTests.swift` — `.server` and `.consumer` span ⇒ exactly one `RequestData`; asserts id/name/duration/responseCode/url; unmapped attributes **and span links** → `properties` (no first-class Breeze span-link field) (US1 Acc 1–4, FR-022, SC-001).
- [ ] T021 [P] [US1] `Tests/StoutTracingTests/HTTPMappingTests.swift` (Request side) — url reconstruction from `url.full`/`http.url` and scheme/host/target; route/method-derived name; current+legacy keys.
- [ ] T022 [P] [US1] `Tests/StoutTracingTests/SuccessPredicateTests.swift` (Request side) — server HTTP ranges: `code<400 && code!=0` success, 4xx & 5xx & 0 fail; error status forces `success=false` (INV-3b).
- [ ] T023 [P] [US1] `Tests/StoutTracingTests/ExporterSubmitTests.swift` — `export(...)` returns promptly with `.success`, submits via `pipeline.submit`, does not block (FR-004).

### Implementation for User Story 1

- [ ] T024 [US1] `Sources/StoutTracing/Translation/SpanTranslator.swift` — pure `translate(_ span:) -> [Envelope]` orchestration (mapping contract steps 1–7): resolve kind → build correlation `itemTags` → protocol fields → carry unconsumed attributes+links to `properties` → success/code → stamp `Envelope` (`time = startTime`, `sampleRate = 100`). Request path wired end-to-end; never throws into host (FR-026).
- [ ] T025 [US1] Request population in `SpanTranslator` (or `Sources/StoutTracing/Translation/RequestMapping.swift`): fill `RequestData` via `HTTPMapping` + `SuccessPredicate` (server) + `BreezeDuration`; `id ← spanId`; unmapped attrs+links → `properties` (FR-010/011, US1 Acc 2 & 4).
- [ ] T026 [US1] `Sources/StoutTracing/AzureMonitorTraceExporter.swift` — `public final class ... : SpanExporter`, `init(pipeline:envelopeFactory:)`; implement **all** required members (sync + async `export`/`flush`/`shutdown`, no `assertionFailure` defaults) per contracts/span-exporter.md; `export` translates each span and `submit`s each envelope, returns `.success`/`.failure`; `Sendable` via injected pipeline actor + immutable factory (FR-001/003/005/027).
- [ ] T027 [US1] `Sources/StoutTracing/TraceExporterRegistration.swift` — thin helper building the exporter from a spec-01 assembled `ExportPipeline` + `EnvelopeFactory`; resource tags are detected **once at registration** via `ResourceDetector.detect(resource:)` on the provider's `Resource` and baked into the injected `EnvelopeFactory` (NOT re-detected per span), FR-009; documents that provider/`BatchSpanProcessor` bootstrap is spec 07, not here.

**Checkpoint**: A `.server` span becomes one correlated `RequestData` on the pipeline — MVP trace path works. STOP and validate independently.

---

## Phase 4: User Story 2 — An outbound call becomes a correlated Dependency (Priority: P1)

**Goal**: `.client`/`.producer`/`.internal`/unspecified spans become exactly one
`RemoteDependencyData` with correct type/target/data/resultCode/success, nested under the request
(shared `ai.operation.id`, `parentId` = parent span id).

**Independent Test**: `export` a `.client` HTTP span and (separately) a DB span; assert one
`RemoteDependencyData` each with expected `type`/`target`/`data`/`resultCode`/`success`/`duration`,
`ai.operation.id` = trace id, `ai.operation.parentId` = parent span id — no network.

### Tests for User Story 2 ⚠️ (write first, ensure they FAIL)

- [ ] T028 [P] [US2] `Tests/StoutTracingTests/DependencyTranslationTests.swift` — `.client`/`.producer`/`.internal`/unspecified ⇒ exactly one `RemoteDependencyData`; `.internal`⇒`type=InProc`; correlation id/parentId asserted; unmapped attributes **and span links** → `properties` (US2 Acc 1 & 4, FR-022, SC-001).
- [ ] T029 [P] [US2] `Tests/StoutTracingTests/DBMappingTests.swift` — DB `.client`: `type ← db.system`|`SQL`, `target ← db.namespace`/server, `data ← db.query.text`/`db.statement`; current+legacy keys (US2 Acc 3, FR-013–015).
- [ ] T030 [P] [US2] `Tests/StoutTracingTests/RPCMappingTests.swift` — gRPC/RPC `type`/`target`/`data`, `resultCode ← rpc.grpc.status_code` (FR-013–016).
- [ ] T031 [P] [US2] `Tests/StoutTracingTests/MessagingMappingTests.swift` — producer messaging `type`/`target`/`data`; consumer messaging `RequestData.source` population (FR-008), else empty.
- [ ] T032 [P] [US2] `SuccessPredicateTests` (Dependency side) — dependency `success = (status != error)` only; a 4xx/5xx dependency with unset status is a **success** (INV-3b, FR-012).

### Implementation for User Story 2

- [ ] T033 [US2] Dependency population in `SpanTranslator` (or `Sources/StoutTracing/Translation/DependencyMapping.swift`): fill `RemoteDependencyData` via `HTTPMapping` (client side) + `SuccessPredicate` (dependency) + `BreezeDuration`; `type`=`HTTP`/`InProc`/protocol; unmapped attrs+links → `properties` (FR-012–015).
- [ ] T034 [P] [US2] `Sources/StoutTracing/Translation/DBMapping.swift` — DB `type/target/data` from `db.*` keys (current+legacy), mssql→`SQL` (FR-013–015).
- [ ] T035 [P] [US2] `Sources/StoutTracing/Translation/RPCMapping.swift` — gRPC/RPC `type` (e.g. `GRPC`, D-04)/`target`/`data`/`resultCode` from `rpc.*` (FR-013–016).
- [ ] T036 [P] [US2] `Sources/StoutTracing/Translation/MessagingMapping.swift` — producer/consumer `type/target/data` from `messaging.*`/`peer.service`, and `RequestData.source` for consumer (FR-008/013–015).
- [ ] T037 [US2] Wire DB/RPC/messaging mappers into `SpanTranslator`'s dependency (and consumer-request `source`) paths so protocol selection is deterministic (FR-016).

**Checkpoint**: Request + linked Dependency render as one transaction (US1 + US2 both pass independently).

---

## Phase 5: User Story 3 — Cross-service / cross-tier correlation preserved losslessly (Priority: P2)

**Goal**: trace/span/parent ids map byte-for-byte to `ai.operation.id`/`ai.operation.parentId`/item
id; two SDK-correlated tiers share one operation id.

**Independent Test**: Feed a caller `.client` and a callee `.server` whose parent span id = caller
span id; assert shared `ai.operation.id` and callee `parentId` = caller item id against W3C hex; a
root span yields empty/absent `parentId`.

### Tests for User Story 3 ⚠️

- [ ] T038 [P] [US3] `Tests/StoutTracingTests/CorrelationMappingTests.swift` — byte-for-byte 32-hex `operationId`/16-hex item id/`parentId`; root span ⇒ absent `parentId` (INV-2, SC-002).
- [ ] T039 [P] [US3] `Tests/StoutTracingTests/CrossTierCorrelationTests.swift` — caller `.client` + callee `.server`: shared `operationId`, callee `parentId` = caller item id (SC-005, US3 Acc 3).
- [ ] T040 [P] [US3] `Tests/StoutTracingTests/SharedCorrelationRuleTests.swift` — assert `CorrelationMapping` produces identical `ai.operation.*` for the same ids regardless of source signal (SC-007 stub for spec 03 reuse, FR-024).

### Implementation for User Story 3

- [ ] T041 [US3] Verify/patch `SpanTranslator` so root-span `parentId` is truly absent (not empty string) on the wire and `operationName` is set for server/consumer (data-model §2); no new correlation logic — `CorrelationMapping` (T014) is the single source (FR-007).

**Checkpoint**: Correlation is provably lossless and shared with the spec-03 contract.

---

## Phase 6: User Story 4 — Errors and exceptions surface correctly (Priority: P2)

**Goal**: error span status forces `success=false` on the owning item (with or without an event);
an `exception` event yields a correlated `ExceptionData`.

**Independent Test**: span with error `Status` + `exception` event ⇒ owning item `success=false` and
one correlated `ExceptionData` (`type/message/stacktrace`, `parentId` = span id); and error status
alone (no event) ⇒ `success=false`, no fabricated `ExceptionData`.

### Tests for User Story 4 ⚠️

- [ ] T042 [P] [US4] `Tests/StoutTracingTests/EventMappingTests.swift` (exception path) — `exception` event ⇒ correlated `ExceptionData`; `hasFullStack`/`stack` only when `exception.stacktrace` present (US4 Acc 2, INV-4).
- [ ] T043 [P] [US4] `Tests/StoutTracingTests/ExceptionErrorStatusTests.swift` — error status forces `success=false` even with no event; drop rule: no `ExceptionData` unless both `exception.type` **and** `exception.message` present (US4 Acc 1, data-model D-08).

### Implementation for User Story 4

- [ ] T044 [US4] `Sources/StoutTracing/Translation/EventMapping.swift` — `exception` event → `ExceptionData` (type/message/stacktrace, remaining event attrs → `properties`), correlated `parentId` = span id; enforce the both-fields-present drop rule (FR-019, data-model D-08).
- [ ] T045 [US4] Wire `EventMapping` exception output into `SpanTranslator` step 6 and confirm error status → `success=false` on the owning Request/Dependency independent of events (FR-021, INV-4).

**Checkpoint**: Failures are visible and correctly correlated.

---

## Phase 7: User Story 5 — Span events become correlated messages (Priority: P3)

**Goal**: a non-`exception` span event becomes a correlated `MessageData` under the same operation.

**Independent Test**: span with one non-`exception` event ⇒ one `MessageData`, correlated (`parentId`
= span id), carrying event name/message + attributes → `properties`.

### Tests for User Story 5 ⚠️

- [ ] T046 [P] [US5] `EventMappingTests.swift` (message path) — non-`exception` event ⇒ one correlated `MessageData` with name/message and attrs → `properties` (US5 Acc 1, FR-020).

### Implementation for User Story 5

- [ ] T047 [US5] Extend `Sources/StoutTracing/Translation/EventMapping.swift` — non-`exception` event → `MessageData` (message ← event name / `message` attr; attrs → `properties`), correlated `parentId` = span id; wire into `SpanTranslator` step 6 (FR-020).

**Checkpoint**: Per-event checkpoints enrich the transaction.

---

## Phase 8: User Story 6 — Graceful shutdown / flush, then go inert (Priority: P3)

**Goal**: `flush()` forwards items promptly and does not strand them; after the pipeline shuts down,
`export(...)` is a safe no-op drop surfaced only via spec 01's rate-limited diagnostic.

**Independent Test**: submit spans, `flush()` ⇒ items forwarded promptly; shut the pipeline down,
`export(...)` ⇒ spans dropped without crash/block, no telemetry emitted.

### Tests for User Story 6 ⚠️

- [ ] T048 [P] [US6] `Tests/StoutTracingTests/ExporterLifecycleTests.swift` — `flush()` forwards buffered items via `pipeline.flushNow()`; nothing stranded (US6 Acc 1).
- [ ] T049 [P] [US6] `ExporterLifecycleTests.swift` (post-shutdown) — after `pipeline.shutdown()`, `export(...)` drops without crash/block, emits **no** telemetry, and surfaces exactly one rate-limited `postShutdownSubmit` diagnostic (US6 Acc 2, FR-005).
- [ ] T050 [P] [US6] `Tests/StoutTracingTests/ConcurrencyTests.swift` — concurrent `export(...)` from many tasks is race-free and safe (FR-027, SC-010).

### Implementation for User Story 6

- [ ] T051 [US6] Implement `flush(...)`/`shutdown(...)` in `AzureMonitorTraceExporter` — async `flush` awaits `pipeline.flushNow()`; `shutdown` delegates to `pipeline.shutdown()` (idempotent); post-shutdown `export` relies on the inert pipeline's drop + `postShutdownSubmit` (no exporter-side state), FR-004/005, contract table.

**Checkpoint**: Lifecycle is correct; host is never blocked or crashed at exit.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T052 [P] Add `sampleRate` (default 100) assertions to the request/dependency/event suites confirming every emitted envelope carries it and no sampling decision is made; assert trace items do **not** emit `itemCount` (not used by the trace `baseData` schema — spec FR-023 / data-model §6) (FR-023, SC-006, INV-6).
- [ ] T053 [P] Public-API doc comments (FR-029) on `AzureMonitorTraceExporter`, its `init`, `TraceExporterRegistration`, and the four Breeze payload types: span-kind→envelope table, correlation-id ownership (SDK propagates; we map), unknown/unspecified-kind behavior, malformed-attribute behavior.
- [ ] T054 [P] Secret-safety pass (FR-025, SC-008): grep the module + a test asserting no connection string / iKey / token appears in any diagnostic or error path; forwarded attributes treated as customer data (delegate to secret-safety-sentinel).
- [ ] T055 Run `swift build`, `swift test`, and `swift format lint --strict --recursive Sources Tests` — all green, 2-space indent, zero strict-concurrency warnings.
- [ ] T056 Execute `specs/002-distributed-tracing/quickstart.md` validation scenarios end-to-end against the mock pipeline (SC-001..007) on macOS/iOS-sim and Linux (SC-010).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (P1)** → no deps.
- **Foundational (P2)** → after Setup. **BLOCKS all user stories** (models, correlation/kind/success/duration/semantics/HTTP mappers are shared).
- **User Stories (P3–P8)** → after Foundational.
  - US1 (P1) and US2 (P1) are the MVP pair; US2 reuses US1's `SpanTranslator` orchestration (T024), so implement US1 first, then US2.
  - US3/US4/US5 (P2/P2/P3) build on the translator but are otherwise independent and can run in parallel once US1's `SpanTranslator` exists.
  - US6 (P3) needs the exporter (T026) but not the other stories.
- **Polish (P9)** → after all targeted stories.

### Within Each User Story

- Tests first (write, watch fail) → implementation → checkpoint validation.
- `SpanTranslator` (T024) is the spine: US1 creates it; US2/US4/US5 extend its steps 3–6.

### Parallel Opportunities

- Setup: T001, T003, T004 in parallel (T002 is a quick Package.swift confirm).
- Foundational: T005–T016 are all `[P]` (distinct files); foundational tests T017–T019 `[P]`.
- Per story: all `[P]` test files author in parallel; within US2, mappers T034/T035/T036 `[P]`.
- Cross-story: once T024 lands, US3 tests + US4 + US5 can proceed concurrently.

---

## Parallel Example: Foundational Phase

```bash
# Breeze payload types + pure mappers — all different files, no interdeps:
Task: "T006 RequestData model in Sources/StoutTracing/Model/RequestData.swift"
Task: "T007 RemoteDependencyData model in Sources/StoutTracing/Model/RemoteDependencyData.swift"
Task: "T010 BreezeDuration in Sources/StoutTracing/Translation/BreezeDuration.swift"
Task: "T014 CorrelationMapping in Sources/StoutTracing/Translation/CorrelationMapping.swift"
Task: "T015 SuccessPredicate in Sources/StoutTracing/Translation/SuccessPredicate.swift"
```

## Parallel Example: User Story 2 mappers

```bash
Task: "T034 DBMapping in Sources/StoutTracing/Translation/DBMapping.swift"
Task: "T035 RPCMapping in Sources/StoutTracing/Translation/RPCMapping.swift"
Task: "T036 MessagingMapping in Sources/StoutTracing/Translation/MessagingMapping.swift"
```

---

## Implementation Strategy

### MVP First

1. Phase 1 Setup → Phase 2 Foundational (CRITICAL — blocks everything).
2. Phase 3 US1 (server → Request) → **validate independently** against a hand-built `.server` span.
3. Phase 4 US2 (client → correlated Dependency) → validate the request+dependency transaction.
4. **US1 + US2 = the MVP trace exporter** (both P1): spans appear in App Insights with request/dependency correlation.

### Incremental Delivery

US3 (lossless correlation goldens) → US4 (errors/exceptions) → US5 (event messages) → US6
(shutdown/inert). Each adds value without breaking prior stories; commit after each task or logical group.

### Notes

- Tests are integral (constitution IV) — write them first per story and confirm they fail.
- Translation stays pure/`Sendable` (INV-8); goldens compare `properties` as maps / sorted keys.
- Only StoutCore edit is T005 (PartATagKeys additions); everything else is new `StoutTracing` code.
