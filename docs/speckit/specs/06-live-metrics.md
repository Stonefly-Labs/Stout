# Spec 06 — Live Metrics (QuickPulse) Real-Time Streaming, v1

Pass the prompt below to `/speckit.specify`.

---

## Overview / Why

`stout` is a collector-free, open-source Azure Monitor / Application Insights exporter for server-side Swift (Linux + macOS, Swift 6). Its core signals (traces, logs, metrics) flow through the "Breeze" ingestion pipeline. This feature adds a **completely separate, opt-in capability: real-time "Live Metrics" (a.k.a. Live Stream / QuickPulse) streaming**.

Live Metrics is a **proprietary Azure Monitor real-time side-channel — it is NOT OpenTelemetry, NOT OTLP, and NOT part of the Breeze ingestion pipeline.** It shares only the connection string with the rest of the library. When an operator opens the **Live Metrics blade** in the Azure portal for this Application Insights resource, they should see this Swift service's live request rate, dependency rate, exception rate, and CPU/memory-style performance counters updating in near real time (roughly once per second). When the operator closes the blade, the Swift service must detect that nobody is watching and stop streaming.

**Why this matters:** Live Metrics gives operators a zero-retention, sub-second view of a running service — invaluable during a deploy or an incident, and something the batched Breeze pipeline (seconds-to-minutes latency, sampled, retained) cannot provide. Today no Swift service can appear in the Live Metrics blade at all, because Microsoft ships QuickPulse clients only for .NET, Java, Node.js, and Python.

**Reverse-engineering caveat (maintenance risk — call out explicitly in the spec and README):** the QuickPulse wire protocol is **not publicly documented by Microsoft**. The authoritative reference is the MIT-licensed .NET `Azure.Monitor.OpenTelemetry.LiveMetrics` sources (and, for the deferred filtering DSL, the legacy `microsoft/ApplicationInsights-dotnet-server` QuickPulse code). We reimplement the *logic and wire contract* in Swift — we do not copy code. Because the contract is internal to Microsoft, it may change without notice; the implementation must degrade gracefully rather than crash when the service returns something unexpected, and the documentation must flag this maintenance risk.

**Scope of v1:** the **ping/post state machine**, streaming of **metrics-only `MonitoringDataPoint` samples** plus a bounded number of sample **`DocumentIngress` documents** (Request / Dependency / Exception), and honoring server-driven control headers. **The client-side filtering DSL is explicitly deferred** (see Out of scope) and must degrade gracefully when the portal pushes a custom filter configuration.

This feature depends on Spec 01 (core config / connection string parsing) **only** for the connection string, from which it reads the `LiveEndpoint`. It is a later phase and its own module.

> Locked design decisions: see design.md §11 (D1–D4). This spec reflects D1 (lifecycle/shutdown: the streaming loop goes inert on shutdown and never crashes on post-shutdown activity).

---

## Consumer scenarios

1. **Operator opens the blade (the headline scenario).** A Swift service is running with Live Metrics enabled. An operator opens the Live Metrics blade in the Azure portal for the matching Application Insights resource. Within a few seconds the operator sees this service appear as a live server/instance, with its incoming request rate, dependency call rate, exception rate, and CPU/memory-style counters updating roughly every second.

2. **Operator closes the blade.** The operator closes the Live Metrics blade. The service detects (via the subscribed signal) that no one is watching, stops streaming samples, and falls back to low-frequency polling. Streaming resumes automatically if a viewer reopens the blade.

3. **Feature is off by default.** A consumer who never enables Live Metrics observes zero Live Metrics network traffic, zero background activity, and no measurable overhead. Enabling requires an explicit, independent toggle (separate from the Breeze pipeline toggles).

4. **Nobody ever watches.** A service runs for days with Live Metrics enabled but with the blade never opened. It quietly polls at the low "ping" frequency, consuming negligible resources and never streaming sample payloads.

5. **Service becomes unreachable / errors.** The Live Endpoint returns errors, times out, or the network drops. The service backs off (does not hammer the endpoint), never crashes, never blocks the host application, and automatically recovers when connectivity returns.

6. **Portal pushes a custom filter configuration (deferred DSL).** An operator configures custom metric filters in the blade. Because v1 does not implement the filtering DSL, the service reports the configuration as unsupported (via the error channel described below) and continues streaming the standard default metrics. It must NOT crash, stall, or silently stop streaming.

7. **Service is redirected.** The Live Endpoint responds with an endpoint-redirect instruction. The service transparently switches to the new endpoint for subsequent calls without operator involvement and without dropping the stream.

---

## Functional requirements

