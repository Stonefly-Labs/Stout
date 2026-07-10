// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

// Linux only. Apple platforms use URLSessionTransport (D9). The presence of
// FoundationNetworking is the compile-time selector for the Linux build.
#if canImport(FoundationNetworking)
  import AsyncHTTPClient
  import FoundationNetworking
  import NIOCore
  import NIOFoundationCompat
  import NIOHTTP1

  import struct Foundation.Data

  /// The Linux `Transport`, backed by `async-http-client` (D9). Foundation's
  /// `URLSession` on Linux is too limited for this workload, so the SSWG-standard
  /// client is used instead.
  public struct AsyncHTTPClientTransport: Transport {
    private let client: HTTPClient
    private let requestTimeout: TimeAmount
    /// Cap on the response body we will buffer, so a hostile/oversized reply can
    /// never exhaust memory (do-no-harm, FR-014/FR-031).
    private let maxResponseBytes: Int

    /// Create a transport over an `HTTPClient`. Defaults to a client on the shared
    /// singleton event-loop group; `shutdown()` releases it.
    public init(
      client: HTTPClient = HTTPClient(eventLoopGroupProvider: .singleton),
      requestTimeout: TimeAmount = .seconds(30),
      maxResponseBytes: Int = 10 * 1024 * 1024
    ) {
      self.client = client
      self.requestTimeout = requestTimeout
      self.maxResponseBytes = maxResponseBytes
    }

    public func send(_ request: TransportRequest) async throws -> TransportResponse {
      var httpRequest = HTTPClientRequest(url: request.url.absoluteString)
      httpRequest.method = Self.method(from: request.method)
      for (name, value) in request.headers {
        httpRequest.headers.add(name: name, value: value)
      }
      httpRequest.body = .bytes(ByteBuffer(bytes: request.body))

      let response = try await client.execute(httpRequest, timeout: requestTimeout)
      var headers: [String: String] = [:]
      for header in response.headers {
        headers[header.name] = header.value
      }
      let buffer = try await response.body.collect(upTo: maxResponseBytes)
      return TransportResponse(
        statusCode: Int(response.status.code),
        headers: headers,
        body: Data(buffer: buffer)
      )
    }

    public func shutdown() async {
      try? await client.shutdown()
    }

    private static func method(from raw: String) -> HTTPMethod {
      switch raw.uppercased() {
      case "POST": return .POST
      case "GET": return .GET
      case "PUT": return .PUT
      case "DELETE": return .DELETE
      default: return .RAW(value: raw)
      }
    }
  }
#endif
