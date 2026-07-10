# Contract: Ingestion Wire Format (Breeze /v2.1/track)

**Feature**: 001-core-ingestion-foundation

The external contract with Application Insights ingestion. This is fixed by the service (Breeze); we
conform to it, not the reverse. See the `breeze-schema` skill for the canonical reference.

## Request

```
POST {IngestionEndpoint}/v2.1/track
Content-Type: application/x-json-stream
Content-Encoding: gzip
<body: gzip( envelope_1 "\n" envelope_2 "\n" ... envelope_N )>
```

- Default host `https://dc.services.visualstudio.com` when the connection string supplies none (FR-023).
- Body is **newline-delimited JSON**: each envelope is one single-line JSON object, `\n`-separated
  (FR-009). The whole payload is gzip-compressed by the core (FR-010).

### Envelope JSON (one line)

```json
{"name":"Microsoft.ApplicationInsights.Request","time":"2026-07-09T14:12:03.412Z","iKey":"<guid>","sampleRate":100,"tags":{"ai.cloud.role":"[payments]/orders-api","ai.cloud.roleInstance":"orders-api-7d9f","ai.internal.sdkVersion":"stout:0.1.0"},"data":{"baseType":"RequestData","baseData":{"ver":2,"...":"..."}}}
```

- `ver` (envelope) = 1, **omitted on the wire by default** (D2).
- `data.baseData.ver` = 2.
- `time` = UTC ISO-8601, fractional seconds, `Z`.
- `baseData` is signal-specific (out of scope here); the core stamps everything around it.

## Response

```json
{ "itemsReceived": 3, "itemsAccepted": 2, "errors": [ { "index": 1, "statusCode": 400, "message": "..." } ] }
```

## Status classification (mirror .NET — Clarifications)

| Outcome | Statuses | Action |
|---|---|---|
| Success | `200` | Done. |
| Retriable (whole response) | `408, 429, 439, 401, 403, 500, 502, 503, 504`, timeouts, conn errors | Retry within bounded attempts (FR-025/026/027). |
| Partial success | `206` | Retry only per-item statuses in `{408, 429, 439, 500, 503}`; drop rest. |
| Non-retriable | everything else (`400`, `402`, `404`, …) | Drop + secret-free self-diagnostics. |

- `Retry-After` (delta-seconds or HTTP-date) honored when present; else exponential backoff + jitter,
  bounded by `maxRetryAttempts` (3) and `maxRetryDelay` (~60 s) (FR-026).
- `439` is an Azure-specific throttling status.

## Contract tests (Acceptance #7, #8, #9; FR-024–FR-027)

- Parse `itemsReceived`/`itemsAccepted`/`errors`; only retriable items retried; permanent dropped +
  recorded (no secrets).
- `429`/`503` + `Retry-After` waits the indicated delay; without it → bounded backoff.
- `400`/`402`/`404` never retried; `401`/`403` retried within budget (then exhausted).
- Empty/non-JSON/malformed response body → non-fatal, classified, no crash.
