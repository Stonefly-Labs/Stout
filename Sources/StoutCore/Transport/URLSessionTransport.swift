// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

// Apple platforms only. Linux uses AsyncHTTPClientTransport (D9).
#if !canImport(FoundationNetworking)
  import Foundation

  /// The Apple-platform `Transport`, backed by Foundation `URLSession` (D9).
  ///
  /// Uses the completion-handler `dataTask` bridged to `async` via a checked
  /// continuation so it runs on the full platform floor (iOS 13+), where the
  /// `async` `data(for:)` API is not yet available.
  public struct URLSessionTransport: Transport {
    private let session: URLSession

    /// Create a transport over a session. Defaults to a dedicated ephemeral
    /// session (owned by this transport, invalidated on `shutdown()`).
    public init(session: URLSession? = nil) {
      self.session = session ?? URLSession(configuration: .ephemeral)
    }

    public func send(_ request: TransportRequest) async throws -> TransportResponse {
      var urlRequest = URLRequest(url: request.url)
      urlRequest.httpMethod = request.method
      urlRequest.httpBody = request.body
      for (name, value) in request.headers {
        urlRequest.setValue(value, forHTTPHeaderField: name)
      }

      return try await withCheckedThrowingContinuation { continuation in
        let task = session.dataTask(with: urlRequest) { data, response, error in
          if let error {
            continuation.resume(throwing: error)
            return
          }
          guard let http = response as? HTTPURLResponse else {
            continuation.resume(throwing: TransportError.nonHTTPResponse)
            return
          }
          var headers: [String: String] = [:]
          for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
              headers[key] = value
            }
          }
          continuation.resume(
            returning: TransportResponse(
              statusCode: http.statusCode,
              headers: headers,
              body: data ?? Data()
            )
          )
        }
        task.resume()
      }
    }

    public func shutdown() async {
      session.finishTasksAndInvalidate()
    }
  }
#endif