> The protocol facts below (endpoints, header names, cadence targets, data-model shapes) are inherent to the QuickPulse contract and are therefore in-scope requirements — not implementation details. Where a value is reverse-engineered and not independently confirmable it is marked `[NEEDS CLARIFICATION]`.

### FR-1 Endpoint & channel identity
- FR-1.1 The Live Endpoint MUST be obtained from the connection string's `LiveEndpoint` field (e.g. `https://<region>.livediagnostics.monitor.azure.com/`), sourced from core config (Spec 01).
- FR-1.2 All Live Metrics traffic MUST go to the Live Endpoint and MUST be entirely separate from the Breeze ingestion endpoint / pipeline. The two share nothing but the connection string.
- FR-1.3 The instrumentation key from the connection string MUST be supplied as the `ikey` query parameter on both the ping and post calls (`/ping?ikey=…`, `/post?ikey=…`).

### FR-2 Ping/Post state machine
- FR-2.1 In the **ping** state the service MUST periodically POST to `/ping?ikey=…` to ask "is anyone watching?" The service determines subscription status from the `x-ms-qps-subscribed` response header (`true` = a viewer is watching).
- FR-2.2 When `x-ms-qps-subscribed` becomes true, the service MUST transition to the **post** state and begin streaming samples to `/post?ikey=…`.
- FR-2.3 In the post state the service MUST send samples at approximately **one per second** (the streaming cadence).
- FR-2.4 When `x-ms-qps-subscribed` becomes false (viewer/blade closed), the service MUST transition back to the ping state and stop streaming samples.
- FR-2.5 Cadence targets (all approximate / server-overridable — see FR-3):
  - Ping poll interval when idle (no subscriber): ~**5 seconds**.
  - Post streaming interval when subscribed: ~**1 second**.
  - Failure backoff — ping after an error: ~**60 seconds**.
  - Failure backoff — post after an error: ~**20 seconds**.
- FR-2.6 The state machine MUST be a well-defined, testable finite state machine (ping ⇄ post, plus error/backoff transitions) whose transitions are driven by response headers and success/failure outcomes.
- FR-2.7 The streaming loop MUST run on a dedicated background task and MUST NEVER block or crash the host application, regardless of endpoint behavior.

### FR-3 Server-driven control headers
- FR-3.1 **Endpoint redirect:** if the service returns `x-ms-qps-service-endpoint-redirect-v2`, the client MUST switch to the indicated endpoint for subsequent ping/post calls.
- FR-3.2 **Polling-interval hint:** if the service returns `x-ms-qps-service-polling-interval-hint`, the client MUST adopt the hinted interval in place of its default cadence.
- FR-3.3 **Configuration ETag sync:** the client MUST track the `x-ms-qps-configuration-etag` value, send the last-known ETag back on subsequent requests, and treat a changed ETag as "new configuration available." (v1 uses this only to detect config changes it must acknowledge/report; it does not evaluate the filter DSL — see FR-6.)
- FR-3.4 Any control header whose value is malformed or unrecognized MUST be ignored gracefully (fall back to defaults) without crashing or stalling the loop.
- FR-3.5 `[NEEDS CLARIFICATION: exact request-side header names and required request headers — e.g. how the client advertises its instance/stream identity, transmission time, machine name, and previously seen ETag — must be confirmed against the .NET LiveMetrics source.]`

### FR-4 Sample data model — `MonitoringDataPoint` (metrics, v1 core)
- FR-4.1 Each streamed sample MUST be a `MonitoringDataPoint` carrying, at minimum: the service/instance identity (role/instance name), the SDK/agent version, a timestamp, and the set of collected metrics for that ~1-second window.
- FR-4.2 v1 MUST collect and report the standard Live Metrics default metrics: incoming **request rate**, request duration, request failure rate; outgoing **dependency rate**, dependency duration, dependency failure rate; **exception rate**; and performance counters (**CPU %** and **committed/working-set memory**), to the extent obtainable on Linux and macOS.
- FR-4.3 Where a performance counter cannot be obtained on a given platform, the sample MUST omit or zero that metric gracefully rather than fail the whole sample. `[NEEDS CLARIFICATION: which perf counters are reliably available on Linux vs macOS server hosts, and the exact metric names/IDs the blade expects.]`
- FR-4.4 The request / dependency / exception rates streamed here MUST be derived from the same telemetry the host emits via the SSWG facades, so the live view is consistent with what later lands in Breeze. `[NEEDS CLARIFICATION: exact tap-in point — do we observe the shared telemetry buffer, or maintain independent live counters?]`

