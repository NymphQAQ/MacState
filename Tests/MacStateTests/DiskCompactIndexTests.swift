import Foundation
import SQLite3
import Testing
@testable import MacState

private func legacyFixture(_ base: URL) throws -> URL {
    let compact = base.appendingPathComponent("fixture.sqlite")
    do {
        let store = try DiskAnalysisStore(url: compact)
        try store.insert(DiskAnalysisEntry(path: "/fixture", name: "Custom Volume Label", directory: true,
            browsable: true, bytes: 43210, files: 2, skipped: 3, pending: true, note: "root note",
            logicalBytes: 321, allocatedBytes: 4096, modified: 12.25, created: 3.5,
            fileExtension: "", kind: "folder", device: 9, inode: 1, links: 2), parent: nil, childCount: 2, pending: 4)
        try store.insert(DiskAnalysisEntry(path: "/fixture/文%_件.bin", name: "文%_件.bin", directory: false,
            bytes: 32768, files: 1, skipped: 1, note: "restricted sample", logicalBytes: 12345,
            allocatedBytes: 32768, modified: 100.125, created: 50.25, fileExtension: "bin",
            kind: "other", device: 9, inode: 10, links: 3), parent: "/fixture")
        try store.insert(DiskAnalysisEntry(path: "/fixture/zero.txt", name: "zero.txt", directory: false,
            bytes: 0, files: 1, logicalBytes: 0, allocatedBytes: 0, kind: "text"), parent: "/fixture")
        try store.setMetadata("schema", "1"); try store.setMetadata("root", "/fixture")
        try store.setMetadata("cursor", "987654"); try store.setMetadata("eventsUUID", "original-events")
        try store.setMetadata("completedAt", "123456.75"); try store.setMetadata("directories", "1")
        try store.enqueue(path: "/fixture/waiting", depth: 2, priority: true)
        try store.finish()
    }
    let legacy = base.appendingPathComponent("legacy.sqlite")
    var db: OpaquePointer?
    try #require(sqlite3_open(legacy.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    var attach: OpaquePointer?
    try #require(sqlite3_prepare_v2(db, "ATTACH DATABASE ? AS source", -1, &attach, nil) == SQLITE_OK)
    compact.path.withCString { _ = sqlite3_bind_text(attach, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    let status = sqlite3_step(attach); sqlite3_finalize(attach)
    try #require(status == SQLITE_DONE)
    try #require(sqlite3_exec(db, "CREATE TABLE entries AS SELECT * FROM source.entries; CREATE UNIQUE INDEX entry_path ON entries(path); CREATE TABLE metadata AS SELECT * FROM source.metadata; CREATE TABLE jobs AS SELECT * FROM source.jobs;", nil, nil, nil) == SQLITE_OK)
    return legacy
}

@Test func compactMigrationPreservesEveryAttributeRootLabelQueueAndEventCursor() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let legacy = try legacyFixture(base)
    try Data("interrupted staging database".utf8).write(to: URL(fileURLWithPath: legacy.path + ".compact-pending"))
    let store = try DiskAnalysisStore(url: legacy, existing: true)
    let root = try #require(try store.directory(path: "/fixture"))
    #expect(root.entry.name == "Custom Volume Label" && root.parent == nil)
    #expect(root.entry.bytes == 43210 && root.entry.files == 2 && root.entry.skipped == 3)
    #expect(root.entry.pending && root.childCount == 2 && root.entry.note == "root note")
    let file = try #require(try store.indexedEntry("/fixture/文%_件.bin"))
    #expect(file.logicalBytes == 12345 && file.allocatedBytes == 32768 && file.bytes == 32768)
    #expect(file.modified == 100.125 && file.created == 50.25 && file.fileExtension == "bin")
    #expect(file.device == 9 && file.inode == 10 && file.links == 3 && file.skipped == 1)
    #expect(try store.metadata("cursor") == "987654")
    #expect(try store.metadata("eventsUUID") == "original-events")
    #expect(try store.metadata("completedAt") == "123456.75")
    #expect(try store.nextJob(priorityOnly: true)?.path == "/fixture/waiting")
    #expect(try store.searchPage(requestID: "migrated", root: "/fixture", query: .init(text: "文%_"), offset: 0)?.entries.first?.path == file.path)
    #expect(try store.children(path: "/fixture", offset: 0).map(\.name) == ["文%_件.bin", "zero.txt"])
    #expect(!FileManager.default.fileExists(atPath: legacy.path + ".compact-pending"))
    let again = try DiskAnalysisStore(url: legacy, existing: true)
    #expect(try again.metadata("fastSearch") == "3")
    #expect(try again.directory(path: "/fixture")?.entry.bytes == 43210)
}

@Test func compactMigrationFailsSafelyWhenLegacySchemaCannotBeCopied() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let legacy = base.appendingPathComponent("invalid.sqlite")
    var db: OpaquePointer?
    try #require(sqlite3_open(legacy.path, &db) == SQLITE_OK)
    try #require(sqlite3_exec(db, "CREATE TABLE entries(path TEXT); INSERT INTO entries VALUES('/must-survive');", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    #expect(throws: (any Error).self) { _ = try DiskAnalysisStore(url: legacy, existing: true) }
    try #require(sqlite3_open(legacy.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    var q: OpaquePointer?
    try #require(sqlite3_prepare_v2(db, "SELECT path FROM entries", -1, &q, nil) == SQLITE_OK)
    defer { sqlite3_finalize(q) }
    try #require(sqlite3_step(q) == SQLITE_ROW)
    #expect(String(cString: sqlite3_column_text(q, 0)) == "/must-survive")
    #expect(!FileManager.default.fileExists(atPath: legacy.path + ".compact-pending"))
}

