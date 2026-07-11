// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetryApi
import XCTest

@testable import StoutTracing

/// User Story 2 — DB `.client` dependency mapping (US2 Acc 3, FR-013–015). Drives
/// `DBMapping` directly and through the full `RemoteDependencyData` build so the
/// current+legacy key precedence and the `properties` carriage are both asserted.
final class DBMappingTests: XCTestCase {
  func testDBTypeTargetAndDataFromCurrentKeys() {
    let db = DBMapping.derive(from: [
      SemanticConventions.dbSystem: .string("postgresql"),
      SemanticConventions.serverAddress: .string("db.internal"),
      SemanticConventions.dbNamespace: .string("orders"),
      SemanticConventions.dbQueryText: .string("SELECT 1"),
    ])

    XCTAssertEqual(db?.type, "postgresql")
    XCTAssertEqual(db?.target, "db.internal | orders")
    XCTAssertEqual(db?.data, "SELECT 1")
  }

  func testLegacyKeysAreRead() {
    let db = DBMapping.derive(from: [
      SemanticConventions.dbSystem: .string("mysql"),
      SemanticConventions.netPeerNameLegacy: .string("mysql.internal"),
      SemanticConventions.dbNameLegacy: .string("shop"),
      SemanticConventions.dbStatementLegacy: .string("SELECT 2"),
    ])

    XCTAssertEqual(db?.type, "mysql")
    XCTAssertEqual(db?.target, "mysql.internal | shop")
    XCTAssertEqual(db?.data, "SELECT 2")
  }

  func testCurrentKeyWinsOverLegacyRegardlessOfOrder() {
    let db = DBMapping.derive(from: [
      SemanticConventions.dbSystem: .string("postgresql"),
      SemanticConventions.dbQueryText: .string("CURRENT"),
      SemanticConventions.dbStatementLegacy: .string("LEGACY"),
    ])
    XCTAssertEqual(db?.data, "CURRENT")
  }

  func testSqlServerVariantsMapToSQL() {
    XCTAssertEqual(
      DBMapping.derive(from: [SemanticConventions.dbSystem: .string("mssql")])?.type, "SQL")
    XCTAssertEqual(
      DBMapping.derive(from: [SemanticConventions.dbSystem: .string("microsoft.sql_server")])?.type,
      "SQL")
  }

  func testNonDBSpanReturnsNil() {
    XCTAssertNil(DBMapping.derive(from: [SemanticConventions.serverAddress: .string("host")]))
  }

  func testDBNameStaysInPropertiesEvenWhenFoldedIntoTarget() {
    let span = SpanDataBuilder(
      kind: .client,
      attributes: [
        SemanticConventions.dbSystem: .string("postgresql"),
        SemanticConventions.serverAddress: .string("db.internal"),
        SemanticConventions.dbNamespace: .string("orders"),
        SemanticConventions.dbQueryText: .string("SELECT 1"),
      ]
    ).build()

    let data = DependencyMapping.remoteDependencyData(for: span)
    XCTAssertEqual(data.type, "postgresql")
    XCTAssertEqual(data.target, "db.internal | orders")
    XCTAssertEqual(data.data, "SELECT 1")
    // db name is folded into `target` yet still surfaced in `properties` (D-04).
    XCTAssertEqual(data.properties[SemanticConventions.dbNamespace], "orders")
    // system, host, and statement are consumed — not in properties.
    XCTAssertNil(data.properties[SemanticConventions.dbSystem])
    XCTAssertNil(data.properties[SemanticConventions.serverAddress])
    XCTAssertNil(data.properties[SemanticConventions.dbQueryText])
  }
}
