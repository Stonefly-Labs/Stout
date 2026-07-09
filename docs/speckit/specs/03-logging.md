# Spec 03 — Logging Exporter (`swift-log` → Azure Monitor)

Pass the prompt below to `/speckit.specify`.

---

Specify the **Logging exporter** feature for **Stout**, a collector-free, open-source Azure Monitor / Application Insights exporter for server-side Swift (Linux + macOS, Swift 6). This feature adds a `swift-log` `LogHandler` implementation that acts as an Azure Monitor logging backend: it captures log records emitted through the SSWG `swift-log` facade, translates them into Application Insights "Breeze" telemetry, and hands them to the already-built core ingestion pipeline for delivery. It builds **on top of** the core ingestion foundation (spec 01) — the Breeze envelope framework, the bounded telemetry pipeline, resource detection, and the HTTPS/gzip transport already exist; this feature consumes them and MUST NOT redefine them.

## Overview / Why

Server-side Swift applications and the frameworks they use (Vapor, Hummingbird, gRPC-swift, etc.) already emit logs through `swift-log`. By providing a `LogHandler` that is bootstrapped via `LoggingSystem.bootstrap`, every existing `logger.info(...)` / `logger.error(...)` call in the host application and its dependencies begins flowing to Application Insights with **no code changes to the logging call sites**. Operators can then see application logs in App Insights alongside their traces and metrics, correlated to the request/operation that produced them, with structured metadata surfaced as searchable custom properties — and with secrets never leaked. This is the intended SSWG extension model: we become another `swift-log` backend.

Logs must appear as first-class App Insights telemetry: ordinary records as **Trace / MessageData**, and records that carry error or exception information as **Exception / ExceptionData**, with correct severity mapping and trace correlation so a log written inside a request handler is tied to that request.

> Locked design decisions: see design.md §11 (D1–D4). This spec reflects D1 (lifecycle/shutdown: the `LogHandler` goes inert on shutdown and post-shutdown emission is safe).

## Consumer scenarios

1. **Bootstrap the backend.** A developer configures the library with an Application Insights connection string (parsed/validated by the core foundation) and bootstraps the logging system so that `Logger` instances created anywhere in the process route through the Azure Monitor `LogHandler`. Given a valid configuration, subsequent log calls produce Breeze telemetry that reaches App Insights; given an invalid/unconfigured setup, bootstrap fails closed and does not silently drop into a broken state.

2. **An error inside a request handler correlates to its request.** Within a request handler that is executing inside an active span/trace context, application code calls `logger.error("payment failed", metadata: ["orderID": "A123"])`. In App Insights, that log appears correlated to the request's operation (same operation id / parent operation), carries `orderID=A123` as a custom property, has severity level "Error", and leaks no secrets. If the same call includes an underlying `Swift.Error`, it appears as an Exception telemetry item instead of a plain trace message.

3. **Structured metadata becomes custom properties.** A developer attaches `Logger.Metadata` at logger creation (via `logger[metadataKey:]`) and/or at the call site. All effective metadata for a record (merged handler + logger + per-call metadata, with the documented precedence) is flattened into the telemetry item's `properties`, so operators can filter/search on them in App Insights.

4. **Log levels map predictably.** A developer emits records at each `swift-log` level and observes them in App Insights at the expected App Insights severity level (see Functional requirements). A developer sets the handler's `logLevel`; records below the threshold are never captured or exported.

5. **Do no harm under failure/load.** Under a slow or failing ingestion endpoint, or a burst of log volume, the host application continues normally: logging calls never block on network I/O, never crash, and never grow memory without bound. Excess telemetry is dropped by the underlying bounded pipeline rather than back-pressuring the caller.

## Functional requirements

### Capture (LogHandler behavior)

- MUST provide a `swift-log` `LogHandler` conformance that can be installed via `LoggingSystem.bootstrap`, so that all `Logger` instances in the process route their records to Azure Monitor.
- MUST capture, for each log record: the log **level**, the **message**, the effective **metadata**, and the **source/label** (logger label and `swift-log` `source`), plus the timestamp of the event.
- MUST honor the standard `LogHandler` contract: a settable `logLevel` threshold (records below it are not exported), settable per-handler `metadata`, and `metadataKey` subscript access. Metadata precedence MUST follow the documented `swift-log` merge order (per-call metadata overrides logger/handler metadata) and MUST be documented.
- MUST support `Logger.MetadataProvider` (task-local / contextual metadata) if present, folding provided metadata into the record's effective metadata.
- MUST be `Sendable` and safe to share across concurrency domains; capturing/handing off a record MUST NOT perform blocking I/O on the caller's thread/task.
- Emitting a log record MUST be a non-throwing, non-blocking enqueue into the core pipeline; when the pipeline's bounded buffer is full the record is dropped (accounted by the core's overflow metric), never buffered without limit and never blocking the caller.

### Translation — normal records → Breeze MessageData (Trace)

