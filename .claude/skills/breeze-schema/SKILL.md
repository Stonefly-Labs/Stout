---
name: breeze-schema
description: Canonical reference for the Application Insights "Breeze" ingestion format used by Stout — envelope structure (Part A tags/iKey/time/sampleRate, data.baseType/baseData), the /v2.1/track transport, connection-string format, standard baseData types (RequestData, RemoteDependencyData, MessageData, ExceptionData, MetricData), and the OTel-semantic-convention → App Insights field mapping. Use this whenever implementing or reviewing Breeze envelope construction, connection-string parsing, transport wiring, or span/log/metric translation, or when answering "what field does X map to", "what does a Breeze envelope look like", "which baseType", "what's the /track path", "how do I encode gzip newline-JSON", or verifying a payload matches what Application Insights expects.
---
# Breeze Ingestion Schema Reference

THE canonical reference for the Application Insights **Breeze** wire format that
Stout translates telemetry into. The OTel input types being translated
(`SpanData` / `ReadableLogRecord` / `MetricData`) come from **`opentelemetry-swift`** —
Stout implements its public `SpanExporter` / `LogRecordExporter` / `MetricExporter`
(D8). Get this exactly right so implementers and reviewers do not re-derive it.
Grounded in `docs/design.md` §2 (transport) and §6 (translation table), and the
MIT-licensed .NET exporter at
`Azure/azure-sdk-for-net` →
`sdk/monitor/Azure.Monitor.OpenTelemetry.Exporter/src/Internals/`
(`SchemaConstants.cs` for the `/track` path and constants, `TraceHelper.cs` for
span→item, `ActivityTagsProcessor.cs` for tags→Part B/C).

We port the **logic** from the .NET reference, not the code (different language;
value is the algorithm + schema constants). Under the prime directive, secrets
(`InstrumentationKey`, connection strings, tokens) are NEVER logged or placed in
error messages / self-diagnostics — this includes anything derived from the
envelope.

## 1. Transport

- **Endpoint:** `POST {IngestionEndpoint}/v2.1/track`. `IngestionEndpoint` comes
  from the connection string (default host `https://dc.services.visualstudio.com`).
  The modern `Azure.Monitor.OpenTelemetry.Exporter` uses **`/v2.1/track`**;
  `/v2/track` is the older classic-SDK path — do NOT use it (locked decision D2).
- **HTTPS only.** Fail closed on any non-HTTPS endpoint.
- **Headers:** `Content-Encoding: gzip`, `Content-Type: application/x-json-stream`.
- **Body:** newline-delimited JSON — one JSON envelope per line (`\n` separated,
  NOT a JSON array), then gzip-compressed. This is the "x-json-stream" format.
- **Response:** JSON with `itemsReceived` / `itemsAccepted` and a per-item `errors`
  array (`index`, `statusCode`, `message`). Drives partial-success handling: retry
  only the retriable failed items; honor `Retry-After` on 429/503.

## 2. Envelope (Part A)

Each line is one **envelope**. Fields:

| Field | Meaning | Notes |
|---|---|---|
| `ver` | Envelope schema version = **1** | **Omitted on the wire** by default |
| `name` | Telemetry item type name | e.g. `Microsoft.ApplicationInsights.Request` |
| `time` | ISO-8601 UTC timestamp | event time / span start |
| `sampleRate` | Percentage 0–100 | carry from day 1; default 100 (see §6 below) |
| `iKey` | Instrumentation key | from connection string `InstrumentationKey` — a secret |
| `tags` | Part A context dictionary | `ai.*` keys (see below) |
| `data` | Part B/C wrapper | `{ "baseType": ..., "baseData": {...} }` |

`data.baseType` is the type discriminator (e.g. `RequestData`,
`RemoteDependencyData`). `data.baseData` is the typed payload, and each
`baseData.ver` = **2** (present on the wire).

**Standard Part A `tags` (`ai.*`):**

