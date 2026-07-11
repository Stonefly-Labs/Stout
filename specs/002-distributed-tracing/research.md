# Research: Distributed Tracing Exporter

Phase 0. Resolves the spec's implementation-binding unknowns and verifies every
.NET-parity claim against the authoritative MIT-licensed reference
(`Azure/azure-sdk-for-net`, `sdk/monitor/Azure.Monitor.OpenTelemetry.Exporter/src/`,
`main`). Findings sourced by the `dotnet-reference-scout` agent with file/line citations.

Ported **logic** (not code — different language) is attributed here per Principle VII;
file headers carry Apache-2.0.

---

## D-01 — SDK shape binding (`opentelemetry-swift-core` 2.5.1)

**Decision.** Confirmed against the pinned checkout:

- `SpanExporter` is `AnyObject, Sendable` with **six** members (sync + async
  `export`/`flush`/`shutdown`, all `explicitTimeout: TimeInterval?`). Async forms have
  default impls that `assertionFailure` — the exporter **must** implement all six.
- `SpanExporterResultCode` = `.success | .failure`.
- `SpanData` exposes `traceId: TraceId`, `spanId: SpanId`, `parentSpanId: SpanId?` (nil ⇒
  root), `name`, `kind: SpanKind`, `startTime`/`endTime: Date`, `attributes:
  [String: AttributeValue]`, `status: Status`, `events: [SpanData.Event]`, `links:
  [SpanData.Link]`, `resource: Resource`. `TraceId.hexString` = 32-hex, `SpanId.hexString` =
  16-hex, `SpanId.isValid` distinguishes an absent parent.
- `SpanKind` = `.internal/.server/.client/.producer/.consumer` (string enum). `Status` =
  `.ok/.unset/.error(description:)`. `AttributeValue` = `.string/.bool/.int/.double/
  .array/.set` (+ deprecated `*Array`).

**Rationale.** These are the exact types the exporter conforms to and consumes; pinning them
removes the spec's "confirmed during plan resolution" markers. **Alternatives:** none — the
package is already pinned in `Package.resolved`.

---

## D-02 — Span kind → envelope type (FR-006) — **matches .NET**

**Decision.** `.server`/`.consumer` → `RequestData`; `.client`/`.producer`/`.internal` and
**absent/unspecified** → `RemoteDependencyData`.

**Rationale.** `Internals/ActivityExtensions.cs` `GetTelemetryType()` maps Server/Consumer →
Request, Client/Producer → Dependency, and `_ =>` (Internal + any default) → Dependency.
Full parity. **Alternatives:** treating `.internal` as a Request — rejected (contradicts .NET
and the transaction model).

---

## D-03 — Success predicate & responseCode/resultCode (FR-011/012) — **RECONCILED to actual .NET**

> **Reconciliation (maintainer-confirmed 2026-07-10).** The spec's FR-011/012 claimed
> ".NET-parity" but stated thresholds that diverge from the reference. The reference was
> verified and the maintainer chose **actual .NET behavior**. The spec's FR-011/012 wording
> is updated to match; this section is authoritative for the golden tests.

**Decision.**

- **Any `status == .error(...)` ⇒ `success = false`**, unconditionally (both item types).
- **`RequestData` (server/consumer):** with **unset** status and an HTTP span, `success =
  (code != 0 && code < 400)` — i.e. **4xx and 5xx both fail**. Non-HTTP or non-unset falls
  through to `status != .error`.
- **`RemoteDependencyData` (client/producer/internal):** `success = (status != .error)`
  **only** — there is **no** HTTP/gRPC status-code threshold. A dependency HTTP 4xx/5xx with
  unset status is a **success**.
- **responseCode/resultCode:** the HTTP (`http.response.status_code` / legacy
  `http.status_code`) or gRPC (`rpc.grpc.status_code`) status string; when none, default
  `"0"` (never omitted where the schema requires it).

**Rationale.** `Customizations/Models/RequestData.cs` `IsSuccess()` (lines 86–100): `return
statusCode != 0 && statusCode < 400` for unset-status HTTP, else `Status != Error`.
`Customizations/Models/RemoteDependencyData.cs` line 84: `Success = activity.Status !=
ActivityStatusCode.Error` — no code logic. Fidelity (Principle VI) requires matching the
reference behavior, not a paraphrase of it.

**Alternatives considered.** *Spec-as-written* (server ≥500, dependency client ≥400,
gRPC non-OK): rejected by the maintainer — it is neither the .NET request rule nor the .NET
dependency rule, so it would make "success" disagree with both App Insights' own exporter and
a co-reporting .NET service.

