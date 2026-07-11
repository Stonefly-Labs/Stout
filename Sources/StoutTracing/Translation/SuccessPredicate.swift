// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi

/// The success / `responseCode` / `resultCode` rules, reconciled to the **actual**
/// .NET `TraceHelper` behavior (data-model §4, research.md D-03; maintainer-confirmed
/// 2026-07-10). Authoritative for the golden tests.
///
/// The two item families differ deliberately:
///
/// - **Request** (server/consumer): an *unset* status on an HTTP span is judged by
///   the status code — `success = code != 0 && code < 400`, so **4xx and 5xx both
///   fail**. A non-HTTP span, or any non-unset status, falls through to
///   `status != .error`.
/// - **Dependency** (client/producer/internal): `success = (status != .error)`
///   **only** — there is no HTTP/gRPC code threshold. A dependency HTTP 4xx/5xx with
///   an unset status is a **success**.
///
/// In both families an explicit `.error` status forces `success = false` regardless
/// of any protocol code.
enum SuccessPredicate {
  /// Request-side success. `httpStatusCode` is the parsed HTTP status when the span
  /// is an HTTP request, else `nil`.
  static func requestSuccess(status: Status, httpStatusCode: Int?) -> Bool {
    if status.isError { return false }
    // Only an *unset* status on an HTTP span defers to the code threshold; an
    // explicit `.ok` (or a non-HTTP span) is already a success here.
    if case .unset = status, let code = httpStatusCode {
      return code != 0 && code < 400
    }
    return true
  }

  /// Dependency-side success: purely `status != .error` (no code threshold).
  static func dependencySuccess(status: Status) -> Bool {
    !status.isError
  }

  /// The `responseCode`/`resultCode` wire string: the resolved protocol status
  /// string (HTTP/gRPC/DB), or the `"0"` default when none — never omitted where
  /// the schema requires it (data-model §4).
  static func codeString(_ protocolCode: String?) -> String {
    protocolCode ?? "0"
  }
}
