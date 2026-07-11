// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi

/// Database-span derivation for `RemoteDependencyData` over current + legacy
/// semantic-convention keys (data-model §5, research.md D-04), used by the
/// Dependency path (US2). Pure and deterministic: the current key wins over its
/// legacy alias regardless of attribute order (INV-3).
///
/// A span is a "DB" span when it carries `db.system`. Generic keys (`server.address`
/// etc.) do **not** classify a span as DB on their own — HTTP/RPC spans use them too
/// — so `derive` returns `nil` for a non-DB span and the caller falls through to the
/// next protocol mapper.
struct DBMapping: Sendable {
  /// Dependency `type` — the `db.system` value, except SQL-Server variants which map
  /// to `"SQL"` (.NET parity, D-04).
  let type: String
  /// Dependency `target` — the DB server host, or `"{host} | {dbName}"` when a
  /// database name is present, else the database name alone.
  let target: String?
  /// Dependency `data` — the DB statement (`db.query.text` / legacy `db.statement`).
  let data: String?
  /// The semantic-convention keys this derivation consumed. The database *name*
  /// (`db.namespace`/`db.name`) is deliberately **not** consumed — it is folded into
  /// `target` yet also left in `properties` (D-04).
  let consumedKeys: [String]

  /// SQL-Server `db.system` values that map to the Breeze `"SQL"` category.
  private static let sqlServerSystems: Set<String> = ["mssql", "microsoft.sql_server"]

  /// Derive DB dependency fields, or `nil` when the span carries no `db.system`.
  static func derive(from attributes: [String: AttributeValue]) -> DBMapping? {
    guard
      let system = SemanticConventions.firstString(
        in: attributes, [SemanticConventions.dbSystem])
    else { return nil }

    let type = sqlServerSystems.contains(system.lowercased()) ? "SQL" : system

    let host = SemanticConventions.firstString(in: attributes, SemanticConventions.host)
    let dbName = SemanticConventions.firstString(in: attributes, SemanticConventions.dbName)
    let target: String?
    if let host {
      target = dbName.map { "\(host) | \($0)" } ?? host
    } else {
      target = dbName
    }

    let data = SemanticConventions.firstString(in: attributes, SemanticConventions.dbStatement)

    // `db.system`, the winning/legacy host keys, and the statement keys are consumed;
    // the db-name keys are intentionally left in `properties` (D-04).
    var consumed = [SemanticConventions.dbSystem]
    consumed += SemanticConventions.presentKeys(
      in: attributes, SemanticConventions.host + SemanticConventions.dbStatement)

    return DBMapping(type: type, target: target, data: data, consumedKeys: consumed)
  }
}