**Follow-up.** spec.md FR-011/012 and the Session-2026-07-10 clarification bullet are updated
to this rule (done in this plan).

---

## D-04 — RemoteDependencyData type / target / data (FR-013/014/015) — **mostly .NET, one deliberate enrichment**

**Decision (per protocol).**

- **HTTP:** `type = "HTTP"`; `target` = `server.address[:server.port]` (V2) / peer.service →
  http.host → URL authority → `net.peer.name[:port]` (legacy), default ports 80/443 dropped;
  `data` = `url.full` (V2) / `http.url` (legacy); `resultCode` = HTTP status.
- **DB:** `type` = the `db.system` value, except `mssql`/`microsoft.sql_server` → `"SQL"`;
  `target` = server/peer (default ports mssql 1433, redis 6379), and when a db name is
  present `target = "{host} | {dbName}"`; `data` = `db.query.text` (V2) / `db.statement`
  (legacy). `db.namespace`/`db.name` also copied to `properties`.
- **Messaging (producer):** `type` = `messaging.system`; host = `server.address` ??
  `net.peer.name`; `target = "{host}/{messaging.destination.name}"`; `data =
  "{network.protocol.name}://{host}/{destination}"`.
- **Internal:** `type = "InProc"` (or `"InProc | {az.namespace}"` when the Azure-SDK
  `az.namespace` attribute is present); `target` from `server.address[:port]` if any.

**gRPC/RPC — deliberate divergence (enrichment).** The .NET exporter has **no** dedicated
RPC mapping (`OperationType.Rpc` is defined but never assigned; RPC falls through the default
dependency branch — `type` empty unless `az.namespace`/Internal). The spec (FR-013/016)
**requires** gRPC `type`/`target`/`data`/status handling, so Stout intentionally goes beyond
.NET here: `type = "GRPC"`, `target = server.address[:port]` (or `rpc.service`), `data =
rpc.service/rpc.method`, `resultCode = rpc.grpc.status_code`. Documented as an accepted
enrichment, not a parity claim.

**Rationale/sources.** `RemoteDependencyData.cs` (26–167), `AzMonListExtensions.cs`
(db/legacy-target), `AzMonNewListExtensions.cs` (V2 url/target + messaging),
`TraceHelper.cs` (Azure-SDK dependency type). **Alternatives:** mirror .NET's RPC gap exactly
(leave gRPC type empty) — rejected; the spec explicitly asks for gRPC fidelity and empty type
degrades the dependency view.

---

## D-05 — RequestData name / url / source (FR-008/010)

**Decision.**

- **name / `ai.operation.name`:** `"{http.request.method} {http.route}"`, falling back to
  `"{method} {url.path}"`, else the span `name` (`DisplayName`). Legacy uses `http.method`/
  `http.route`/`http.url` path. `ai.operation.name` is set for requests (drives transaction
  search).
- **url:** `url.full` (V2) / `http.url` (legacy), else reconstruct from scheme + host + target
  (`url.scheme`+`server.address`+`url.path` / `http.scheme`+`http.host`+`http.target`).
- **source (FR-008):** populated **only** for messaging/consumer requests — the messaging
  `host[/destination]` from `GetMessagingUrlAndSourceOrTarget`; otherwise **empty**. There is
  no generic correlation-context origin beyond messaging (plus the `microsoft.request.source`
  override). This matches the spec's FR-008 clarification.

**Rationale/sources.** `RequestData.cs` (name/url/source), `TelemetryItem.cs`
`GetOperationName(V2)`, `AzMonListExtensions.GetRequestUrl`. **Alternatives:** inventing a
`source` from `client.address`/peer for non-messaging spans — rejected (not what .NET does;
would fabricate correlation).

---

## D-06 — Part A correlation ids (FR-007/024) — **matches .NET**

**Decision.**

- `ai.operation.id` = `traceId.hexString` (32-hex lowercase) — **always**.
- item `id` (`RequestData.id`/`RemoteDependencyData.id`) = `spanId.hexString` (16-hex).
- `ai.operation.parentId` = `parentSpanId.hexString`, **omitted when the span is root**
  (`parentSpanId == nil` / not valid).
- Child items (Exception/Message from events): `ai.operation.id` copied from the owning span;
  `ai.operation.parentId` = the **span's** id; timestamp = the event timestamp.

Implemented in `CorrelationMapping` operating on `TraceId`/`SpanId`/`SpanId?` (not
`SpanData`), so spec 03's `LogRecordExporter` imports the identical rule (FR-024, SC-007).

**Rationale/sources.** `TelemetryItem.cs` Activity ctor (25–30): parentId set only when
`ParentSpanId != default`; `ToHexString()` lowercase, no `0x`. **Alternatives:** a
trace-only helper embedded in the translator — rejected; FR-024 requires a reusable rule.

