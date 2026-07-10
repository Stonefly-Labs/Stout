# Spec 01 — Core Ingestion Foundation

Pass the prompt below to `/speckit.specify`.

---

Build the **core ingestion foundation** for `stout`, a collector-free, open-source Azure Monitor / Application Insights exporter built on the **OpenTelemetry Swift SDK (`opentelemetry-swift`)**, running cross-platform on **iOS, macOS, watchOS, tvOS (+ visionOS), and Linux** (Swift 6). This is the substrate that every telemetry signal exporter (traces, logs, metrics) is built on. It does NOT know about any specific signal; it provides the configuration, envelope framework, buffering/exporting pipeline, resource detection, and HTTP transport abstraction that the sibling signal exporters plug into.

## Overview / Why

Application Insights ingestion does not accept OTLP as a GA, collector-free path. The only supported direct path is to translate telemetry into the legacy Application Insights **"Breeze"** schema and POST it to the ingestion endpoint over HTTPS. Microsoft ships this exporter for .NET, Java, Node.js, and Python — but not Swift. This feature delivers the reusable, signal-agnostic core of that Breeze exporter for Swift so that any Swift app — an iOS/macOS/watchOS/tvOS client or a Linux/macOS server, instrumented with `opentelemetry-swift` — can send telemetry directly to Application Insights with no OpenTelemetry Collector and no Azure Monitor Agent.

Consumers of this core are the sibling signal exporter modules (tracing, logging, metrics — each implementing an `opentelemetry-swift` exporter protocol) and, eventually, a one-call provider-configuration layer. The core must be safe to run inside customers' production services **and on end-user devices**: telemetry failures must never crash or block the host, memory and on-device disk must be bounded, and secrets must never leak.

> Locked design decisions: see design.md §11 (D1–D4, D7–D9) and §2/§12. This spec reflects D1 (lifecycle/shutdown), D2 (ingestion path), D7 (platforms), and D9 (transport abstraction).

## Consumer scenarios

1. **A signal exporter configures the transport from a connection string.** A developer initializes the exporter by supplying an Application Insights connection string (typically read from an environment variable on a server, or from build config / a provisioning profile on a device). The core parses it, extracts the instrumentation key and ingestion endpoint, validates it, and fails closed with a clear (secret-free) error if it is malformed or missing required fields.

2. **A signal exporter submits a telemetry item for export.** A `SpanExporter`/`LogRecordExporter`/`MetricExporter` implementation translates `opentelemetry-swift` data (`SpanData`/`ReadableLogRecord`/`MetricData`) into a signal-specific `baseData` payload, hands it to the core wrapped in an envelope (or via a core-provided factory that stamps the common Part A tags, `iKey`, `time`, and `sampleRate`), and returns immediately. The core enqueues the item into a bounded buffer and returns without blocking the caller.

3. **The pipeline flushes automatically.** Buffered items are flushed to ingestion when either the batch-size threshold is reached OR a time interval elapses, whichever comes first. An async export loop serializes the batch to newline-delimited JSON, gzip-compresses it (**the core gzips request bodies itself** — see transport below), and POSTs it to `{IngestionEndpoint}/v2.1/track` (default host `https://dc.services.visualstudio.com`) via the transport abstraction (URLSession on Apple platforms, async-http-client on Linux).

4. **Ingestion partially accepts a batch.** The endpoint responds that some items were accepted and others rejected (per-item errors). The core parses `itemsReceived` / `itemsAccepted` and per-item errors, retries only the retriable failures, and drops permanently-rejected items (surfacing them via self-diagnostics without leaking payload secrets).

5. **The endpoint is slow or unavailable and the buffer fills.** Under sustained backpressure the bounded buffer reaches capacity. New items are **dropped** (drop-on-overflow) rather than growing memory without bound or blocking the host. A counter of dropped items is available for self-diagnostics.

