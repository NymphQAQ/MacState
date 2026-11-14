import Foundation
import SQLite3
import Testing
@testable import MacState

private func searchFixture(_ url: URL, count: Int = 250) throws -> DiskAnalysisStore {
    let store = try DiskAnalysisStore(url: url)
    try store.insert(DiskAnalysisEntry(path: "/fixture", name: "Fixture", directory: true, browsable: true, bytes: 10000, files: count), parent: nil)
    for i in 0..<count {
        try store.insert(DiskAnalysisEntry(path: "/fixture/file-\(i).txt", name: "file-\(i).txt", directory: false, bytes: UInt64(i), files: 1, kind: "text"), parent: "/fixture")
    }
    try store.finish(); return store
}

@Test func fastSearchPreservesLiteralNamesAndIncrementalChanges() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
    let store = try searchFixture(url)
    try store.prepareFastSearch()
    let names = ["中文文件.png", "a%_b.txt", "quote\"AND\".txt", "back\\slash.txt", "Café.txt", "REPORT.PDF", "🙂相片.png", "a\u{1}b.txt"]
    try store.transaction {
        for name in names {
            try store.insert(DiskAnalysisEntry(path: "/fixture/" + name, name: name, directory: false, bytes: 999, files: 1, kind: "image"), parent: "/fixture")
        }
    }
    for needle in ["中文文", "%_b", "\"AND\"", "back\\s", "Café", "report.pdf", "%_", "中文", "文", "fé", "🙂相", "a\u{1}"] {
        let page = try #require(try store.searchPage(requestID: "test", root: "/fixture", query: DiskFileQuery(text: needle), offset: 0))
        #expect(page.entries.count == 1, "Literal query: \(needle)")
    }
    #expect(try store.searchPage(requestID: "test", root: "/fixture", query: DiskFileQuery(text: "中文文", kind: "text"), offset: 0)?.entries.isEmpty == true)
    try store.transaction { try store.removeIndexedTree("/fixture/中文文件.png", root: "/fixture") }
    #expect(try store.searchPage(requestID: "test", root: "/fixture", query: DiskFileQuery(text: "中文文"), offset: 0)?.entries.isEmpty == true)
    let reopened = try DiskAnalysisStore(url: url, existing: true)
    #expect(try reopened.metadata("fastSearch") == "3")
    #expect(try reopened.searchPage(requestID: "test", root: "/fixture", query: DiskFileQuery(text: "report.pdf"), offset: 0)?.entries.count == 1)
    try store.transaction { try store.execute("UPDATE file_records SET name='renamed-photo.png' WHERE dir_id=(SELECT id FROM directory_paths WHERE path='/fixture') AND name='REPORT.PDF'") }
    #expect(try store.searchPage(requestID: "test", root: "/fixture", query: DiskFileQuery(text: "report.pdf"), offset: 0)?.entries.isEmpty == true)
    #expect(try store.searchPage(requestID: "test", root: "/fixture", query: DiskFileQuery(text: "renamed-photo"), offset: 0)?.entries.count == 1)
    do {
        try store.transaction {
            try store.insert(DiskAnalysisEntry(path: "/fixture/rolled-back", name: "rolled-back", directory: false, bytes: 0), parent: "/fixture")
            throw DiskAnalysisStore.Failure(message: "fixture rollback")
        }
    } catch {}
    #expect(try store.searchPage(requestID: "test", root: "/fixture", query: DiskFileQuery(text: "rolled-back"), offset: 0)?.entries.isEmpty == true)
    try store.execute("INSERT INTO search_fts(search_fts,rank) VALUES('integrity-check',1)")
}

@Test func fastSearchPaginatesWithoutCountingOrSortingAllMatches() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
    let store = try searchFixture(url)
    var found = Set<String>()
    for offset in [0, 100, 200] {
        let page = try #require(try store.searchPage(requestID: "test", root: "/fixture", query: DiskFileQuery(text: "file-"), offset: offset))
        #expect(page.entries.count == (offset == 200 ? 50 : 100))
        #expect(page.countIsExact == (offset == 200))
        #expect(page.entryCount == (offset == 200 ? 250 : offset + 101))
        for entry in page.entries { #expect(found.insert(entry.path).inserted) }
    }
    #expect(found.count == 250)
    let token = DiskScanCancellation(); token.cancel()
    #expect(try store.searchPage(requestID: "cancelled", root: "/fixture", query: DiskFileQuery(text: "missing"), offset: 0, cancellation: token) == nil)
}