- A record without error/exception information MUST translate to a **MessageData** `baseData` inside a standard Breeze envelope obtained from the core envelope framework.
- MessageData fields MUST be populated as: `message` ← the rendered log message text; `severityLevel` ← the mapped App Insights severity (below); `properties` ← the flattened effective metadata plus any standardized fields (e.g. the logger label / `source`) as string key/value pairs.
- The envelope's Part A tags (iKey, sdkVersion, cloud role/roleInstance, timestamp) MUST be populated by the shared core/resource machinery, not re-implemented here.

### Translation — error/exception records → Breeze ExceptionData

- A record that carries error/exception information MUST translate to an **ExceptionData** `baseData` instead of MessageData. "Carries error/exception information" MUST at minimum cover the case where a `Swift.Error` is conveyed with the log record (see Open questions for the exact convention used to attach an error to a `swift-log` record).
- ExceptionData MUST represent the error as an exception detail with: an exception `typeName` (the error/type identity), an exception `message` (the error/localized description and/or the log message), and MUST carry the log record's `severityLevel` and the flattened metadata as `properties`.
- Stack-trace population is best-effort: if no reliable stack trace is available for a plain `Swift.Error`, the exception detail MUST still be emitted with the available type/message information rather than being dropped. [NEEDS CLARIFICATION: is any stack-trace/frame information reliably available for arbitrary `Swift.Error` on Linux + macOS, or is ExceptionData emitted without frames in the MVP?]

### Severity mapping (inherent, in-scope requirement)

- `swift-log` levels MUST map to App Insights severity levels as follows:
  - `trace` → Verbose
  - `debug` → Verbose
  - `info` → Information
  - `notice` → Information
  - `warning` → Warning
  - `error` → Error
  - `critical` → Critical
- This mapping MUST be covered by tests. [NEEDS CLARIFICATION: confirm `notice` → Information (vs Warning) and `debug` → Verbose against the authoritative .NET/OTel severity-number mapping for App Insights.]

### Metadata → properties (with secret hygiene)

- All effective `Logger.Metadata` for a record MUST be flattened to string key/value `properties`. Nested metadata (dictionaries/arrays) MUST be rendered deterministically to string form so operators get stable, searchable values.
- Secret hygiene is REQUIRED and is a security acceptance criterion: metadata keys recognized as sensitive (e.g. keys matching a documented sensitive-key set / patterns such as authorization, password, secret, token, connection string, api key) MUST be redacted or omitted, never emitted verbatim. The library's own configuration secrets (connection string, instrumentation key, tokens) MUST NEVER appear in any emitted property or in any self-diagnostic. Redaction MUST be the default and MUST be covered by tests. [NEEDS CLARIFICATION: is the sensitive-key redaction policy fixed/built-in, consumer-configurable (allow/deny list), or both? Default MUST fail closed.]

### Trace correlation (shared contract with tracing spec 02)