6. **The host application shuts down.** On graceful shutdown the core follows the **drain-and-go-inert** contract (D1): it flushes pending buffered items (best-effort, within a bounded timeout), completes in-flight requests, stops the export loop, and closes the HTTP client. After shutdown the pipeline is **inert** — any further submission is dropped (never crashes, never blocks); the first such post-shutdown submission emits a single rate-limited warning via the library's internal diagnostics channel (never the user telemetry pipeline, never any payload data), and subsequent ones are silently dropped.

7. **Resource attributes populate cloud role/instance (and device tags on-device).** The `opentelemetry-swift` `Resource` provides attributes (e.g. `service.name`, `service.namespace`, `service.instance.id`, `host.name`, and on Apple platforms device/app attributes) or the core accepts auto-detected defaults; the core maps them onto the Part A tags (`ai.cloud.role`, `ai.cloud.roleInstance`) and stamps `ai.internal.sdkVersion`. On-device, resource detection can additionally populate `ai.device.*` (device model/OS/type) and `ai.application.ver` (app version) when available. Explicit overrides take precedence over detection.

## Functional requirements

### Connection string parsing
- Parse an Application Insights connection string of the form:
  `InstrumentationKey=<guid>;IngestionEndpoint=https://<region>.in.applicationinsights.azure.com/;LiveEndpoint=https://<region>.livediagnostics.monitor.azure.com/`
- The format is a case-insensitive, semicolon-delimited list of `Key=Value` pairs. Extract at minimum: `InstrumentationKey` (the iKey), `IngestionEndpoint`, and `LiveEndpoint`. Also recognize and retain optional fields if present: `EndpointSuffix` (used to derive default endpoints when explicit endpoints are absent), and any authorization/region-related field present in the standard format (e.g. `AADAudience`) — retained for later specs, not consumed here.
- If `IngestionEndpoint` is absent but `EndpointSuffix` (and optionally a location prefix) is present, derive the ingestion endpoint per the standard Application Insights rules. If neither an explicit endpoint nor a suffix is available, [NEEDS CLARIFICATION: is a hard-coded default public-cloud ingestion endpoint acceptable, or should parsing fail closed?].
- Validate: `InstrumentationKey` MUST be present and be a well-formed GUID; endpoints MUST be well-formed absolute HTTPS URLs. Reject and fail closed on missing required fields, malformed GUID, non-HTTPS or malformed endpoint URLs, duplicate keys, or empty input.
- Normalize endpoint URLs (e.g. trailing-slash handling) so that the transport can reliably build `{IngestionEndpoint}/v2.1/track` without producing double slashes or a missing separator.

### Breeze envelope framework
- Provide the common **Envelope** structure with these fields: `ver` (schema version integer — envelope `ver` = 1, omitted on the wire by default per D2), `name` (the telemetry item type name / envelope name string), `time` (UTC timestamp, ISO-8601 with fractional seconds and `Z`), `sampleRate` (percentage, default 100), `iKey` (the instrumentation key), `tags` (the Part A tag dictionary), and `data` — a container carrying `baseType` (string discriminator, e.g. `RequestData`, `MetricData`) and `baseData` (the signal-specific payload; each `baseData.ver` = 2 per D2).
- The core owns the envelope, the `tags`/Part A model, the `data`/`baseType`/`baseData` container shape, and all shared schema constants (schema `ver`, envelope names, `baseType` discriminators). The core defines a **clean extension point** for `baseData` so that sibling signal specs can supply their own payload types (`RequestData`, `RemoteDependencyData`, `ExceptionData`, `MessageData`, `MetricData`) without the core depending on them. The concrete signal `baseData` payload types are OUT OF SCOPE here (defined by sibling specs).
- Carry `sampleRate` in the envelope model from day one (default 100 = no sampling). Sampling *logic* is out of scope; the field and its serialization are in scope.
- Encoding: serialize each envelope as a single JSON object on one line, and encode a batch as **newline-delimited JSON** (one envelope per line, `\n`-separated) — Content-Type `application/x-json-stream`. JSON field naming and structure MUST match the Breeze wire contract. Timestamps and enum-like values MUST serialize in the exact string forms ingestion expects.
- Provide **gzip** compression of the newline-JSON payload for transport (Content-Encoding `gzip`). The core MUST compress the request body **itself** on every platform — neither URLSession (Apple) nor the Linux client auto-compresses request bodies — using a cross-platform gzip strategy [PLAN: system `zlib` vs a Swift package].

