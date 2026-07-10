# Data Model: Core Ingestion Foundation

**Feature**: 001-core-ingestion-foundation
**Date**: 2026-07-09
**Source**: [spec.md](./spec.md) Key Entities + Functional Requirements

This model describes the logical entities the core owns. All types are `Sendable` (FR-030). Types
that hold secrets (connection string, iKey) are noted; they must never render those in
`description`/`debugDescription`/logs (FR-028). Concrete signal `baseData` payload types are **out of
scope** here — the core only defines the extension seam.

---

## 1. ConnectionConfiguration

The validated result of parsing an Application Insights connection string (FR-001–FR-005).
**Holds secrets** — `instrumentationKey` is sensitive; conforms to a redacting debug description.

| Field | Type | Notes / Validation |
|---|---|---|
| `instrumentationKey` | `String` (GUID) | Required. Well-formed GUID (FR-003). **Secret.** → envelope `iKey`. |
| `ingestionEndpoint` | `URL` | Normalized, absolute, **HTTPS-only** (FR-003/FR-005/FR-029). Resolved per precedence (FR-004). |
| `liveEndpoint` | `URL?` | Optional; retained for spec 06 (Live Metrics), not consumed here. |
| `endpointSuffix` | `String?` | Optional; used to derive endpoints when explicit ones absent (FR-004). |
| `retainedFields` | `[String: String]` | Optional auth/region fields (e.g. `AADAudience`) retained verbatim for spec 05. Never logged. |

**Derivation precedence for `ingestionEndpoint`** (FR-004):
1. explicit `IngestionEndpoint` → use verbatim (must be HTTPS, absolute).
2. else `EndpointSuffix` present → `https://[{location}.]dc.{suffix}`.
3. else default → `https://dc.services.visualstudio.com/`.

