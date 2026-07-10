# Contract: StoutCore Public API Surface

**Feature**: 001-core-ingestion-foundation · **Module**: `StoutCore`

This is the **public API boundary** (FR-033, Constitution V — API Stewardship). Anything not listed
stays non-`public`. Signatures are illustrative Swift shapes, not final implementation. All public
types are `Sendable` and documented with doc comments before release (Constitution IV).

> Signal `baseData` payload types (`RequestData`, …) are **not** part of this contract — they live in
> sibling modules (specs 02–04) and conform to the `BaseData` seam below.

---

## Connection configuration

```swift
public struct ConnectionConfiguration: Sendable {
  /// Parse and validate an Application Insights connection string. Fails closed
  /// with a secret-free error on invalid input.
  public init(connectionString: String) throws
  public var ingestionEndpoint: URL { get }
  // instrumentationKey is NOT publicly readable as plain text; redacted in debug output.
}

/// Thrown on invalid connection strings. Its message NEVER contains secret material (FR-028).
public enum ConnectionStringError: Error, Sendable, CustomStringConvertible {
  case empty
  case missingInstrumentationKey
  case malformedInstrumentationKey        // does NOT echo the value
  case missingOrMalformedEndpoint(field: String)
  case nonHTTPSEndpoint(field: String)    // does NOT echo the URL host userinfo
  case duplicateKey(String)
}
```

**Contract tests** (map to Acceptance #1, #2, #11; FR-001–FR-005, FR-028, FR-029):
- Valid string → correct iKey (validated GUID), normalized ingestion + live endpoints.
- Case-insensitive keys; optional fields retained, not required.
- Each invalid variant (missing iKey, bad GUID, non-HTTPS, malformed URL, duplicate key, empty) →
  the matching `ConnectionStringError`, and the error's `description` contains **no** secret.
- Endpoint precedence: explicit → suffix-derived → default `https://dc.services.visualstudio.com/`.

---

## Envelope + BaseData extension seam

```swift
/// Signal modules conform their payloads to this seam; the core never depends on them.
public protocol BaseData: Sendable, Encodable {
  /// The Breeze baseType discriminator, e.g. "RequestData".
  static var baseType: String { get }
  // baseData.ver == 2 is enforced by the core envelope factory / encoder.
}

public struct Envelope: Sendable, Encodable {
  // ver (=1, omitted on wire by default), name, time, sampleRate, iKey, tags, data.
}

/// Stamps the common Part A fields around a caller-supplied payload (FR-007).
public struct EnvelopeFactory: Sendable {
  /// Takes the iKey string directly (NOT ConnectionConfiguration) so it is testable
  /// without the connection-string parser (US1). Callers pass `config.instrumentationKey`.
  public init(instrumentationKey: String, resourceTags: TelemetryTags)
  public func makeEnvelope<D: BaseData>(
    name: String,
    payload: D,
    time: Date,
    sampleRate: Double,
    itemTags: TelemetryTags?      // merged over resource tags
  ) -> Envelope
}
```

**Contract tests** (Acceptance #3; FR-006–FR-009, SC-004):
- A batch of N envelopes → exactly N `\n`-delimited single-line JSON objects.
- Field names/order match the Breeze wire contract; `ver` omitted; `baseData.ver` == 2.
- `time` serializes as UTC ISO-8601 with fractional seconds + `Z`, regardless of host TZ/locale.

---

## Resource / Part A tags

```swift
public struct TelemetryTags: Sendable, Encodable { /* [String: String] Part A tags */ }

public struct ResourceDetector: Sendable {
  /// Compute Part A tags once from OTel resource attributes + optional explicit overrides.
  /// Explicit overrides beat auto-detection (FR-020).
  public static func makeTags(
    resourceAttributes: [String: String],
    overrides: TelemetryTags?,
    sdkVersion: String
  ) -> TelemetryTags
}
```

**Contract tests** (Acceptance #10; FR-018–FR-021):
- `ai.cloud.role` == `[ns]/name` when namespace present, else `name`.
- `ai.cloud.roleInstance` == `service.instance.id` ?? host name.
- `ai.internal.sdkVersion` == `stout:<version>`.
- On-device `ai.device.*` / `ai.application.ver` populate when available.
- Override beats detection.

---

## Export pipeline

```swift
public struct ExporterConfiguration: Sendable {
  public init(
    bufferCapacity: Int = 2048,
    flushInterval: Duration = .seconds(5),
    maxBatchSize: Int = 512,
    shutdownDrainTimeout: Duration = .seconds(30),
    maxRetryAttempts: Int = 3,
    maxRetryDelay: Duration = .seconds(60)
  )
}

/// Independently constructable / injectable (FR-011). Not a global.
public actor ExportPipeline {
  public init(
    configuration: ExporterConfiguration,
    ingestionEndpoint: URL,          // from ConnectionConfiguration; a plain URL keeps the pipeline testable without US1
    transport: any Transport,
    diagnostics: any Diagnostics
  )
  /// Non-blocking submit. Drops on overflow / when inert (never throws into host) (FR-012/14/16).
  public nonisolated func submit(_ envelope: Envelope)
  /// Drain-and-go-inert. Idempotent; bounded by shutdownDrainTimeout (FR-015).
  public func shutdown() async
  /// Observability for self-diagnostics/tests.
  public var droppedCount: UInt64 { get }
}
```

**Contract tests** (Acceptance #4, #5, #6; FR-011–FR-017, SC-001/003/005):
- submit returns without awaiting network; flush on size AND on interval (partial batch).
- at capacity → drop + `droppedCount` increments exactly.
- shutdown flushes ≤ timeout, closes client, no hang; second shutdown no-op; post-shutdown submit
  dropped with exactly one diagnostics warning (no payload).

---

## Transport abstraction

See [transport.md](./transport.md) and [ingestion-wire.md](./ingestion-wire.md).

```swift
public protocol Transport: Sendable {
  func send(_ request: TransportRequest) async throws -> TransportResponse
}
```

## Diagnostics

```swift
/// Secret-free internal channel; never the user telemetry pipeline, never payload data (FR-028/16).
public protocol Diagnostics: Sendable {
  func warn(_ event: DiagnosticEvent)   // DiagnosticEvent carries NO secrets/payload
}
```