### Generic telemetry pipeline
- The pipeline/exporter MUST be an **independently-constructable, injectable object** (for DI and testability) — the testability seam per D1. Any global/facade `bootstrap()` is a thin layer on top of it; the object itself is usable and testable without mutating process-global state.
- Provide a `Sendable` buffer + batch processor that accepts fully-formed (or factory-stamped) envelopes from any signal adapter.
- Flush a batch when EITHER a configurable **batch-size** threshold is reached OR a configurable **time interval** elapses since the last flush — whichever comes first.
- Run an **async export loop** that pulls batches and drives the transport, decoupled from the enqueue call so producers never block on I/O.
- Enforce **bounded capacity** with **drop-on-overflow**: when the buffer is full, new items are dropped (never block the caller, never grow unbounded). Expose a dropped-item counter for self-diagnostics.
- **Graceful shutdown (drain-and-go-inert, D1)**: on shutdown, stop accepting new items, flush pending items (best-effort within a bounded timeout), await in-flight exports, terminate the export loop, and close the HTTP client. Shutdown MUST be idempotent and MUST NOT hang the host process. After shutdown the pipeline is **inert**: further submissions are dropped and MUST NOT crash or block; the first post-shutdown submission emits a single **rate-limited warning** via the library's internal diagnostics channel — never the user telemetry pipeline and never any payload data — with subsequent post-shutdown submissions silently dropped.
- All configuration knobs (batch size, flush interval, buffer capacity, shutdown timeout) MUST have safe defaults and MUST be documented.

### Resource detection
- Map resource attributes to Part A tags:
  - `service.name` (optionally combined with `service.namespace`) → `ai.cloud.role`.
  - `service.instance.id` (falling back to `host.name`) → `ai.cloud.roleInstance`.
  - Set `ai.internal.sdkVersion` = `stout:<version>`, where `<version>` is the library's package version.
