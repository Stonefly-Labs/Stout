# Spec 04 — Metrics Exporter (`opentelemetry-swift` `MetricExporter` → Breeze `MetricData`)

Pass the prompt below to `/speckit.specify`.

---

## Overview / Why

`stout` is a collector-free, open-source Azure Monitor / Application Insights exporter built on the **OpenTelemetry Swift SDK (`opentelemetry-swift`)**, running cross-platform on **iOS, macOS, watchOS, tvOS (+ visionOS), and Linux** (Swift 6). It implements `opentelemetry-swift`'s public exporter protocols and translates telemetry into the Application Insights **"Breeze"** schema, POSTing it straight to ingestion — no OpenTelemetry Collector, no Azure Monitor Agent.

This feature adds the **metrics signal**: an `opentelemetry-swift` **`MetricExporter`** implementation that acts as an Azure Monitor exporter, registered with the OTel SDK's `MeterProvider` (via a `PeriodicMetricReaderBuilder` / metric reader). Once registered, any application or library that records metrics through the OTel API — counters, up-down counters, gauges, histograms — has those measurements **aggregated and periodically read by the SDK**, handed to our exporter as `MetricData`, translated to Breeze `MetricData` envelopes, and delivered to Application Insights as custom metrics. On-device instrumentations (e.g. MetricKit) and server instrumentation both flow through the same `MeterProvider`, so existing instrumentation lights up as App Insights custom metrics without the consumer touching this library's internals.

**Why this matters.** Metrics are the third telemetry signal (after traces and logs) required for parity with the .NET / Java / Node / Python Azure Monitor distributions. Consumers want operational counters, latency distributions, and gauges visible in App Insights (Metrics Explorer, custom-metric charts, dashboards) alongside their requests and dependencies — collector-free.

**What this feature is NOT:** it is not Live Metrics / real-time streaming (that is the separate QuickPulse protocol against a different endpoint — spec 06). This feature produces standard Breeze `MetricData` telemetry through the same ingestion path as every other signal.

> Locked design decisions: see design.md §11 (D1–D4, D7–D9). This spec reflects D1 (lifecycle/shutdown: the exporter goes inert on `shutdown()`), D4 (metrics semantics: delta temporality, overflow-bucket cardinality bound), D7 (cross-platform), and D8 (build on `opentelemetry-swift`'s `MetricExporter`). **Known maturity trade-off (design §3):** `opentelemetry-swift` Metrics are Beta/Development; this exporter knowingly rides that beta API.

**Aggregation & temporality now come from the OTel SDK, not from us.** Unlike a `swift-metrics` backend that reimplements aggregation, this exporter consumes already-aggregated `MetricData` produced by the SDK's `MeterProvider` (its views, aggregation, and the reader's temporality). Our job is to declare the temporality we need (**delta**, per D4) via the exporter's `getAggregationTemporality(...)` and translate the resulting sum/gauge/histogram points to Breeze — not to accumulate or reset counters ourselves.

**Foundation this builds on (spec 01, already implemented — consume, do not redefine):** the Breeze envelope framework and `baseData` model (including the `MetricData` envelope type), the connection-string parser and secret handling, resource detection (`ai.cloud.role` / `ai.cloud.roleInstance` / device / SDK-version tags applied to Part A envelope tags), the bounded drop-on-overflow telemetry pipeline / buffer, and the gzip newline-JSON transport abstraction (URLSession/async-http-client) with retry/backoff and partial-success handling. This feature emits `MetricData` telemetry items into that existing pipeline; it MUST NOT introduce a second transport, buffer, or connection-string path.

## Consumer scenarios