**Parse failures (fail closed, secret-free error):** missing/malformed iKey, non-HTTPS or malformed
endpoint URL, duplicate keys, empty input (FR-003, Acceptance #2).

---

## 2. Envelope

The shared Breeze item wrapper the core stamps around every signal payload (FR-006–FR-009).

| Field | Wire key | Type | Notes |
|---|---|---|---|
| `version` | `ver` | `Int` = 1 | Envelope schema version; **omitted on the wire by default** (D2). |
| `name` | `name` | `String` | Telemetry item type name (e.g. `Microsoft.ApplicationInsights.Request`). |
| `time` | `time` | `String` | UTC ISO-8601, fractional seconds, `Z` suffix. Locale/timezone-independent. |
| `sampleRate` | `sampleRate` | `Double` = 100 | Percentage; default 100 (no sampling). Serialized; policy out of scope (FR-008). |
| `instrumentationKey` | `iKey` | `String` | From `ConnectionConfiguration`. **Secret on the wire only.** |
| `tags` | `tags` | `TelemetryTags` | Part A tag dictionary (entity 3). |
| `data` | `data` | `DataContainer` | Discriminated payload container (entity 2a). |

### 2a. DataContainer

The `data` object carrying the signal-agnostic discriminator + payload (FR-007).

| Field | Wire key | Type | Notes |
|---|---|---|---|
| `baseType` | `baseType` | `String` | Discriminator, e.g. `RequestData`, `MetricData`. Supplied by signal module. |
| `baseData` | `baseData` | `BaseData` (protocol) | The signal payload; `baseData.ver` = 2. **Extension seam.** |

**Extension seam (FR-007):** `BaseData` is a `Sendable & Encodable` protocol (or equivalent) the core
owns; sibling signal modules conform their own payload types (`RequestData`, …) without the core
depending on them. The core provides an **envelope factory** that stamps `ver`/`name`/`time`/
`sampleRate`/`iKey`/`tags` given a caller-supplied `baseType` + `baseData`. The factory is initialized
with the **`iKey` string** + resource `TelemetryTags` (not the whole `ConnectionConfiguration`), and
`ExportPipeline` takes the **`ingestionEndpoint` `URL`** directly — both accept primitives so US2 is
buildable and testable without the US1 connection-string parser.

---

## 3. TelemetryTags (Part A)

The resource-derived tag dictionary applied to every envelope (FR-018–FR-021), merged with any
per-item signal tags (signal tags win on key conflict, or are documented as an explicit merge rule).

| Tag key | Source | Notes |
|---|---|---|
| `ai.cloud.role` | `service.namespace` + `service.name` | `[{namespace}]/{name}` if namespace present, else `{name}` (FR-018). |
| `ai.cloud.roleInstance` | `service.instance.id` ?? host name | (FR-018). |
| `ai.internal.sdkVersion` | package version | `stout:<version>` (FR-018). |
| `ai.device.model` | Apple resource/platform | On-device only, when available (FR-019). |
| `ai.device.osVersion` | Apple resource/platform | On-device only. |
| `ai.device.type` | Apple resource/platform | On-device only (e.g. Phone). |
| `ai.application.ver` | Apple resource/platform | App version/build, on-device (FR-019). |

Truncation: role/roleInstance capped at the Breeze max lengths (mirror .NET `SchemaConstants`).

---

## 4. ResourceAttributes → tag mapping

Input to entity 3. Sourced from the `opentelemetry-swift` `Resource` and/or cheap platform detection,
with **explicit overrides taking precedence over detection** (FR-020). Computed **once** and reused
(FR-021).

State: `detected` values < `explicit override` values (override wins). No lifecycle transitions beyond
one-time computation at pipeline construction.

---

## 5. ExporterConfiguration (tuning knobs)

Safe, documented defaults aligned to .NET/OTel (FR-017, Clarifications).

| Knob | Default | Notes |
|---|---|---|
| `bufferCapacity` | 2048 items | Hard cap; drop-on-overflow (FR-014). |
| `flushInterval` | 5 s | Time trigger (FR-013). |
| `maxBatchSize` | 512 items | Size trigger (FR-013). |
| `shutdownDrainTimeout` | 30 s | Bounded drain (FR-015). |
| `maxRetryAttempts` | 3 | In-memory attempts (FR-026/FR-027). |
| `maxRetryDelay` | ~60 s | Backoff cap (FR-026). |

---

## 6. TelemetryBatch

An ordered set of `Envelope`s selected for one POST (FR-009/FR-010).

| Field | Type | Notes |
|---|---|---|
| `envelopes` | `[Envelope]` | 1..maxBatchSize. |
| `encodedBody` | `Data` | Newline-delimited JSON (one envelope/line), then gzip-compressed. |

Invariant: N envelopes → exactly N `\n`-delimited JSON lines; gzip round-trips to identical bytes
(Acceptance #3, SC-004).

---

## 7. BoundedBuffer / ExportPipeline

The `Sendable`, independently-constructable pipeline (FR-011–FR-016). Actor-isolated mutable state.

**State:**

| Field | Type | Notes |
|---|---|---|
| `buffer` | bounded queue of `Envelope` | Capacity = `bufferCapacity`; FIFO. |
| `droppedCount` | `UInt64` | Increments on overflow (FR-014, SC-003). |
| `lifecycleState` | enum `{ running, draining, inert }` | (FR-015/FR-016). |
| `postShutdownWarned` | `Bool` | Ensures single rate-limited warning (FR-016). |

**Lifecycle state machine (D1 drain-and-go-inert):**

```
running --submit--> running            (enqueue; or drop+++ if full)
running --shutdown--> draining         (stop accepting; flush best-effort ≤ timeout; await in-flight)
draining --done/timeout--> inert       (loop terminated; client closed)
inert --submit--> inert                (drop; first submit emits ONE diagnostics warning)
inert --shutdown--> inert              (idempotent no-op)
```

Invariants: submit never blocks on I/O (SC-001); memory ≤ capacity (SC-003); shutdown never hangs
(SC-005); idempotent shutdown (Acceptance #6).

---

## 8. Transport (protocol) + request/response

One `Sendable` transport protocol, two compile-time implementations (FR-022, D9): URLSession (Apple)
/ async-http-client (Linux).

**TransportRequest:** method `POST`; url `{ingestionEndpoint}/v2.1/track`; headers
`Content-Type: application/x-json-stream`, `Content-Encoding: gzip`; body = gzip bytes (FR-023).

**TransportResponse:** `statusCode: Int`; `headers` (incl. `Retry-After`); `body: Data`.

---

## 9. IngestionResponse

Parsed ingestion result → retry/drop classification (FR-024–FR-027).

| Field | Wire key | Type | Notes |
|---|---|---|---|
| `itemsReceived` | `itemsReceived` | `Int` | |
| `itemsAccepted` | `itemsAccepted` | `Int` | |
| `errors` | `errors` | `[ItemError]` | Per-item: `index`, `statusCode`, `message`. |

**ItemError:** `{ index: Int, statusCode: Int, message: String }` — `message` MUST NOT be re-logged
with payload secrets (FR-025).

**Classification (mirror .NET fully — Clarifications):**
- HTTP `200` → success.
- Whole-response retriable: `{408, 429, 439, 401, 403, 500, 502, 503, 504}` + timeouts/connection
  errors → retry within bounded attempts.
- `206` partial-success: retry only items with per-item status in `{408, 429, 439, 500, 503}`; drop
  the rest.
- Any other (`400`, `402`, `404`, …) → drop + self-diagnostics (secret-free).
- `Retry-After` honored (delta-seconds or HTTP-date); else exponential backoff + jitter (FR-026).

---

## 10. Diagnostics channel

Internal self-diagnostics sink (FR-016/FR-028/FR-031) — **never** the user telemetry pipeline, never
payload data, always secret-redacted. Emits: dropped-item accounting, permanent-drop notices, the
single post-shutdown warning. Pluggable/observable for tests (assert secret-free — SC-002).