@Test func fastSearchWALReaderDoesNotWaitForWriterLock() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
    let store = try searchFixture(url)
    _ = try store.searchPage(requestID: "warm", root: "/fixture", query: DiskFileQuery(text: "file-"), offset: 0)
    let locked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { done.signal() }
        store.withLock { locked.signal(); _ = release.wait(timeout: .now() + 5) }
    }
    try #require(locked.wait(timeout: .now() + 2) == .success)
    defer { release.signal(); _ = done.wait(timeout: .now() + 5) }
    let started = Date()
    let page = try store.searchPage(requestID: "read", root: "/fixture", query: DiskFileQuery(text: "file-249"), offset: 0)
    #expect(page?.entries.count == 1)
    #expect(Date().timeIntervalSince(started) < 1)
}

@Test func initialBulkWriterDefersSizeIndexesUntilFinish() throws {
    let store = try DiskAnalysisStore(deferSizeIndexes: true)
    func hasSizeIndex() throws -> Bool {
        let q = try store.prepare("SELECT 1 FROM sqlite_master WHERE name='children_by_size'")
        defer { sqlite3_finalize(q) }; return sqlite3_step(q) == SQLITE_ROW
    }
    #expect(try !hasSizeIndex())
    try store.insert(DiskAnalysisEntry(path: "/fixture", name: "Fixture", directory: true, browsable: true, bytes: 0), parent: nil)
    try store.insert(DiskAnalysisEntry(path: "/fixture/small", name: "small", directory: false, bytes: 10), parent: "/fixture")
    try store.insert(DiskAnalysisEntry(path: "/fixture/big", name: "big", directory: false, bytes: 100), parent: "/fixture")
    try store.finish()
    #expect(try hasSizeIndex())
    #expect(try store.children(path: "/fixture", offset: 0).map(\.name) == ["big", "small"])
}

@Test func diskSortingOrdersWholeResultsBeforePagination() throws {
    let store = try DiskAnalysisStore()
    try store.insert(DiskAnalysisEntry(path: "/sort", name: "Sort", directory: true, browsable: true, bytes: 99999, files: 205), parent: nil, childCount: 205)
    for i in (0..<205).reversed() {
        let name = String(format: "item-%03d", i)
        try store.insert(DiskAnalysisEntry(path: "/sort/" + name, name: name, directory: false, bytes: UInt64(205-i), files: 1,
            logicalBytes: UInt64(i+1), modified: Double(i), kind: i < 100 ? "audio" : "video"), parent: "/sort")
    }
    try store.finish();try store.prepareFastSearch()
    for key in ["name", "size", "modified", "kind", "path"] {
        for descending in [false, true] {
            let sort = DiskFileSort(key: key, descending: descending)
            let query = DiskFileQuery(text: "item-", sort: sort)
            let first = try #require(try store.searchPage(requestID: "sort", root: "/sort", query: query, offset: 0))
            let second = try #require(try store.searchPage(requestID: "sort", root: "/sort", query: query, offset: 100))
            let third = try #require(try store.searchPage(requestID: "sort", root: "/sort", query: query, offset: 200))
            let rows = first.entries + second.entries + third.entries
            #expect(rows.count == 205 && Set(rows.map(\.path)).count == 205)
            #expect(first.sortKey == key && first.sortDescending == descending)
            let values = rows.map { row -> String in key == "path" ? row.path : key == "kind" ? row.kind : row.name }
            if key == "size" {
                let actual = rows.map(\.logicalBytes)
                let expected = actual.sorted { descending ? $0 > $1 : $0 < $1 }
                #expect(actual == expected)
            } else if key == "modified" {
                let actual = rows.map(\.modified)
                let expected = actual.sorted { descending ? $0 > $1 : $0 < $1 }
                #expect(actual == expected)
            } else {
                let expected = values.sorted { descending ? $0 > $1 : $0 < $1 }
                #expect(values == expected)
            }
            let children = try store.children(path: "/sort", offset: 0, sort: sort)
            #expect(children.map(\.path) == first.entries.map(\.path))
        }
    }
    #expect(DiskFileSort(key: "name; DROP TABLE file_records").key.isEmpty)
}