### FR-5 Sample documents — `DocumentIngress` (samples, v1)
- FR-5.1 Along with metrics, the post payload MUST be able to include a **bounded** set of sample `DocumentIngress` documents for the window: Request, Dependency, and Exception documents (these populate the blade's live sample-telemetry list).
- FR-5.2 The number of documents per sample MUST be capped (bounded memory) and excess documents dropped, never buffered unboundedly.
- FR-5.3 Document contents MUST NOT include the connection string, instrumentation key, or any credential. `[NEEDS CLARIFICATION: the exact document field set and any server-imposed per-sample document cap.]`

### FR-6 Filtering DSL — deferred, graceful degradation (v1)
- FR-6.1 v1 MUST NOT implement the client-side filtering DSL (`CollectionConfigurationInfo` / `DerivedMetricInfo` filter evaluation).
- FR-6.2 When the service pushes a collection/filter configuration the client cannot honor, the client MUST report it as unsupported via the `CollectionConfigurationError[]` channel in the outgoing payload (so the portal is informed), and MUST continue streaming the standard default metrics.
- FR-6.3 Receiving a custom filter configuration MUST NOT crash, stall, or silently stop the stream.
- FR-6.4 `[NEEDS CLARIFICATION: exact shape of the CollectionConfigurationError entry (id, type, message, full-name fields) expected by the service.]`

### FR-7 Authentication (control channel)
- FR-7.1 v1 MUST support authenticating the Live Metrics control channel. The spec MUST plan for **Microsoft Entra ID token auth**, because instrumentation-key auth for Live Metrics is being retired.
- FR-7.2 Where instrumentation-key auth is still accepted by the service, v1 MAY use it as the default, but the design MUST leave a clean seam for Entra token auth (bearer token on ping/post).
- FR-7.3 Tokens, keys, and connection strings MUST NEVER be logged, echoed in errors, or included in streamed documents/metrics. `[NEEDS CLARIFICATION: required audience/scope for the Entra token on the LiveEndpoint; whether v1 must ship Entra now or may stage it behind the same auth seam used by Breeze hardening (Spec 04-ish).]`

### FR-8 Toggle & lifecycle
- FR-8.1 Live Metrics MUST be **OFF by default** and enabled only via an explicit, independent configuration toggle (separate from Breeze enablement).
- FR-8.2 When disabled, there MUST be zero Live Metrics network calls and no background task started.
- FR-8.3 The feature MUST start cleanly at bootstrap and shut down cleanly (drain-and-go-inert, D1): on graceful shutdown it cancels the background task, stops streaming, and closes its HTTP client. The streaming component is an independently-constructable, injectable object; any global bootstrap is a thin layer over it (the testability seam). After shutdown the loop is **inert** — post-shutdown ping/post activity is dropped and MUST NOT crash or block the host; any such drop is surfaced only via the library's internal diagnostics channel (rate-limited, never leaking payload, keys, or tokens).

---

## Non-functional / quality requirements (OSS — non-negotiable acceptance criteria)

### Security
- NFR-S1 The connection string, instrumentation key, and any Entra token MUST NEVER be logged, placed in error messages, or included in any streamed metric, document, or our own telemetry.
- NFR-S2 The client MUST **fail closed**: on any auth failure, malformed config, or endpoint error it stops/backs off rather than leaking data or entering a tight retry loop.
- NFR-S3 All Live Endpoint communication MUST be over HTTPS/TLS.

### Stability
- NFR-ST1 Swift 6 strict concurrency: all shared types `Sendable`, no data races; the state machine and its timers/state are race-free by construction.
- NFR-ST2 The streaming loop MUST NEVER crash the host and MUST NEVER block the host application's request path, even when the Live Endpoint is slow, wrong, or returns malformed data.
- NFR-ST3 **Bounded memory:** live counters, buffered samples, and sample documents are all bounded with drop-on-overflow. No unbounded growth is permitted under any traffic or backpressure condition.
- NFR-ST4 Feature OFF by default and independently toggled (see FR-8).
- NFR-ST5 All backoff loops MUST be bounded and jittered enough that they never become a tight retry/DoS-on-self loop.

### Quality
- NFR-Q1 **High test coverage of the ping/post state machine**, including every transition (idle→subscribed, subscribed→idle, redirect, polling-hint adoption, ETag change) and **all failure/backoff paths** (ping error, post error, timeout, malformed header, malformed config, auth failure).
- NFR-Q2 Tests MUST exercise graceful degradation for the deferred filtering DSL (FR-6) — confirming the stream survives an unsupported config and reports the error.
- NFR-Q3 SemVer discipline; the public API surface for enabling/configuring Live Metrics is documented and stable.
- NFR-Q4 Documented behavior, including an explicit note of the **maintenance risk** that the QuickPulse protocol is undocumented and reverse-engineered from the MIT .NET source.
- NFR-Q5 Behavior MUST be verifiable without live Azure access (mocked/faked Live Endpoint returning the relevant control headers and subscription states).

---

## Acceptance criteria

- AC-1 With Live Metrics disabled (default), zero requests are made to the Live Endpoint and no background task exists.
- AC-2 With Live Metrics enabled and no viewer, the client polls `/ping?ikey=…` at ~5s intervals and never posts samples; `x-ms-qps-subscribed=false` keeps it in the ping state.
- AC-3 When the faked service returns `x-ms-qps-subscribed=true`, the client transitions to posting `/post?ikey=…` at ~1s intervals with `MonitoringDataPoint` samples.
- AC-4 When subscription flips back to false, the client stops posting within one cycle and returns to ~5s pinging.
- AC-5 On ping error the client backs off to ~60s; on post error it backs off to ~20s; both recover automatically when the endpoint succeeds again. No tight-loop retries.
- AC-6 An `x-ms-qps-service-endpoint-redirect-v2` response causes all subsequent calls to target the new endpoint.
- AC-7 An `x-ms-qps-service-polling-interval-hint` response overrides the default cadence.
- AC-8 A changed `x-ms-qps-configuration-etag` is detected and echoed back on the next request.
- AC-9 A pushed custom filter configuration results in a `CollectionConfigurationError[]` entry in the outgoing payload, standard metrics keep streaming, and nothing crashes.
- AC-10 Streamed `MonitoringDataPoint` samples include role/instance identity, SDK version, timestamp, and the default metric set (request/dependency/exception rates + CPU/memory where available).
- AC-11 Sample `DocumentIngress` documents are capped per sample; excess are dropped (no unbounded buffering).
- AC-12 The connection string, iKey, and any token appear in NO log line, error, metric, or document (verified by test).
- AC-13 The host application's request-handling path shows no blocking or crash regardless of Live Endpoint behavior (slow, erroring, malformed, redirecting).
- AC-14 The auth seam accepts an Entra bearer token on ping/post (even if key-auth is the default in v1).
- AC-15 All of the above are verifiable against a faked Live Endpoint with no live Azure resource.

---

## Out of scope (sibling specs)

- **All Breeze ingestion** — connection-string parsing beyond reading `LiveEndpoint`, envelope model, batch pipeline, `/v2.1/track` transport, partial-success/retry (Specs 01–05). Live Metrics shares only the connection string.
- **The client-side filtering DSL** — `CollectionConfigurationInfo` / `DerivedMetricInfo` filter parsing and local evaluation. **Explicitly deferred to a future Live Metrics version.** v1 only degrades gracefully and reports unsupported configs.
- **One-call bootstrap / distro convenience layer** (Spec 07) — that spec merely offers a toggle to enable this feature; it does not define the protocol.
- **Traces / logs / metrics facade adapters** and their Breeze translation (their own specs).
- **Statsbeat** and any Microsoft-internal usage telemetry.

---

## Open questions

- Q1 `[NEEDS CLARIFICATION]` Exact request-side header set for ping and post (instance/stream identity, transmission time, machine name, previously-seen ETag advertisement) — confirm against the .NET `LiveMetrics` source.
- Q2 `[NEEDS CLARIFICATION]` Exact `MonitoringDataPoint` field/JSON shape and the precise metric names/IDs the blade expects for the default metrics.
- Q3 `[NEEDS CLARIFICATION]` Which performance counters (CPU %, committed/working-set memory) are reliably obtainable on Linux vs macOS server hosts, and how to source them without a heavy dependency.
- Q4 `[NEEDS CLARIFICATION]` Exact `DocumentIngress` field set per document type (Request/Dependency/Exception) and any server-imposed per-sample document cap.
- Q5 `[NEEDS CLARIFICATION]` Exact `CollectionConfigurationError` entry shape expected by the service when reporting an unsupported/deferred configuration.
- Q6 `[NEEDS CLARIFICATION]` Whether the request/dependency/exception live counters tap the shared SSWG telemetry buffer or maintain independent counters, and how to keep the live view consistent with Breeze.
- Q7 `[NEEDS CLARIFICATION]` Entra ID token audience/scope for the LiveEndpoint, and whether v1 must ship Entra auth now or may stage it behind the shared auth seam.
- Q8 `[NEEDS CLARIFICATION]` Whether the service still accepts instrumentation-key auth for Live Metrics at v1 ship time, given the retirement of key-auth for this channel.
- Q9 `[NEEDS CLARIFICATION]` Content type / compression expected on `/post` payloads (JSON? gzip?) and whether ping and post share a serialization format.
- Q10 `[NEEDS CLARIFICATION]` Exact interpretation and units of `x-ms-qps-service-polling-interval-hint`, and precedence between the hint and the default cadence in each state.
