# Contract: Transport Abstraction (D9)

**Feature**: 001-core-ingestion-foundation · **Module**: `StoutCore`

One `Sendable` transport protocol; two implementations selected at compile time via
`#if canImport(FoundationNetworking)` (FR-022, design D9). The pipeline and signal modules depend
**only on the protocol**, never on a concrete client.

```swift
public struct TransportRequest: Sendable {
  public var url: URL            // {ingestionEndpoint}/v2.1/track
  public var method: String      // "POST"
  public var headers: [String: String]  // Content-Type + Content-Encoding (+ later auth)
  public var body: Data          // gzip-compressed newline-JSON (compressed by the CORE)
}

public struct TransportResponse: Sendable {
  public var statusCode: Int
  public var headers: [String: String]   // includes Retry-After when present
  public var body: Data
}

public protocol Transport: Sendable {
  func send(_ request: TransportRequest) async throws -> TransportResponse
}
```

## Implementations

| Platform selector | Implementation | Notes |
|---|---|---|
| `#if canImport(FoundationNetworking)` **false** (Apple) | `URLSessionTransport` | Foundation `URLSession`; async `data(for:)`. Background-session upload is deferred (FR-034), behind this same protocol. |
| `#if canImport(FoundationNetworking)` **true** (Linux) | `AsyncHTTPClientTransport` | `async-http-client`; Linux-only conditional dependency. |

## Invariants / requirements

- The **core gzips the request body itself** before calling `send` — neither transport
  auto-compresses request bodies (FR-010/FR-023). The transport sets no compression itself.
- HTTPS-only; a non-HTTPS URL never reaches `send` (rejected at config time, FR-029).
- `send` errors (timeouts, connection failures) surface as `throws` and are classified as retriable
  by the pipeline (FR-025) — they never propagate into the host (FR-031).
- `Sendable`-clean under Swift 6 strict concurrency on **both** backends (FR-030, SC-007).

## Contract tests (Acceptance #7, #12; SC-007)

- POST to `{ingestionEndpoint}/v2.1/track` with method `POST`, `Content-Type: application/x-json-stream`,
  `Content-Encoding: gzip`, body = gzip bytes.
- A fully-accepted (200) response → treated as success by the pipeline.
- Exercised against a **mock** `Transport` in unit tests (no network), and both concrete backends
  compile + run on their platform (Apple via iOS Simulator/macOS, Linux).