- When a log record is emitted within an active span / distributed-tracing context, the resulting telemetry item MUST be stamped with `ai.operation.id` ← the current **trace id** and `ai.operation.parentId` ← the current **span id**, so the log correlates to its operation/request in App Insights.
- The active context MUST be read from the ambient `swift-distributed-tracing` / `ServiceContext` propagation mechanism shared with spec 02 (the tracing feature); this feature MUST consume that shared correlation contract and MUST NOT define its own parallel context propagation. When no active trace context is present, the correlation tags MUST be omitted (the log is still exported, uncorrelated).
- The exact source of the trace id / span id values (the shared context keys and their format) is the contract defined jointly with spec 02. [NEEDS CLARIFICATION: confirm the shared context-key/type used to read the active span's trace id and span id, and W3C-vs-internal format, is defined by spec 02 and stable.]

### Configuration & lifecycle

- The handler MUST accept the already-validated core configuration (connection string / resolved endpoint + iKey) rather than parsing secrets itself; connection-string parsing and validation belong to spec 01.
- The handler MUST be an **independently-constructable, injectable object** (D1); the `LoggingSystem.bootstrap` registration is a thin layer over it (the testability seam).
- The handler's export path MUST participate in the core pipeline's **drain-and-go-inert** flush/shutdown (D1) so that a graceful shutdown attempts to deliver buffered log telemetry within a bounded time before exit (using the core's shutdown contract; this feature does not define its own transport or flush loop). After the pipeline shuts down, the installed — and un-removable — `LogHandler` MUST become a **safe no-op**: records emitted post-shutdown are dropped and MUST NOT crash or block the caller; the drop is surfaced only via spec 01's rate-limited internal-diagnostics warning (never re-emitted as telemetry, never carrying record/metadata payload).

## Non-functional / quality requirements

These restate the binding constitution principles as explicit, testable acceptance criteria for this feature.

- **Security (NON-NEGOTIABLE).** Secrets (connection string, instrumentation key, Entra/AAD tokens) MUST NEVER be logged, emitted as telemetry, or included in error messages or self-diagnostics. Sensitive metadata keys MUST be redacted by default. All of this MUST be covered by tests. The feature MUST fail closed on invalid/ambiguous input.
- **Resilience / Do-No-Harm (NON-NEGOTIABLE).** Logging MUST NEVER crash, block, deadlock, or measurably degrade the host. No `fatalError`, force-unwrap, `try!`, or blocking I/O on the caller's path. Memory MUST be bounded — the handler relies on the core's bounded, drop-on-overflow buffer and MUST NOT introduce any unbounded queue of its own. Telemetry loss is always preferable to host impact.
- **Concurrency safety (NON-NEGOTIABLE).** All types MUST build and test clean under Swift 6 strict concurrency with no suppressed data-race warnings; types crossing concurrency boundaries MUST be correctly `Sendable`; `@unchecked Sendable` requires reviewed justification. No data races on shared handler state (metadata, log level).
- **Quality & testing.** The severity mapping table, the MessageData-vs-ExceptionData branch selection, metadata flattening, secret redaction, and the trace-correlation stamping MUST all be covered by automated tests, including failure paths (overflow/drop, missing context, malformed metadata). CI MUST pass on Linux and macOS for supported Swift 6 toolchains; lint/format gates blocking.
- **API stewardship & docs.** Public API (the handler type and its bootstrap entry points) MUST follow SemVer, keep internal machinery non-`public`, and be documented with doc comments before release. Observable behavior (level→severity mapping, metadata precedence, redaction policy, correlation behavior) MUST be documented.
- **Fidelity.** MessageData / ExceptionData structure, `severityLevel` values, and correlation tags MUST match authoritative Breeze/App Insights behavior (verified against the MIT-licensed .NET reference logic), covered by golden/round-trip tests.

## Acceptance criteria

1. Bootstrapping the Azure Monitor `LogHandler` via `LoggingSystem.bootstrap` with a valid configuration causes all `Logger` records at/above the configured level to be captured and handed to the core pipeline; below-threshold records are never exported.
2. A record with no error yields a **MessageData** telemetry item; a record carrying a `Swift.Error` yields an **ExceptionData** telemetry item with a populated exception type name and message.
3. Each `swift-log` level produces the specified App Insights severity level (trace/debug→Verbose, info/notice→Information, warning→Warning, error→Error, critical→Critical), verified by test.
4. Effective merged metadata (handler + logger + per-call + metadata-provider, with documented precedence) appears as string `properties` on the emitted item.
5. Sensitive metadata keys are redacted/omitted by default; the library's own secrets never appear in any property, message, or diagnostic — proven by a redaction test. Failure to redact is a release blocker.
6. A log emitted inside an active trace context is stamped with `ai.operation.id` (trace id) and `ai.operation.parentId` (span id) matching the active span; a log with no active context is exported without those tags and is not dropped for lack of context.
7. End-to-end consumer scenario: a `logger.error(...)` inside a request handler appears in App Insights correlated to that request's operation, with its metadata as custom properties and no secrets leaked.
8. Under a full pipeline (slow/failing endpoint or burst load), logging calls do not block, crash, or grow memory unbounded; excess records are dropped and accounted via the core overflow metric.
9. All types are `Sendable`-clean under Swift 6 strict concurrency; CI green on Linux and macOS; public API documented.

## Out of scope (sibling specs)

- **Envelope framework, telemetry pipeline, resource detection, transport, connection-string parsing/secret handling, partial-success/retry** — spec 01 (core ingestion foundation). This feature consumes them.
- **Tracing** (`Tracer` / span → Request/Dependency translation, W3C traceparent propagation) — spec 02. This feature only **references the trace-correlation contract** (reading the active trace id / span id) shared with spec 02; it does not implement tracing or context propagation.
- **Metrics** (`MetricsFactory` → MetricData) — spec 04.
- **Live Metrics / QuickPulse** — spec 06.
- **Durable/offline delivery, ingestion sampling, and Entra/AAD auth** — spec 05 (hardening). This feature inherits whatever the core pipeline provides but defines none of it.

## Open questions

- [NEEDS CLARIFICATION] Exact `swift-log` convention for attaching a `Swift.Error`/exception to a log record that this handler keys the MessageData-vs-ExceptionData decision on (metadata key convention vs a dedicated API), owned jointly with the core team.
- [NEEDS CLARIFICATION] Whether reliable stack-trace/frame information is obtainable for arbitrary `Swift.Error` on Linux + macOS; if not, ExceptionData is emitted without frames in the MVP.
- [NEEDS CLARIFICATION] Confirm the severity mapping edge cases (`notice` → Information vs Warning; `debug`/`trace` → Verbose) against the authoritative .NET/OTel severity-number mapping.
- [NEEDS CLARIFICATION] Sensitive-metadata redaction policy: fixed built-in set vs consumer-configurable allow/deny list vs both; default MUST fail closed (redact when unsure).
- [NEEDS CLARIFICATION] The shared context key/type and id format (W3C vs internal) used to read the active span's trace id / span id — defined and owned by spec 02 (tracing) as the shared correlation contract.
- [NEEDS CLARIFICATION] Deterministic rendering of nested/structured `Logger.MetadataValue` (dictionaries/arrays) into `properties` string values — exact serialization format.
