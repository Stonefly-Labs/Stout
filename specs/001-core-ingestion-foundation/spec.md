# Feature Specification: Core Ingestion Foundation

**Feature Branch**: `speckit/01-core-ingestion-foundation`

**Created**: 2026-07-09

**Status**: Draft

**Input**: User description: "refer to details in docs/speckit/specs/01-core-ingestion-foundation.md"

## Overview

The signal-agnostic substrate that every Stout telemetry exporter (traces, logs, metrics) is
built on. It provides configuration from an Application Insights connection string, the shared
"Breeze" envelope framework, a bounded buffering-and-export pipeline, resource detection, and an
HTTPS transport abstraction — with no knowledge of any specific signal. It must be safe to run
inside customers' production services **and on end-user devices**: telemetry failures must never
crash or block the host, memory and on-device disk must be bounded, and secrets must never leak.

Concrete signal → Breeze translation (`RequestData`, `RemoteDependencyData`, `ExceptionData`,
`MessageData`, `MetricData`) is delivered by sibling features (specs 02–07) that plug into the
extension point this feature defines.

## Clarifications

### Session 2026-07-09

- Q: When a connection string supplies neither an explicit `IngestionEndpoint` nor an
  `EndpointSuffix`, what should parsing do? → A: Default to the public-cloud endpoint
  `https://dc.services.visualstudio.com/` (mirrors the .NET exporter); `InstrumentationKey` is still
  required and HTTPS is still enforced. Do not fail closed on a missing endpoint alone.
- Q: How should `ai.cloud.role` be composed from `service.namespace` + `service.name`? → A: Mirror
  the .NET exporter — `[{service.namespace}]/{service.name}` (namespace wrapped in square brackets,
  forward-slash separated) when `service.namespace` is present, else `service.name` alone;
  `ai.cloud.roleInstance` = `service.instance.id` when present, else the platform host name.
- Q: What default tuning values should the pipeline ship with? → A: .NET/OpenTelemetry-aligned —
  buffer capacity 2048 items, flush interval 5s, max batch size 512 items, shutdown drain timeout
  30s, and bounded retry of ≤3 in-memory attempts with exponential backoff + jitter capped ~60s.
- Q: How should ingestion HTTP statuses be classified for retry? → A: Mirror the .NET exporter fully
  — whole-response retriable set `{408, 429, 439, 401, 403, 500, 502, 503, 504}`; `206`
  partial-success per-item retriable set is the narrower `{408, 429, 439, 500, 503}`; HTTP `200` =
  success; every other status is dropped. (`439` is an Azure-specific throttling status.)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Configure the exporter from a connection string (Priority: P1)

A developer initializes an exporter by supplying an Application Insights connection string (read
from an environment variable on a server, or from build config / a provisioning profile on a
device). The core parses it, extracts the instrumentation key and endpoints, validates them, and
either yields a usable configuration or fails closed with a clear, secret-free error.

**Why this priority**: Nothing can be sent until the destination and credential are established.
This is the entry point of the entire library and gates every other capability.

**Independent Test**: Feed a matrix of valid and invalid connection strings and assert the parsed
values (or the fail-closed rejection) without any network — fully unit-testable in isolation.

**Acceptance Scenarios**:

1. **Given** a well-formed connection string, **When** it is parsed, **Then** the instrumentation
   key (validated GUID), `IngestionEndpoint`, and `LiveEndpoint` are extracted and endpoints are
   normalized so `{IngestionEndpoint}/v2.1/track` is well-formed (no double or missing slash).
2. **Given** a connection string that is missing `InstrumentationKey`, has a malformed GUID, has a
   non-HTTPS endpoint, has a malformed endpoint URL, has duplicate keys, or is empty, **When** it
   is parsed, **Then** parsing fails closed with a clear error that contains **no secret material**.
3. **Given** a connection string whose casing on keys varies (e.g. `instrumentationkey=`), **When**
   it is parsed, **Then** keys are matched case-insensitively and the value is extracted correctly.