- On-device (Apple platforms), additionally map device/app attributes when available: `ai.device.*` (e.g. device model, OS name/version, device type) and `ai.application.ver` (app version/build), sourced from the `opentelemetry-swift` `Resource` and/or platform APIs.
- Support **auto-detection** of sensible defaults (e.g. host name, process/service identity on servers; device/app identity on-device) where cheaply available on each platform, and allow **explicit overrides** that take precedence over detection. [NEEDS CLARIFICATION: exact precedence and combination rule for `service.namespace` + `service.name` when forming `ai.cloud.role` — confirm against the .NET exporter's role-name logic.]
- Resource tags are computed once and applied to every envelope's `tags` (merged with any signal-specific Part A tags supplied per item).

### HTTP transport & reliability
- Provide a single **`Sendable` transport protocol** (one abstraction) with two implementations selected at compile time via `#if canImport(FoundationNetworking)` (D9):
  - **Apple platforms (iOS/macOS/watchOS/tvOS/visionOS)** → **URLSession**.
  - **Linux** → **`async-http-client`** (a Linux-only, conditional dependency; Linux's `URLSession`/`FoundationNetworking` is too limited for this workload).
  - This mirrors Apple's own `swift-openapi-urlsession` + `async-http-client` split. Signal exporters and the pipeline depend only on the protocol, never on a concrete client.
- The core **gzips the request body itself** before handing it to either transport (URLSession does not auto-compress request bodies, and neither does the Linux client). Background/streaming upload (e.g. `URLSession` background sessions for app-suspension delivery) is an Apple-only enhancement layered behind the same protocol; [NEEDS CLARIFICATION: whether background-session upload is in scope for the core MVP or a later iOS-hardening item].
- POST the gzip-compressed newline-JSON batch to `{IngestionEndpoint}/v2.1/track` over HTTPS with headers `Content-Type: application/x-json-stream` and `Content-Encoding: gzip`. The `/v2.1/track` path is decided (D2; `/v2/track` is the older classic-SDK path). Default ingestion host `https://dc.services.visualstudio.com` when the connection string supplies none.
- Parse the ingestion **response body** for `itemsReceived` and `itemsAccepted`, and the per-item `errors` array (each with an item index, a status code, and a message) to detect **partial success**.
- Classify results:
  - Fully accepted → done.
  - Partial success / per-item retriable errors (e.g. throttling `429`, transient `500`/`503`) → retry only the retriable items.
  - Permanent per-item errors (e.g. `400` invalid item) → drop those items and record them in self-diagnostics (never re-log payload secrets).
- Honor the `Retry-After` response header (when present) for the retry delay.
- When `Retry-After` is absent, use **exponential backoff with jitter** for retriable failures, up to a bounded maximum number of attempts and a bounded maximum delay.
- Retries in this spec are **immediate/in-memory** only (bounded attempts against the in-flight batch). Durable disk-backed persistence across retries is OUT OF SCOPE (later hardening spec).
- Distinguish retriable network/HTTP failures (timeouts, connection errors, `408`/`429`/`5xx`) from non-retriable ones (`400`/`401`/`403`) so that non-retriable failures are dropped rather than retried indefinitely.

## Non-functional / quality requirements (OSS — non-negotiable)

**Security**
- Connection strings, instrumentation keys, and any tokens are **secrets**: they MUST NEVER be logged, MUST NEVER appear in error messages, exception descriptions, or self-diagnostic/self-telemetry output, and MUST NOT be surfaced in any public API description or debug dump. Redact on any diagnostic path.
- Validate all external input (connection string, resource attributes, endpoint URLs) and **fail closed** on invalid input rather than sending to a wrong or insecure destination.
- Enforce HTTPS-only endpoints. Reject non-HTTPS ingestion endpoints.
- Keep dependencies minimal and auditable; every runtime dependency must be justified. The core depends on `opentelemetry-swift` (`OpenTelemetrySdk` data types), Foundation/URLSession (Apple), and `async-http-client` **(Linux only, conditional)** — no others without justification.

**Stability**
- Swift 6 **strict concurrency**: all shared types crossing concurrency boundaries are `Sendable`; no data races. The buffer/pipeline is safe under concurrent producers.
- Telemetry failures (parse errors, network errors, ingestion rejections, buffer overflow) MUST NEVER crash the host, throw into the host's hot path, or block the host application. They degrade gracefully and are surfaced only via self-diagnostics.
- **Bounded memory**: the buffer has a hard capacity; overflow drops items. No unbounded growth is permitted anywhere in the pipeline (including retry queues).
- Robust retry/backoff with bounded attempts and delays; no unbounded retry storms.

**Quality**
- High test coverage including: connection-string parsing (valid, each invalid variant, endpoint derivation), envelope serialization (exact newline-JSON + field-name wire correctness), gzip round-trip, buffer flush-on-size and flush-on-interval, drop-on-overflow accounting, graceful-shutdown flush, resource-tag mapping/override precedence, and every transport failure path (partial success, `Retry-After`, backoff, retriable vs non-retriable classification). **Testing MUST cover both an Apple platform (iOS simulator / macOS) AND Linux** — the two transport backends and their Foundation differences are real and must both be exercised.
- Clear, documented **public API** boundary; SemVer discipline; documented default behaviors and configuration knobs.

## Acceptance criteria

1. Given a well-formed connection string, parsing yields the correct iKey (validated GUID), `IngestionEndpoint`, and `LiveEndpoint`; endpoints are normalized so `{IngestionEndpoint}/v2.1/track` is well-formed.
2. Given a connection string missing `InstrumentationKey`, with a malformed GUID, with a non-HTTPS endpoint, with a malformed endpoint URL, with duplicate keys, or empty — parsing fails closed with a clear error that contains **no secret material**.
3. A batch of N envelopes serializes to exactly N lines of `\n`-delimited JSON, each a valid single-line JSON object with Breeze-correct field names and timestamp format, and gzip-compresses/decompresses to the identical bytes.
4. Submitting an item returns without blocking; the item is flushed when the batch-size threshold is hit and, separately, when the flush interval elapses with a partial batch pending.
5. When the buffer is at capacity, additional submissions are dropped (not blocked, not OOM), and the dropped-item counter increments accordingly.
6. On graceful shutdown (drain-and-go-inert), pending items are flushed within the shutdown timeout, in-flight exports complete, the HTTP client is closed, and the process does not hang; a second shutdown call is a safe no-op. Post-shutdown submissions are dropped without crashing/blocking, and only the first emits a rate-limited internal-diagnostics warning (no payload data).
7. A batch POST targets `{IngestionEndpoint}/v2.1/track` with the correct method and `Content-Type`/`Content-Encoding` headers via the transport abstraction (URLSession on Apple, async-http-client on Linux), with the request body gzip-compressed by the core; a fully-accepted response is treated as success.
8. A partial-success response is parsed correctly; only retriable items are retried and permanently-rejected items are dropped and recorded in self-diagnostics (without secrets).
9. A `429`/`503` with `Retry-After` waits the indicated delay; without `Retry-After`, retries use exponential backoff with jitter, bounded in attempts and max delay; `400`/`401`/`403` are not retried.
10. Resource attributes map to `ai.cloud.role` / `ai.cloud.roleInstance` correctly, `ai.internal.sdkVersion` = `stout:<version>`, on-device `ai.device.*` / `ai.application.ver` populate when available, and explicit overrides beat auto-detection.
11. No test, log, or error path ever emits the connection string, iKey, or any token.
12. All public pipeline/transport/config types compile clean under Swift 6 strict concurrency (`Sendable`, no data-race warnings) on **both an Apple platform and Linux**.

## Out of scope (sibling specs)

- **Signal → Breeze translation** and the concrete `baseData` payload types, each implemented as an `opentelemetry-swift` exporter: `SpanData` → `RequestData`/`RemoteDependencyData`/`ExceptionData` (spec 02 — `SpanExporter`/tracing), `ReadableLogRecord` → `MessageData`/`ExceptionData`/severity/trace-correlation (spec 03 — `LogRecordExporter`/logging), `MetricData` → Breeze MetricData/histograms/dimensions (spec 04 — `MetricExporter`/metrics). Core defines only the envelope/tag/encoding framework and the `baseData` extension point.
- **Durable, disk-backed offline persistence** of un-sent telemetry (later hardening spec).
- **Ingestion sampling logic** (fixed-rate `sampleRate`/`itemCount` decisions) — core only carries the `sampleRate` field in the model.
- **Entra / AAD (token) authentication** on the ingestion channel (spec 05). Core only retains any auth-related connection-string fields for later use.
- **Live Metrics / QuickPulse** (spec 06) — separate endpoint (`LiveEndpoint`), data model, and protocol.
- **One-call distro bootstrap** from a connection string and optional framework middleware (spec 07).

## Open questions

- ~~**`/v2/track` vs `/v2.1/track`**~~ — **RESOLVED (D2):** the ingestion track path is `{IngestionEndpoint}/v2.1/track` (`/v2/track` is the older classic-SDK path). Envelope `ver` = 1 (omitted on the wire by default); each `data.baseData.ver` = 2. Default host `https://dc.services.visualstudio.com`. See design.md §11 (D2).
- Endpoint derivation when only `EndpointSuffix` (no explicit `IngestionEndpoint`) is supplied, and whether a hard default public-cloud endpoint is acceptable vs failing closed. [NEEDS CLARIFICATION]
- Exact role-name composition rule for `service.namespace` + `service.name` → `ai.cloud.role`. [NEEDS CLARIFICATION — confirm against .NET exporter]
- Default values for batch size, flush interval, buffer capacity, max retry attempts, and shutdown timeout. [NEEDS CLARIFICATION — align with .NET exporter defaults where reasonable]
