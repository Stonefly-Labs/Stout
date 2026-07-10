# Spec 02 — Distributed Tracing Exporter (`opentelemetry-swift` `SpanExporter` → Breeze)

Pass the prompt below to `/speckit.specify`.

---

## Overview / Why

Build the **distributed tracing exporter** for `stout`: an Azure Monitor / Application Insights `SpanExporter` for the **OpenTelemetry Swift SDK ([`opentelemetry-swift`](https://github.com/open-telemetry/opentelemetry-swift))**. Swift apps — iOS/macOS/watchOS/tvOS clients and Linux/macOS servers (Vapor, Hummingbird, gRPC-swift, application code, on-device URLSession/MetricKit instrumentation) — already produce spans through `opentelemetry-swift`'s `TracerProvider`. This feature implements that SDK's public **`SpanExporter`** protocol (`export(_ spans: [SpanData])` / `flush()` / `shutdown()`) as an Azure Monitor exporter, so finished spans are translated into Application Insights "Breeze" telemetry and delivered to ingestion — **collector-free**, with no OpenTelemetry Collector or Azure Monitor Agent. It mirrors .NET's `Azure.Monitor.OpenTelemetry.Exporter` trace path.

This is the trace half of Phase 1 ("Core + Traces exporter") in the design. The success condition from the design: **a Swift app's spans appear in Application Insights with correct request/dependency correlation** — an incoming HTTP request (server) or an on-device operation and the outbound calls it makes render as a correctly-linked transaction in the App Insights transaction/application map.

This feature **builds on** the core ingestion foundation (spec 01). The Breeze envelope model (Part A tags + `baseData` variants), the bounded drop-on-overflow export pipeline, resource detection (cloud role / role instance / device / SDK version tags), connection-string parsing, and the gzip newline-JSON HTTPS transport abstraction (URLSession/async-http-client) to `{IngestionEndpoint}/v2.1/track` **already exist and MUST be consumed, not redefined**. This spec covers only: implementing the `SpanExporter` protocol and translating finished `SpanData` to Breeze telemetry items.

**W3C Trace Context propagation is handled by the OpenTelemetry SDK, not by us.** `opentelemetry-swift` ships the W3C `TraceContextPropagator` and manages inject/extract and the active span context; Stout is a *terminal exporter* that consumes already-correlated `SpanData` (trace id, span id, parent span id are on each `SpanData`). We do NOT implement inject/extract, `Instrument`, or context propagation — we translate the identity the SDK already resolved onto the Breeze correlation tags.

> Locked design decisions: see design.md §11 (D1–D4, D7–D9). This spec reflects D1 (lifecycle/shutdown: the exporter goes inert on `shutdown()`, post-shutdown export is safe), D7 (cross-platform), D8 (build on `opentelemetry-swift`'s `SpanExporter`), and consumes the D2 ingestion path from spec 01.

Why it matters: distributed tracing is the flagship signal (traces first in the phased plan, and the one signal that is **Stable** in `opentelemetry-swift`). Without correct `SpanData` → Breeze translation, cross-service/cross-tier correlation — the single most valuable thing App Insights offers — does not work. This is also an OSS library that runs inside customers' production services and on end-user devices and handles secrets, so security, stability, and quality are first-class, non-negotiable requirements.

## Consumer scenarios

1. **Registration.** A developer registers the Azure Monitor `SpanExporter` with `opentelemetry-swift`'s `TracerProvider` (typically wrapped in a `BatchSpanProcessor`) at startup, configured from the ingestion pipeline established in spec 01. From then on, any library or code that produces spans through the OTel SDK exports to Application Insights with no further wiring.

2. **Incoming server request → Request telemetry.** An HTTP request arrives at a Vapor/Hummingbird app (or an on-device operation begins). Instrumentation starts a `.server` span. On finish, the SDK hands its `SpanData` to our exporter, and it appears in App Insights as a **Request** with the correct name, URL, response code, success flag, and duration.

3. **Outbound dependency → Dependency telemetry, correlated.** While handling that request, the app calls a downstream HTTP API and a database (server) or a REST endpoint (on-device, via `opentelemetry-swift`'s URLSession instrumentation). Each produces a `.client` span whose `SpanData` we translate to a **Dependency** with the correct target, type, data, result code, success, and duration — nested under the request in the transaction map (same operation id, dependency's parent = the request's span id).

4. **Cross-service / cross-tier correlation (W3C Trace Context — handled by the SDK).** Service/tier A calls B. The **OTel SDK** injects `traceparent` (and `tracestate`) into the outbound request and B's SDK extracts them, continuing the same trace — we do not implement this. By the time each finished span reaches our exporter as `SpanData`, its trace id and parent span id already reflect the propagated context. In App Insights the two tiers' spans share one operation id and link parent→child across the process boundary, rendering as a single end-to-end transaction.

5. **Error / exception on a span.** A handler throws. The span is finished with error status and records an `exception` span event. In its `SpanData`, our exporter shows the Request/Dependency as failed (`success = false`) and emits an associated **Exception** telemetry item with the exception type, message, and (when available) stack trace, correlated to the operation.

6. **Span events → messages.** A span records a non-exception event (e.g. a checkpoint / log-like event). Our exporter renders it as a correlated **Message** ("trace") telemetry item under the same operation.

7. **Graceful shutdown / flush.** On shutdown, the SDK calls the exporter's `flush()` and `shutdown()` so buffered telemetry has the opportunity to flush before exit (drain-and-go-inert flush semantics are owned by spec 01's pipeline; this feature must forward exported spans promptly and not strand them). After the pipeline has shut down, the exporter becomes a **safe no-op** (D1): `SpanData` handed to `export(...)` post-shutdown is dropped and MUST NOT crash or block; the drop is surfaced only via spec 01's rate-limited internal-diagnostics warning, never as telemetry and never with payload data.

## Functional requirements

### `SpanExporter` implementation & lifecycle
- Implement the `opentelemetry-swift` public **`SpanExporter`** protocol as an Azure Monitor exporter: `export(_ spans: [SpanData]) -> SpanExporterResultCode`, `flush() -> SpanExporterResultCode`, and `shutdown()`. The exporter is registered with the SDK's `TracerProvider`, normally via a `BatchSpanProcessor` (batching/span-lifecycle is the SDK's job, not ours). [NEEDS CLARIFICATION: confirm the exact `SpanExporter` protocol signatures, `SpanExporterResultCode` cases, and whether `export` receives an explicit timeout parameter in the targeted `opentelemetry-swift` version.]
- Consume each finished span as **`SpanData`** — which already carries name, `SpanKind`, start/end nanos, attributes, `Status`, events, links, and the `SpanContext`/parent context (trace id, span id, parent span id, trace flags). We do NOT start/finish spans, set attributes, or manage active context — the SDK owns the span lifecycle and produces `SpanData` on finish.
- On `export(...)`, translate each `SpanData` to exactly one Breeze telemetry item (Request or Dependency) plus any derived Exception/Message items from its events, and hand them to the spec 01 pipeline.
- Export MUST be **non-blocking** for the SDK's export path: handing translated items to the pipeline must not block on network I/O or a full buffer (the buffer is bounded and drops on overflow per spec 01), and `export(...)` returns promptly with a success/failure result code.
- The exporter MUST be an **independently-constructable, injectable object** (D1) so it can be built and unit-tested without an active `TracerProvider`; registration with the provider is a thin layer over it (the testability seam). After the underlying pipeline shuts down (drain-and-go-inert, D1), the exporter MUST become a **safe no-op**: `SpanData` handed to `export(...)` post-shutdown is dropped without crashing or blocking, with the drop surfaced only via spec 01's rate-limited internal-diagnostics warning (never user telemetry, never payload data).

### Span kind → envelope type
- SpanKind **`.server`** and **`.consumer`** → **`RequestData`**.
- SpanKind **`.client`**, **`.producer`**, and **`.internal`** → **`RemoteDependencyData`**.
- If span kind is absent/unspecified, default the mapping to **`RemoteDependencyData`** (internal) [NEEDS CLARIFICATION: confirm default when `SpanData.kind` is unset/`.internal` — .NET treats unspecified activities as dependencies; verify this default matches the .NET exporter behavior].

### Part A tags (correlation)
- `ai.operation.id` ← the `SpanData` **trace id** (W3C 32-hex-char trace-id form).
- `ai.operation.parentId` ← the `SpanData` **parent span id** (empty/absent for a root span).
- Telemetry **item id** ← the `SpanData` **span id** (16-hex-char form).
- `ai.cloud.role`, `ai.cloud.roleInstance`, `ai.internal.sdkVersion` (and on-device `ai.device.*` / `ai.application.ver`) come from resource detection in spec 01 (sourced from the OTel `Resource` on the `SpanData`) — consume them; do not recompute.
- For a `.server`/`.consumer` span, when the incoming context carried a propagated distributed trace, set `RequestData` **`source`** where the convention provides an originating identity [NEEDS CLARIFICATION: source population rules — mirror .NET's use of enqueued-time / correlation-context where applicable].

### RequestData fields (server / consumer spans)
- `id` ← span id; `name` ← span name (HTTP requests SHOULD use the route/method-derived name per HTTP semantic conventions when available); `duration` ← end − start; attributes → `properties`.
- **`responseCode`** ← `http.response.status_code` (HTTP) or `rpc.grpc.status_code` (gRPC); for other kinds, derive from status [NEEDS CLARIFICATION: default responseCode string when no protocol status attribute is present].
- **`success`** ← span status is not error AND (for HTTP) status code is not in the failure range [NEEDS CLARIFICATION: exact success predicate per protocol — HTTP 4xx server-side handling, gRPC non-OK].
- **`url`** ← reconstructed request URL from HTTP semantic-convention attributes (scheme/host/target or `url.full`/`http.url`).

### RemoteDependencyData fields (client / producer / internal spans)
- `id` ← span id; `name` ← span name; `duration` ← end − start; attributes → `properties`.
- **`resultCode`** ← `http.response.status_code` (HTTP) or `rpc.grpc.status_code` (gRPC); DB/messaging as applicable.
- **`success`** ← from span status / protocol status, mirroring the RequestData predicate.
- **`type`** ← protocol-derived: **`HTTP`** for HTTP spans; **`SQL`** (or the specific `db.system` value, e.g. `mysql`/`postgresql`) for database spans; the messaging system / **queue** type for producer/messaging spans; a generic/`InProc` type for internal spans.
- **`target`** ← dependency target: host[:port] for HTTP (from `server.address`/`server.port` or the URL), `db.name`/server for DB, `peer.service`/messaging destination for messaging.
- **`data`** ← the operation detail: `url.full`/`http.url` for HTTP, `db.statement`/`db.query.text` for DB, destination for messaging.

### Semantic-convention mapping (protocol facts — in scope)
- Map **OpenTelemetry HTTP** semantic conventions (`http.request.method`, `http.response.status_code`, `url.full`/`url.scheme`/`url.path`, `server.address`/`server.port`, and their legacy `http.*` equivalents) to the Request/Dependency fields above.
- Map **database** conventions (`db.system`, `db.name`/`db.namespace`, `db.statement`/`db.query.text`) to Dependency `type`/`target`/`data`.
- Map **RPC/gRPC** conventions (`rpc.system`, `rpc.service`, `rpc.method`, `rpc.grpc.status_code`) to name/type/result code.
- Map **messaging** conventions (`messaging.system`, `messaging.destination.name`, operation) to producer/consumer target/type.
- Support **both** current and legacy attribute keys where they overlap during OTel semantic-convention transition, preferring the current key when both are present. Attributes not consumed by a specific mapping are carried into `properties`.
- [NEEDS CLARIFICATION: the exact semantic-convention version(s) to target as the baseline, and how strictly to follow the .NET exporter's `ActivityTagsProcessor` precedence].

### Span events → telemetry
- A span event named **`exception`** → an **`ExceptionData`** item, correlated to the span (same operation id; parent id = the span id). Populate exception **type** (`exception.type`), **message** (`exception.message`), and **stack trace** (`exception.stacktrace`) from the event attributes when present.
- Any **other** span event → a **`MessageData`** item, correlated to the span, with the event name/message and event attributes → `properties`.
- Marking a span's status as error MUST be reflected in the owning Request/Dependency `success = false`, independent of whether an `exception` event was recorded.

### W3C Trace Context propagation (owned by the OTel SDK — NOT this feature)
- **We do NOT implement inject/extract, `Instrument`, propagators, or context management.** `opentelemetry-swift` ships the W3C `TraceContextPropagator` and manages the active span context; consumers configure it on the SDK. Stout is a terminal `SpanExporter`.
- Each `SpanData` we export already carries a W3C-correct 128-bit trace id, 64-bit span id, and parent span id resolved by the SDK's propagation. We MUST map these ids **losslessly** to `ai.operation.id` / `ai.operation.parentId` / item id in their canonical W3C hex forms — the correlation only works if we preserve the ids the SDK produced byte-for-byte.
- Because propagation is the SDK's job, malformed inbound headers, missing context, and root-vs-child determination are all resolved before `SpanData` reaches us; we simply reflect the resulting ids (a root span has an empty/absent parent span id).

### Sampling hooks (policy is out of scope)
- Each emitted telemetry item MUST carry the envelope **`sampleRate`** field (and **`itemCount`** where the schema uses it) so ingestion sampling can be honored. **This feature only attaches/propagates these fields** — the actual sampling *decision/policy* is spec 05. Default `sampleRate` when no policy is configured is 100 (no sampling).

### Log/trace correlation contract (shared with spec 03)
- Trace/log correlation is provided by the **OTel SDK**, not by this feature: `opentelemetry-swift` stamps each `ReadableLogRecord` with the active span's `SpanContext` (trace id + span id) at emit time. Spec 03's `LogRecordExporter` reads those ids directly off the `ReadableLogRecord`. This feature does not need to expose or maintain any separate ambient context for spec 03 — both exporters independently translate the SDK-provided trace/span ids onto `ai.operation.id` / `ai.operation.parentId` using the **same mapping rule** defined here (canonical W3C hex → `ai.operation.*`), which is the shared correlation contract. This feature MUST NOT itself implement log translation.

## Non-functional / quality requirements (OSS mandate — non-negotiable)

- **Security / secrets:** No connection string, instrumentation key, `iKey`, token, or any secret is ever logged, placed in an error message, or emitted as our own telemetry. Span attributes forwarded to `properties` are customer data and MUST NOT be logged by this library. Fail closed on invalid configuration.
- **Stability — telemetry never harms the host:** Producing/finishing spans and propagation MUST NEVER crash, throw into, or block the calling application. Translation errors, malformed attributes, oversized events, or a full/overflowing pipeline buffer degrade gracefully (drop the item) — they never propagate to the host. Bounded memory only; no unbounded buffers introduced by this feature.
- **Swift 6 strict concurrency:** All exporter/tracer types compile under Swift 6 strict concurrency with correct `Sendable` conformance and **no data races**; span state shared across tasks is safe. Concurrent span start/finish from many tasks is safe.
- **Deterministic, table-driven translation:** The span → Breeze mapping is pure and deterministic given a finished span; identical input yields identical output.
- **Quality / testing:** High test coverage, explicitly including (a) the span-kind → envelope-type table, (b) each semantic-convention → Breeze-field mapping (HTTP/DB/RPC/messaging, current + legacy keys), (c) lossless `SpanData` trace-id/span-id/parent-span-id → `ai.operation.id`/`ai.operation.parentId`/item-id mapping (canonical W3C hex, including root spans with no parent), (d) exception-event → `ExceptionData` and other-event → `MessageData` paths, and (e) failure paths (missing attributes, error status, buffer overflow drop). Tests MUST run on **both an Apple platform (iOS simulator / macOS) and Linux**.
- **SemVer & documented behavior:** Public API follows SemVer; the mapping rules and propagation behavior are documented; behavior on unknown/unsupported span kinds and attributes is specified.

## Acceptance criteria

1. Registering the `SpanExporter` with `opentelemetry-swift`'s `TracerProvider` causes finished spans (delivered as `SpanData`) to be translated and handed to the spec 01 pipeline — with no direct use of pipeline/transport internals redefined here.
2. A finished `.server`/`.consumer` span yields exactly one `RequestData` item; a finished `.client`/`.producer`/`.internal` span yields exactly one `RemoteDependencyData` item.
3. For a finished span: `ai.operation.id` = trace id, item id = span id, and (non-root) `ai.operation.parentId` = parent span id — verifiable byte-for-byte against the W3C hex forms.
4. HTTP server span: `RequestData.responseCode` = `http.response.status_code`, `url` reconstructed from HTTP attributes, `success` reflects status + span status. HTTP client span: `RemoteDependencyData.type = HTTP`, `target` = host[:port], `data` = full URL, `resultCode` = status code.
5. DB client span: `type` = `db.system` (or `SQL`), `target` = db/server, `data` = statement. gRPC span: result/response code = `rpc.grpc.status_code`. Messaging producer span → `RemoteDependencyData` with messaging target/type; messaging consumer span → `RequestData`.
6. An `exception` span event produces a correlated `ExceptionData` with type/message/stacktrace; a non-exception event produces a correlated `MessageData`; an error span status forces `success = false` on the owning item.
7. A `SpanData`'s trace id, span id, and parent span id map losslessly to `ai.operation.id`, item id, and `ai.operation.parentId` in canonical W3C hex; a root span (no parent) yields an empty/absent `ai.operation.parentId`. (Propagation itself is the SDK's; not tested here.)
8. Two tiers whose spans the SDK correlated (via SDK-managed W3C propagation) share one `ai.operation.id`, and the callee's server span's parent id equals the caller's client span id (end-to-end transaction correlation) — verifiable from their `SpanData`.
9. Every emitted item carries `sampleRate` (default 100) and `itemCount` where applicable, without this feature making any sampling decision.
10. The trace-id/span-id → `ai.operation.*` mapping rule used here is the same one spec 03 applies to a `ReadableLogRecord`'s span context, so a log and its owning span correlate to the same operation.
11. No secret ever appears in logs, errors, or telemetry; invalid config fails closed.
12. No span operation, translation error, or buffer-full condition ever throws into or blocks the host application; over-capacity items are dropped, not queued unbounded.
13. All code compiles and passes tests under Swift 6 strict concurrency with no data-race diagnostics, on **both an Apple platform and Linux**; the translation and correlation-mapping test suites (including failure and malformed-attribute paths) pass.

## Out of scope (sibling specs)

- **Spec 01 — Core:** the Breeze envelope framework/model, the batch pipeline (buffering, size/interval flush, drop-on-overflow), resource detection (cloud role/instance, SDK version), connection-string parsing/secret handling, and the gzip newline-JSON HTTPS transport to `/v2.1/track`, plus retry/partial-success. **Consumed here, not defined.**
- **Spec 03 — Logs:** `LogRecordExporter` (`ReadableLogRecord` → `MessageData`/`ExceptionData`), severity mapping. This feature only defines the shared trace/span-id → `ai.operation.*` mapping rule that spec 03 reuses.
- **Spec 04 — Metrics:** `MetricExporter` (`MetricData` → Breeze MetricData), histograms/dimensions.
- **Ingestion sampling policy — Spec 05:** this feature attaches `sampleRate`/`itemCount` to every item, but the sampling *decision/policy* (fixed-rate ingestion sampling) lives in spec 05.
- **Spec 06 — Live Metrics (QuickPulse):** the proprietary live-stream side-channel is entirely separate.
- **W3C context propagation, span lifecycle, sampling decisions, batching:** owned by `opentelemetry-swift` (`TraceContextPropagator`, `BatchSpanProcessor`, `TracerProvider`), not this feature.
- Auto-instrumentation of specific frameworks (Vapor/Hummingbird middleware; on-device URLSession/MetricKit); the distro convenience bootstrap layer (later phase). Consumers here use `opentelemetry-swift`'s existing instrumentations that already produce spans.

## Open questions

- [NEEDS CLARIFICATION: default envelope type when span kind is unspecified — confirm `.internal`→Dependency matches .NET behavior.]
- [NEEDS CLARIFICATION: exact `success` predicate per protocol (HTTP 4xx on server vs client, gRPC non-OK, DB errors) — mirror the .NET `TraceHelper`/`ActivityExtensions` logic.]
- [NEEDS CLARIFICATION: target OTel semantic-convention version baseline and the precedence order when both current and legacy attribute keys are present.]
- [NEEDS CLARIFICATION: `RequestData.source` population rules for messaging/consumer and cross-service incoming context.]
- [NEEDS CLARIFICATION: default `responseCode`/`resultCode` string when no protocol status attribute exists (e.g. internal spans).]
- [NEEDS CLARIFICATION: whether span **links** map to any Breeze field or are carried only as `properties` (App Insights has no first-class span-link concept).]
- [NEEDS CLARIFICATION: exact `opentelemetry-swift` `SpanExporter` protocol signatures / `SpanExporterResultCode` cases / `SpanData` shape in the targeted version — confirm during spec 01's plan while resolving the package.]
