# Spec 03 — Logging Exporter (`opentelemetry-swift` `LogRecordExporter` → Breeze)

Pass the prompt below to `/speckit.specify`.

---

Specify the **Logging exporter** feature for **Stout**, a collector-free, open-source Azure Monitor / Application Insights exporter built on the **OpenTelemetry Swift SDK (`opentelemetry-swift`)**, running cross-platform on **iOS, macOS, watchOS, tvOS (+ visionOS), and Linux** (Swift 6). This feature adds an `opentelemetry-swift` **`LogRecordExporter`** implementation that acts as an Azure Monitor logging exporter: it receives log records (`ReadableLogRecord`) produced through the OTel SDK's `LoggerProvider`, translates them into Application Insights "Breeze" telemetry, and hands them to the already-built core ingestion pipeline for delivery. It builds **on top of** the core ingestion foundation (spec 01) — the Breeze envelope framework, the bounded telemetry pipeline, resource detection, and the HTTPS/gzip transport abstraction already exist; this feature consumes them and MUST NOT redefine them.

## Overview / Why

Swift apps and the frameworks they use — iOS/macOS/watchOS/tvOS clients and Linux/macOS servers (Vapor, Hummingbird, gRPC-swift, etc.) — emit logs through `opentelemetry-swift`'s logging bridge (which can itself capture `swift-log`, `os.Logger`, or direct OTel log emission upstream). By registering a `LogRecordExporter` with the OTel SDK's `LoggerProvider`, those records begin flowing to Application Insights with no bespoke wiring in the library. Operators can then see application logs in App Insights alongside their traces and metrics, correlated to the request/operation that produced them, with structured attributes surfaced as searchable custom properties — and with secrets never leaked. Stout is the Azure Monitor **exporter**; capturing/bridging logs into the OTel SDK is upstream and not this feature's job.

Logs must appear as first-class App Insights telemetry: ordinary records as **Trace / MessageData**, and records that carry error or exception information as **Exception / ExceptionData**, with correct severity mapping and trace correlation so a log written inside a request handler (or an on-device operation) is tied to that operation.

> Locked design decisions: see design.md §11 (D1–D4, D7–D9). This spec reflects D1 (lifecycle/shutdown: the `LogRecordExporter` goes inert on `shutdown()` and post-shutdown export is safe), D7 (cross-platform), and D8 (build on `opentelemetry-swift`'s `LogRecordExporter`). **Known maturity trade-off (design §3):** `opentelemetry-swift` Logs are Beta/Development; this exporter knowingly rides that beta API.

## Consumer scenarios

1. **Register the exporter.** A developer configures the library with an Application Insights connection string (parsed/validated by the core foundation) and registers the Azure Monitor `LogRecordExporter` with the OTel SDK's `LoggerProvider` (normally via a `BatchLogRecordProcessor`). Given a valid configuration, subsequent log records produce Breeze telemetry that reaches App Insights; given an invalid/unconfigured setup, configuration fails closed and does not silently drop into a broken state.

2. **An error inside a request handler correlates to its request.** Within an operation executing inside an active span, application code logs `"payment failed"` with attribute `orderID=A123` and severity Error. The OTel SDK stamps the record's `ReadableLogRecord` with the active span context; in App Insights that log appears correlated to the operation (same operation id / parent operation), carries `orderID=A123` as a custom property, has severity level "Error", and leaks no secrets. If the record conveys an underlying error/exception, it appears as an Exception telemetry item instead of a plain trace message.

3. **Structured attributes become custom properties.** A developer attaches attributes to the log record. All effective attributes for a record are flattened into the telemetry item's `properties`, so operators can filter/search on them in App Insights.

4. **Log severities map predictably.** A developer emits records at each OTel severity and observes them in App Insights at the expected App Insights severity level (see Functional requirements). Records the SDK filters below the configured minimum severity are never handed to the exporter.

5. **Do no harm under failure/load.** Under a slow or failing ingestion endpoint, or a burst of log volume, the host application continues normally: the export path never blocks on network I/O, never crashes, and never grows memory without bound. Excess telemetry is dropped by the underlying bounded pipeline rather than back-pressuring the caller.

## Functional requirements

### Export (`LogRecordExporter` behavior)

- MUST provide an `opentelemetry-swift` **`LogRecordExporter`** conformance — `export(logRecords: [ReadableLogRecord]) -> ExportResult`, `flush()`, `shutdown()` — that is registered with the SDK's `LoggerProvider` (normally via a `BatchLogRecordProcessor`). [NEEDS CLARIFICATION: confirm the exact `LogRecordExporter` protocol signatures, the record type (`ReadableLogRecord` / `ReadableLogRecord`) field set, and `ExportResult` cases in the targeted `opentelemetry-swift` version — Logs are Beta and the surface may shift.]
- MUST read, from each record's `ReadableLogRecord`: the OTel **severity** (number/text), the **body**/message, the effective **attributes**, the record's **`SpanContext`** (for trace correlation), the OTel `Resource` (for Part A tags), the **instrumentation scope** (name/version), and the observed/event timestamp.
- Severity thresholding, batching, and record capture/bridging are the SDK's job — this feature translates whatever `ReadableLogRecord` the SDK hands to `export(...)`; it does not implement a threshold or a metadata-merge order itself.
- MUST be `Sendable` and safe to share across concurrency domains; the `export(...)` path MUST NOT perform blocking I/O on the caller's thread/task.
- `export(...)` MUST be a non-throwing, non-blocking enqueue into the core pipeline that returns a success/failure result promptly; when the pipeline's bounded buffer is full the record is dropped (accounted by the core's overflow metric), never buffered without limit and never blocking the caller.