4. **Given** a connection string that carries optional fields (`EndpointSuffix`, an
   authorization/region field such as `AADAudience`), **When** it is parsed, **Then** those fields
   are retained for later features without being consumed or required here.

---

### User Story 2 - Buffer, encode, and export a batch to ingestion (Priority: P1)

A signal exporter hands the core a fully-formed (or factory-stamped) envelope and returns
immediately. The core enqueues it into a bounded buffer, and an async loop flushes batches —
serialized to newline-delimited JSON, gzip-compressed by the core, and POSTed to
`{IngestionEndpoint}/v2.1/track` over HTTPS — treating a fully-accepted response as success.

**Why this priority**: This is the spine of the exporter — the reusable path that carries every
signal to Application Insights. Without it, no telemetry reaches the service.

**Independent Test**: Submit N envelopes against a mock ingestion endpoint; assert the request path,
method, headers, that the body is gzip of exactly N `\n`-delimited JSON lines with Breeze-correct
field names/timestamp format, and that a 200 accepted response ends the exchange.

**Acceptance Scenarios**:

1. **Given** the pipeline is running, **When** a signal exporter submits an item, **Then** the call
   returns without blocking on I/O and the item is enqueued.
2. **Given** buffered items, **When** the batch-size threshold is reached, **Then** a batch is
   flushed; **and separately, When** the flush interval elapses with a partial batch pending,
   **Then** that partial batch is flushed.
3. **Given** a batch of N envelopes, **When** it is encoded, **Then** the payload is exactly N lines
   of `\n`-delimited single-line JSON objects with Breeze-correct field names and timestamp format,
   and it gzip-compresses/decompresses to identical bytes.
4. **Given** an encoded batch, **When** it is transmitted, **Then** it is POSTed to
   `{IngestionEndpoint}/v2.1/track` with `Content-Type: application/x-json-stream` and
   `Content-Encoding: gzip` via the transport abstraction, and a fully-accepted response is treated
   as success.

---

### User Story 3 - Survive backpressure without harming the host (Priority: P2)

When ingestion is slow or unavailable and the bounded buffer fills, new items are dropped rather
than growing memory without bound or blocking the caller, and a dropped-item counter is available
for self-diagnostics.

**Why this priority**: Do-no-harm is non-negotiable, but it layers on top of the working pipeline
(US2). An exporter that harms its host under load is a net negative.

**Independent Test**: With a stalled/mock-blocked transport, submit past capacity and assert
submissions never block, memory stays bounded to the configured capacity, and the dropped counter
increments by exactly the overflow count.

**Acceptance Scenarios**:

1. **Given** the buffer is at capacity, **When** additional items are submitted, **Then** they are
   dropped (never blocked, never OOM) and the dropped-item counter increments accordingly.
2. **Given** sustained backpressure, **When** the pipeline runs over time, **Then** no queue in the
   pipeline (including retry state) grows without bound.

---

### User Story 4 - Deliver reliably through transient failures (Priority: P2)

The core parses partial-success responses and classifies failures so that only retriable items are
retried (honoring `Retry-After`, else exponential backoff with jitter, bounded), while
permanently-rejected items are dropped and recorded in self-diagnostics without leaking payload
secrets.

**Why this priority**: Real networks are lossy; correct retry classification is what makes delivery
trustworthy. It depends on the working transport (US2).

**Independent Test**: Drive the response parser and retry classifier with canned responses
(partial success, `429`/`503` with and without `Retry-After`, `400`/`401`/`403`) and assert which
items retry, the delays used, and that dropped items are recorded secret-free.

**Acceptance Scenarios**:

1. **Given** a partial-success response, **When** it is parsed, **Then** `itemsReceived` /
   `itemsAccepted` and the per-item `errors` array are read correctly, only retriable items are
   retried, and permanently-rejected items are dropped and recorded in self-diagnostics (no secrets).
