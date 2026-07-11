# Contract: `AzureMonitorTraceExporter` (SpanExporter conformance)

The public surface this feature adds to `StoutTracing`. Confirmed against
`opentelemetry-swift-core` 2.5.1's `SpanExporter` protocol.

## Protocol obligations (from the SDK)

`SpanExporter` is `AnyObject, Sendable`, so the exporter is a **`final class`**. The SDK
declares both sync and async forms; the async forms have default impls that
`assertionFailure` — Stout **MUST** provide real implementations of all required members:

```swift
public final class AzureMonitorTraceExporter: SpanExporter {
  @discardableResult
  public func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode
  public func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode
  public func shutdown(explicitTimeout: TimeInterval?)

  @discardableResult
  public func export(spans: [SpanData], explicitTimeout: TimeInterval?) async -> SpanExporterResultCode
  public func flush(explicitTimeout: TimeInterval?) async -> SpanExporterResultCode
  public func shutdown(explicitTimeout: TimeInterval?) async
}
```

## Construction (FR-005)

```swift
public init(pipeline: ExportPipeline, envelopeFactory: EnvelopeFactory)
```

- Both dependencies come from spec 01 and are injected — the exporter is
  independently-constructable and unit-testable with **no live `TracerProvider`** and **no
  network** (a mock `Transport`/`Diagnostics` behind the pipeline).
- `Sendable` holds because the stored properties are an `ExportPipeline` (actor) and an
  `EnvelopeFactory` (immutable `Sendable` value). No other mutable state.

A thin `TraceExporterRegistration` helper builds the exporter from the spec-01 assembled
pipeline + factory (and is where the umbrella `Stout` distro, spec 07, will register it with
a `TracerProvider` via `BatchSpanProcessor`). This feature does **not** implement provider
bootstrap.

## Behavioral contract

| Member | Contract |
|---|---|
| `export(spans:...)` | Translate each `SpanData` to exactly one `RequestData`/`RemoteDependencyData` **plus** any `ExceptionData`/`MessageData` from its events (FR-003); build an `Envelope` per item via `envelopeFactory`; `pipeline.submit(_:)` each. **Non-blocking** (submit hands off to the actor and returns; no network/no full-buffer wait, FR-004). Returns `.success` when items were handed off, `.failure` only if the exporter is inert. Never throws into the host; a per-span translation error drops that span best-effort and continues (FR-026). |
| `flush(...)` | Forward buffered items promptly — `await pipeline.flushNow()` on the async path (US6 Acc #1). Returns `.success`. Does not strand items. |
| `shutdown(...)` | Idempotent; drain-and-go-inert is owned by spec 01 (`pipeline.shutdown()`). After it, the exporter is inert. |
| post-shutdown `export` | Safe no-op drop: items go to the (inert) pipeline which drops them and emits spec 01's single rate-limited `postShutdownSubmit` warning. No crash, no block, no telemetry (FR-005, US6 Acc #2). |
| concurrency | Concurrent `export(...)` from many tasks is safe (FR-027) — translation is pure and submit is actor-hop. |

## Non-goals (owned elsewhere)

Inject/extract, propagators, `Instrument`, span lifecycle, batching, sampling **decision**,
and the transport/retry/buffer are **not** implemented here (SDK owns the first set; spec 01
owns transport/pipeline; spec 05 owns the sampling decision).

## Public API doc requirement (FR-029)

The exporter type, its init, the registration helper, and each Breeze payload type carry doc
comments stating: the span-kind→envelope table, correlation-id ownership (SDK propagates; we
map), behavior on unknown/unspecified span kinds, and behavior on malformed attributes.