### Translation — normal records → Breeze MessageData (Trace)

- A record without error/exception information MUST translate to a **MessageData** `baseData` inside a standard Breeze envelope obtained from the core envelope framework.
- MessageData fields MUST be populated as: `message` ← the rendered log **body** text; `severityLevel` ← the mapped App Insights severity (below); `properties` ← the flattened effective **attributes** plus any standardized fields (e.g. the instrumentation scope name/version) as string key/value pairs.
- The envelope's Part A tags (iKey, sdkVersion, cloud role/roleInstance, on-device device/app tags, timestamp) MUST be populated by the shared core/resource machinery from the record's OTel `Resource`, not re-implemented here.

### Translation — error/exception records → Breeze ExceptionData

- A record that carries error/exception information MUST translate to an **ExceptionData** `baseData` instead of MessageData. "Carries error/exception information" MUST at minimum cover records that carry the OTel exception attributes (`exception.type` / `exception.message` / `exception.stacktrace`) and/or an error severity conveying an exception. [NEEDS CLARIFICATION: the exact convention `opentelemetry-swift` uses to attach exception information to a `ReadableLogRecord` — exception attributes on the record vs a dedicated field — that this exporter keys the MessageData-vs-ExceptionData decision on.]
- ExceptionData MUST represent the error as an exception detail with: an exception `typeName` (from `exception.type` / the error identity), an exception `message` (from `exception.message` and/or the log body), and MUST carry the record's `severityLevel` and the flattened attributes as `properties`.
- Stack-trace population is best-effort: if no reliable stack trace (`exception.stacktrace`) is available, the exception detail MUST still be emitted with the available type/message information rather than being dropped. [NEEDS CLARIFICATION: whether reliable stack-trace/frame information is present on `ReadableLogRecord` across the target platforms (iOS/macOS/watchOS/tvOS + Linux), or ExceptionData is emitted without frames in the MVP.]

### Severity mapping (inherent, in-scope requirement)

- OTel log **severity numbers** MUST map to App Insights severity levels, following the OTel severity-number bands:
  - `TRACE*` (1–4) → Verbose
  - `DEBUG*` (5–8) → Verbose
  - `INFO*` (9–12) → Information
  - `WARN*` (13–16) → Warning
  - `ERROR*` (17–20) → Error
  - `FATAL*` (21–24) → Critical
- This mapping MUST be covered by tests. [NEEDS CLARIFICATION: confirm the exact band boundaries and any edge cases against the authoritative .NET/OTel severity-number → App Insights `severityLevel` mapping.]

### Attributes → properties (with secret hygiene)

