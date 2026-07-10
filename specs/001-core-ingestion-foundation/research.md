# Phase 0 Research: Core Ingestion Foundation

**Feature**: 001-core-ingestion-foundation · **Date**: 2026-07-09

Consolidates the technical decisions needed to plan the core. Spec-level `[NEEDS CLARIFICATION]`
markers were already resolved in `/speckit-clarify` (see spec `## Clarifications`) against the
MIT-licensed .NET reference exporter; this file records the remaining **implementation** decisions
(the design.md `[PLAN]` gzip item) plus the confirmed platform/SDK facts.

---

## R1 — Cross-platform gzip strategy (resolves design.md §10 `[PLAN]`)

**Decision**: Own a tiny **system-zlib** wrapper in `StoutCore`. **No new SPM package.** On Apple,
`import zlib` from the SDK modulemap; on Linux, a `.systemLibrary` target (`CZlib`, `pkgConfig: "zlib"`,
`providers: [.apt(["zlib1g-dev"])]`). Produce gzip framing with `windowBits = MAX_WBITS + 16` (31) so
zlib emits the gzip header + CRC-32 + ISIZE trailer itself — we write no framing/checksum code. Call
the underscore primitive `deflateInit2_(&stream, level, Z_DEFLATED, MAX_WBITS+16, MAX_MEM_LEVEL,
Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))` directly from Swift (the
`deflateInit2` macro is not callable from Swift; the underscore form avoids needing a C shim). Expose
it as one synchronous `func gzip(_:) throws -> [UInt8]` over value types, so nothing (`z_stream` is not
`Sendable`) escapes the call — trivially concurrency-safe.

**Rationale**: zlib is a system library on every target (Apple `libz.tbd` — App-Store-safe, the same
libz Foundation uses; Linux `zlib1g`). This is the only option that satisfies the constitution's
minimal-audited-dependencies mandate *and* avoids hand-rolling the CRC-32/trailer logic that is easy
to get subtly wrong. One code path across all platforms. The gzip API surface (`deflateInit2_`,
`MAX_WBITS`, `Z_FINISH`) is stable across zlib 1.2.x/1.3.x.

**Alternatives considered**:
- **Apple `Compression` (libcompression) + zlib on Linux** — rejected: `COMPRESSION_ZLIB` emits *raw*
  DEFLATE (no gzip header/trailer), forcing us to hand-assemble the 10-byte header, CRC-32, and ISIZE
  on the Apple path — two code paths plus the exact correctness risk we want to avoid, for the
  non-benefit of "not linking libz on Apple" (Apple ships and blesses libz).
- **Third-party package** (GzipSwift / compress-nio / swift-nio-extras) — rejected: adds an SPM
  dependency against the constitution, and they all just wrap system zlib anyway. compress-nio and
  swift-nio-extras drag SwiftNIO onto iOS (inappropriate for on-device). GzipSwift is MIT/Swift-6-clean
  and internally identical to our decision, retained only as a fallback if we later decide not to own
  ~120 lines.

**Plan follow-up**: verify Apple SDK zlib vs distro `zlib1g` in CI; gzip round-trip golden test
(SC-004) covers correctness on both backends.

---

## R2 — opentelemetry-swift package & exporter protocol surface (confirms design.md §10 risk)

**Decision**: Depend on **`opentelemetry-swift-core`** (already wired in `Package.swift`), product
`OpenTelemetrySdk` (+ `OpenTelemetryApi`), pinned `from: 2.5.0`. The core consumes only the SDK data
types and the exporter-protocol surface; **no OTLP/gRPC/protobuf** (the `-core` split avoids them).

**Rationale**: Spec 01 is signal-agnostic — it needs the `Resource` type (for Part A tag mapping) and
the shared export-result/shutdown semantics, but **not** `SpanExporter`/`LogRecordExporter`/
`MetricExporter` themselves (those are implemented in specs 02–04). Keeping the core free of the signal
exporter protocols preserves the clean `baseData` seam. Traces are Stable in opentelemetry-swift; Logs/
Metrics are Beta — irrelevant to the core, which touches none of them (accepted, design D8).

