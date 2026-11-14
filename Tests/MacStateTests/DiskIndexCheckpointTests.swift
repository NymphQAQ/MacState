import Foundation
import SQLite3
import Testing
@testable import MacState

private func checkpointScalar(_ database: OpaquePointer?, _ sql: String) throws -> Int64 {
    var statement: OpaquePointer?
    try #require(sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    try #require(sqlite3_step(statement) == SQLITE_ROW)
    return sqlite3_column_int64(statement, 0)
}

private func checkpointWALSize(_ url: URL) throws -> Int64 {
    try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).int64Value
}

@Test func checkpointInitializesFreshMaintenanceConnectionAndPersistsCommittedPages() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("index.sqlite")
    var writer: OpaquePointer?
    try #require(sqlite3_open(url.path, &writer) == SQLITE_OK)
    defer { sqlite3_close(writer) }
    try #require(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE sample(value INTEGER); INSERT INTO sample VALUES(42);", nil, nil, nil) == SQLITE_OK)
    let maintenance = try DiskIndexCheckpoint(url: url)
    maintenance.request(); maintenance.stop()

    // Immutable reads ignore WAL, so this checks the actual database pages.
    var persisted: OpaquePointer?
    try #require(sqlite3_open_v2(url.absoluteString + "?immutable=1", &persisted, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK)
    defer { sqlite3_close(persisted) }
    #expect(try checkpointScalar(persisted, "SELECT value FROM sample") == 42)
}

@Test func checkpointRetainsPinnedSnapshotThenReclaimsLargeWALWithoutLosingLatestCommit() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("index.sqlite")
    let wal = URL(fileURLWithPath: url.path + "-wal")
    var writer: OpaquePointer?, reader: OpaquePointer?
    try #require(sqlite3_open(url.path, &writer) == SQLITE_OK)
    defer { sqlite3_close(writer) }
    try #require(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA synchronous=NORMAL; CREATE TABLE sample(version INTEGER,payload BLOB); INSERT INTO sample VALUES(1,zeroblob(1048576));", nil, nil, nil) == SQLITE_OK)
    try #require(sqlite3_open_v2(url.path, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { sqlite3_close(reader) }
    try #require(sqlite3_exec(reader, "BEGIN; SELECT version FROM sample;", nil, nil, nil) == SQLITE_OK)
    for version in 2...68 {
        try #require(sqlite3_exec(writer, "UPDATE sample SET version=\(version),payload=randomblob(1048576);", nil, nil, nil) == SQLITE_OK)
    }
    let before = try checkpointWALSize(wal)
    try #require(before > 64 * 1024 * 1024)
    let truncated = DispatchSemaphore(value: 0)
    let pinned = try DiskIndexCheckpoint(url: url) { truncated.signal() }
    pinned.request(); pinned.stop()
    #expect(truncated.wait(timeout: .now()) == .timedOut)
    #expect(try checkpointScalar(reader, "SELECT version FROM sample") == 1)
    #expect(try checkpointScalar(writer, "SELECT version FROM sample") == 68)
    #expect(try checkpointWALSize(wal) == before)
    try #require(sqlite3_exec(reader, "COMMIT;", nil, nil, nil) == SQLITE_OK)

    let retry = try DiskIndexCheckpoint(url: url) { truncated.signal() }
    retry.request(); retry.stop()
    #expect(truncated.wait(timeout: .now()) == .success)
    #expect(try checkpointWALSize(wal) == 0)
    #expect(try checkpointScalar(reader, "SELECT version FROM sample") == 68)
    #expect(try checkpointScalar(reader, "SELECT length(payload) FROM sample") == 1048576)
}