- All effective record **attributes** MUST be flattened to string key/value `properties`. Nested/structured attribute values (arrays/maps) MUST be rendered deterministically to string form so operators get stable, searchable values.
- Secret hygiene is REQUIRED and is a security acceptance criterion: attribute keys recognized as sensitive (e.g. keys matching a documented sensitive-key set / patterns such as authorization, password, secret, token, connection string, api key) MUST be redacted or omitted, never emitted verbatim. The library's own configuration secrets (connection string, instrumentation key, tokens) MUST NEVER appear in any emitted property or in any self-diagnostic. Redaction MUST be the default and MUST be covered by tests. [NEEDS CLARIFICATION: is the sensitive-key redaction policy fixed/built-in, consumer-configurable (allow/deny list), or both? Default MUST fail closed.]

### Trace correlation (shared rule with tracing spec 02)

- When a log record carries an active span context, the resulting telemetry item MUST be stamped with `ai.operation.id` ← the record's **trace id** and `ai.operation.parentId` ← the record's **span id**, so the log correlates to its operation/request in App Insights.
- The trace id / span id are read **directly from the record's `ReadableLogRecord.spanContext`** — the OTel SDK stamps the active span context onto each record at emit time; this feature MUST NOT define its own parallel context propagation. When the record carries no valid span context, the correlation tags MUST be omitted (the log is still exported, uncorrelated).
- The trace-id/span-id → `ai.operation.*` mapping rule is the **shared correlation rule defined by spec 02** (canonical W3C hex → `ai.operation.*`); this feature reuses it. [NEEDS CLARIFICATION: confirm the `ReadableLogRecord` field carrying the span context and that it is populated by the SDK's log-trace correlation in the targeted version.]

### Configuration & lifecycle

- The exporter MUST accept the already-validated core configuration (connection string / resolved endpoint + iKey) rather than parsing secrets itself; connection-string parsing and validation belong to spec 01.
- The exporter MUST be an **independently-constructable, injectable object** (D1) so it can be built and unit-tested without an active `LoggerProvider`; registration with the provider is a thin layer over it (the testability seam).
- The exporter's export path MUST participate in the core pipeline's **drain-and-go-inert** flush/shutdown (D1) so that a graceful shutdown — triggered via the SDK's `flush()`/`shutdown()` — attempts to deliver buffered log telemetry within a bounded time before exit (using the core's shutdown contract; this feature does not define its own transport or flush loop). After the pipeline shuts down, the `LogRecordExporter` MUST become a **safe no-op**: records handed to `export(...)` post-shutdown are dropped and MUST NOT crash or block the caller; the drop is surfaced only via spec 01's rate-limited internal-diagnostics warning (never re-emitted as telemetry, never carrying record/attribute payload).

## Non-functional / quality requirements

These restate the binding constitution principles as explicit, testable acceptance criteria for this feature.

- **Security (NON-NEGOTIABLE).** Secrets (connection string, instrumentation key, Entra/AAD tokens) MUST NEVER be logged, emitted as telemetry, or included in error messages or self-diagnostics. Sensitive attribute keys MUST be redacted by default. All of this MUST be covered by tests. The feature MUST fail closed on invalid/ambiguous input.
- **Resilience / Do-No-Harm (NON-NEGOTIABLE).** Logging MUST NEVER crash, block, deadlock, or measurably degrade the host. No `fatalError`, force-unwrap, `try!`, or blocking I/O on the caller's path. Memory MUST be bounded — the handler relies on the core's bounded, drop-on-overflow buffer and MUST NOT introduce any unbounded queue of its own. Telemetry loss is always preferable to host impact.
- **Concurrency safety (NON-NEGOTIABLE).** All types MUST build and test clean under Swift 6 strict concurrency with no suppressed data-race warnings; types crossing concurrency boundaries MUST be correctly `Sendable`; `@unchecked Sendable` requires reviewed justification. No data races on shared exporter state.
- **Quality & testing.** The severity mapping table, the MessageData-vs-ExceptionData branch selection, attribute flattening, secret redaction, and the trace-correlation stamping MUST all be covered by automated tests, including failure paths (overflow/drop, missing span context, malformed attributes). CI MUST pass on **an Apple platform (iOS simulator / macOS) and Linux** for supported Swift 6 toolchains; lint/format gates blocking.
- **API stewardship & docs.** Public API (the exporter type and its configuration entry points) MUST follow SemVer, keep internal machinery non-`public`, and be documented with doc comments before release. Observable behavior (severity→severityLevel mapping, redaction policy, correlation behavior) MUST be documented.
- **Fidelity.** MessageData / ExceptionData structure, `severityLevel` values, and correlation tags MUST match authoritative Breeze/App Insights behavior (verified against the MIT-licensed .NET reference logic), covered by golden/round-trip tests.

