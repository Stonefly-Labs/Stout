# Quickstart / Validation: Distributed Tracing Exporter

Runnable scenarios that prove the `SpanExporter` works end-to-end without a live
`TracerProvider` or network. Field/rule detail is in [data-model.md](./data-model.md) and
[contracts/](./contracts/); this is the run guide.

## Prerequisites

- Toolchain: Swift 6 (tools 6.0). Repo builds already (`swift build`).
- No Application Insights resource needed for the unit-level scenarios (mock pipeline).
- For the optional real-ingestion check: an App Insights connection string (see the
  `appinsights-local-setup` skill) and the `verify-telemetry` procedure.

## Build, test, lint (must pass — gates)

```sh
swift build
swift test --filter StoutTracingTests
swift format lint --strict --recursive Sources Tests
```

Full matrix (per constitution IV): the suite MUST also pass on the **iOS Simulator** and
**Linux**, not macOS alone.

## Scenario 1 — Server span → one RequestData (US1, SC-001/002)

1. Build a `.server` `SpanData` (via `SpanDataBuilder`) with `http.request.method = GET`,
   `http.response.status_code = 200`, `url.full = https://api/x`, known trace/span ids.
2. Construct `AzureMonitorTraceExporter(pipeline:envelopeFactory:)` over a **mock** pipeline
   (mock `Transport` + `Diagnostics`).
3. `exporter.export(spans: [span], explicitTimeout: nil)`; drain the mock.

**Expect:** exactly one envelope, `baseType = RequestData`; `id` = span id (16-hex);
`ai.operation.id` = trace id (32-hex); `name` = `"GET …"`; `duration` = end−start;
`responseCode = "200"`; `success = true`; `url` reconstructed; result `.success`.

## Scenario 2 — Client span → correlated RemoteDependencyData (US2, SC-003)

1. Build a `.client` HTTP span with `server.address = db.host`, `server.port = 443`,
   `http.response.status_code = 500`, `parentSpanId` = the Scenario-1 span id.
2. Export.

**Expect:** one `RemoteDependencyData`; `type = "HTTP"`; `target = "db.host"` (443 dropped);
`data` = full URL; `resultCode = "500"`; **`success = true`** (dependency success ignores the
HTTP code — only an error span status fails it, research.md D-03); `ai.operation.id` = the
shared trace id; `ai.operation.parentId` = the request's span id.
Repeat with a DB span (`db.system = postgresql`, `db.statement = SELECT 1`) → `type =
"postgresql"`, `target` = db server, `data = "SELECT 1"`.

## Scenario 3 — Cross-tier correlation & root span (US3, SC-002/005)

1. Caller `.client` span (span id `A`, root: no parent) and callee `.server` span (parent
   `A`), same trace id. Export both.

**Expect:** identical `ai.operation.id`; callee `ai.operation.parentId` = `A`; the **root**
caller emits **no** `ai.operation.parentId`. Verify ids byte-for-byte against the W3C hex.

## Scenario 4 — Errors & exceptions (US4, SC-004)

1. `.server` span with `status = .error`, an `exception` event (`exception.type`,
   `exception.message`, `exception.stacktrace`). Export.

**Expect:** owning `RequestData.success = false`; plus one correlated `ExceptionData`
(`typeName`/message/`stack`, `ai.operation.parentId` = span id).
2. Same span with error status but **no** event → still `success = false`, **no**
`ExceptionData` fabricated.
3. `exception` event missing `exception.message` → event **dropped** (no fabricated message).

## Scenario 5 — Non-exception event → MessageData (US5)

`.server` span with a `checkpoint` event → one correlated `MessageData` (`message =
"checkpoint"`, event attrs → `properties`, `ai.operation.parentId` = span id).

## Scenario 6 — Current-over-legacy precedence (SC-003)

Span with **both** `http.request.method` and `http.method` (and `http.response.status_code`
+ `http.status_code`). **Expect:** the current keys win deterministically; the legacy values
do not appear in mapped fields; unmapped attrs land in `properties`.

## Scenario 7 — Lifecycle: flush then inert (US6, SC-009)

1. Export spans, `await exporter.flush(explicitTimeout: nil)` → items forwarded to the
   pipeline promptly (assert mock received them), returns `.success`.
2. `await pipeline.shutdown()`; then `exporter.export(...)` again → items **dropped**, no
   crash/block, **no** telemetry emitted; the mock `Diagnostics` records exactly one
   `postShutdownSubmit` warning.

## Scenario 8 — Concurrency & purity (SC-010, FR-028)

- Fire `export(...)` from many concurrent tasks → no data-race warnings (Swift 6 strict
  concurrency), all items accounted for.
- Translate the same `SpanData` twice → byte-identical envelopes (deterministic).

## Optional — real ingestion (proves data lands)

Follow the `verify-telemetry` skill: send a span through the exporter to a real App Insights
resource, then query `requests`, `dependencies`, `traces`, `exceptions` via KQL and confirm
one linked transaction (request + nested dependency) appears with the expected `success`,
`resultCode`, and operation ids. **No secret is ever logged** during this check (SC-008).
