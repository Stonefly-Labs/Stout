// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import StoutCore

// MARK: - Test payload

/// A minimal `BaseData` payload for exercising the envelope/pipeline seam.
struct TestData: BaseData {
  static var baseType: String { "TestData" }
  let ver = 2
  let message: String
}

// MARK: - Mock transport

/// A recording, controllable `Transport`. Captures every request, returns a
/// configurable status, and can stall (to exercise backpressure) until released.
actor MockTransport: Transport {
  private(set) var requests: [TransportRequest] = []
  private(set) var shutdownCalled = false
  private var statusCode: Int
  private var responseBody: Data
  private var stall = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(statusCode: Int = 200, responseBody: Data = Data()) {
    self.statusCode = statusCode
    self.responseBody = responseBody
  }

  func send(_ request: TransportRequest) async throws -> TransportResponse {
    requests.append(request)
    if stall {
      await withCheckedContinuation { waiters.append($0) }
    }
    return TransportResponse(statusCode: statusCode, headers: [:], body: responseBody)
  }

  func shutdown() async {
    shutdownCalled = true
  }

  // MARK: Controls / observation

  func setStall(_ value: Bool) {
    stall = value
    if !value {
      let pending = waiters
      waiters.removeAll()
      for waiter in pending { waiter.resume() }
    }
  }

  var requestCount: Int { requests.count }

  /// Total envelope lines received across all requests (decompresses each body).
  func totalEnvelopes() -> Int {
    requests.reduce(0) { partial, request in
      partial + ((try? Self.envelopeLines(request.body).count) ?? 0)
    }
  }

  /// gunzip a request body and split into newline-delimited envelope lines.
  static func envelopeLines(_ body: Data) throws -> [String] {
    let inflated = try gunzip([UInt8](body))
    guard let text = String(bytes: inflated, encoding: .utf8), !text.isEmpty else {
      return []
    }
    return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }
}

// MARK: - Recording diagnostics

/// A thread-safe `Diagnostics` sink that records events for assertions.
final class RecordingDiagnostics: Diagnostics, @unchecked Sendable {
  // @unchecked is justified: all mutable state is guarded by `lock`. Test-only.
  private let lock = NSLock()
  private var storage: [DiagnosticEvent] = []

  func report(_ event: DiagnosticEvent) {
    lock.lock()
    storage.append(event)
    lock.unlock()
  }

  var events: [DiagnosticEvent] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

// MARK: - Async polling

extension XCTestCase {
  /// Poll `condition` until it is true or the timeout elapses. Used because
  /// `submit` is fire-and-forget, so effects appear asynchronously.
  func waitUntil(
    timeout: TimeInterval = 2.0,
    pollInterval: TimeInterval = 0.01,
    _ condition: @Sendable () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
    let finalResult = await condition()
    XCTAssertTrue(finalResult, "waitUntil timed out after \(timeout)s", file: file, line: line)
  }
}
