# Spec 04 — Metrics Exporter (`swift-metrics` → Breeze `MetricData`)

Pass the prompt below to `/speckit.specify`.

---

## Overview / Why

`stout` is a collector-free, open-source Azure Monitor / Application Insights exporter for server-side Swift (Linux + macOS, Swift 6). It implements the Swift Server Working Group (SSWG) observability facades directly and translates telemetry into the Application Insights **"Breeze"** schema, POSTing it straight to ingestion — no OpenTelemetry Collector, no Azure Monitor Agent.

This feature adds the **metrics signal**: a `swift-metrics` `MetricsFactory` implementation that acts as an Azure Monitor backend, bootstrapped through `MetricsSystem.bootstrap(_:)`. Once bootstrapped, any application or library that emits metrics through the `swift-metrics` facade — `Counter`, `FloatingPointCounter`, `Recorder`, `Timer`, `Gauge`/`Meter` — has those measurements aggregated, periodically flushed, translated to Breeze `MetricData` envelopes, and delivered to Application Insights as custom metrics. Because `swift-metrics` is the standard facade used by Vapor, Hummingbird, gRPC-swift, and the wider ecosystem, existing instrumentation lights up as App Insights custom metrics without the consumer touching this library's internals.

**Why this matters.** Metrics are the third telemetry signal (after traces and logs) required for parity with the .NET / Java / Node / Python Azure Monitor distributions. Consumers want operational counters, latency distributions, and gauges visible in App Insights (Metrics Explorer, custom-metric charts, dashboards) alongside their requests and dependencies — collector-free.

**What this feature is NOT:** it is not Live Metrics / real-time streaming (that is the separate QuickPulse protocol against a different endpoint — spec 06). This feature produces standard Breeze `MetricData` telemetry through the same ingestion path as every other signal.

> Locked design decisions: see design.md §11 (D1–D4). This spec reflects D1 (lifecycle/shutdown: the factory/handlers go inert on shutdown) and D4 (metrics semantics: delta export, idle-counter suppression, overflow-bucket cardinality bound).

**Foundation this builds on (spec 01, already implemented — consume, do not redefine):** the Breeze envelope framework and `baseData` model (including the `MetricData` envelope type), the connection-string parser and secret handling, resource detection (`ai.cloud.role` / `ai.cloud.roleInstance` / SDK-version tag applied to Part A envelope tags), the bounded drop-on-overflow telemetry pipeline / buffer, the batch processor, and the gzip newline-JSON transport with retry/backoff and partial-success handling. This feature emits `MetricData` telemetry items into that existing pipeline; it MUST NOT introduce a second transport, buffer, or connection-string path.

## Consumer scenarios

1. **Counter appears as a custom metric.** A service creates `Counter("requests")` (via `Metrics.Counter`, backed by our factory) and increments it as requests arrive, with a dimension `route`. Within one flush interval, the total appears in App Insights as a custom metric named `requests` with the summed value and a `route` property, and it is charted correctly in Metrics Explorer.
2. **Timer as a latency distribution.** A service records `Timer("latency")` for each request. On flush, the metric `latency` appears with the aggregated `count`, `min`, `max`, and standard deviation (and value = sum or mean per the defined aggregation semantics) so operators can chart average and percentiles-style summaries.
3. **Gauge / Meter as a point value.** A service uses a `Gauge` (or `Meter`) to report current queue depth; on flush, the most recent value for the interval is exported as `MetricData`.
4. **Dimensions become properties.** A `Counter("cache.ops")` is created with labels/dimensions `[("op","get"),("result","hit")]`; each distinct label set is exported as a separate `MetricData` item whose `properties` carry the dimensions, so the metric is filterable/splittable by those dimensions in the portal.
5. **Recorder histogram summary.** A service uses an aggregating `Recorder("payload.bytes")`; on flush it produces `MetricData` with `count`/`min`/`max`/`stdDev` summarizing the values recorded during the interval.
6. **No-op safety when unconfigured / failing.** If the metrics backend cannot deliver (endpoint down, buffer full), metric recording on the caller's thread still returns immediately and never throws, blocks, or crashes; excess telemetry is dropped, consistent with the pipeline's drop-on-overflow behavior (spec 01).
7. **Bounded cardinality guard.** A buggy consumer emits a `Counter` with an unbounded, high-cardinality dimension (e.g. a raw user ID or request URL as a label value). The library enforces a bounded number of tracked dimension series per metric; past a configurable per-metric cap, excess dimension combinations **fold into a single `{otel.metric.overflow = true}` series** (D4) so grand totals stay correct while the per-dimension tail breakdown is lost. It emits a rate-limited internal diagnostic/counter, and never grows memory without limit.
8. **Lifecycle / destroy.** When a consumer destroys a handler (`MetricsSystem` handler `destroy`), the library flushes or discards that handler's pending aggregate per defined semantics and releases its state, so metric handlers created and destroyed over the app's lifetime do not leak memory.

