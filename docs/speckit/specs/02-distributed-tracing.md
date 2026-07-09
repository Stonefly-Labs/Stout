# Spec 02 — Distributed Tracing Exporter

Pass the prompt below to `/speckit.specify`.

---

## Overview / Why

Build the **distributed tracing exporter** for `stout`: an Azure Monitor / Application Insights backend for [`swift-distributed-tracing`](https://github.com/apple/swift-distributed-tracing). Server-side Swift services (Vapor, Hummingbird, gRPC-swift, application code) already emit spans through the Swift Server Working Group (SSWG) distributed-tracing facade. This feature implements that facade's `Tracer` and `Instrument` protocols as an Azure Monitor backend, bootstrapped via `InstrumentationSystem`, so those spans are translated into Application Insights "Breeze" telemetry and delivered to ingestion — **collector-free**, with no OpenTelemetry Collector or Azure Monitor Agent.

This is the trace half of Phase 1 ("Core + Traces MVP") in the design. The success condition from the design: **a Swift service's spans appear in Application Insights with correct request/dependency correlation** — an incoming HTTP request and the outbound calls it makes render as a correctly-linked transaction in the App Insights transaction/application map.

This feature **builds on** the core ingestion foundation (spec 01). The Breeze envelope model (Part A tags + `baseData` variants), the bounded drop-on-overflow batch pipeline, resource detection (cloud role / role instance / SDK version tags), connection-string parsing, and the gzip newline-JSON HTTPS transport to `{IngestionEndpoint}/v2.1/track` **already exist and MUST be consumed, not redefined**. This spec covers only: implementing the tracing facade, producing/finishing spans, translating finished spans to Breeze telemetry items, and W3C Trace Context propagation.

> Locked design decisions: see design.md §11 (D1–D4). This spec reflects D1 (lifecycle/shutdown: handlers go inert, post-shutdown emission is safe) and consumes the D2 ingestion path from spec 01.

Why it matters: distributed tracing is the flagship signal (traces first in the phased plan). Without correct span → Breeze translation and W3C context propagation, cross-service correlation — the single most valuable thing App Insights offers a distributed system — does not work. This is also an OSS library that runs inside customers' production services and handles secrets, so security, stability, and quality are first-class, non-negotiable requirements.

## Consumer scenarios

1. **Bootstrap.** A service developer registers the Azure Monitor tracer as the process's tracing backend via `InstrumentationSystem` at startup, configured from the ingestion pipeline established in spec 01. From then on, any library or code that uses the `swift-distributed-tracing` facade emits to Application Insights with no further wiring.

2. **Incoming server request → Request telemetry.** An HTTP request arrives at a Vapor/Hummingbird app. The framework's tracing middleware starts a `.server` span. On finish, it appears in App Insights as a **Request** with the correct name, URL, response code, success flag, and duration.

3. **Outbound dependency → Dependency telemetry, correlated.** While handling that request, the app calls a downstream HTTP API and a database. Each produces a `.client` span that appears in App Insights as a **Dependency** with the correct target, type, data, result code, success, and duration — nested under the request in the transaction map (same operation id, dependency's parent = the request's span id).

4. **Cross-service correlation (W3C Trace Context).** Service A calls Service B over HTTP. Service A's tracer **injects** `traceparent` (and `tracestate` when present) into the outbound request headers. Service B's middleware **extracts** them, continuing the same trace. In App Insights the two services' spans share one operation id and link parent→child across the process boundary, rendering as a single end-to-end transaction.

5. **Error / exception on a span.** A handler throws. The span is finished with error status and records an `exception` span event. App Insights shows the Request/Dependency as failed (`success = false`) and an associated **Exception** telemetry item with the exception type, message, and (when available) stack trace, correlated to the operation.

6. **Span events → messages.** A span records a non-exception event (e.g. a checkpoint / log-like event). It appears as a correlated **Message** ("trace") telemetry item under the same operation.

7. **Graceful shutdown / flush.** On service shutdown, in-flight finished spans are handed to the pipeline so buffered telemetry has the opportunity to flush before exit (drain-and-go-inert flush semantics are owned by spec 01's pipeline; this feature must forward finished spans promptly and not strand them). After the pipeline has shut down, the bootstrapped tracer/instrument handlers become **safe no-ops** (D1): spans started or finished post-shutdown are dropped and MUST NOT crash or block; the drop is surfaced only via spec 01's rate-limited internal-diagnostics warning, never as telemetry and never with payload data.

## Functional requirements

### Facade implementation & lifecycle
- Implement the `swift-distributed-tracing` **`Tracer`** protocol (and the underlying **`Instrument`** protocol for context propagation) as an Azure Monitor backend, registrable through `InstrumentationSystem.bootstrap(...)`.
- Support **starting** a span (name, kind, start instant, initial attributes, and the parent `ServiceContext`) and **finishing** a span (end instant, final attributes, status, recorded events/links). On finish — and only on finish — the span is translated to a Breeze telemetry item and handed to the spec 01 pipeline.
- Support setting span attributes, status (ok/error), and recording events during the span's lifetime, per the facade API.
- Propagate the active span through `ServiceContext` (task-local) so child spans automatically parent to the current span.
- Span production and finishing MUST be **non-blocking** for the calling code: handing a finished span to the pipeline must not block the host on network I/O or a full buffer (the buffer is bounded and drops on overflow per spec 01).
- The tracer/exporter MUST be an **independently-constructable, injectable object** (D1); the `InstrumentationSystem.bootstrap(...)` registration is a thin layer over it (the testability seam). After the underlying pipeline shuts down (drain-and-go-inert, D1), the installed — and un-removable — handlers MUST become **safe no-ops**: post-shutdown span start/finish/attribute/event operations are dropped without crashing or blocking, with the drop surfaced only via spec 01's rate-limited internal-diagnostics warning (never user telemetry, never payload data).

### Span kind → envelope type
- SpanKind **`.server`** and **`.consumer`** → **`RequestData`**.
- SpanKind **`.client`**, **`.producer`**, and **`.internal`** → **`RemoteDependencyData`**.
- If span kind is absent/unspecified, default the mapping to **`RemoteDependencyData`** (internal) [NEEDS CLARIFICATION: confirm default when the facade does not supply a kind — .NET treats unspecified activities as dependencies; verify this default matches the .NET exporter behavior].

### Part A tags (correlation)
- `ai.operation.id` ← the **trace id** (W3C 32-hex-char trace-id form).
- `ai.operation.parentId` ← the **parent span id** (empty/absent for a root span).
- Telemetry **item id** ← the **span id** (16-hex-char form).
- `ai.cloud.role`, `ai.cloud.roleInstance`, and `ai.internal.sdkVersion` come from resource detection in spec 01 — consume them; do not recompute.
- For a `.server`/`.consumer` span, when the parent context carried an incoming distributed trace, set `RequestData` **`source`** where the convention provides an originating identity [NEEDS CLARIFICATION: source population rules — mirror .NET's use of enqueued-time / correlation-context where applicable].

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

### W3C Trace Context propagation (Instrument extract/inject)
- Implement the `Instrument` **`inject`** operation to write **`traceparent`** (and **`tracestate`** when carried in context) into an outbound carrier, per the [W3C Trace Context](https://www.w3.org/TR/trace-context/) format (`version-traceid-spanid-flags`, e.g. `00-<32hex>-<16hex>-<2hex>`).
- Implement the `Instrument` **`extract`** operation to read `traceparent`/`tracestate` from an incoming carrier into `ServiceContext`, so a locally started `.server`/`.consumer` span continues the remote trace (adopting its trace id and using the remote span id as parent).
- Injection and extraction MUST be carrier-type-agnostic via the facade's `Injector`/`Extractor` abstraction (works for HTTP headers and any key-value carrier).
- Malformed or absent `traceparent` on extract MUST NOT throw or crash: treat as no incoming context and start a new root trace (fail safe).
- The internal trace/span id representation MUST be W3C-compatible (128-bit trace id, 64-bit span id) so ids round-trip losslessly through inject/extract and map directly to `ai.operation.id` / item id.

### Sampling hooks (policy is out of scope)
- Each emitted telemetry item MUST carry the envelope **`sampleRate`** field (and **`itemCount`** where the schema uses it) so ingestion sampling can be honored. **This feature only attaches/propagates these fields** — the actual sampling *decision/policy* is spec 05. Default `sampleRate` when no policy is configured is 100 (no sampling).

### Log/trace correlation contract (shared with spec 03)
- The trace/span identity surfaced here (operation id ← trace id, active span id via `ServiceContext`) is the **shared correlation contract** that spec 03 (logs) consumes to correlate `LogHandler` records to the active span. This feature MUST expose/maintain the active span identity in `ServiceContext` in the agreed form; it MUST NOT itself implement log translation.

## Non-functional / quality requirements (OSS mandate — non-negotiable)

- **Security / secrets:** No connection string, instrumentation key, `iKey`, token, or any secret is ever logged, placed in an error message, or emitted as our own telemetry. Span attributes forwarded to `properties` are customer data and MUST NOT be logged by this library. Fail closed on invalid configuration.
- **Stability — telemetry never harms the host:** Producing/finishing spans and propagation MUST NEVER crash, throw into, or block the calling application. Translation errors, malformed attributes, oversized events, or a full/overflowing pipeline buffer degrade gracefully (drop the item) — they never propagate to the host. Bounded memory only; no unbounded buffers introduced by this feature.
- **Swift 6 strict concurrency:** All exporter/tracer types compile under Swift 6 strict concurrency with correct `Sendable` conformance and **no data races**; span state shared across tasks is safe. Concurrent span start/finish from many tasks is safe.
- **Deterministic, table-driven translation:** The span → Breeze mapping is pure and deterministic given a finished span; identical input yields identical output.
- **Quality / testing:** High test coverage, explicitly including (a) the span-kind → envelope-type table, (b) each semantic-convention → Breeze-field mapping (HTTP/DB/RPC/messaging, current + legacy keys), (c) W3C `traceparent`/`tracestate` inject/extract round-trip incl. malformed input, (d) exception-event → `ExceptionData` and other-event → `MessageData` paths, and (e) failure paths (missing attributes, error status, buffer overflow drop).
- **SemVer & documented behavior:** Public API follows SemVer; the mapping rules and propagation behavior are documented; behavior on unknown/unsupported span kinds and attributes is specified.

## Acceptance criteria

1. Bootstrapping the tracer via `InstrumentationSystem` causes spans emitted through the `swift-distributed-tracing` facade to be translated and handed to the spec 01 pipeline — with no direct use of pipeline/transport internals redefined here.
2. A finished `.server`/`.consumer` span yields exactly one `RequestData` item; a finished `.client`/`.producer`/`.internal` span yields exactly one `RemoteDependencyData` item.
3. For a finished span: `ai.operation.id` = trace id, item id = span id, and (non-root) `ai.operation.parentId` = parent span id — verifiable byte-for-byte against the W3C hex forms.
4. HTTP server span: `RequestData.responseCode` = `http.response.status_code`, `url` reconstructed from HTTP attributes, `success` reflects status + span status. HTTP client span: `RemoteDependencyData.type = HTTP`, `target` = host[:port], `data` = full URL, `resultCode` = status code.
5. DB client span: `type` = `db.system` (or `SQL`), `target` = db/server, `data` = statement. gRPC span: result/response code = `rpc.grpc.status_code`. Messaging producer span → `RemoteDependencyData` with messaging target/type; messaging consumer span → `RequestData`.
6. An `exception` span event produces a correlated `ExceptionData` with type/message/stacktrace; a non-exception event produces a correlated `MessageData`; an error span status forces `success = false` on the owning item.
7. `inject` writes a spec-conformant `traceparent` (and `tracestate` when present); `extract` parses them and continues the trace. A round-trip (inject then extract) preserves trace id and span id exactly. Malformed/absent `traceparent` results in a new root trace with no thrown error.
8. Two services correlated via injected/extracted context share one `ai.operation.id`, and the callee's server span's parent id equals the caller's client span id (end-to-end transaction correlation).
9. Every emitted item carries `sampleRate` (default 100) and `itemCount` where applicable, without this feature making any sampling decision.
10. The active span identity is available in `ServiceContext` in the form spec 03 requires for log correlation.
11. No secret ever appears in logs, errors, or telemetry; invalid config fails closed.
12. No span operation, translation error, or buffer-full condition ever throws into or blocks the host application; over-capacity items are dropped, not queued unbounded.
13. All code compiles and passes tests under Swift 6 strict concurrency with no data-race diagnostics; the translation and propagation test suites (including failure and malformed-input paths) pass.

## Out of scope (sibling specs)

- **Spec 01 — Core:** the Breeze envelope framework/model, the batch pipeline (buffering, size/interval flush, drop-on-overflow), resource detection (cloud role/instance, SDK version), connection-string parsing/secret handling, and the gzip newline-JSON HTTPS transport to `/v2.1/track`, plus retry/partial-success. **Consumed here, not defined.**
- **Spec 03 — Logs:** `LogHandler` → `MessageData`/`ExceptionData`, severity mapping. This feature only exposes the active-span correlation contract that spec 03 consumes (shared contract).
- **Spec 04 — Metrics:** `MetricsFactory` → `MetricData`, histograms/dimensions.
- **Ingestion sampling policy — Spec 05:** this feature attaches `sampleRate`/`itemCount` to every item, but the sampling *decision/policy* (fixed-rate ingestion sampling) lives in spec 05.
- **Spec 06 — Live Metrics (QuickPulse):** the proprietary live-stream side-channel is entirely separate.
- Auto-instrumentation of specific frameworks (Vapor/Hummingbird middleware); the distro convenience bootstrap layer (later phase). Consumers here use the existing framework tracing middleware that already emits to the facade.

## Open questions

- [NEEDS CLARIFICATION: default envelope type when span kind is unspecified — confirm `.internal`→Dependency matches .NET behavior.]
- [NEEDS CLARIFICATION: exact `success` predicate per protocol (HTTP 4xx on server vs client, gRPC non-OK, DB errors) — mirror the .NET `TraceHelper`/`ActivityExtensions` logic.]
- [NEEDS CLARIFICATION: target OTel semantic-convention version baseline and the precedence order when both current and legacy attribute keys are present.]
- [NEEDS CLARIFICATION: `RequestData.source` population rules for messaging/consumer and cross-service incoming context.]
- [NEEDS CLARIFICATION: default `responseCode`/`resultCode` string when no protocol status attribute exists (e.g. internal spans).]
- [NEEDS CLARIFICATION: whether span **links** map to any Breeze field or are carried only as `properties` (App Insights has no first-class span-link concept).]
- [NEEDS CLARIFICATION: exact `ServiceContext` key/shape for the active-span correlation contract shared with spec 03 — must be agreed jointly.]