2. **Given** a `429`/`503` with a `Retry-After` header, **When** retrying, **Then** the indicated
   delay is honored; **and Given** no `Retry-After`, **Then** exponential backoff with jitter is
   used, bounded in attempts and maximum delay.
3. **Given** a `400`/`402`/`404` response, **When** classified, **Then** it is treated as
   non-retriable and dropped rather than retried; **and Given** a `401`/`403`, **Then** it is
   classified retriable (mirroring .NET) and re-attempted within the bounded attempt budget.
4. **Given** a network timeout or connection error (or `408`), **When** classified, **Then** it is
   treated as retriable within the bounded attempt budget.

---

### User Story 5 - Drain and go inert on shutdown (Priority: P2)

On graceful shutdown the core flushes pending items (best-effort within a bounded timeout),
completes in-flight requests, stops the export loop, and closes the HTTP client. Afterward the
pipeline is inert: further submissions are dropped without crashing or blocking; only the first
post-shutdown submission emits a single rate-limited internal-diagnostics warning.

**Why this priority**: Correct lifecycle prevents data loss at exit and prevents host hangs, but it
is exercised only once the pipeline exists (US2).

**Independent Test**: Enqueue items, call shutdown against a mock endpoint, and assert pending items
flush within the timeout, the process does not hang, a second shutdown is a safe no-op, and
post-shutdown submissions are dropped with exactly one warning emitted (no payload data).

**Acceptance Scenarios**:

1. **Given** pending buffered items, **When** shutdown is called, **Then** they are flushed within
   the shutdown timeout, in-flight exports complete, the HTTP client is closed, and the process does
   not hang.
2. **Given** the pipeline has shut down, **When** shutdown is called again, **Then** it is a safe
   no-op.
3. **Given** the pipeline has shut down, **When** an item is submitted, **Then** it is dropped
   without crashing or blocking; only the first such submission emits a rate-limited
   internal-diagnostics warning carrying no payload data.

---

### User Story 6 - Populate cloud role, instance, and device tags via resource detection (Priority: P3)