**Alternatives considered**: full `opentelemetry-swift` package (rejected — pulls OTLP/gRPC/protobuf,
violating minimal-deps). Vendoring OTel types (rejected — fidelity/maintenance).

**Plan follow-up**: during implementation, confirm the exact `Resource` attribute-accessor API and
that `OpenTelemetrySdk` builds clean under Swift 6 strict concurrency on iOS-sim + Linux (resolve &
build). This is the one API-surface item to verify against the pinned version.

---

## R3 — Transport split (confirms design D9)

**Decision**: One `Sendable` `Transport` protocol; `URLSessionTransport` on Apple and
`AsyncHTTPClientTransport` on Linux, selected via `#if canImport(FoundationNetworking)`. The core
gzips the body itself (R1) before calling `send`. Background/streaming URLSession upload is deferred
(FR-034), layered behind the same protocol later.

**Rationale**: Linux `URLSession`/`FoundationNetworking` is too limited for this workload; async-http-client
is the SSWG-standard client (mirrors Apple's own `swift-openapi-urlsession` + async-http-client split).
`async-http-client` is already a Linux-only conditional dependency in `Package.swift`.

**Alternatives considered**: URLSession everywhere (rejected — Linux limitations); swift-openapi
generator (rejected — overkill for one endpoint).

---

## R4 — Timestamp & JSON encoding

**Decision**: Encode `time` as UTC ISO-8601 with fractional seconds + `Z`, produced deterministically
regardless of host locale/timezone. Encode each envelope as a single-line JSON object; join a batch
with `\n`. Field names/order match the Breeze wire contract; envelope `ver` omitted; `baseData.ver`=2.

**Rationale**: FR-006/FR-009 and the ingestion contract require exact wire forms; determinism is
required for the golden round-trip tests (SC-004). Foundation's date formatting differs subtly between
Darwin and swift-corelibs-foundation, so the encoder must pin the format explicitly and be tested on
both platforms.

**Alternatives considered**: `JSONEncoder.dateEncodingStrategy = .iso8601` (rejected — no fractional
seconds by default, platform-variant). A fixed formatter or manual formatting is used instead.

---

## R5 — Concurrency model for the pipeline

**Decision**: Model `ExportPipeline` as an `actor` guarding the bounded buffer, dropped counter, and
lifecycle state; expose a `nonisolated` non-blocking `submit` that hands off to the actor without the
caller awaiting I/O. The async export loop is an actor-owned `Task`. Compression (R1) and transport
(R3) operate on `Sendable` value types outside any lock.

**Rationale**: Satisfies FR-011 (injectable, no process-global state), FR-012 (non-blocking submit),
FR-030 (Sendable, no data races), and the drain-and-go-inert lifecycle (FR-015/016) with a single
isolation domain — the simplest structure that is provably race-free under Swift 6.

**Alternatives considered**: lock-based (`NSLock`/`Mutex`) buffer (rejected — actor is the idiomatic,
strict-concurrency-clean choice); unbounded `AsyncStream` (rejected — violates bounded-memory FR-014).

---

## Resolved spec clarifications (recorded for traceability — see spec `## Clarifications`)

| Ref | Decision |
|---|---|
| FR-004 | Endpoint precedence explicit → suffix `https://[loc.]dc.{suffix}` → default `https://dc.services.visualstudio.com/`; never fail-closed on missing endpoint alone. |
| FR-018 | `ai.cloud.role` = `[{namespace}]/{name}` (brackets) else `{name}`; roleInstance = `service.instance.id` else host name. |
| FR-017 | Defaults: buffer 2048, flush 5 s, batch 512, shutdown 30 s, ≤3 in-memory attempts, backoff ≤~60 s. |
| FR-025/027 | Retriable `{408,429,439,401,403,500,502,503,504}`; 206 per-item retriable `{408,429,439,500,503}`; else drop. |
