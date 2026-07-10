// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

/// The extension seam for signal-specific Breeze payloads (FR-007).
///
/// Each sibling signal module (`StoutTracing`, `StoutLogging`, `StoutMetrics`,
/// specs 02–04) conforms its own payload types — `RequestData`,
/// `RemoteDependencyData`, `MessageData`, `ExceptionData`, `MetricData` — to
/// this protocol. `StoutCore` stamps the surrounding envelope without ever
/// depending on those concrete types, which keeps the module graph acyclic and
/// the seam stable.
///
/// - Note: On the wire, a Breeze `baseData` object always carries `"ver": 2`.
///   Conforming payload types are responsible for encoding that field; the core
///   envelope encoder and golden tests (spec US2) assert it.
public protocol BaseData: Sendable, Encodable {
  /// The Breeze `baseType` discriminator for this payload, e.g. `"RequestData"`.
  /// Written into the envelope's `data.baseType`.
  static var baseType: String { get }
}