Resource attributes (from `opentelemetry-swift`'s `Resource` and/or cheap platform detection) are
mapped once onto the Part A tags applied to every envelope, with explicit overrides taking
precedence over auto-detection.

**Why this priority**: Correct role/instance/device attribution improves telemetry quality but the
pipeline is functional without it; it is an enrichment layer over US2.

**Independent Test**: Provide resource attributes and explicit overrides, then assert the resulting
Part A tags on emitted envelopes, including override-beats-detection precedence — no network needed.

**Acceptance Scenarios**:

1. **Given** resource attributes, **When** tags are computed, **Then** `service.name` (optionally
   combined with `service.namespace`) maps to `ai.cloud.role`, `service.instance.id` (falling back
   to `host.name`) maps to `ai.cloud.roleInstance`, and `ai.internal.sdkVersion` is set to
   `stout:<version>`.
2. **Given** the exporter runs on an Apple device with device/app attributes available, **When**
   tags are computed, **Then** `ai.device.*` and `ai.application.ver` are populated when available.
3. **Given** both an explicit override and an auto-detected value for the same tag, **When** tags
   are computed, **Then** the explicit override wins.
4. **Given** the resource tag set is computed, **When** each envelope is stamped, **Then** the
   resource tags are applied to every envelope and merged with any per-item signal-specific Part A
   tags.

---

### Edge Cases

- **Only `EndpointSuffix` supplied (no explicit `IngestionEndpoint`)**: the ingestion endpoint is
  derived as `https://[{location}.]dc.{EndpointSuffix}`; when neither an explicit endpoint nor a
  suffix is available, the default public-cloud endpoint `https://dc.services.visualstudio.com/` is
  used (see FR-004).
- **Duplicate keys / trailing separators / surrounding whitespace** in the connection string are
  rejected or normalized deterministically, never silently guessed.
- **Ingestion returns a body that is empty, non-JSON, or malformed**: treated as a non-fatal
  transport outcome (classified for retry/drop) without crashing the pipeline.
- **All items in a batch are permanently rejected**: the batch is dropped with self-diagnostics; no
  infinite retry.
- **Shutdown called while a retry backoff is pending**: shutdown still completes within its bounded
  timeout rather than waiting out the backoff.
- **Clock/timestamp formatting**: timestamps always serialize as UTC ISO-8601 with fractional
  seconds and `Z`, regardless of host locale/timezone.
- **Concurrent producers** submitting simultaneously never corrupt the buffer or race.

## Requirements *(mandatory)*

### Functional Requirements

**Connection string parsing & validation**

- **FR-001**: System MUST parse an Application Insights connection string as a case-insensitive,
  semicolon-delimited list of `Key=Value` pairs and extract at minimum `InstrumentationKey`,
  `IngestionEndpoint`, and `LiveEndpoint`.
- **FR-002**: System MUST recognize and retain optional fields when present — `EndpointSuffix` and
  any standard authorization/region field (e.g. `AADAudience`) — without consuming or requiring them
  in this feature.
- **FR-003**: System MUST validate that `InstrumentationKey` is present and a well-formed GUID, and
  that endpoints are well-formed absolute HTTPS URLs, and MUST fail closed on any missing required
  field, malformed GUID, non-HTTPS or malformed endpoint URL, duplicate key, or empty input.
- **FR-004**: System MUST resolve the ingestion endpoint in strict precedence: (1) an explicit
  `IngestionEndpoint` if present; else (2) derive `https://[{location}.]dc.{EndpointSuffix}` when
  `EndpointSuffix` is present (with an optional alphanumeric location prefix); else (3) fall back to
  the default public-cloud endpoint `https://dc.services.visualstudio.com/`. Endpoint resolution
  MUST NOT fail closed on a missing endpoint alone (a valid connection string may legitimately omit
  it); `InstrumentationKey` remains required and HTTPS remains enforced on any explicit endpoint.
- **FR-005**: System MUST normalize endpoint URLs (e.g. trailing-slash handling) so the transport
  reliably builds `{IngestionEndpoint}/v2.1/track` with no double slash and no missing separator.

**Breeze envelope framework**

- **FR-006**: System MUST provide a common Envelope model with fields `ver` (envelope schema version
  = 1, omitted on the wire by default), `name`, `time` (UTC ISO-8601 with fractional seconds and
  `Z`), `sampleRate` (percentage, default 100), `iKey`, `tags` (Part A dictionary), and `data` (a
  container with `baseType` discriminator and `baseData` payload whose `ver` = 2).
- **FR-007**: System MUST own the envelope, the Part A `tags` model, the `data`/`baseType`/`baseData`
  container shape, and all shared schema constants, and MUST expose a clean extension point so
  sibling features supply their own `baseData` payload types without the core depending on them.
  Concrete signal `baseData` types are out of scope here.
- **FR-008**: System MUST carry `sampleRate` in the model from the outset (default 100 = no
  sampling) and serialize it; sampling decision logic is out of scope.
- **FR-009**: System MUST serialize each envelope as a single-line JSON object and encode a batch as
  newline-delimited JSON (`\n`-separated, one envelope per line) with field names, structure,
  timestamp, and enum-like string forms matching the Breeze wire contract.
- **FR-010**: System MUST gzip-compress the newline-JSON request body itself on every platform
  (neither transport auto-compresses request bodies) and set `Content-Encoding: gzip`.

**Generic telemetry pipeline**

- **FR-011**: The pipeline/exporter MUST be an independently-constructable, injectable object usable
  and testable without mutating process-global state; any global/facade bootstrap is a thin layer
  atop it.
- **FR-012**: System MUST provide a `Sendable` bounded buffer + batch processor that accepts
  fully-formed or factory-stamped envelopes from any signal adapter, and MUST return from submission
  without blocking the caller on I/O.
- **FR-013**: System MUST flush a batch when EITHER a configurable batch-size threshold is reached OR
  a configurable time interval elapses since the last flush — whichever comes first — driven by an
  async export loop decoupled from the enqueue call.
- **FR-014**: System MUST enforce bounded buffer capacity with drop-on-overflow (never block, never
  grow unbounded) and expose a dropped-item counter for self-diagnostics.
- **FR-015**: System MUST perform graceful drain-and-go-inert shutdown: stop accepting items, flush
  pending items best-effort within a bounded timeout, await in-flight exports, terminate the export
  loop, and close the HTTP client. Shutdown MUST be idempotent and MUST NOT hang the host.
- **FR-016**: After shutdown the pipeline MUST be inert — further submissions dropped without crash
  or block — with the first post-shutdown submission emitting a single rate-limited
  internal-diagnostics warning (never via the user telemetry pipeline, never carrying payload data)
  and subsequent ones silently dropped.
- **FR-017**: All configuration knobs MUST have safe, documented defaults, aligned with the
  .NET/OpenTelemetry exporter: buffer capacity 2048 items, flush interval 5s, max batch size 512
  items, shutdown drain timeout 30s, and bounded retry of at most 3 in-memory attempts with
  exponential backoff + full jitter capped at 60s (see FR-026 for the exact schedule).

**Resource detection**

- **FR-018**: System MUST compose `ai.cloud.role` as `[{service.namespace}]/{service.name}` (the
  namespace wrapped in square brackets, forward-slash separated) when `service.namespace` is present,
  else `service.name` alone; compose `ai.cloud.roleInstance` as `service.instance.id` when present,
  else the platform host name; and set `ai.internal.sdkVersion` = `stout:<version>`. This mirrors the
  .NET exporter's role-name logic for cross-SDK Application Map consistency.
- **FR-019**: On Apple platforms, System MUST additionally map available device/app attributes to
  `ai.device.*` and `ai.application.ver`, sourced from the `Resource` and/or platform APIs.
- **FR-020**: System MUST support auto-detection of cheaply-available defaults per platform and allow
  explicit overrides that take precedence over detection.
- **FR-021**: System MUST compute the resource tag set once and apply it to every envelope's `tags`,
  merged with any per-item signal-specific Part A tags.

**HTTP transport & reliability**

- **FR-022**: System MUST expose a single `Sendable` transport protocol with two compile-time
  implementations selected via platform capability detection — URLSession on Apple platforms and
  `async-http-client` on Linux — such that the pipeline and signal exporters depend only on the
  protocol, never on a concrete client.
- **FR-023**: System MUST POST the gzip-compressed newline-JSON batch to
  `{IngestionEndpoint}/v2.1/track` over HTTPS with `Content-Type: application/x-json-stream` and
  `Content-Encoding: gzip`, defaulting the ingestion host to `https://dc.services.visualstudio.com`
  when the connection string supplies none.
- **FR-024**: System MUST parse the ingestion response for `itemsReceived`, `itemsAccepted`, and the
  per-item `errors` array (index, status code, message) to detect partial success.
- **FR-025**: System MUST classify results — HTTP `200` (fully accepted) → done; a retriable
  whole-response status in `{408, 429, 439, 401, 403, 500, 502, 503, 504}`, a timeout, or a
  connection error → retry; a `206` partial-success → parse per-item errors and retry only items
  whose per-item status is in the narrower set `{408, 429, 439, 500, 503}`, dropping the rest; any
  other status (e.g. `400`, `402`, `404`) → drop and record in self-diagnostics without re-logging
  payload secrets. (`439` is an Azure-specific throttling status.) The non-retriable set and the
  in-memory attempt bound are specified in FR-027; the backoff schedule in FR-026.
- **FR-026**: System MUST honor a `Retry-After` response header when present (parsed as either
  delta-seconds or an HTTP-date). When absent, System MUST use **exponential backoff with full
  jitter**: `delay = random(0, min(maxRetryDelay, baseDelay × 2^attempt))` with `baseDelay` = 1s and
  `attempt` starting at 0, bounded by `maxRetryAttempts` (default 3) and `maxRetryDelay` (default
  60s).
- **FR-027**: System MUST treat non-listed statuses (e.g. `400`, `402`, `404`) as non-retriable
  (dropped, not retried). Per the clarification, `401`/`403` ARE classified retriable — mirroring the
  .NET exporter, to survive the token refresh added in spec 05; with no auth layer in this feature
  they simply exhaust the bounded attempt budget. All retry state MUST be kept in-memory and bounded
  (durable disk-backed retry is out of scope). Note: this bounded in-memory retry is a **deliberate
  mechanism divergence** from the .NET exporter's unbounded disk-backed retry timer — the "mirror
  .NET fully" clarification governs the status-code *classification*, not the retry transport.

**Cross-cutting non-functional requirements (non-negotiable per constitution)**

- **FR-028**: System MUST NEVER log, include in error/exception messages, surface in
  self-diagnostics/self-telemetry, or expose via public API/debug dumps the connection string,
  instrumentation key, or any token; redaction MUST be the default on every diagnostic path.
- **FR-029**: System MUST enforce HTTPS-only endpoints and reject non-HTTPS ingestion endpoints.
- **FR-030**: All shared types crossing concurrency boundaries MUST be `Sendable` and MUST compile
  clean under Swift 6 strict concurrency with no data races and no suppressed warnings.
- **FR-031**: Telemetry failures (parse, network, ingestion rejection, overflow) MUST NEVER crash,
  throw into the host's hot path, or block the host; they degrade gracefully and surface only via
  self-diagnostics.
- **FR-032**: Runtime dependencies MUST be limited to `opentelemetry-swift` data types,
  Foundation/URLSession (Apple), and `async-http-client` (Linux only, conditional); any additional
  runtime dependency MUST be justified.
- **FR-033**: The public API boundary MUST be explicit and documented, with anything not intended for
  consumers kept non-public, following SemVer discipline.
- **FR-034**: Background/streaming upload (e.g. URLSession background sessions for app-suspension
  delivery) is deferred as an Apple-only enhancement behind the same transport protocol and is not
  part of this feature's scope (see Assumptions).

### Key Entities

- **Connection Configuration**: the validated result of parsing a connection string — instrumentation
  key, normalized ingestion endpoint, live endpoint, and retained optional fields. Holds secrets;
  never rendered in diagnostics.
- **Envelope**: the shared Breeze item wrapper — `ver`, `name`, `time`, `sampleRate`, `iKey`, Part A
  `tags`, and a `data` container (`baseType` + `baseData`). Owns the extension point for
  signal-specific `baseData`.
- **Part A Tag Set**: the resource-derived tag dictionary (`ai.cloud.role`, `ai.cloud.roleInstance`,
  `ai.internal.sdkVersion`, and on-device `ai.device.*` / `ai.application.ver`) computed once and
  applied to every envelope.
- **Telemetry Batch**: an ordered set of envelopes encoded as newline-delimited JSON and
  gzip-compressed for a single POST.
- **Bounded Buffer / Pipeline**: the `Sendable` queue + async export loop with fixed capacity,
  drop-on-overflow accounting, flush triggers, and drain-and-go-inert lifecycle.
- **Transport**: the `Sendable` protocol abstraction over the platform HTTP client, plus its
  request/response shape and header contract.
- **Ingestion Response**: the parsed result carrying `itemsReceived`, `itemsAccepted`, per-item
  errors, and status — the input to retry/drop classification.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Submitting a telemetry item returns to the caller without waiting on network I/O in
  100% of cases, including when the endpoint is unreachable.
- **SC-002**: Across the full test matrix (valid connection strings, every invalid variant,
  serialization round-trips, all transport failure paths, shutdown, resource mapping), zero test,
  log, error, or diagnostic path ever emits the connection string, instrumentation key, or any token.
- **SC-003**: Under sustained overload the pipeline's memory footprint never exceeds the configured
  buffer capacity, and the dropped-item counter equals the exact number of items submitted past
  capacity.
- **SC-004**: A batch of N envelopes always encodes to exactly N newline-delimited JSON lines that
  gzip-decompress to identical bytes and match the Breeze wire contract for field names and timestamp
  format.
- **SC-005**: Graceful shutdown always completes within the configured timeout without hanging the
  host, a second shutdown is always a no-op, and post-shutdown submissions produce exactly one
  diagnostic warning regardless of how many are submitted.
- **SC-006**: Given a partial-success response, only the retriable items are retried and every
  permanently-rejected item is dropped and recorded — verified for partial success, `Retry-After`,
  backoff-with-jitter, and retriable-vs-non-retriable classification.
- **SC-007**: The full test suite passes on both an Apple platform (iOS Simulator / macOS) and Linux,
  exercising both transport backends, with no data-race warnings under Swift 6 strict concurrency.

## Assumptions

- **Track path and versions**: the ingestion path is `{IngestionEndpoint}/v2.1/track`, envelope
  `ver` = 1 (omitted on the wire by default), each `data.baseData.ver` = 2, and the default host is
  `https://dc.services.visualstudio.com` (locked decision D2 — not open).
- **Background-session upload out of scope**: URLSession background-session / app-suspension delivery
  is deferred to a later iOS-hardening feature; the core MVP uses standard foreground transport
  behind the transport protocol (FR-034). This resolves the source doc's background-upload open
  question by deferral.
- **Immediate/in-memory retry only**: durable, disk-backed persistence of un-sent telemetry across
  retries is out of scope (later hardening feature); retry state is bounded and in-memory.
- **Signal payloads out of scope**: concrete `baseData` types and signal→Breeze translation are
  delivered by specs 02 (tracing), 03 (logging), 04 (metrics); this feature defines only the
  envelope/tag/encoding framework and the extension point.
- **Later-feature concerns out of scope here**: ingestion sampling logic, Entra/AAD ingestion auth
  (spec 05), Live Metrics / QuickPulse (spec 06), and one-call distro bootstrap (spec 07) are
  excluded; auth-related connection-string fields are only retained, not consumed.
- **Gzip strategy is a planning decision**: the specific cross-platform gzip mechanism (system
  `zlib` vs a Swift package) is an implementation choice deferred to the plan; the requirement is
  that the core compresses request bodies itself on every platform.
- **Default tuning values**: resolved (see Clarifications) — buffer 2048 items, flush 5s, max batch
  512, shutdown timeout 30s, and ≤3 in-memory retry attempts with exponential backoff + full jitter
  capped at 60s, aligned with the .NET/OpenTelemetry exporter (FR-017/FR-026).
- **Platform posture**: the feature targets iOS, macOS, watchOS, tvOS (+ visionOS), and Linux on
  Swift 6, built on `opentelemetry-swift` (locked decisions D7/D8).

## Dependencies

- `opentelemetry-swift` (`OpenTelemetrySdk`) data types consumed by sibling signal exporters.
- Foundation / URLSession on Apple platforms; `async-http-client` on Linux only (conditional).
- A reachable Application Insights ingestion endpoint (or a mock) for integration-level tests.

## Out of Scope

- Signal → Breeze translation and concrete `baseData` payload types (specs 02–04).
- Durable, disk-backed offline persistence of un-sent telemetry (later hardening feature).
- Ingestion sampling decision logic (core carries only the `sampleRate` field).
- Entra / AAD token authentication on the ingestion channel (spec 05).
- Live Metrics / QuickPulse (spec 06) — separate endpoint, data model, and protocol.
- One-call distro bootstrap and framework middleware (spec 07).
- URLSession background-session upload (later iOS-hardening item; FR-034).
