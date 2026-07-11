# Data Model: Distributed Tracing Exporter

Entities are the four Breeze `baseData` payloads this feature adds, the correlation tag
set, and the deterministic mapping tables. Everything is consumed by spec 01's
`EnvelopeFactory` → `Envelope` → `ExportPipeline`; nothing from spec 01 is redefined.

## 0. Input — `SpanData` (from `opentelemetry-swift-core` 2.5.1, consumed, never mutated)

Fields used by this feature (confirmed against the pinned SDK):

| `SpanData` field | Type | Used for |
|---|---|---|
| `traceId` | `TraceId` (`.hexString` → 32-hex) | `ai.operation.id` |
| `spanId` | `SpanId` (`.hexString` → 16-hex) | item `id`; children's `parentId` |
| `parentSpanId` | `SpanId?` (nil ⇒ root) | `ai.operation.parentId` (absent for root) |
| `name` | `String` | item `name` / `ai.operation.name` |
| `kind` | `SpanKind` (`.server/.client/.producer/.consumer/.internal`) | envelope-type table |
| `startTime` / `endTime` | `Date` | envelope `time` = `startTime`; `duration` = `endTime − startTime` |
| `attributes` | `[String: AttributeValue]` | field mapping + `properties` |
| `status` | `Status` (`.ok/.unset/.error(description:)`) | `success` predicate |
| `events` | `[SpanData.Event]` (`name`, `timestamp`, `attributes`) | Exception/Message items |
| `links` | `[SpanData.Link]` (`context`, `attributes`) | `properties` (FR-022) |
| `resource` | `Resource` | resource Part A tags via spec 01 `ResourceDetector` (FR-009) |

`AttributeValue` cases handled: `.string`, `.bool`, `.int`, `.double`, `.array`, `.set`
(and deprecated `*Array`). Non-string values are stringified for `properties`/fields.

## 1. Breeze payload types (new `BaseData` conformers in `StoutTracing`)

All conform to spec 01's `public protocol BaseData: Sendable, Encodable` and encode
`"ver": 2` as their first field. Field names below are the Breeze wire names.

### 1a. `RequestData` — `baseType = "RequestData"`, name `Microsoft.ApplicationInsights.Request`

| Field | Type | Source (FR) |
|---|---|---|
| `ver` | Int = 2 | schema |
| `id` | String | span id (16-hex) — FR-010 |
| `name` | String | route/method-derived HTTP name, else span name — FR-010 |
| `duration` | String `d.hh:mm:ss.fffffff` | `endTime − startTime` — FR-010 |
| `responseCode` | String | `http.response.status_code` / `rpc.grpc.status_code`, else `"0"` — FR-010 |
| `success` | Bool | success predicate (server-side) — FR-011 |
| `url` | String? | reconstructed from HTTP attributes — FR-010 |
| `source` | String? | messaging/correlation originating identity, else empty — FR-008 |
| `properties` | `[String: String]` | unmapped attributes + links — FR-010/022 |

### 1b. `RemoteDependencyData` — `baseType = "RemoteDependencyData"`, name `…Insights.RemoteDependency`

| Field | Type | Source (FR) |
|---|---|---|
| `ver` | Int = 2 | schema |
| `id` | String | span id (16-hex) — FR-012 |
| `name` | String | span name — FR-012 |
| `duration` | String | `endTime − startTime` — FR-012 |
| `resultCode` | String | HTTP/gRPC/DB status, else `"0"` — FR-012 |
| `success` | Bool | success predicate (client-side) — FR-012 |
| `type` | String | `HTTP` / `db.system`\|`SQL` (mssql) / messaging system / `GRPC` (enrichment, D-04) / `InProc` — FR-013 |
| `target` | String? | host[:port] / db-server / messaging destination — FR-014 |
| `data` | String? | full URL / `db.statement` / destination — FR-015 |
| `properties` | `[String: String]` | unmapped attributes + links — FR-012/022 |

### 1c. `ExceptionData` — `baseType = "ExceptionData"`, name `…Insights.Exception`

From an `exception` span event (FR-019). One `ExceptionDetails` entry:

| Field | Type | Source |
|---|---|---|
| `ver` | Int = 2 | schema |
| `exceptions[].typeName` | String | `exception.type` |
| `exceptions[].message` | String | `exception.message` |
| `exceptions[].hasFullStack` | Bool | `exception.stacktrace` present |
| `exceptions[].stack` | String? | `exception.stacktrace` when present |
| `properties` | `[String: String]` | remaining event attributes |

> **Drop rule (matches .NET, research.md D-08):** emit `ExceptionData` only when **both**
> `exception.type` and `exception.message` are present; otherwise drop the event — never
> fabricate a placeholder.

### 1d. `MessageData` — `baseType = "MessageData"`, name `…Insights.Message`

From a non-`exception` span event (FR-020):

| Field | Type | Source |
|---|---|---|
| `ver` | Int = 2 | schema |
| `message` | String | event `name` (or a `message` attribute) |
| `properties` | `[String: String]` | event attributes |

> **Forward concern (not built here):** `ExceptionData`/`MessageData` are identical in shape
> to what spec 03 (Logs) needs. They live in `StoutTracing` for spec 02; promotion to a
> shared location is a spec-03 decision. This feature does not pre-build sharing.

## 2. Correlation tag set (Part A) — `CorrelationMapping` (FR-007, shared contract FR-024)

New keys added to spec 01's `PartATagKeys`:

| Key constant | Wire tag | Value |
|---|---|---|
| `operationId` | `ai.operation.id` | `traceId.hexString` (32-hex) — every item in the span's tree |
| `operationParentId` | `ai.operation.parentId` | see per-item rule below |
| `operationName` | `ai.operation.name` | request name (server/consumer), for transaction search — .NET parity |

Per-item `ai.operation.parentId` rule:

| Item | `ai.operation.parentId` | item `id` |
|---|---|---|
| Request / Dependency (the span itself) | `parentSpanId.hexString`, **absent when root** | span id |
| Exception / Message (derived from the span's event) | **span id** (owning item) | n/a (event item) |

Ids are mapped byte-for-byte in canonical W3C lowercase hex — no re-encoding, no
truncation (SC-002). `CorrelationMapping` operates on `TraceId`/`SpanId`/`SpanId?`, not on
`SpanData`, so spec 03 reuses it verbatim.

Resource tags (`ai.cloud.role`, `ai.cloud.roleInstance`, `ai.internal.sdkVersion`,
`ai.device.*`, `ai.application.ver`) come from spec 01's `ResourceDetector.detect(resource:)`,
applied **once at registration** to the provider's `Resource` and baked into the injected
`EnvelopeFactory` (its `resourceTags`) — consumed, never recomputed per span (FR-009). This matches
the SpanExporter contract's `init(pipeline:envelopeFactory:)`: a `TracerProvider` shares one
`Resource` across all its spans, so the tags are detected once, not off each `SpanData`. The exporter
passes per-item correlation tags as `itemTags` to `EnvelopeFactory.makeEnvelope`, which merges them
**over** the baked-in resource tags.

## 3. Span-kind → envelope-type table (`SpanKindMapping`, FR-006)

| `SpanKind` | Envelope | Item type |
|---|---|---|
| `.server` | `RequestData` | Request |
| `.consumer` | `RequestData` | Request |
| `.client` | `RemoteDependencyData` | Dependency |
| `.producer` | `RemoteDependencyData` | Dependency |
| `.internal` | `RemoteDependencyData` | Dependency (`type = InProc`) |
| absent/unspecified | `RemoteDependencyData` | Dependency (mirrors .NET) |

## 4. Success / resultCode predicate (`SuccessPredicate`, FR-011/012) — actual .NET `TraceHelper` (see research.md D-03)

- `status == .error(...)` ⇒ `success = false` **always**, regardless of protocol code
  (both item types).
- **`RequestData` (server/consumer):** with **unset** status and an HTTP span,
  `success = (code != 0 && code < 400)` — **4xx and 5xx both fail**. Non-HTTP or non-unset
  falls through to `status != .error`.
- **`RemoteDependencyData` (client/producer/internal):** `success = (status != .error)`
  **only** — **no** HTTP/gRPC status-code threshold. A dependency HTTP 4xx/5xx with unset
  status is a **success**.
- `responseCode`/`resultCode`: the protocol status string (HTTP/gRPC); when none, derived
  from span status → default `"0"` (never omitted where schema requires it).

> Reconciled to actual .NET behavior (maintainer-confirmed 2026-07-10); the spec's
> FR-011/012 wording was updated to match. This is authoritative for the golden tests.

## 5. Semantic-convention mapping tables (`SemanticConventions` + per-protocol files, FR-016–018)

Current key preferred when both present (mirrors .NET `ActivityTagsProcessor`). Consumed
keys are removed from `properties`; everything else is carried into `properties`.

| Concept | Current key | Legacy key(s) |
|---|---|---|
| HTTP method | `http.request.method` | `http.method` |
| HTTP status | `http.response.status_code` | `http.status_code` |
| URL (full) | `url.full` | `http.url` |
| URL parts | `url.scheme` / `url.path` / `url.query` | `http.scheme` / `http.target` |
| Host / port | `server.address` / `server.port` | `net.peer.name` / `net.peer.port`, `http.host` |
| DB system | `db.system` | (same) |
| DB name | `db.namespace` | `db.name` |
| DB statement | `db.query.text` | `db.statement` |
| RPC system/service/method | `rpc.system` / `rpc.service` / `rpc.method` | (same) |
| gRPC status | `rpc.grpc.status_code` | (same) |
| Messaging system | `messaging.system` | (same) |
| Messaging destination | `messaging.destination.name` | `messaging.destination` |
| Peer service | `peer.service` | (same) |

Per-protocol field derivation is in data-model §1 (type/target/data/url/name); the
per-file tables (`HTTPMapping`, `DBMapping`, `RPCMapping`, `MessagingMapping`) implement it.

## 6. Envelope-level fields (FR-023)

- `sampleRate`: default **100** (no sampling) — this feature attaches, never decides (spec 05).
  Carried on the envelope via `EnvelopeFactory.makeEnvelope(sampleRate:)`.
- `time`: span `startTime` (App Insights item timestamp; `duration` carries the span length).
- `itemCount`: **not emitted** for trace items. The trace `baseData` types
  (Request/Dependency/Exception/Message) do not use it and spec-01's `Envelope`/`EnvelopeFactory`
  expose no `itemCount` field; `sampleRate` alone carries the sampling weight. (`itemCount` for
  aggregated metrics is spec 04.)

## State / lifecycle

The exporter is stateless with respect to translation (pure function). Its only lifecycle is
the pipeline's: **running → (pipeline `shutdown()`) → inert**. Post-shutdown `export(...)` is
a safe no-op drop, surfaced only via spec 01's rate-limited `postShutdownSubmit` diagnostic
(FR-005). No state is added by this feature beyond holding the injected factory + pipeline.