## Functional requirements

**Bootstrap & factory**
- Provide a `Sendable` type conforming to `swift-metrics`'s `MetricsFactory`, constructible from an Application Insights connection string / resolved configuration produced by spec 01's config layer, and installable via `MetricsSystem.bootstrap(_:)`.
- Implement the full `MetricsFactory` surface: `makeCounter`, `makeFloatingPointCounter` (if present in the targeted `swift-metrics` version — otherwise route floating-point counters through the counter path per facade semantics), `makeRecorder` (honoring the `aggregate` flag for aggregating vs. non-aggregating recorders), `makeTimer`, and `makeMeter`/`makeGauge` as exposed by the targeted `swift-metrics` version; and the corresponding `destroy*` calls. [NEEDS CLARIFICATION: exact minimum supported `swift-metrics` version and which of `Meter`/`Gauge`/`FloatingPointCounter` are present in it — the facade surface has evolved across versions]

**Handler kinds & aggregation semantics**
- **Counter / FloatingPointCounter:** monotonic additive. Per label set, accumulate increments during the flush interval and export the **per-interval delta** as the `MetricData` value, resetting the accumulator each flush. Delta (not a cumulative running total) is **decided (D4)**: App Insights sum-aggregates interval data, so a cumulative value would double-count. This MUST be documented.
- **Idle counters:** by default a counter (or any interval aggregate) that was **not touched during the interval emits nothing** — no `MetricData` data point is produced when the value is unchanged (D4). This MUST be **configurable to emit zeros** for consumers who want a continuous series. This MUST be documented.
- **Recorder (aggregating, `aggregate == true`):** accumulate the values recorded during the interval and export summary statistics — `count`, `min`, `max`, sum, and standard deviation — mapped to Breeze `MetricData` (`value`, `count`, `min`, `max`, `stdDev`).
- **Recorder (non-aggregating, `aggregate == false`):** export each recorded value as an individual `MetricData` point (count = 1) rather than a summary. [NEEDS CLARIFICATION: whether non-aggregating recorders should emit one envelope per value or a bounded batch, given cardinality/volume concerns]
- **Timer:** treat as an aggregating distribution of durations; export `count`/`min`/`max`/sum/`stdDev`. Timers report nanoseconds via the facade — define and document the unit exported to App Insights (recommended: milliseconds, the App Insights convention) and the conversion. [NEEDS CLARIFICATION: target unit and whether the metric name should carry a unit suffix]
- **Gauge / Meter:** last-value (point-in-time) semantics; export the most recent value observed in the interval. Support the additive/`increment`/`decrement` Meter operations per facade semantics where applicable.
- Aggregation state MUST be keyed by (metric name + label set) so distinct dimension combinations aggregate independently.

**Periodic flush**
- Aggregate in memory and flush on a **periodic cadence** (configurable interval, with a sane, documented default). On each flush, snapshot-and-reset interval aggregates, translate to `MetricData` envelopes, and hand them to the spec 01 pipeline.
- Flush MUST be off the caller's thread (recording never triggers synchronous export). A flush MUST also occur on graceful shutdown (drain-and-go-inert, D1) so a short-lived process's final interval is not lost, subject to best-effort/bounded shutdown timing. [NEEDS CLARIFICATION: default flush interval value — align with App Insights custom-metric granularity, and default shutdown flush timeout]
- The factory MUST be an **independently-constructable, injectable object** (D1); the `MetricsSystem.bootstrap(_:)` registration is a thin layer over it (the testability seam). After the pipeline shuts down, the installed — and un-removable — factory/handlers MUST become **safe no-ops**: metrics recorded post-shutdown are dropped and MUST NOT crash or block the caller; the drop is surfaced only via spec 01's rate-limited internal-diagnostics warning (never re-emitted as telemetry, never carrying measurement/dimension payload).

