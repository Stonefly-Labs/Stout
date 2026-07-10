# Spec 05 — Durable Delivery, Ingestion Sampling & Secure Entra Auth

Pass the prompt below to `/speckit.specify`.

---

## Overview / Why

`stout` is a collector-free, open-source Azure Monitor / Application Insights exporter built on the **OpenTelemetry Swift SDK (`opentelemetry-swift`)**, running cross-platform on **iOS, macOS, watchOS, tvOS (+ visionOS), and Linux** (Swift 6). It POSTs telemetry directly to the App Insights ingestion endpoint in the legacy "Breeze" schema. Spec 01 (core ingestion foundation) already delivers the transport abstraction (URLSession/async-http-client), connection-string parsing, partial-success parsing, and **basic in-memory retry with backoff**. That foundation loses telemetry the moment the buffer fills or the process restarts (or the app is suspended/terminated on-device) during an outage, only supports instrumentation-key auth, and sends every item.

> Locked design decisions: see design.md §11 (D1–D4, D7–D9). This spec reflects D1 (lifecycle/shutdown: the offline store and delivery components drain-and-go-inert on graceful shutdown — flush/persist pending telemetry, stop the export loop, close the HTTP client — with post-shutdown emission dropped after a single rate-limited internal-diagnostics warning, never via the user telemetry pipeline and never carrying payload or secrets) and D7 (cross-platform: the offline store must respect **bounded on-device disk** and honor **app-suspension flush** on Apple platforms).

This feature is the **hardening layer** that makes delivery survivable and secure in real production services. It adds four capabilities on top of the core foundation:

1. **Durable offline store** — persist unsent telemetry to disk during a transient failure or outage, survive process restarts, replay when ingestion recovers, and stay bounded on disk so it can never fill the host's disk.
2. **Advanced delivery semantics** — honor HTTP 429 throttling and `Retry-After`, apply exponential backoff with jitter, and circuit-break on sustained failure so a failing or slow ingestion endpoint never blocks or harms the host application.
3. **Ingestion sampling** — fixed-rate sampling using the Breeze envelope `sampleRate` + `itemCount` fields, with per-operation (per-trace) consistency so a sampled operation keeps its spans and correlated logs together.
4. **Entra / AAD token authentication** — an alternative to instrumentation-key auth on the ingestion channel, with secure token acquisition and refresh, so a service can authenticate with a managed identity and no instrumentation key.

**Why it matters.** This is a public OSS library that runs inside customers' production services **and on end-user devices** and handles credentials. Telemetry delivery must degrade gracefully: an unreachable backend must never crash the host, block a request thread, exhaust memory, exhaust (a device's limited) disk, or leak a secret. Losing ten minutes of telemetry to a transient outage is unacceptable when the fix — a bounded, secret-safe on-disk buffer — is well understood. Managed-identity auth is a hard requirement for many Azure customers who are forbidden from embedding instrumentation keys in configuration.

## Consumer scenarios

1. **10-minute outage with clean recovery.** A running service emits telemetry while the App Insights ingestion endpoint is unreachable for 10 minutes, then recovers. Expected: no telemetry is lost up to the configured disk bound; the host application experiences no added latency, no thread blocking, and no crash; on-disk usage stays within its configured cap throughout; when ingestion recovers, buffered telemetry is replayed and accepted; steady-state resumes with the offline store drained.

2. **Process restart mid-outage.** The endpoint is down, telemetry has spilled to disk, and the host process restarts (deploy, crash, or scale event) while the outage continues. Expected: on restart the library discovers the previously persisted telemetry and, once ingestion is reachable, replays it. No persisted item is silently dropped except via the documented eviction policy.

3. **Disk bound reached during a long outage.** The endpoint is unreachable for longer than the disk budget can absorb. Expected: on-disk usage never exceeds the configured cap; the oldest persisted telemetry is evicted first to make room for newer telemetry; eviction is observable (counter/diagnostic) but never crashes or blocks the host; the disk never grows unbounded.

4. **Throttling (HTTP 429) with `Retry-After`.** Ingestion returns 429 with a `Retry-After` header. Expected: the library stops sending until at least the `Retry-After` interval has elapsed, does not busy-retry, does not drop the throttled items (they are retained/persisted subject to bounds), and resumes automatically afterward.

5. **Sustained failure trips the circuit breaker.** The endpoint returns persistent 5xx / connection failures beyond a threshold. Expected: the circuit opens, outbound attempts pause for a cooldown (fail-fast, no per-item network attempts), telemetry continues to buffer/persist within bounds, the circuit periodically probes for recovery (half-open), and closes automatically when the endpoint is healthy again. Throughout, the host application is never blocked and never crashes.

