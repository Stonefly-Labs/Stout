// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A single HTTP request to the Application Insights ingestion endpoint (D9,
/// FR-022/FR-023).
///
/// The **core** builds and compresses the body before constructing this value —
/// the transport is a thin sender that must not re-encode or auto-compress it.
public struct TransportRequest: Sendable {
  /// Absolute target URL, `{ingestionEndpoint}/v2.1/track`. Always HTTPS
  /// (non-HTTPS is rejected at configuration time, FR-029).
  public var url: URL
  /// HTTP method, `"POST"` for ingestion.
  public var method: String
  /// Request headers, including `Content-Type: application/x-json-stream` and
  /// `Content-Encoding: gzip` (and, later, auth).
  public var headers: [String: String]
  /// The gzip-compressed, newline-delimited JSON body produced by the core.
  public var body: Data

  public init(url: URL, method: String, headers: [String: String], body: Data) {
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
  }
}

/// The result of an ingestion request (FR-023/FR-024).
public struct TransportResponse: Sendable {
  /// HTTP status code (e.g. `200`, `206`, `429`).
  public var statusCode: Int
  /// Response headers, including `Retry-After` when the service supplies it.
  public var headers: [String: String]
  /// Raw response body, parsed downstream into an ingestion result.
  public var body: Data

  public init(statusCode: Int, headers: [String: String], body: Data) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }
}

/// The `Sendable` HTTP transport abstraction the pipeline depends on (D9).
///
/// Exactly one concrete implementation is compiled per platform —
/// `URLSessionTransport` on Apple, `AsyncHTTPClientTransport` on Linux — selected
/// with `#if canImport(FoundationNetworking)`. The pipeline and signal modules
/// depend only on this protocol, never on a concrete client.
///
/// - Important: Delivery failures (timeouts, connection errors) surface as
///   `throws` and are classified as retriable by the pipeline; they must never
///   propagate into the host (FR-031).
public protocol Transport: Sendable {
  /// Send one request and return its response, or throw on a delivery failure.
  func send(_ request: TransportRequest) async throws -> TransportResponse
}
