# Quickstart & Validation Guide: Core Ingestion Foundation

**Feature**: 001-core-ingestion-foundation

How to build, validate, and prove the core works. This is a **validation/run guide** — implementation
lives in `tasks.md` + the implementation phase. Scenarios map to the spec's Acceptance Criteria (Acc)
and Success Criteria (SC).

## Prerequisites

- Swift 6 toolchain (tools 6.0+).
- Apple: Xcode with an iOS Simulator; macOS to build the Apple transport.
- Linux: a Swift 6 container with `zlib1g-dev` installed (the `CZlib` systemLibrary target links `z`).
- No Azure account needed for the core test suite — the transport is mocked. Real ingestion is
  validated separately via the `verify-telemetry` skill once a signal exporter (spec 02) exists.

## Build & gate

```sh
swift build
swift test
swift format lint --strict --recursive Sources Tests
```

All three MUST pass (constitution IV). The suite MUST be run on **both** an Apple platform and Linux —
the two transport backends and Foundation date/JSON differences are real (SC-007). On Linux, ensure
`zlib1g-dev` is present so `CZlib` resolves.

## Validation scenarios

Each is a runnable XCTest; no network required (transport mocked). See
[contracts/](./contracts/) for the exact shapes and [data-model.md](./data-model.md) for entities.

| # | Scenario | Proves | Maps to |
|---|---|---|---|
| 1 | Parse a well-formed connection string → correct GUID iKey, normalized ingestion/live endpoints; `{endpoint}/v2.1/track` well-formed. | Config happy path | Acc #1, FR-001/005 |
| 2 | Parse each invalid variant (missing iKey, bad GUID, non-HTTPS, malformed URL, duplicate key, empty) → matching `ConnectionStringError`; assert `error.description` contains **no** secret. | Fail-closed, secret-free | Acc #2/#11, FR-003/028, SC-002 |
| 3 | Endpoint precedence: explicit → suffix `https://[loc.]dc.{suffix}` → default `https://dc.services.visualstudio.com/`. | Clarified derivation | Acc #1, FR-004 |
| 4 | Encode N envelopes → exactly N `\n`-delimited single-line JSON objects; Breeze field names; `time` = UTC ISO-8601 fractional `Z`; envelope `ver` omitted; `baseData.ver`=2. | Wire correctness | Acc #3, FR-006/009, SC-004 |
| 5 | gzip(body) → decompress → identical bytes; header/trailer valid (round-trip on Apple + Linux). | Gzip fidelity | Acc #3, FR-010, SC-004 |
| 6 | Submit item → returns without awaiting network; flushes when batch hits 512 AND, separately, when the 5 s interval elapses with a partial batch. | Non-blocking + dual flush | Acc #4, FR-012/013, SC-001 |
| 7 | Fill buffer to capacity → further submits dropped, not blocked; `droppedCount` increments by exactly the overflow count; memory ≤ capacity. | Do-no-harm overflow | Acc #5, FR-014, SC-003 |
| 8 | Enqueue, `shutdown()` → pending flushed ≤ 30 s timeout, in-flight completes, client closed, no hang; 2nd `shutdown()` is a no-op; post-shutdown submit dropped with exactly ONE diagnostics warning (no payload). | Drain-and-go-inert | Acc #6, FR-015/016, SC-005 |
| 9 | Mock transport asserts POST `{endpoint}/v2.1/track`, `Content-Type: application/x-json-stream`, `Content-Encoding: gzip`, gzip body; 200 → success. | Transport contract | Acc #7, FR-022/023 |
| 10 | Partial-success (206) response parsed; only per-item `{408,429,439,500,503}` retried; others dropped + recorded secret-free. | Partial success | Acc #8, FR-024/025 |
| 11 | `429`/`503` + `Retry-After` waits indicated delay; without it → exponential backoff+jitter, ≤3 attempts, ≤~60 s; `400`/`402`/`404` never retried; `401`/`403` retried within budget then exhausted. | Retry policy | Acc #9, FR-026/027 |
| 12 | Resource attrs → `ai.cloud.role`=`[ns]/name` (or `name`), `roleInstance`=`instance.id`?? host, `ai.internal.sdkVersion`=`stout:<ver>`, on-device `ai.device.*`/`ai.application.ver`; explicit override beats detection. | Tag mapping | Acc #10, FR-018/021 |
| 13 | All public pipeline/transport/config types compile clean under Swift 6 strict concurrency on Apple + Linux (no data-race warnings). | Concurrency | Acc #12, FR-030, SC-007 |

## Definition of done (this feature)

- Scenarios 1–13 pass on **both** an Apple platform and Linux.
- `swift build` / `swift test` / `swift format lint --strict` all green.
- No secret ever appears in any test/log/error/diagnostic output (SC-002).
- Public API documented (doc comments) and matches [contracts/public-api.md](./contracts/public-api.md).
- Constitution Check re-confirmed PASS (see plan.md).
