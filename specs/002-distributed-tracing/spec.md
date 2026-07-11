# Feature Specification: Distributed Tracing Exporter

**Feature Branch**: `feat/spec02-distributed-tracing`

**Created**: 2026-07-10

**Status**: Draft

**Input**: User description: "Refer to @docs/speckit/specs/02-distributed-tracing.md"

## Overview

The distributed-tracing exporter for Stout: an Application Insights `SpanExporter` for the
OpenTelemetry Swift SDK (`opentelemetry-swift`). Swift apps and services — iOS/macOS/watchOS/tvOS
clients and Linux/macOS servers — already produce spans through the OTel SDK's `TracerProvider`.
This feature implements that SDK's public `SpanExporter` protocol as an Azure Monitor exporter, so
finished spans are translated into Application Insights "Breeze" telemetry and handed to the spec 01
ingestion pipeline — **collector-free**, with no OpenTelemetry Collector or Azure Monitor Agent. It
mirrors the trace path of .NET's `Azure.Monitor.OpenTelemetry.Exporter`.

This is the trace half of Phase 1 ("Core + Traces exporter"). The success condition: **a Swift
app's spans appear in Application Insights with correct request/dependency correlation** — an
incoming request (server) or an on-device operation and the outbound calls it makes render as a
correctly-linked transaction in the App Insights transaction / application map.

This feature **builds on** the core ingestion foundation (spec 01) and **consumes, never
redefines**, its Breeze envelope model (Part A tags + `baseData` variants), the bounded
drop-on-overflow export pipeline, resource detection (cloud role / role instance / device / SDK
version tags), connection-string parsing/secret handling, and the gzip newline-JSON HTTPS transport
to `{IngestionEndpoint}/v2.1/track`. It covers only: implementing the `SpanExporter` protocol and
translating finished `SpanData` to Breeze telemetry items.

**W3C Trace Context propagation is owned by the OTel SDK, not by this feature.**
`opentelemetry-swift` ships the W3C `TraceContextPropagator`, performs inject/extract, and manages
the active span context; Stout is a *terminal exporter* that consumes already-correlated `SpanData`
(trace id, span id, parent span id already on each `SpanData`). We do NOT implement inject/extract,
`Instrument`, propagators, span lifecycle, batching, or sampling decisions — we translate the
identity the SDK already resolved onto the Breeze correlation tags.