@Test func compactSubtreeDeletionPreservesPrefixSiblingsAndSearch() throws {
    let store = try DiskAnalysisStore()
    try store.insert(DiskAnalysisEntry(path: "/", name: "Disk", directory: true, browsable: true, bytes: 500, files: 2), parent: nil)
    for directory in ["a_%", "a_%more"] {
        try store.insert(DiskAnalysisEntry(path: "/" + directory, name: directory, directory: true, browsable: true, bytes: 250, files: 1), parent: "/", childCount: 1)
        try store.insert(DiskAnalysisEntry(path: "/" + directory + "/你好.txt", name: "你好.txt", directory: false, bytes: 250, files: 1, kind: "text"), parent: "/" + directory)
    }
    try store.finish(); try store.prepareFastSearch()
    try store.transaction { try store.removeIndexedTree("/a_%", root: "/") }
    #expect(!store.contains(path: "/a_%/你好.txt"))
    #expect(store.contains(path: "/a_%more/你好.txt"))
    #expect(try store.directory(path: "/")?.entry.bytes == 250)
    #expect(try store.searchPage(requestID: "after-delete", root: "/", query: .init(text: "你好"), offset: 0)?.entries.map(\.path) == ["/a_%more/你好.txt"])
    try store.transaction {
        try store.insert(DiskAnalysisEntry(path: "/a_%", name: "a_%", directory: true, browsable: true, bytes: 0), parent: "/")
        try store.insert(DiskAnalysisEntry(path: "/a_%/new.png", name: "new.png", directory: false, bytes: 10, files: 1, kind: "image"), parent: "/a_%")
    }
    #expect(try store.searchPage(requestID: "reinsert", root: "/", query: .init(text: "new"), offset: 0)?.entries.first?.path == "/a_%/new.png")
}

@Test func compactMigrationKeepsOriginalWhileAnotherWriterIsActive() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let legacy = try legacyFixture(base)
    var writer: OpaquePointer?
    try #require(sqlite3_open(legacy.path, &writer) == SQLITE_OK)
    defer { sqlite3_close(writer) }
    try #require(sqlite3_exec(writer, "BEGIN IMMEDIATE; UPDATE metadata SET value='busy-writer' WHERE key='eventsUUID';", nil, nil, nil) == SQLITE_OK)
    #expect(throws: (any Error).self) { _ = try DiskAnalysisStore(url: legacy, existing: true) }
    try #require(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
    var q: OpaquePointer?
    try #require(sqlite3_prepare_v2(writer, "SELECT type FROM sqlite_master WHERE name='entries'", -1, &q, nil) == SQLITE_OK)
    try #require(sqlite3_step(q) == SQLITE_ROW)
    #expect(String(cString: sqlite3_column_text(q, 0)) == "table")
    sqlite3_finalize(q); sqlite3_close(writer); writer = nil
    let migrated = try DiskAnalysisStore(url: legacy, existing: true)
    #expect(try migrated.metadata("eventsUUID") == "original-events")
}

@Test func compactLargestFilesRetainsPathOrderingAcrossEqualSizes() throws {
    let store = try DiskAnalysisStore()
    try store.insert(.init(path: "/fixture", name: "Disk", directory: true, browsable: true, bytes: 6000), parent: nil)
    for i in (0..<60).reversed() {
        let directory = String(format: "/fixture/%03d", i)
        try store.insert(.init(path: directory, name: String(format: "%03d", i), directory: true, browsable: true, bytes: 100), parent: "/fixture")
        try store.insert(.init(path: directory + "/equal.dat", name: "equal.dat", directory: false, bytes: 100, files: 1), parent: directory)
    }
    try store.finish()
    let expected = (0..<50).map { String(format: "/fixture/%03d/equal.dat", $0) }
    #expect(try store.largestFiles().map(\.path) == expected)
}