6. **Fixed-rate sampling keeps a trace intact.** A service is configured for 25% ingestion sampling. Expected: whole operations (traces) are kept or dropped as a unit — for a kept operation, its spans and correlated log records are all sent; for a dropped operation, none are sent; each sent envelope carries the correct `sampleRate`, and item counts are scaled via `itemCount` so the portal reports statistically correct totals.

7. **Managed-identity auth, no instrumentation key.** A service is configured to authenticate the ingestion channel via Entra (e.g., a system- or user-assigned managed identity / a token credential) instead of an instrumentation key. Expected: the library acquires a token, authenticates ingestion POSTs, refreshes the token before expiry, and never logs or surfaces the token, connection string, or key. Telemetry flows without an instrumentation key present.

8. **Auth failure fails closed and safe.** Token acquisition or refresh fails (identity misconfigured, permission denied, endpoint unreachable). Expected: the library does not crash the host, does not spin/retry unboundedly, surfaces a diagnostic that names the failure category **without** leaking token/secret material, and retries acquisition with backoff. Affected telemetry is buffered/persisted within bounds rather than silently discarded (subject to eviction).

## Functional requirements

### Durable offline store
- On a transient send failure or outage, unsent telemetry MUST be persisted to a durable on-disk store rather than only held in memory.
- Persisted telemetry MUST survive host process restarts and be eligible for replay on the next run.
- The store MUST enforce a **configurable maximum on-disk size** and MUST NOT exceed it; when full, it MUST evict **oldest-first** to admit newer telemetry. On-device (Apple platforms) the disk bound MUST be conservative — the store MUST never contend for an end-user device's limited storage — and MUST be placed in an appropriate, purgeable/cache-class location per platform conventions.
- When ingestion becomes reachable, persisted telemetry MUST be replayed; successfully accepted items MUST be removed from the store.
- Replay MUST respect delivery semantics below (429/`Retry-After`, backoff, circuit breaker) and partial-success results from spec 01 (accepted items removed; only genuinely retriable items retained).
- The store MUST be safe under concurrent producers and the export loop (Swift 6 `Sendable`, no data races) and MUST tolerate a corrupt/partial record from an interrupted write without failing the whole store (skip/quarantine the bad record).
- Enabling the offline store MUST be opt-in/configurable, including its location and size cap. [NEEDS CLARIFICATION: default enabled-vs-disabled, default size cap (e.g., MB and/or item count), and default on-disk location per platform — Linux, macOS, and the Apple client platforms (iOS/watchOS/tvOS caches/app-container directories).]
- **App-suspension flush (Apple platforms, D7).** On iOS/watchOS/tvOS the process can be suspended or terminated by the OS at any time. The delivery components MUST support a **best-effort flush-and-persist on app-suspension** (e.g. driven by the distro's app-lifecycle hooks / background-task assertion) so pending telemetry is persisted within the OS's bounded suspension window rather than lost. [NEEDS CLARIFICATION: whether app-suspension flush uses a background `URLSession` upload, a short background-task assertion to persist-only, or both — and its bounded time budget.]
- On graceful shutdown (D1, drain-and-go-inert), the delivery components MUST flush buffered telemetry best-effort and persist anything still unsent to the offline store (subject to the disk bound) so it survives to the next run, then stop the export loop and close the HTTP client. Shutdown MUST NOT block or crash the host. After shutdown the components are inert: telemetry emitted post-shutdown is dropped and surfaced only via the library's internal diagnostics channel (rate-limited, never via the user telemetry pipeline, never carrying payload or secrets).

### Advanced delivery semantics
- On HTTP 429, the library MUST honor the `Retry-After` header (delay-seconds or HTTP-date) and MUST NOT resend affected items before that interval elapses.
- On retriable failures (429, retriable 5xx, connection/timeout), retries MUST use **exponential backoff with jitter**, bounded by a maximum delay/attempt budget; `Retry-After`, when present, takes precedence over computed backoff.
- A **circuit breaker** MUST open after a configurable threshold of sustained failures, fail-fast during an open cooldown (no per-item network attempts), transition to half-open to probe recovery, and close on success.
- A failing, slow, or unreachable endpoint MUST NEVER block a host application thread, add latency to host request paths, or crash the host; all delivery work is off the host's critical path.
- Non-retriable responses (e.g., 400, and 401/403 that are not resolvable by token refresh) MUST NOT be retried indefinitely; affected items MUST be dropped in a bounded, observable way (never silently, never unboundedly retried).
- These behaviors EXTEND spec 01's basic in-memory retry/backoff; they MUST NOT redefine or duplicate the basic path — where both apply, the hardened policy governs.

### Ingestion sampling
- The library MUST support **fixed-rate ingestion sampling** driven by the Breeze envelope `sampleRate` (percentage kept) and `itemCount` fields.
- The sampling decision MUST be **consistent per operation (per trace)**: all spans and correlated log records belonging to a kept operation are kept; all belonging to a dropped operation are dropped. The decision MUST be deterministic from the operation/trace identity (so independently-processed items of the same trace agree without shared coordination).
- Every emitted envelope MUST carry the effective `sampleRate`, and counts MUST be represented via `itemCount` so downstream aggregation is statistically correct.
- Sampling rate MUST be configurable; a rate of 100% (no sampling) MUST be the default so behavior is unchanged unless opted in. [NEEDS CLARIFICATION: whether metrics envelopes are exempt from trace-based sampling and always sent, matching Azure Monitor behavior]
- Sampling MUST compose with the offline store and delivery semantics (dropped items never persisted; kept items carry their `sampleRate`/`itemCount` through persistence and replay unchanged).

### Entra / AAD token authentication
- The library MUST support authenticating the **ingestion channel** via an Entra/AAD access token as an alternative to instrumentation-key auth.
- The consumer MUST be able to supply a credential/token source (e.g., managed identity, or a caller-provided token-credential abstraction) via configuration. [NEEDS CLARIFICATION: exact credential abstraction and whether the Azure Identity Swift ecosystem provides a supported credential type, or whether we define a token-provider protocol the consumer implements]
- Tokens MUST be acquired for the correct ingestion audience/scope and attached to ingestion POSTs.
- Tokens MUST be **refreshed before expiry** so requests are not sent with an expired token; refresh MUST be off the host's critical path.
- Tokens, connection strings, instrumentation keys, and credential material MUST NEVER be logged, included in error messages, added to telemetry, or persisted to the offline store.
- On auth acquisition/refresh failure, the library MUST fail closed for that request, retry acquisition with bounded backoff, emit a secret-free diagnostic identifying the failure category, and buffer/persist affected telemetry within bounds rather than crash.
- When both an instrumentation key and an Entra credential are configured, the resolution/precedence MUST be defined and documented. [NEEDS CLARIFICATION: precedence when both key and Entra credential are present; whether Entra fully replaces the `iKey`/`InstrumentationKey` on envelopes or is used only for the transport Authorization header]

## Non-functional / quality requirements

- **Security**
  - No connection string, instrumentation key, Entra token, or credential material is ever logged, surfaced in errors or exceptions, embedded in emitted telemetry, or written to the offline store in clear form.
  - Persisted telemetry on disk MUST be **secret-safe at rest** (no secrets/tokens in persisted payloads; persisted files created with least-privilege permissions). [NEEDS CLARIFICATION: whether "encrypted at rest" is required for telemetry payloads themselves, or whether secret-exclusion + restrictive file permissions is the accepted bar, given telemetry payloads are not themselves credentials]
  - Configuration and inputs are validated and the library **fails closed** on invalid/ambiguous security configuration (e.g., neither a valid key nor a working credential) rather than sending unauthenticated.
- **Stability**
  - Full Swift 6 strict concurrency: all shared state is `Sendable` with no data races across producers, the export loop, the offline store, and the token refresh path.
  - Telemetry delivery failures NEVER crash, deadlock, or block the host application; all I/O (network + disk) is off the host's request/critical path.
  - Memory is bounded (drop-on-overflow per the core pipeline) AND disk is bounded (oldest-first eviction); neither can grow without limit under a sustained outage.
  - Backoff, throttling, and circuit-breaking prevent request storms against a struggling endpoint and prevent tight retry loops on auth failure.
- **Quality**
  - High automated test coverage of the failure paths specifically: simulated outage + replay, process-restart replay, disk-cap eviction, 429/`Retry-After` honoring, circuit open/half-open/close, per-trace sampling consistency, token refresh, and auth-failure fail-closed behavior.
  - A test MUST assert that no secret/token value appears in logs, errors, emitted telemetry, or persisted files.
  - Observable behavior (counters/diagnostics) for: items persisted, items evicted, items replayed, circuit state changes, throttle events, and auth-refresh failures — none of which leak secrets.
  - Public API changes follow SemVer; all new configuration and behavior is documented, including defaults and the eviction/precedence policies.

## Acceptance criteria

1. During a simulated 10-minute outage followed by recovery, no telemetry is lost up to the configured disk bound, the host sees no added latency/blocking/crash, on-disk usage never exceeds the cap, and all buffered telemetry is replayed and accepted on recovery.
2. Telemetry persisted during an outage is discovered and replayed after a host process restart; no persisted item is dropped except via documented oldest-first eviction.
3. When the offline store reaches its configured cap, oldest telemetry is evicted first, on-disk size never exceeds the cap, and eviction is reported via a diagnostic/counter without crashing or blocking.
4. On HTTP 429 with `Retry-After`, no affected item is resent before the `Retry-After` interval elapses, there is no busy-retry, and sending resumes automatically after the interval.
5. Retriable failures use exponential backoff with jitter bounded by a max, and `Retry-After` takes precedence over computed backoff when present.
6. Sustained failures open the circuit; during the open cooldown no per-item network attempts occur; the circuit half-opens to probe and closes on recovery; the host is never blocked or crashed throughout.
7. With fixed-rate sampling configured, each operation is kept or dropped as a whole (all its spans + correlated logs together), sent envelopes carry the correct `sampleRate`, and `itemCount` reflects the scaling so portal totals are statistically correct. Default configuration performs no sampling (100% kept).
8. A service configured with a managed identity (no instrumentation key) authenticates ingestion via Entra, telemetry is accepted, and tokens are refreshed before expiry.
9. On token acquisition/refresh failure the library fails closed for the affected request, retries acquisition with bounded backoff, does not crash the host, and emits a secret-free diagnostic; affected telemetry is buffered/persisted within bounds.
10. Across all of the above, no connection string, instrumentation key, or Entra token appears in any log, error message, emitted telemetry item, or persisted on-disk record — asserted by automated test.
11. All new shared state compiles and passes under Swift 6 strict concurrency with no data races (e.g., ThreadSanitizer/CI green).

## Out of scope (sibling specs)

- **Spec 01 — core ingestion foundation:** connection-string parsing, transport, gzip/newline-JSON encoding, partial-success parsing, and the **basic in-memory retry/backoff**. This spec EXTENDS those; it does not redefine them.
- **Specs 02 / 03 / 04 — signal translations** (the `SpanExporter` / `LogRecordExporter` / `MetricExporter` implementations and their `SpanData`/`ReadableLogRecord`/`MetricData` → Breeze mapping). This spec consumes their output but does not define translation.
- **Spec 06 — Live Metrics (QuickPulse) channel and its separate auth.** Live Metrics has its own endpoint, data model, HTTP pipeline, and control-channel auth. Referenced here (its auth also moves to Entra) but specified separately; this spec covers only the **Breeze ingestion channel**.
- **Spec 07 — distro convenience bootstrap** (one-call setup, optional framework middleware). Configuration surfaces defined here are wired up there but not owned here.

## Open questions

1. [NEEDS CLARIFICATION] Offline store defaults: enabled or disabled by default; default size cap (bytes and/or item count); default on-disk location per platform (Linux, macOS, and the Apple client platforms' caches/app-container directories); single-writer assumption vs multiple processes sharing a store directory.
2. [NEEDS CLARIFICATION] "Secret-safe at rest" bar: is full encryption of persisted telemetry payloads required, or is secret-exclusion plus restrictive file permissions the accepted standard given payloads are telemetry, not credentials?
3. [NEEDS CLARIFICATION] Whether metric envelopes are exempt from per-trace ingestion sampling (always sent), matching Azure Monitor's behavior.
4. [NEEDS CLARIFICATION] Entra credential abstraction: is there a supported Azure Identity credential type for Swift, or do we define a token-provider protocol the consumer implements? Which audience/scope for the ingestion endpoint?
5. [NEEDS CLARIFICATION] Precedence and envelope handling when both an instrumentation key and an Entra credential are configured: does Entra fully replace `iKey`, or is it only the transport `Authorization` header alongside the key?
6. [NEEDS CLARIFICATION] Circuit-breaker and backoff tunables: default failure threshold, open cooldown, half-open probe policy, max backoff, and whether these are consumer-configurable.
7. [NEEDS CLARIFICATION] Behavior when the offline store is enabled but its configured location is unwritable (permission/disk error) at startup — fail closed, disable persistence with a diagnostic, or refuse to start?
