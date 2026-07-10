---
name: verify-telemetry
description: Procedure to prove Stout telemetry actually LANDS end-to-end, since unit tests cannot confirm ingestion. Covers two approaches — (a) a local mock ingestion endpoint that captures the gzip newline-JSON POST to /v2.1/track, decompresses it, and asserts envelope shape/fields; and (b) a real Application Insights check that sends via Stout then queries with KQL (requests, dependencies, traces, customMetrics) via `az monitor app-insights` or the Azure MCP server. Use this when asked to "verify telemetry", "prove data reaches App Insights", "does my span/log/metric show up", "test the exporter end-to-end", "check the Breeze payload on the wire", or as the /verify step for a telemetry-emitting change before merging.
---
# Verify Telemetry (the "/verify" for a telemetry library)

Unit tests prove translation logic in isolation; they cannot prove telemetry
actually reaches Application Insights with correct field mapping. This is the
procedure to close that gap. Use it after any change that touches envelope
construction, transport, or a translation table. It applies on every platform Stout
targets — **run it on the iOS Simulator as well as macOS and Linux**, since the
transport differs (URLSession on Apple, async-http-client on Linux) and only an
end-to-end check exercises the real path. Both approaches respect the prime
directive: never print `iKey` / connection strings / tokens.

Two complementary approaches — do (a) always (fast, deterministic, offline), do
(b) before shipping a signal or when field mapping is in doubt.

---

## Approach A — Local mock ingestion endpoint (offline, deterministic)

Stand up a tiny HTTP server that impersonates `{IngestionEndpoint}/v2.1/track`,
point Stout at it, flush, and assert on what was actually sent on the wire.

### Steps
1. **Start a mock server** bound to `127.0.0.1:<port>` with a handler for
   `POST /v2.1/track`. Any minimal HTTP server works (Swift NIO / Hummingbird test
   server, or a throwaway script). It must:
   - read the raw request body,
   - assert `Content-Encoding: gzip` and
     `Content-Type: application/x-json-stream`,
   - **gunzip** the body,
   - **split on `\n`** into individual envelopes and JSON-decode each,
   - capture them for assertions,
   - reply `200` with a valid ingestion response so Stout's partial-success path is
     exercised:
     ```json
     {"itemsReceived":<n>,"itemsAccepted":<n>,"errors":[]}
     ```
     (To test retry/partial-success, return an `errors` array with a retriable
     `statusCode` for one `index` and a lower `itemsAccepted`.)
2. **Point Stout at the mock.** Use a test connection string whose
   `IngestionEndpoint` is `http://127.0.0.1:<port>/` (the mock; localhost http is
   fine for the test harness only) and a dummy `InstrumentationKey` GUID.
3. **Emit + flush.** Emit the span/log/metric under test, then force a flush /
   `shutdown()` (drain-and-go-inert, decision D1) so the batch is exported
   synchronously for the test.
4. **Assert envelope shape** against `breeze-schema`:
   - envelope `ver` is **absent**; `baseData.ver == 2`;
   - `name` / `data.baseType` correct (e.g. `RequestData`);
   - Part A tags: `ai.operation.id` == trace id, `ai.operation.parentId` == parent
     span id, `ai.cloud.role`, `ai.internal.sdkVersion == "stout:<version>"`;
   - field mapping: e.g. RequestData `responseCode`/`success`/`url`/`duration`;
     RemoteDependencyData `target`/`type`/`data`/`resultCode`;
   - `sampleRate` present and sane;
   - **secret hygiene:** the only place `iKey` appears is the envelope field — it
     is never in logs, never in the mock's own output.

Prefer this in CI: no network, no Azure resource, no secrets, fully hermetic.

---

## Approach B — Real Application Insights (end-to-end truth)

Send through Stout to a real App Insights resource, then query it back with KQL to
confirm arrival and correct mapping. Ingestion latency is typically ~1–3 minutes,
so poll.

### Prereqs
- A real App Insights resource + connection string. Provision one with the
  `appinsights-local-setup` skill and export it (never commit it):
  ```sh
  export STOUT_CONNECTION_STRING="InstrumentationKey=...;IngestionEndpoint=...;LiveEndpoint=..."
  export STOUT_APPINSIGHTS_APP_ID="<app-id-guid>"   # from `az monitor app-insights component show`
  ```
- Azure CLI logged in (`az login`) with the `application-insights` extension, OR
  the Azure MCP server available.

### Steps
1. **Run the harness** that emits known, uniquely-tagged telemetry (put a unique
   marker in an attribute/property, e.g. `stout.test.run=<uuid>`, so you can filter
   precisely). Flush / shut down cleanly.
2. **Wait** ~60–180s for ingestion.
3. **Query with KQL.** Via CLI:
   ```sh
   az monitor app-insights query \
     --app "$STOUT_APPINSIGHTS_APP_ID" \
     --analytics-query "requests | where timestamp > ago(30m) | where customDimensions['stout.test.run'] == '<uuid>' | project timestamp, name, resultCode, success, url, cloud_RoleName | take 20"
   ```
   Or ask the **Azure MCP server** to run the same KQL against the resource.
4. **Assert per signal** (each Breeze type lands in a different table):

   | Emitted | KQL table | Confirm |
   |---|---|---|
   | server span | `requests` | `name`, `resultCode`, `success`, `url`, `operation_Id` == trace id, `cloud_RoleName` |
   | client span | `dependencies` | `name`, `type`, `target`, `data`, `resultCode`, `success`, `operation_Id` |
   | log record | `traces` | `message`, `severityLevel`, `operation_Id` (correlated to span) |
   | exception | `exceptions` | `type`, `outerMessage`, `operation_Id` |
   | metric | `customMetrics` | `name`, `value`, `valueCount`, dimensions in `customDimensions` |

   Example correlation check (request + its dependency share `operation_Id`):
   ```
   union requests, dependencies
   | where timestamp > ago(30m) and operation_Id == '<traceId>'
   | project itemType, name, operation_Id, operation_ParentId, resultCode, success
   ```
   Example metric check:
   ```
   customMetrics
   | where timestamp > ago(30m) and name == 'orders.count'
   | project timestamp, name, value, valueCount, customDimensions
   ```

### Interpreting results
- **Nothing returned** after waiting: check that flush/shutdown ran, the connection
  string's `IngestionEndpoint` matches the resource's region, and the ingestion
  response had `itemsAccepted > 0`. Re-run Approach A to see the raw payload.
- **Row present but a field is wrong/empty:** it is a translation-table bug — fix
  the mapping (see `breeze-schema` §5) and re-verify with Approach A first.
- **`cloud_RoleName` empty:** resource detection / Part A tag mapping issue.

### Cleanup
The unique-marker filtering means you rarely need to delete data; App Insights data
expires per the resource retention. Never leave a real connection string in shell
history or files — it is a secret.