| Tag | Source |
|---|---|
| `ai.operation.id` | trace ID |
| `ai.operation.parentId` | parent span ID |
| `ai.cloud.role` | `service.name` / `service.namespace` |
| `ai.cloud.roleInstance` | `service.instance.id` / `host.name` |
| `ai.internal.sdkVersion` | **`stout:<version>`** (Stout's SDK-version string) |
| `ai.user.id`, `ai.session.id`, `ai.device.*`, `ai.application.ver` | optional; populated on-device from the OTel resource when available |

Envelope skeleton (illustrative):

```json
{"name":"Microsoft.ApplicationInsights.Request","time":"2026-07-09T12:00:00.000Z","sampleRate":100,"iKey":"<guid>","tags":{"ai.operation.id":"<traceId>","ai.cloud.role":"checkout","ai.internal.sdkVersion":"stout:0.1.0"},"data":{"baseType":"RequestData","baseData":{"ver":2,"id":"<spanId>","name":"GET /cart","duration":"00:00:00.1230000","responseCode":"200","success":true,"url":"https://.../cart","properties":{}}}}
```

Note `duration` is the App Insights timespan format `d.hh:mm:ss.fffffff` (days
optional), NOT seconds/millis.

## 3. Connection string

```
InstrumentationKey=<guid>;IngestionEndpoint=https://<region>.in.applicationinsights.azure.com/;LiveEndpoint=https://<region>.livediagnostics.monitor.azure.com/
```

- `InstrumentationKey` → each envelope's `iKey`. **Secret.**
- `IngestionEndpoint` → base URL for `/v2.1/track` (Breeze).
- `LiveEndpoint` → QuickPulse / Live Metrics channel only (see design §7) — NOT
  Breeze. A separate endpoint/protocol/data model; shares only the connection
  string.
- Parse defensively; validate GUID and HTTPS scheme; fail closed on malformed
  input. Never echo the raw string in errors.

## 4. Standard baseData types

Each has `ver` = 2 and a `properties` (string→string) bag for custom dimensions;
several also carry a `measurements` (string→double) bag.

### `Microsoft.ApplicationInsights.Request` → `RequestData`
Inbound operations (span kind `.server` / `.consumer`).
Key fields: `id` (span id), `name`, `duration`, `responseCode`, `success`
(bool), `url`, `source`, `properties`, `measurements`.

### `Microsoft.ApplicationInsights.RemoteDependency` → `RemoteDependencyData`
Outbound calls (span kind `.client` / `.producer` / `.internal`).
Key fields: `id`, `name`, `duration`, `resultCode`, `success`, `data`
(query/URL/statement), `target` (host / db / peer), `type` (HTTP / SQL /
`db.system` / queue), `properties`, `measurements`.

### `Microsoft.ApplicationInsights.Message` → `MessageData`
Log records and non-exception span events.
Key fields: `message`, `severityLevel` (0=Verbose,1=Information,2=Warning,
3=Error,4=Critical), `properties`.

### `Microsoft.ApplicationInsights.Exception` → `ExceptionData`
`exception` span events and error-level logs with an error.
Key fields: `exceptions` (array of `{ typeName, message, hasFullStack,
stack, parsedStack }`), `severityLevel`, `properties`.

### `Microsoft.ApplicationInsights.Metric` → `MetricData`
Aggregated metrics.
Key fields: `metrics` (array of `{ name, kind, value, count, min, max, stdDev }`),
`properties` (dimensions). Stout exports **delta** per flush (decision D4:
cumulative would double-count under App Insights' sum aggregation).

## 5. Semantic-convention → App Insights field mapping

Span kind decides the envelope: `.server`/`.consumer` → **RequestData**;
`.client`/`.producer`/`.internal` → **RemoteDependencyData**. Then map OTel
attributes:

| Signal / attribute | RequestData | RemoteDependencyData |
|---|---|---|
| `name` (op/route) | `name` | `name` |
| **HTTP** `http.request.method` + `url.*` / `http.url` | `url`, `name` | `data` (full URL), `type`=`"HTTP"` |
| **HTTP** `http.response.status_code` | `responseCode` | `resultCode` |
| **HTTP** `server.address`/`net.peer.name` | — | `target` (host[:port]) |
| **DB** `db.system` | — | `type` (e.g. `"SQL"`, `"mysql"`, `"Redis"`) |
| **DB** `db.statement`/`db.query.text` | — | `data` |
| **DB** `db.name`/`db.namespace` | — | `target` (server \| database) |
| **RPC/gRPC** `rpc.system` | `type` via app logic | `type` (e.g. `"GRPC"`) |
| **RPC/gRPC** `rpc.grpc.status_code` | `responseCode` | `resultCode` |
| **RPC** `rpc.service`/`rpc.method` | `name` | `name`, `target` |
| **Messaging** `messaging.system` | — | `type` (e.g. `"Queue Message \| <system>"`) |
| **Messaging** `messaging.destination.name` | `source` (consumer) | `target` (producer) |
| **success** | derive from status (2xx/OK ⇒ true) | derive from status |
| all other attributes | → `properties` | → `properties` |

`success`: HTTP status < 400 (or gRPC `OK`/0) ⇒ `true`; record explicit
`error`/exception status as `false`. `resultCode`/`responseCode` are strings.

**Span events / logs / metrics:**
- `exception` event → `ExceptionData`; other events → `MessageData`.
- `ReadableLogRecord` → `MessageData` (or `ExceptionData` when an error is
  attached); map OTel severity → `severityLevel`; correlate to the owning span via
  `ai.operation.id`/`ai.operation.parentId`.
- `MetricData` → `MetricData` envelope (value/count/min/max for histograms);
  dimensions →
  `properties`; bounded cardinality via the overflow bucket
  `{otel.metric.overflow = true}` (decision D4).

## 6. Sampling

App Insights uses fixed-rate **ingestion sampling** via envelope `sampleRate`
(0–100) plus per-item `itemCount` (= 100/sampleRate) so the backend scales counts
back up. Full traces-MVP sampling is deferred, but **carry `sampleRate` in the
envelope model from day 1** (§6 of design) so it is never a schema migration later.

## 7. Pitfalls

- Do not emit `envelope.ver` on the wire; DO emit `baseData.ver = 2`.
- Body is newline-delimited JSON, not a JSON array; one envelope per line.
- `duration` is the timespan string format, not a number.
- `sampleRate` lives on the envelope (Part A), not in `baseData`.
- `LiveEndpoint` is QuickPulse, not Breeze — never POST Breeze envelopes there.
- Do not conflate Azure service names ("Azure Monitor", "Application Insights")
  with Stout modules or the .NET reference types.