**Translation → Breeze `MetricData`**
- Emit a `MetricData` `baseData` (schema/version per spec 01's envelope model) for each (metric, label set) per flush, carrying: metric `name`; `value`; and for aggregated/distribution metrics `count`, `min`, `max`, and `stdDev` (the standard Breeze `DataPoint` fields).
- Map metric **dimensions/labels → `properties`** (string key/value) on the envelope. Property values are stringified; keys collide-safely.
- Part A envelope tags (cloud role/instance, SDK version, `iKey`, `sampleRate`) MUST come from the shared resource-detection and envelope framework (spec 01) — this feature does not re-derive them.
- Preserve the `sampleRate`/`itemCount` fields carried by the envelope model (metrics are typically not ingestion-sampled, but the model field is respected).

**Cardinality & lifecycle**
- Enforce a **bounded** maximum number of distinct dimension series tracked per metric. Once the per-metric cap is reached, excess (new) dimension combinations MUST **fold into a single overflow series** marked `{otel.metric.overflow = true}` (D4) — never allocate new series unboundedly. The overflow bucket preserves **correct grand totals** while sacrificing only the tail's per-dimension breakdown, and a **rate-limited warning** is emitted via the library's internal diagnostics channel (plus an internal diagnostic counter). This overflow-bucket policy is **decided (D4)**; only the **default cap value** remains a tunable [NEEDS CLARIFICATION] (see Open questions). The cap MUST be configurable. This is an OSS-safety requirement, not optional. (Aligns with OpenTelemetry's cardinality-limit design.)
- `destroy` of a handler MUST release that handler's aggregation state (no leak across create/destroy churn) and MUST NOT crash if the handler is destroyed while a flush is in flight.
- Total metrics memory MUST be bounded overall (series-per-metric cap × tracked metrics), consistent with the constitution's bounded-memory mandate.

## Non-functional / quality requirements

These restate the binding constitution principles as explicit, testable acceptance criteria for this feature.

- **Security (NON-NEGOTIABLE):** connection strings, instrumentation keys, and tokens MUST NEVER appear in logs, error messages, thrown errors, self-diagnostics, or exported metric names/dimensions/properties. Configuration is validated and **fails closed**. HTTPS-only via the shared transport. No new runtime dependency introduced by this feature beyond those already justified in spec 01; any addition requires explicit justification.
- **Resilience / do-no-harm (NON-NEGOTIABLE):** metric recording MUST NEVER crash, block, deadlock, or measurably degrade the host — no `fatalError`, force-unwrap, `try!`, blocking I/O, or unbounded waits on caller paths. Recording is a fast, non-throwing, in-memory operation. On buffer/pipeline overflow or endpoint failure, telemetry is dropped (with an internal counter), never buffered without limit. Metrics memory is bounded (cardinality cap). Telemetry loss is always preferable to host impact.
- **Concurrency safety (NON-NEGOTIABLE):** all types build and test clean under Swift 6 strict concurrency with no suppressed data-race warnings. The factory and all handlers are correctly `Sendable`; shared aggregation state is protected (actor or equivalent) with no data races; concurrent increments/records from many tasks aggregate correctly. `@unchecked Sendable` requires reviewed justification.
- **Quality / testing:** automated tests MUST cover each handler kind's aggregation math (counter sum/delta, recorder & timer count/min/max/stdDev, gauge last-value), the dimension→`properties` mapping, the cardinality-cap overflow path, destroy/lifecycle (no leak), the periodic-flush + shutdown-flush behavior, secret redaction, and the drop-on-overflow failure path. CI passes on Linux and macOS for supported Swift 6 toolchains; lint/format gates are blocking. Every public API is documented with doc comments.
- **API stewardship:** SemVer; public-vs-internal boundaries explicit (only the factory and configuration entry points are `public`, internals stay non-`public`); documented behavior for aggregation, units, flush cadence, and cardinality policy.
- **Fidelity:** the `MetricData` mapping (field placement, aggregation math, unit convention, dimension→property mapping) MUST be faithful and verified against the authoritative MIT-licensed .NET exporter behavior, covered by golden/round-trip tests.

## Acceptance criteria

- Given `MetricsSystem.bootstrap(_:)` with our factory configured from a valid connection string, when a consumer creates and increments `Counter("requests")` with a `route` dimension, then within one flush interval a `MetricData` envelope named `requests` is produced with the interval sum as its value and a `route` property, delivered through the spec 01 pipeline.
- Given a `Timer("latency")` recording multiple durations in an interval, when the interval flushes, then a single `MetricData` item is produced with correct `count`, `min`, `max`, and `stdDev`, and durations expressed in the documented unit (converted from the facade's nanoseconds).
- Given an aggregating `Recorder`, when values are recorded and flushed, then `count`/`min`/`max`/`stdDev` reflect the recorded values; given a non-aggregating recorder, then values are emitted per the defined non-aggregating semantics.
- Given a `Gauge`/`Meter`, when multiple values are set in an interval, then the exported value is the last observed value for the interval.
- Given two distinct label sets on the same metric name, when flushed, then two independent `MetricData` items are produced, each carrying its own dimensions as `properties`.
- Given a metric emitting more distinct dimension series than the configured cap, when the cap is exceeded, then excess dimension combinations fold into the single `{otel.metric.overflow = true}` series (grand totals preserved, tail breakdown dropped), a rate-limited internal diagnostic counter/warning is emitted, and process memory stays bounded.
- Given a counter/aggregate not touched during a flush interval, when the interval flushes, then by default no `MetricData` data point is produced for it; when zero-emission is configured, a zero-valued point is produced instead.
- Given a counter incremented during an interval, when the interval flushes, then the exported value is the per-interval delta and the accumulator resets for the next interval (no cumulative running total).
- Given a handler is destroyed, when destroy is invoked (including concurrently with a flush), then its aggregation state is released, no leak occurs, and no crash/data race is observed.
- Given a failing or unreachable ingestion endpoint or a full pipeline buffer, when metrics are recorded, then recording returns immediately without throwing/blocking, telemetry is dropped with an internal counter, and the host is unaffected.
- Given a connection string / instrumentation key in configuration, when the library logs or self-diagnoses at any level (including errors), then no secret material appears in output, exported metric names, or dimension properties (verified by test).
- All of the above build and pass under Swift 6 strict concurrency on both Linux and macOS with lint/format gates green, and every public API is documented.

## Out of scope (sibling specs)

- **Envelope framework, `MetricData` `baseData` model, pipeline/buffer, batch processor, transport, connection-string parsing, resource detection, retry/backoff, partial-success** — spec 01 (core ingestion foundation). This feature consumes them.
- **Tracing** (`Tracer`, span→Request/Dependency translation, W3C propagation) — spec 02.
- **Logs** (`LogHandler` → Message/Exception) — spec 03.
- **Ingestion sampling** (fixed-rate `sampleRate`/`itemCount` sampling logic) — spec 05. This feature respects the envelope fields but does not implement sampling.
- **Live Metrics real-time streaming** — spec 06. That is the proprietary **QuickPulse** side-channel (`LiveEndpoint`, `MonitoringDataPoint`/`DocumentIngress`, ping/post state machine) — a different protocol against a different endpoint. It is explicitly **NOT** this feature; nothing here targets QuickPulse.
- Framework-specific auto-instrumentation and the distro convenience bootstrap layer — later phases.

## Open questions

- [NEEDS CLARIFICATION: minimum supported `swift-metrics` version, and which handler kinds — `Meter`, `Gauge`, `FloatingPointCounter` — exist in it and must be implemented directly vs. bridged.]
- ~~counter export semantics — delta-per-interval vs. cumulative~~ — **RESOLVED (D4):** export the **per-interval delta**, resetting each flush (App Insights sum-aggregates interval data; cumulative would double-count). See design.md §11 (D4).
- ~~idle-counter emission~~ — **RESOLVED (D4):** idle counters (unchanged during an interval) **emit nothing by default**; configurable to emit zeros. See design.md §11 (D4).
- [NEEDS CLARIFICATION: default periodic flush interval, and default graceful-shutdown flush timeout.]
- [NEEDS CLARIFICATION: Timer/duration target unit exported to App Insights (milliseconds recommended) and whether the metric name carries a unit suffix.]
- [NEEDS CLARIFICATION: non-aggregating `Recorder` export shape — one `MetricData` per value vs. bounded batching, given volume/cardinality.]
- Overflow policy — **RESOLVED (D4):** past a configurable per-metric cap, excess dimension combinations **fold into a single `{otel.metric.overflow = true}` series** (correct grand totals preserved, tail per-dimension breakdown lost) with a rate-limited warning; the cap is configurable. See design.md §11 (D4). The **default cap value** remains open: [NEEDS CLARIFICATION: default per-metric dimension-series cardinality cap value].
- [NEEDS CLARIFICATION: mapping of `Gauge`/`Meter` additive operations (`increment`/`decrement`) to last-value vs. accumulating semantics for the targeted facade version.]