---

## D-07 — Current vs legacy semantic-convention precedence (FR-016/017/018)

**Decision.** Support both key generations; **prefer the current key explicitly** when both
are present. Route by which method/db-system key exists; read the matching generation's keys;
carry everything unconsumed into `properties`.

**Rationale + caveat.** `ActivityTagsProcessor.CategorizeTags` selects a single
`activityType` (V2 vs legacy) and reads only that generation's keys. **Caveat surfaced by the
scout:** .NET's "winner" is actually **tag-enumeration-order dependent** (last assignment
wins), not guaranteed current-wins. Stout deliberately makes this **deterministic** — when
both `http.request.method` and `http.method` (or `db.system.name`/`db.system`) are present,
the **current** key wins, regardless of ordering. This satisfies FR-018 and the purity
requirement (FR-028) that identical input yield identical output. **Alternatives:** replicate
.NET's order-dependence — rejected (non-deterministic; violates FR-028).

Key equivalence table lives in [data-model.md §5](./data-model.md).

---

## D-08 — Span events → Exception / Message (FR-019/020/021) — **matches .NET**

**Decision.**

- Event named `exception` → `ExceptionData`: `typeName` ← `exception.type`, message ←
  `exception.message`, `stack` ← `exception.stacktrace` when present (`hasFullStack` set
  accordingly); remaining event attributes → `properties`. **Emit only when both
  `exception.type` and `exception.message` are present; otherwise drop the event (do not
  fabricate)** — matching .NET.
- Any other event → `MessageData`: `message` = event `name`; event attributes → `properties`
  (array values comma-joined).
- An **error span status forces `success = false`** on the owning Request/Dependency
  independent of any `exception` event (FR-021); no `ExceptionData` is fabricated from status
  alone.

**Rationale/sources.** `TraceHelper.AddTelemetryFromActivityEvents` (245–279),
`GetExceptionDataDetailsOnTelemetryItem` (309–364) — returns null (drops) when `type` is null
or `message` empty. **Note:** this refines data-model.md §1c ("static placeholder message")
→ **drop instead of placeholder** to match .NET. **Alternatives:** always emit with a
placeholder message — rejected (fabricates telemetry; diverges from reference).

---

## D-09 — Resource Part A tags (FR-009)

**Decision.** Consume spec 01's `ResourceDetector.detect(resource:)` on `SpanData.resource`;
do not recompute. It already mirrors `ResourceExtensions.CreateAzureMonitorResource`
(`ai.cloud.role` = `"[namespace]/name"` else `name`; `roleInstance` =
`service.instance.id` ?? `host.name`; `ai.internal.sdkVersion` = `stout:<version>`;
`ai.device.*`/`ai.application.ver` on-device). **Rationale/source:** `ResourceExtensions.cs`;
spec 01 `ResourceDetector.swift`. **Alternatives:** re-derive in the tracing module —
rejected (FR-009 forbids; duplicates spec 01).

---

## D-10 — Exporter object model & concurrency (FR-005/027)

**Decision.** `AzureMonitorTraceExporter` is a **`final class` (SpanExporter requires
`AnyObject`)**, `Sendable`, holding an injected `ExportPipeline` (actor) + `EnvelopeFactory`
(immutable `Sendable` value) — no other mutable state, so concurrent `export(...)` is safe.
`export` translates then `pipeline.submit(_:)` (non-blocking actor hop); `flush` awaits
`pipeline.flushNow()`; lifecycle/inertness is spec 01's `pipeline.shutdown()` (drain-and-go-
inert, D1). Translation lives in pure, stateless, `Sendable` free functions/tables.

**Rationale.** Satisfies FR-004 (non-blocking), FR-005 (independently constructable + inert
post-shutdown), FR-027 (Sendable-clean), FR-028 (pure mapping). **Alternatives:** an actor
exporter — rejected; the SDK calls the sync `export` on its `BatchSpanProcessor` thread and
an actor would force awaits/ordering the protocol doesn't want; a class holding an actor
pipeline is both `Sendable` and non-blocking.

---

## Open items / forward concerns

- **`ExceptionData`/`MessageData` sharing with spec 03 (Logs):** identical shapes. Kept in
  `StoutTracing` for spec 02; promotion to a shared location is a spec-03 decision — **not**
  pre-built here.
- **gRPC enrichment beyond .NET (D-04):** flagged as an accepted, documented divergence.
- **`itemCount`/`sampleRate` (FR-023):** attached (default `sampleRate = 100`); the sampling
  *decision* is spec 05.

No remaining `[NEEDS CLARIFICATION]` markers.
