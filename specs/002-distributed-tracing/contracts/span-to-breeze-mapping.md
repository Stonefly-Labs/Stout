# Contract: `SpanData` → Breeze translation

The pure, deterministic mapping (FR-028): identical `SpanData` in ⇒ identical `[Envelope]`
out, no side effects, `Sendable`. Full field tables live in [data-model.md](../data-model.md);
this contract states the invariants tests assert.

## Orchestration (`SpanTranslator.translate(_:) -> [Envelope]`)

For one `SpanData`:

1. Resolve envelope type from `kind` (§3 table). → `RequestData` or `RemoteDependencyData`.
2. Build correlation `itemTags` (`ai.operation.id`/`ai.operation.parentId`/`ai.operation.name`).
3. Populate protocol fields via the matching per-protocol mapper (HTTP/DB/RPC/messaging),
   consuming recognized attribute keys.
4. Carry all unconsumed attributes **and** links into `properties`.
5. Compute `success`/`responseCode`|`resultCode` via `SuccessPredicate`.
6. Emit exactly one Request/Dependency item, then one `ExceptionData` per `exception` event
   and one `MessageData` per other event — each correlated with `ai.operation.parentId` = the
   span id (§2 rule).
7. Stamp each item into an `Envelope` (`time` = span `startTime`; `sampleRate` = 100 default).

## Invariants (test-asserted)

- **INV-1 (kind→type, SC-001):** `.server`/`.consumer` ⇒ exactly one `RequestData`;
  `.client`/`.producer`/`.internal`/absent ⇒ exactly one `RemoteDependencyData`. Exactly one
  Request/Dependency item per span, always.
- **INV-2 (correlation, SC-002):** `ai.operation.id` = `traceId.hexString` (32-hex); item
  `id` = `spanId.hexString` (16-hex); `ai.operation.parentId` = `parentSpanId.hexString` or
  **absent** for a root span — byte-for-byte, no truncation/transposition.
- **INV-3 (protocol fields, SC-003):** across HTTP/DB/RPC/messaging (current **and** legacy
  keys) `type`/`target`/`data`/`responseCode`/`resultCode`/`url` match the tables; the
  **current** key wins when both current and legacy are present (deterministic, not
  order-dependent — research.md D-07); unmapped attributes and links appear in `properties`.
- **INV-3b (success, actual .NET — research.md D-03):** error span status ⇒ `success = false`
  always. **Request** (server/consumer): unset-status HTTP ⇒ `success = code != 0 && code < 400`
  (4xx & 5xx fail). **Dependency** (client/producer/internal): `success = (status != error)`
  only — no HTTP/gRPC code threshold (a dependency 4xx/5xx with unset status is a success).
- **INV-4 (events, SC-004):** an `exception` event ⇒ one correlated `ExceptionData`
  (`type`←`exception.type`, `message`←`exception.message`, `stack`←`exception.stacktrace`
  when present); a non-exception event ⇒ one correlated `MessageData`; an **error span
  status ⇒ `success = false`** on the owning item even with no `exception` event.
- **INV-5 (defaults/edge):** unspecified kind ⇒ Dependency; missing protocol status ⇒
  `responseCode`/`resultCode` = `"0"` (never omitted); malformed/unreconstructable
  attributes ⇒ best-effort item, remainder to `properties`, **never throws**.
- **INV-6 (sampling, SC-006):** every emitted envelope carries `sampleRate` (default 100)
  and `itemCount` where the schema uses it; this feature makes **no** sampling decision.
- **INV-7 (shared rule, SC-007):** the trace/span-id → `ai.operation.*` mapping is provided
  by `CorrelationMapping` operating on ids (not `SpanData`), so spec 03 reuses it identically.
- **INV-8 (purity, FR-028/SC-010):** the mapper is pure/`Sendable`; identical input yields
  byte-identical output; clean under Swift 6 strict concurrency; no data races.
- **INV-9 (security, SC-008):** no connection string / iKey / token is ever produced by the
  mapper or its diagnostics; forwarded span attributes are treated as customer data.

## Determinism notes

- `properties` map ordering must not affect output equality (compare as maps, or encode with
  sorted keys) so goldens are stable across platforms.
- `duration` is formatted as Breeze `d.hh:mm:ss.fffffff` from `endTime − startTime`; a
  negative or zero span clamps to `0` (never crashes).
- `AttributeValue` → `properties` string conversion is a single documented rule for all
  cases (`.string/.bool/.int/.double/.array/.set`).