1. **Counter appears as a custom metric.** A consumer records to a `Counter` named `requests` (via the OTel API) as requests arrive, with an attribute `route`. The SDK's `MeterProvider` aggregates it; on the periodic read our exporter receives a `MetricData` sum point and it appears in App Insights as a custom metric named `requests` with the interval-delta value and a `route` property, charted correctly in Metrics Explorer.
2. **Histogram as a latency distribution.** A consumer records to a `Histogram` named `latency` for each request. On the periodic read our exporter receives a histogram `MetricData` point and produces a Breeze `MetricData` with the aggregated `count`, `min`, `max`, sum, and (derived) standard deviation so operators can chart average and percentiles-style summaries.
3. **Gauge as a point value.** A consumer uses a gauge (or an async observable gauge) to report current queue depth; on read, the most recent value for the interval is exported as `MetricData`.
4. **Dimensions become properties.** A `Counter("cache.ops")` is recorded with attributes `[("op","get"),("result","hit")]`; the SDK produces one point per distinct attribute set, and each is exported as a separate `MetricData` item whose `properties` carry the dimensions, so the metric is filterable/splittable in the portal.
5. **Histogram summary.** A consumer records a histogram `payload.bytes`; on read our exporter produces `MetricData` with `count`/`min`/`max`/sum/`stdDev` summarizing the interval's distribution.
6. **No-op safety when unconfigured / failing.** If the exporter cannot deliver (endpoint down, buffer full), `export(...)` returns promptly with a failure result and never throws, blocks, or crashes the host; excess telemetry is dropped, consistent with the pipeline's drop-on-overflow behavior (spec 01). Metric *recording* on the caller's thread is the SDK's fast in-memory path, unaffected.
7. **Bounded cardinality guard.** A buggy consumer emits a metric with an unbounded, high-cardinality dimension (e.g. a raw user ID or URL as an attribute value). Cardinality is bounded so that, past a per-metric cap, excess dimension combinations **fold into a single `{otel.metric.overflow = true}` series** (D4) — grand totals stay correct while the per-dimension tail breakdown is lost. This is primarily configured on the SDK's `MeterProvider` (view/cardinality limit); the exporter faithfully translates the SDK's overflow point and MUST NOT itself allocate series unboundedly. A rate-limited internal diagnostic/counter is emitted, and memory never grows without limit. [NEEDS CLARIFICATION: whether `opentelemetry-swift`'s `MeterProvider` supports a cardinality limit / overflow attribute in the targeted version, or the exporter must enforce a translation-side cap as a fallback.]
8. **Lifecycle / shutdown.** On `MeterProvider` / exporter shutdown, the SDK performs a final collection and calls the exporter's `flush()`/`shutdown()`, so a short-lived process's final interval is not lost; the exporter releases its state and goes inert.

## Functional requirements

**Exporter registration**
- Provide a `Sendable` type conforming to `opentelemetry-swift`'s **`MetricExporter`** protocol — `export(metrics: [MetricData]) -> MetricExporterResultCode`, `flush()`, `shutdown()`, and `getAggregationTemporality(for:)` — constructible from an Application Insights connection string / resolved configuration produced by spec 01's config layer, and registered with the SDK's `MeterProvider` via a periodic metric reader. [NEEDS CLARIFICATION: confirm the exact `MetricExporter` protocol signatures, `MetricData`/point-data shape (sum/gauge/histogram), result-code cases, and temporality-selector API in the targeted (Beta) `opentelemetry-swift` version.]
- The SDK owns metric creation, recording, aggregation, views, and periodic collection; this feature does NOT implement a `MetricsFactory`, per-instrument handlers, or its own aggregation math. It declares its required temporality and translates the SDK's already-aggregated `MetricData` points.

**Temporality & point-kind translation**
- **Temporality = delta (D4).** The exporter MUST select **delta** temporality via `getAggregationTemporality(...)` so each `MetricData` point represents the per-interval change, not a cumulative running total: App Insights sum-aggregates interval data, so cumulative would double-count. This MUST be documented. (Whether idle series emit a zero point is governed by the SDK's reader/aggregation config, not reimplemented here.)
- **Sum points (counter / up-down counter):** translate the point's delta value to the Breeze `MetricData` `value`.
- **Gauge points (sync/async gauge):** translate the last-value point to the Breeze `MetricData` `value`.
- **Histogram points:** translate `count`, `min`, `max`, and sum to the Breeze `MetricData` distribution fields (`value`=sum, `count`, `min`, `max`), deriving `stdDev` where the App Insights `DataPoint` expects it. [NEEDS CLARIFICATION: whether `min`/`max` and a derivable `stdDev` are reliably present on `opentelemetry-swift` histogram points, or must be omitted/approximated.]
- **Units:** carry the OTel instrument unit through; where App Insights convention differs (e.g. durations in milliseconds), document any conversion. [NEEDS CLARIFICATION: unit convention exported to App Insights and whether the metric name carries a unit suffix.]
- Points are already keyed by (metric name + attribute set) by the SDK; each maps to its own Breeze `MetricData` item.

**Periodic read (SDK-driven)**
- Collection cadence is owned by the SDK's periodic metric reader (configurable interval with a sane, documented default); on each read the SDK hands `MetricData` to `export(...)`, which translates to `MetricData` envelopes and hands them to the spec 01 pipeline. This feature does not run its own flush loop.
- `export(...)` MUST be off the host's hot path and non-blocking on network I/O. A final collection/export MUST occur on graceful shutdown (drain-and-go-inert, D1) via the SDK's `flush()`/`shutdown()` so a short-lived process's final interval is not lost, subject to best-effort/bounded shutdown timing. [NEEDS CLARIFICATION: recommended periodic-reader interval — align with App Insights custom-metric granularity — and default shutdown flush timeout.]
- The exporter MUST be an **independently-constructable, injectable object** (D1) so it can be built and unit-tested without an active `MeterProvider`; registration with the provider/reader is a thin layer over it (the testability seam). After the pipeline shuts down, the exporter MUST become a **safe no-op**: `MetricData` handed to `export(...)` post-shutdown is dropped and MUST NOT crash or block; the drop is surfaced only via spec 01's rate-limited internal-diagnostics warning (never re-emitted as telemetry, never carrying measurement/dimension payload).

**Translation → Breeze `MetricData`**
- Emit a `MetricData` `baseData` (schema/version per spec 01's envelope model) for each point (metric, attribute set) per read, carrying: metric `name`; `value`; and for histogram points `count`, `min`, `max`, and `stdDev` (the standard Breeze `DataPoint` fields).
- Map metric **dimensions/attributes → `properties`** (string key/value) on the envelope. Property values are stringified; keys collide-safely.
- Part A envelope tags (cloud role/instance, device/app tags, SDK version, `iKey`, `sampleRate`) MUST come from the shared resource-detection and envelope framework (spec 01), sourced from the point's OTel `Resource` — this feature does not re-derive them.
- Preserve the `sampleRate`/`itemCount` fields carried by the envelope model (metrics are typically not ingestion-sampled, but the model field is respected).

**Cardinality & lifecycle**
- Cardinality MUST be bounded so distinct dimension series per metric cannot grow without limit. The primary mechanism is the SDK's `MeterProvider` cardinality limit / view, which folds excess dimension combinations into a single overflow series marked `{otel.metric.overflow = true}` (D4) — preserving **correct grand totals** while sacrificing only the tail's per-dimension breakdown. The exporter MUST faithfully translate that overflow point and MUST NOT allocate translation-side series unboundedly; where the SDK does not enforce a limit in the targeted version, the exporter MUST apply a **configurable translation-side cap** as a fallback with the same overflow semantics. A **rate-limited warning** (plus an internal diagnostic counter) is emitted when the cap engages. This overflow-bucket policy is **decided (D4)**; only the **default cap value** remains a tunable [NEEDS CLARIFICATION] (see Open questions). This is an OSS-safety requirement, not optional. (Aligns with OpenTelemetry's cardinality-limit design.)
- `shutdown()` of the exporter MUST release any per-metric translation state (no leak) and MUST NOT crash if invoked while an `export(...)` is in flight.
- Total metrics memory attributable to this feature MUST be bounded overall, consistent with the constitution's bounded-memory mandate.

## Non-functional / quality requirements

These restate the binding constitution principles as explicit, testable acceptance criteria for this feature.

- **Security (NON-NEGOTIABLE):** connection strings, instrumentation keys, and tokens MUST NEVER appear in logs, error messages, thrown errors, self-diagnostics, or exported metric names/dimensions/properties. Configuration is validated and **fails closed**. HTTPS-only via the shared transport. No new runtime dependency introduced by this feature beyond those already justified in spec 01; any addition requires explicit justification.
- **Resilience / do-no-harm (NON-NEGOTIABLE):** metric recording MUST NEVER crash, block, deadlock, or measurably degrade the host — no `fatalError`, force-unwrap, `try!`, blocking I/O, or unbounded waits on caller paths. Recording is a fast, non-throwing, in-memory operation. On buffer/pipeline overflow or endpoint failure, telemetry is dropped (with an internal counter), never buffered without limit. Metrics memory is bounded (cardinality cap). Telemetry loss is always preferable to host impact.
- **Concurrency safety (NON-NEGOTIABLE):** all types build and test clean under Swift 6 strict concurrency with no suppressed data-race warnings. The exporter is correctly `Sendable`; any shared translation state is protected (actor or equivalent) with no data races; concurrent `export(...)`/`flush(...)` from the SDK's reader is safe. `@unchecked Sendable` requires reviewed justification.
- **Quality / testing:** automated tests MUST cover each point-kind's translation (sum-point delta value, histogram count/min/max/sum/stdDev, gauge last-value), delta-temporality selection, the dimension→`properties` mapping, the cardinality overflow-point translation (and any fallback translation-side cap), shutdown-flush behavior and inert-after-shutdown, secret redaction, and the drop-on-overflow failure path. CI passes on **an Apple platform (iOS simulator / macOS) and Linux** for supported Swift 6 toolchains; lint/format gates are blocking. Every public API is documented with doc comments.
- **API stewardship:** SemVer; public-vs-internal boundaries explicit (only the factory and configuration entry points are `public`, internals stay non-`public`); documented behavior for aggregation, units, flush cadence, and cardinality policy.
- **Fidelity:** the `MetricData` mapping (field placement, aggregation math, unit convention, dimension→property mapping) MUST be faithful and verified against the authoritative MIT-licensed .NET exporter behavior, covered by golden/round-trip tests.

## Acceptance criteria

- Given the `MetricExporter` registered with a `MeterProvider` from a valid connection string, when a consumer records to `Counter("requests")` with a `route` attribute, then on the periodic read a `MetricData` envelope named `requests` is produced with the delta sum as its value and a `route` property, delivered through the spec 01 pipeline.
- Given a histogram (`latency`) recording multiple durations in an interval, when the SDK reads it, then a single `MetricData` item is produced with correct `count`, `min`, `max`, and `stdDev`, in the documented unit.
- Given a histogram point, when translated, then `count`/`min`/`max`/sum/`stdDev` reflect the point's aggregated values.
- Given a gauge, when multiple values are observed in an interval, then the exported value is the last observed value for the interval.
- Given two distinct attribute sets on the same metric name, when read, then two independent `MetricData` items are produced, each carrying its own dimensions as `properties`.
- Given a metric emitting more distinct dimension series than the cap (SDK cardinality limit, or the exporter's fallback cap), when the cap is exceeded, then excess dimension combinations fold into the single `{otel.metric.overflow = true}` series (grand totals preserved, tail breakdown dropped), a rate-limited internal diagnostic counter/warning is emitted, and process memory stays bounded.
- Given the exporter declares delta temporality, when a sum point is read, then the exported value is the per-interval delta, not a cumulative running total (no double-counting under App Insights sum-aggregation).
- Given the exporter is shut down (including concurrently with an `export(...)`), then translation state is released, no leak occurs, and no crash/data race is observed; subsequent `export(...)` calls are safe no-ops.
- Given a failing or unreachable ingestion endpoint or a full pipeline buffer, when `export(...)` is called, then it returns promptly without throwing/blocking, telemetry is dropped with an internal counter, and the host is unaffected.
- Given a connection string / instrumentation key in configuration, when the library logs or self-diagnoses at any level (including errors), then no secret material appears in output, exported metric names, or dimension properties (verified by test).
- All of the above build and pass under Swift 6 strict concurrency on **an Apple platform and Linux** with lint/format gates green, and every public API is documented.

## Out of scope (sibling specs)

- **Envelope framework, `MetricData` `baseData` model, pipeline/buffer, batch processor, transport, connection-string parsing, resource detection, retry/backoff, partial-success** — spec 01 (core ingestion foundation). This feature consumes them.
- **Tracing** (`SpanExporter`, `SpanData`→Request/Dependency translation) — spec 02.
- **Logs** (`LogRecordExporter` → Message/Exception) — spec 03.
- **Metric creation, recording, aggregation, views, temporality conversion, and periodic collection** — owned by `opentelemetry-swift`'s `MeterProvider` / metric reader, not this feature. We only declare required temporality and translate `MetricData`.
- **Ingestion sampling** (fixed-rate `sampleRate`/`itemCount` sampling logic) — spec 05. This feature respects the envelope fields but does not implement sampling.
- **Live Metrics real-time streaming** — spec 06. That is the proprietary **QuickPulse** side-channel (`LiveEndpoint`, `MonitoringDataPoint`/`DocumentIngress`, ping/post state machine) — a different protocol against a different endpoint. It is explicitly **NOT** this feature; nothing here targets QuickPulse.
- Framework-specific / on-device auto-instrumentation and the distro convenience provider-setup layer — later phases.

## Open questions

- [NEEDS CLARIFICATION: exact `opentelemetry-swift` `MetricExporter` protocol signatures, `MetricData`/point-data shapes (sum/gauge/histogram), result-code cases, and temporality-selector API in the targeted (Beta) version.]
- ~~counter export semantics — delta-per-interval vs. cumulative~~ — **RESOLVED (D4):** the exporter declares **delta** temporality (App Insights sum-aggregates interval data; cumulative would double-count). See design.md §11 (D4).
- ~~idle-series emission~~ — governed by the SDK's reader/aggregation config, not reimplemented here; delta temporality (D4) already avoids double-counting.
- [NEEDS CLARIFICATION: recommended periodic-metric-reader interval and default graceful-shutdown flush timeout.]
- [NEEDS CLARIFICATION: histogram target unit exported to App Insights (milliseconds recommended) and whether the metric name carries a unit suffix; whether `min`/`max`/`stdDev` are reliably derivable from `opentelemetry-swift` histogram points.]
- Overflow policy — **RESOLVED (D4):** past a per-metric cap, excess dimension combinations **fold into a single `{otel.metric.overflow = true}` series** (correct grand totals preserved, tail per-dimension breakdown lost) with a rate-limited warning. Enforced primarily by the SDK's `MeterProvider` cardinality limit; a translation-side fallback cap applies where the SDK does not. See design.md §11 (D4). Still open: [NEEDS CLARIFICATION: whether `opentelemetry-swift`'s `MeterProvider` enforces a cardinality limit in the targeted version, and the default cap value for the fallback.]
- [NEEDS CLARIFICATION: which OTel point kinds (sync/async gauge, up-down counter, exponential histogram) the targeted `opentelemetry-swift` version emits and how each maps to a Breeze `MetricData` point.]