> Locked design decisions: design.md §11 (D1–D4, D7–D9). This spec reflects D1 (drain-and-go-inert
> lifecycle; the exporter goes inert on `shutdown()`), D7 (cross-platform), and D8 (build on
> `opentelemetry-swift`'s public `SpanExporter`), and consumes the D2 ingestion path from spec 01.

## Clarifications

### Resolved by informed default (mirroring the .NET exporter — see Assumptions)

- **Default envelope type when span kind is unspecified/`.internal`** → `RemoteDependencyData` (the
  .NET exporter treats unspecified activities as dependencies).
- **Default `responseCode`/`resultCode` when no protocol status attribute is present** → derive from
  span status: `"0"` on a non-error span, `"0"` (with `success = false`) on an error span; never a
  secret, never empty-on-the-wire where the schema requires the field.
- **Span links** → carried into `properties` (App Insights has no first-class span-link concept); no
  dedicated Breeze field is invented for them.
- **`SpanExporter` protocol signatures / `SpanExporterResultCode` cases / `SpanData` shape** →
  confirmed against the pinned `opentelemetry-swift` version during `/speckit-plan` package
  resolution (an implementation binding, not a product decision).

### Session 2026-07-10

- Q: What is the exact `success` predicate per protocol (HTTP 4xx server vs client, gRPC non-OK, DB
  errors)? → A: Mirror the **actual** .NET `TraceHelper`/`RequestData.IsSuccess`/`RemoteDependencyData`
  behavior (verified against the reference during `/speckit-plan`, research.md D-03; maintainer-confirmed
  2026-07-10): an error span `Status` always forces `success = false`. Otherwise a **Request**
  (server/consumer) with unset status and an HTTP code is a failure when `code == 0 || code >= 400`
  (i.e. 4xx **and** 5xx fail; success iff `code != 0 && code < 400`); a **Dependency**
  (client/producer/internal) is `success = (status != error)` **only** — there is no HTTP/gRPC
  status-code threshold for dependencies. (FR-011/FR-012)
- Q: Which OTel semantic-convention baseline do we target, and what is the current-vs-legacy key
  precedence? → A: Support **both** the current stable keys (`http.request.method`, `url.full`,
  `server.address`, …) and their legacy equivalents (`http.method`, `http.url`, `net.peer.name`, …),
  preferring the current key when both are present (matches the .NET exporter). (FR-018)
- Q: How is `RequestData.source` populated for consumer/messaging and cross-service incoming
  context? → A: Mirror the .NET exporter — populate `source` from the messaging/correlation-context
  originating identity where the convention provides one, else leave it empty. (FR-008)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Register the exporter; a server request becomes a Request (Priority: P1)

A developer registers the Azure Monitor `SpanExporter` with `opentelemetry-swift`'s
`TracerProvider` (normally wrapped in a `BatchSpanProcessor`) at startup, configured from the
spec 01 pipeline. An incoming HTTP request (or an on-device operation) starts a `.server` span; on
finish the SDK hands its `SpanData` to the exporter, which translates it to exactly one `RequestData`
item — correct name, URL, response code, success flag, and duration — and hands it to the pipeline.

**Why this priority**: This is the minimum viable trace exporter — spans finishing as correlated
Requests in App Insights. Registration plus one signal path is the smallest slice that delivers
value; every other trace scenario builds on it.

**Independent Test**: Construct the exporter standalone (no live `TracerProvider`), pass a
hand-built `.server` `SpanData`, and assert exactly one `RequestData` envelope with the expected
`id`, `name`, `duration`, `responseCode`, `url`, and `success` is submitted to a mock pipeline — no
network required.

**Acceptance Scenarios**:

1. **Given** the exporter is registered with a `TracerProvider`, **When** a `.server` span finishes,
   **Then** the SDK-delivered `SpanData` is translated to exactly one `RequestData` item handed to
   the spec 01 pipeline, with no direct use of pipeline/transport internals redefined here.
2. **Given** a finished HTTP `.server` span, **When** it is translated, **Then** `RequestData.id` =
   span id, `name` is the route/method-derived name when available, `duration` = end − start,
   `responseCode` = `http.response.status_code`, `url` is reconstructed from HTTP attributes, and
   `success` reflects status + span status.
3. **Given** a finished `.consumer` span, **When** it is translated, **Then** it also yields exactly
   one `RequestData` item.
4. **Given** any finished span, **When** it is translated, **Then** its attributes not consumed by a
   specific field mapping are carried into `properties`.

---

### User Story 2 - An outbound call becomes a correlated Dependency (Priority: P1)

While handling a request, the app calls a downstream HTTP API, a database, or a REST endpoint
(on-device, via the SDK's URLSession instrumentation). Each produces a `.client` span whose
`SpanData` the exporter translates to a `RemoteDependencyData` item — correct target, type, data,
result code, success, and duration — nested under the request in the transaction map (same operation
id; the dependency's parent = the request's span id).

**Why this priority**: Request-plus-dependency correlation is the flagship value of App Insights
(the transaction/application map). A Request alone is half the picture; the linked outbound call
completes the MVP transaction.

**Independent Test**: Pass a `.client` `SpanData` carrying HTTP (and separately DB) attributes and
assert one `RemoteDependencyData` with the expected `type`, `target`, `data`, `resultCode`,
`success`, and `duration`, plus `ai.operation.id` = trace id and `ai.operation.parentId` = parent
span id — no network required.

**Acceptance Scenarios**:

1. **Given** a finished `.client`, `.producer`, or `.internal` span, **When** it is translated,
   **Then** it yields exactly one `RemoteDependencyData` item.
2. **Given** an HTTP `.client` span, **When** it is translated, **Then** `type` = `HTTP`, `target` =
   host[:port], `data` = full URL, and `resultCode` = the HTTP status code.
3. **Given** a DB `.client` span, **When** it is translated, **Then** `type` = the `db.system` value
   (or `SQL`), `target` = the db/server, and `data` = the statement/query text.
4. **Given** a dependency span whose parent is a request span in the same trace, **When** both are
   translated, **Then** they share one `ai.operation.id` and the dependency's `ai.operation.parentId`
   equals the request span's id (nested in the transaction map).

---

### User Story 3 - Cross-service / cross-tier correlation is preserved losslessly (Priority: P2)

Tier A calls tier B. The **OTel SDK** injects `traceparent`/`tracestate` and B's SDK extracts them,
continuing the same trace — Stout does not do this. By the time each finished span reaches the
exporter, its trace id and parent span id already reflect the propagated context. The exporter maps
those ids **byte-for-byte** to `ai.operation.id` / `ai.operation.parentId` / item id in canonical
W3C hex, so the two tiers render as a single end-to-end transaction.

**Why this priority**: Correlation only works if the ids are preserved exactly; a single
transposed/truncated id silently breaks the transaction map. It layers on the working Request and
Dependency paths (US1/US2).

**Independent Test**: Feed a caller `.client` `SpanData` and a callee `.server` `SpanData` whose
parent span id equals the caller's span id (as the SDK would produce), and assert they share one
`ai.operation.id` and the callee's `ai.operation.parentId` equals the caller's item id, verified
against the W3C hex forms; also assert a root span (no parent) yields an empty/absent
`ai.operation.parentId`.

**Acceptance Scenarios**:

1. **Given** any finished span, **When** it is translated, **Then** `ai.operation.id` = trace id
   (32-hex), item id = span id (16-hex), and (non-root) `ai.operation.parentId` = parent span id,
   verifiable byte-for-byte against the canonical W3C hex forms.
2. **Given** a root span (no parent), **When** it is translated, **Then** `ai.operation.parentId` is
   empty/absent.
3. **Given** two tiers whose spans the SDK correlated via W3C propagation, **When** both are
   translated, **Then** they share one `ai.operation.id` and the callee server span's parent id
   equals the caller client span's id.

---

### User Story 4 - Errors and exceptions surface correctly (Priority: P2)

A handler throws. The span is finished with error status and records an `exception` span event. The
exporter marks the owning Request/Dependency `success = false` and emits an associated
`ExceptionData` item — type, message, and (when available) stack trace — correlated to the
operation.

**Why this priority**: Failure visibility is a primary reason teams adopt distributed tracing; a
success flag that ignores error status or a dropped exception undermines trust in the data. It
depends on the working Request/Dependency paths (US1/US2).

**Independent Test**: Pass a span with error `Status` and an `exception` event carrying
`exception.type`/`exception.message`/`exception.stacktrace`; assert the owning item has
`success = false` and that a correlated `ExceptionData` (same operation id, parent id = span id) with
those fields is emitted — and, separately, that error status forces `success = false` even with no
`exception` event.

**Acceptance Scenarios**:

1. **Given** a span finished with error status, **When** it is translated, **Then** the owning
   Request/Dependency has `success = false`, independent of whether an `exception` event exists.
2. **Given** a span carrying an `exception` event, **When** it is translated, **Then** a correlated
   `ExceptionData` is emitted with `type` ← `exception.type`, `message` ← `exception.message`, and
   `stacktrace` ← `exception.stacktrace` when present, sharing the operation id with parent id = the
   span id.

---

### User Story 5 - Span events become correlated messages (Priority: P3)

A span records a non-exception event (a checkpoint / log-like event). The exporter renders it as a
correlated `MessageData` ("trace") item under the same operation, carrying the event name/message
and the event attributes as `properties`.

**Why this priority**: Useful enrichment, but the transaction is already meaningful without
per-event messages; it is additive over the core Request/Dependency/Exception paths.

**Independent Test**: Pass a span with one non-`exception` event and assert a `MessageData` item is
emitted, correlated to the span (same operation id; parent id = span id), with the event
name/message and attributes → `properties`.

**Acceptance Scenarios**:

1. **Given** a span with a non-`exception` event, **When** it is translated, **Then** a correlated
   `MessageData` item is emitted with the event name/message and event attributes → `properties`.

---

### User Story 6 - Graceful shutdown / flush, then go inert (Priority: P3)

On shutdown the SDK calls the exporter's `flush()` and `shutdown()` so buffered telemetry has the
opportunity to flush before exit; the exporter forwards exported spans promptly and does not strand
them. After the underlying pipeline has shut down (drain-and-go-inert, D1), the exporter becomes a
**safe no-op**: `SpanData` handed to `export(...)` post-shutdown is dropped without crashing or
blocking, surfaced only via spec 01's rate-limited internal-diagnostics warning.

**Why this priority**: Correct lifecycle prevents data loss at exit and host hangs, but it is
exercised only once the translation + submission path exists (US1/US2). Flush/drain semantics
themselves are owned by spec 01.

**Independent Test**: Submit spans, invoke `flush()` and assert items are forwarded to the pipeline
promptly; shut the pipeline down, then call `export(...)` and assert the spans are dropped without
crash or block and no telemetry is produced (the drop is surfaced only via spec 01's diagnostics).

**Acceptance Scenarios**:

1. **Given** exported spans buffered by the SDK, **When** `flush()` is called, **Then** the exporter
   forwards its translated items to the spec 01 pipeline promptly and does not strand them.
2. **Given** the underlying pipeline has shut down, **When** `export(...)` is called, **Then** the
   `SpanData` is dropped without crashing or blocking and MUST NOT be emitted as telemetry; the drop
   is surfaced only via spec 01's rate-limited internal-diagnostics warning (never payload data).

---

### Edge Cases

- **Span kind absent/unspecified**: defaults to `RemoteDependencyData` (internal), mirroring .NET.
- **No protocol status attribute** (e.g. an internal span): `responseCode`/`resultCode` is derived
  from span status (default `"0"`), never omitted where the schema requires it.
- **Malformed / missing semantic-convention attributes** (e.g. a URL that won't reconstruct, absent
  `server.address`): the item is still emitted best-effort with the fields that are derivable; the
  unmapped attributes are carried into `properties`; translation never throws into the host.
- **Both current and legacy attribute keys present** (e.g. `http.response.status_code` and
  `http.status_code`): the current key wins; precedence order is FR-018.
- **Root span (no parent)**: `ai.operation.parentId` is empty/absent.
- **Error status with no `exception` event**: the owning item is still `success = false`; no
  `ExceptionData` is fabricated.
- **`exception` event missing some fields** (e.g. no stack trace): the `ExceptionData` is emitted
  with the fields that are present.
- **Span links present**: carried into `properties` (no first-class Breeze span-link field).
- **Oversized events/attributes or a full pipeline buffer**: the item is dropped by spec 01's
  drop-on-overflow buffer, never queued unbounded and never blocking the host.
- **`export(...)` after shutdown**: safe no-op drop with one rate-limited diagnostics warning.

## Requirements *(mandatory)*

### Functional Requirements

**`SpanExporter` implementation & lifecycle**

- **FR-001**: System MUST implement `opentelemetry-swift`'s public `SpanExporter` protocol as an
  Azure Monitor exporter — `export(_ spans:) -> SpanExporterResultCode`, `flush() ->
  SpanExporterResultCode`, and `shutdown()` — registrable with the SDK's `TracerProvider`, normally
  via a `BatchSpanProcessor` (batching and span lifecycle are the SDK's job, not this feature's).
- **FR-002**: System MUST consume each finished span as `SpanData` (name, `SpanKind`, start/end
  nanos, attributes, `Status`, events, links, `SpanContext`/parent context) and MUST NOT start,
  finish, mutate, or manage span context — the SDK owns the span lifecycle.
- **FR-003**: On `export(...)`, System MUST translate each `SpanData` to exactly one Breeze item
  (`RequestData` or `RemoteDependencyData`) plus any derived `ExceptionData`/`MessageData` items from
  its events, and hand them to the spec 01 pipeline.
- **FR-004**: Handing translated items to the pipeline MUST be non-blocking for the SDK's export path
  (no blocking on network I/O or a full buffer — the buffer is bounded and drops on overflow per
  spec 01), and `export(...)` MUST return promptly with a success/failure result code.
- **FR-005**: The exporter MUST be an independently-constructable, injectable object usable and
  unit-testable without a live `TracerProvider`; provider registration is a thin layer over it. After
  the underlying pipeline shuts down (drain-and-go-inert, D1), the exporter MUST become a safe no-op:
  post-shutdown `SpanData` is dropped without crash or block, surfaced only via spec 01's
  rate-limited internal-diagnostics warning (never user telemetry, never payload data).

**Span kind → envelope type**

- **FR-006**: System MUST map SpanKind `.server` and `.consumer` → `RequestData`, and SpanKind
  `.client`, `.producer`, and `.internal` → `RemoteDependencyData`. When span kind is
  absent/unspecified, System MUST default to `RemoteDependencyData` (internal), mirroring the .NET
  exporter.

**Part A correlation tags**

- **FR-007**: System MUST set `ai.operation.id` ← the `SpanData` trace id (canonical 32-hex W3C
  form), `ai.operation.parentId` ← the parent span id (empty/absent for a root span), and the
  telemetry item id ← the span id (canonical 16-hex form), mapped **losslessly** (byte-for-byte).
- **FR-008**: For a `.server`/`.consumer` span whose incoming context carried a propagated
  distributed trace, System MUST populate `RequestData.source` from the messaging/correlation-context
  originating identity where the convention provides one (mirroring the .NET exporter), and leave it
  empty otherwise.
- **FR-009**: System MUST consume `ai.cloud.role`, `ai.cloud.roleInstance`, `ai.internal.sdkVersion`
  (and on-device `ai.device.*` / `ai.application.ver`) from spec 01's resource detection
  (`ResourceDetector.detect(resource:)`), applied **once at exporter registration** to the provider's
  OTel `Resource` and carried by the injected `EnvelopeFactory`; the exporter MUST NOT recompute them
  per span. (A `TracerProvider` has a single `Resource` shared by all its spans, so per-span
  re-detection is unnecessary; the injected factory holds the detected resource tags.)

**RequestData fields (server / consumer spans)**

- **FR-010**: For a Request, System MUST set `id` ← span id; `name` ← span name (HTTP requests SHOULD
  use the route/method-derived name per HTTP semantic conventions when available); `duration` ← end −
  start; unmapped attributes → `properties`; `responseCode` ← `http.response.status_code` (HTTP) or
  `rpc.grpc.status_code` (gRPC), else derived from span status (default `"0"`); `url` ← reconstructed
  from HTTP semantic-convention attributes (`url.full`/`http.url`, or scheme/host/target).
- **FR-011**: System MUST set `RequestData.success` by mirroring the **actual** .NET
  `RequestData.IsSuccess` behavior (research.md D-03): an error span `Status` always forces
  `success = false`; otherwise, for a server/consumer HTTP span with **unset** status, the span is a
  failure when the HTTP code is `0` or `≥ 400` (success iff `code != 0 && code < 400` — so 4xx **and**
  5xx fail); any non-HTTP or non-unset case falls through to `success = (status != error)`.

**RemoteDependencyData fields (client / producer / internal spans)**

- **FR-012**: For a Dependency, System MUST set `id` ← span id; `name` ← span name; `duration` ← end
  − start; unmapped attributes → `properties`; `resultCode` ← `http.response.status_code` (HTTP) or
  `rpc.grpc.status_code` (gRPC), DB/messaging as applicable, else derived from span status (default
  `"0"`); and `success = (span status != error)` **only** — mirroring actual .NET
  `RemoteDependencyData` (research.md D-03), with **no** HTTP/gRPC status-code failure threshold for
  dependencies (a dependency 4xx/5xx with unset status is a success).
- **FR-013**: System MUST set `RemoteDependencyData.type` protocol-derived: `HTTP` for HTTP spans;
  the specific `db.system` value (e.g. `mysql`/`postgresql`) or `SQL` for DB spans; the messaging
  system / queue type for producer/messaging spans; a generic/`InProc` type for internal spans.
- **FR-014**: System MUST set `RemoteDependencyData.target` ← host[:port] for HTTP (from
  `server.address`/`server.port` or the URL), `db.name`/server for DB, `peer.service`/messaging
  destination for messaging.
- **FR-015**: System MUST set `RemoteDependencyData.data` ← the operation detail: `url.full`/
  `http.url` for HTTP, `db.statement`/`db.query.text` for DB, the destination for messaging.

**Semantic-convention mapping (protocol facts — in scope)**

- **FR-016**: System MUST map OpenTelemetry HTTP conventions (`http.request.method`,
  `http.response.status_code`, `url.full`/`url.scheme`/`url.path`, `server.address`/`server.port`,
  and their legacy `http.*` equivalents), database conventions (`db.system`, `db.name`/
  `db.namespace`, `db.statement`/`db.query.text`), RPC/gRPC conventions (`rpc.system`, `rpc.service`,
  `rpc.method`, `rpc.grpc.status_code`), and messaging conventions (`messaging.system`,
  `messaging.destination.name`, operation) to the Request/Dependency fields defined above.
- **FR-017**: System MUST support **both** current and legacy attribute keys where they overlap
  during the OTel semantic-convention transition, preferring the current key when both are present;
  attributes not consumed by a specific mapping MUST be carried into `properties`.
- **FR-018**: The mapping MUST support **both** the current stable OTel semantic-convention keys
  (`http.request.method`, `url.full`, `server.address`, …) and their legacy equivalents
  (`http.method`, `http.url`, `net.peer.name`, …), preferring the current key when both are present
  (mirroring the .NET exporter's `ActivityTagsProcessor` precedence).

**Span events → telemetry**

- **FR-019**: A span event named `exception` MUST produce an `ExceptionData` item correlated to the
  span (same operation id; parent id = span id), populating `type` ← `exception.type`, `message` ←
  `exception.message`, and `stacktrace` ← `exception.stacktrace` from the event attributes when
  present.
- **FR-020**: Any other span event MUST produce a `MessageData` item correlated to the span, with the
  event name/message and event attributes → `properties`.
- **FR-021**: A span status of error MUST force `success = false` on the owning Request/Dependency,
  independent of whether an `exception` event was recorded.
- **FR-022**: Span **links** MUST be carried into `properties` (App Insights has no first-class
  span-link field); no dedicated Breeze field is invented for them.

**Sampling hooks (policy is out of scope — spec 05)**

- **FR-023**: Every emitted telemetry item MUST carry the envelope `sampleRate` field so ingestion
  sampling can be honored. This feature only attaches/propagates `sampleRate`; the sampling
  *decision/policy* is spec 05. Default `sampleRate` when no policy is configured is 100 (no
  sampling). `itemCount` is **not emitted** for trace items (`RequestData`/`RemoteDependencyData`/
  `ExceptionData`/`MessageData`) — it is an aggregation field the trace `baseData` schema does not
  use; `sampleRate` alone carries the sampling weight. (`itemCount` handling for aggregated metrics
  is spec 04's concern.)

**Log/trace correlation contract (shared with spec 03)**

- **FR-024**: The trace-id/span-id → `ai.operation.id`/`ai.operation.parentId` mapping rule defined
  here (canonical W3C hex → `ai.operation.*`) is the shared correlation contract that spec 03's
  `LogRecordExporter` MUST reuse when translating a `ReadableLogRecord`'s SDK-stamped span context.
  This feature MUST NOT implement log translation and MUST NOT maintain any separate ambient context
  for spec 03.

**Cross-cutting non-functional requirements (non-negotiable per constitution)**

- **FR-025**: System MUST NEVER log, place in error/exception messages, or emit as its own
  telemetry/self-diagnostics any connection string, instrumentation key, `iKey`, or token. Span
  attributes forwarded to `properties` are customer data and MUST NOT be logged by this library.
  Invalid configuration MUST fail closed.
- **FR-026**: Translation errors, malformed/oversized attributes or events, and a full/overflowing
  pipeline buffer MUST degrade gracefully (drop the item) and MUST NEVER crash, throw into, or block
  the host application. No unbounded buffers are introduced by this feature.
- **FR-027**: All exporter/translation types MUST compile clean under Swift 6 strict concurrency with
  correct `Sendable` conformance and no data races; concurrent `export(...)` from many tasks MUST be
  safe.
- **FR-028**: The `SpanData` → Breeze mapping MUST be pure and deterministic: identical input yields
  identical output (table-driven, side-effect-free translation).
- **FR-029**: The public API boundary MUST follow SemVer; the mapping rules, propagation ownership,
  and behavior on unknown/unsupported span kinds and attributes MUST be documented.

### Key Entities

- **`SpanData` (input)**: the SDK-produced finished-span record — name, `SpanKind`, start/end nanos,
  attributes, `Status`, events, links, and `SpanContext`/parent context (trace id, span id, parent
  span id, trace flags). Consumed, never mutated.
- **Request telemetry item (`RequestData`)**: the Breeze `baseData` for `.server`/`.consumer` spans —
  `id`, `name`, `duration`, `responseCode`, `success`, `url`, `source`, `properties`.
- **Dependency telemetry item (`RemoteDependencyData`)**: the Breeze `baseData` for
  `.client`/`.producer`/`.internal` spans — `id`, `name`, `duration`, `resultCode`, `success`,
  `type`, `target`, `data`, `properties`.
- **Exception telemetry item (`ExceptionData`)**: derived from an `exception` span event — type,
  message, stack trace — correlated to the owning span.
- **Message telemetry item (`MessageData`)**: derived from a non-`exception` span event — message and
  `properties` — correlated to the owning span.
- **Correlation tag set (Part A)**: `ai.operation.id` (trace id), `ai.operation.parentId` (parent
  span id), and telemetry item id (span id), plus the resource tags consumed from spec 01.
- **Span-kind → envelope-type table**: the deterministic mapping from `SpanKind` to Request vs
  Dependency, including the unspecified-kind default.
- **Semantic-convention mapping tables**: the deterministic HTTP/DB/RPC/messaging attribute →
  Breeze-field mappings, current + legacy keys.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A finished `.server`/`.consumer` span always yields exactly one `RequestData` item, and
  a finished `.client`/`.producer`/`.internal` (or unspecified) span always yields exactly one
  `RemoteDependencyData` item — verified across the full span-kind table.
- **SC-002**: For every finished span, `ai.operation.id` = trace id, item id = span id, and (non-root)
  `ai.operation.parentId` = parent span id, verifiable byte-for-byte against the canonical W3C hex
  forms; a root span yields an empty/absent `ai.operation.parentId`.
- **SC-003**: Across the HTTP/DB/RPC/messaging mapping suites (current + legacy keys), each
  protocol's `type`/`target`/`data`/`responseCode`/`resultCode`/`url`/`success` field is populated
  per the mapping tables; unmapped attributes appear in `properties`.
- **SC-004**: An `exception` span event always produces a correlated `ExceptionData`
  (type/message/stacktrace); a non-exception event always produces a correlated `MessageData`; an
  error span status always forces `success = false` on the owning item (even with no `exception`
  event).
- **SC-005**: Two tiers whose spans the SDK correlated share one `ai.operation.id`, and the callee
  server span's parent id equals the caller client span's id — verifiable from their `SpanData`.
- **SC-006**: Every emitted item carries `sampleRate` (default 100), with this feature making no
  sampling decision; trace items do not emit `itemCount` (not used by the trace `baseData` schema).
- **SC-007**: The trace-id/span-id → `ai.operation.*` mapping used here is identical to the one spec
  03 applies to a `ReadableLogRecord`'s span context, so a log and its owning span correlate to the
  same operation (verified by a shared mapping-rule test).
- **SC-008**: Across the full test matrix, zero test/log/error/diagnostic path ever emits the
  connection string, instrumentation key, or any token; invalid config fails closed.
- **SC-009**: No span translation error, malformed-attribute case, or buffer-full condition ever
  throws into or blocks the host; over-capacity items are dropped, not queued unbounded — verified
  under load.
- **SC-010**: The full translation + correlation test suite (including failure and malformed-attribute
  paths) passes on both an Apple platform (iOS Simulator / macOS) and Linux, with no data-race
  warnings under Swift 6 strict concurrency.

## Assumptions

- **Consumes spec 01, does not redefine it**: the Breeze envelope model, Part A tags, bounded
  drop-on-overflow pipeline, resource detection, connection-string/secret handling, and gzip
  newline-JSON HTTPS transport to `/v2.1/track` already exist and are consumed here.
- **Propagation, span lifecycle, batching, sampling decisions are the SDK's**: `opentelemetry-swift`
  owns `TraceContextPropagator`, `BatchSpanProcessor`, `TracerProvider`, and the sampling decision;
  by the time `SpanData` reaches the exporter the trace id, span id, and parent span id are already
  resolved. This feature is a terminal exporter.
- **Unspecified span kind → Dependency**: default mapping mirrors the .NET exporter (resolves the
  source doc's open question by informed default; see Clarifications).
- **Default `responseCode`/`resultCode` = `"0"`** when no protocol status attribute is present,
  derived from span status; never omitted where the schema requires the field.
- **Span links → `properties`**: App Insights has no first-class span-link concept, so links are
  carried as properties rather than a new Breeze field.
- **`SpanExporter`/`SpanExporterResultCode`/`SpanData` shape** is bound to the pinned
  `opentelemetry-swift` version confirmed during `/speckit-plan` package resolution (implementation
  detail, not a product decision).
- **Sampling policy out of scope**: this feature only attaches `sampleRate`/`itemCount`; the
  decision/policy is spec 05. Default `sampleRate` = 100.
- **Platform posture**: iOS, macOS, watchOS, tvOS (+ visionOS), and Linux on Swift 6, built on
  `opentelemetry-swift` (locked decisions D7/D8); tests run on both an Apple platform and Linux.

## Dependencies

- **Spec 01 — Core ingestion foundation** (the envelope model, pipeline, resource detection,
  connection-string parsing, transport) — consumed, not redefined.
- `opentelemetry-swift` (`OpenTelemetrySdk`) for the `SpanExporter` protocol, `SpanData`,
  `SpanKind`, `Status`, and `SpanContext` types.
- Application Insights ingestion endpoint (or a mock) for end-to-end verification of translated
  items.

## Out of Scope

- **Spec 01 — Core**: the Breeze envelope framework, batch pipeline (buffering, flush,
  drop-on-overflow), resource detection, connection-string parsing/secret handling, gzip newline-JSON
  HTTPS transport, and retry/partial-success — consumed here, not defined.
- **Spec 03 — Logs**: `LogRecordExporter` (`ReadableLogRecord` → `MessageData`/`ExceptionData`),
  severity mapping. This feature only defines the shared trace/span-id → `ai.operation.*` mapping rule
  that spec 03 reuses.
- **Spec 04 — Metrics**: `MetricExporter` (`MetricData` → Breeze `MetricData`), histograms/dimensions.
- **Spec 05 — Ingestion sampling policy**: this feature attaches `sampleRate`/`itemCount`; the
  sampling decision/policy lives in spec 05.
- **Spec 06 — Live Metrics (QuickPulse)**: the proprietary live-stream side-channel, entirely
  separate.
- **W3C context propagation, span lifecycle, sampling decisions, batching**: owned by
  `opentelemetry-swift` (`TraceContextPropagator`, `BatchSpanProcessor`, `TracerProvider`).
- **Auto-instrumentation of frameworks** (Vapor/Hummingbird middleware; on-device
  URLSession/MetricKit) and the distro convenience bootstrap (spec 07) — consumers here use the SDK's
  existing instrumentations that already produce spans.