## Acceptance criteria

1. Registering the Azure Monitor `LogRecordExporter` with the OTel `LoggerProvider` with a valid configuration causes records the SDK hands to `export(...)` to be translated and handed to the core pipeline; records the SDK filtered below the configured minimum severity are never received.
2. A record with no error yields a **MessageData** telemetry item; a record carrying exception information (OTel `exception.*` attributes) yields an **ExceptionData** telemetry item with a populated exception type name and message.
3. Each OTel severity band produces the specified App Insights severity level (TRACE/DEBUG→Verbose, INFO→Information, WARN→Warning, ERROR→Error, FATAL→Critical), verified by test.
4. The record's effective attributes appear as string `properties` on the emitted item.
5. Sensitive attribute keys are redacted/omitted by default; the library's own secrets never appear in any property, message, or diagnostic — proven by a redaction test. Failure to redact is a release blocker.
6. A record carrying an active span context is stamped with `ai.operation.id` (trace id) and `ai.operation.parentId` (span id) from its `ReadableLogRecord.spanContext`; a record with no span context is exported without those tags and is not dropped for lack of context.
7. End-to-end consumer scenario: an error-severity log inside a request handler appears in App Insights correlated to that request's operation, with its attributes as custom properties and no secrets leaked.
8. Under a full pipeline (slow/failing endpoint or burst load), the export path does not block, crash, or grow memory unbounded; excess records are dropped and accounted via the core overflow metric.
9. All types are `Sendable`-clean under Swift 6 strict concurrency; CI green on **an Apple platform and Linux**; public API documented.

## Out of scope (sibling specs)

- **Envelope framework, telemetry pipeline, resource detection, transport, connection-string parsing/secret handling, partial-success/retry** — spec 01 (core ingestion foundation). This feature consumes them.
- **Tracing** (`SpanExporter` / `SpanData` → Request/Dependency translation) — spec 02. This feature only **reuses the trace-id/span-id → `ai.operation.*` mapping rule** defined by spec 02; it does not implement tracing. W3C propagation is the OTel SDK's, not either spec's.
- **Metrics** (`MetricExporter` / `MetricData` → Breeze MetricData) — spec 04.
- **Capturing/bridging logs into the OTel SDK** (`swift-log`/`os.Logger`/OTel-native bridges, severity thresholding, batching) — upstream in `opentelemetry-swift`, not this feature.
- **Live Metrics / QuickPulse** — spec 06.
- **Durable/offline delivery, ingestion sampling, and Entra/AAD auth** — spec 05 (hardening). This feature inherits whatever the core pipeline provides but defines none of it.

## Open questions

- [NEEDS CLARIFICATION] Exact `opentelemetry-swift` `LogRecordExporter` protocol signatures, record type (`ReadableLogRecord`/`ReadableLogRecord`) field set, and `ExportResult` cases in the targeted (Beta) version.
- [NEEDS CLARIFICATION] Exact convention `opentelemetry-swift` uses to attach exception information to a `ReadableLogRecord` (OTel `exception.*` attributes vs a dedicated field) that this exporter keys the MessageData-vs-ExceptionData decision on.
- [NEEDS CLARIFICATION] Whether reliable stack-trace/frame information (`exception.stacktrace`) is obtainable across the target platforms (iOS/macOS/watchOS/tvOS + Linux); if not, ExceptionData is emitted without frames in the MVP.
- [NEEDS CLARIFICATION] Confirm the exact OTel severity-number band boundaries → App Insights `severityLevel` mapping against the authoritative .NET/OTel mapping.
- [NEEDS CLARIFICATION] Sensitive-attribute redaction policy: fixed built-in set vs consumer-configurable allow/deny list vs both; default MUST fail closed (redact when unsure).
- [NEEDS CLARIFICATION] The `ReadableLogRecord` field carrying the active span context, and confirmation the SDK populates it via log-trace correlation in the targeted version (the mapping rule itself is spec 02's).
- [NEEDS CLARIFICATION] Deterministic rendering of nested/structured OTel attribute values (arrays/maps) into `properties` string values — exact serialization format.
