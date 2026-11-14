import Foundation
import Darwin
import SQLite3
import Testing
@testable import MacState

/// Opt-in, local-only snapshot benchmark; never changes the user's live index.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACSTATE_SEARCH_BENCH_SOURCE"] != nil))
func realVolumeSearchSnapshotBenchmark() throws {
    let sourcePath = try #require(ProcessInfo.processInfo.environment["MACSTATE_SEARCH_BENCH_SOURCE"])
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macstate-search-bench-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("snapshot.sqlite")
    var source: OpaquePointer?, target: OpaquePointer?
    try #require(sqlite3_open_v2(sourcePath, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { sqlite3_close(source) }
    sqlite3_exec(source, "BEGIN; SELECT value FROM metadata LIMIT 1;", nil, nil, nil)
    try #require(sqlite3_open(destination.path, &target) == SQLITE_OK)
    let backup = try #require(sqlite3_backup_init(target, "main", source, "main"))
    var status: Int32 = SQLITE_OK
    let copyStart = Date()
    repeat {
        status = sqlite3_backup_step(backup, 2048)
        if status == SQLITE_BUSY || status == SQLITE_LOCKED { usleep(10000) }
    } while (status == SQLITE_OK || status == SQLITE_BUSY || status == SQLITE_LOCKED) && Date().timeIntervalSince(copyStart) < 120
    sqlite3_backup_finish(backup); sqlite3_close(target)
    try #require(status == SQLITE_DONE)
    sqlite3_exec(source, "ROLLBACK", nil, nil, nil)
    func diskBytes() throws -> Int64 { (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0 }
    let beforeBytes = try diskBytes()
    let needles = ["disk-analysis.js", ".png", "macstate_missing_search_9a4f2", "微信", "zz"]
    var previousTimes: [String: [Double]] = [:]
    var expectedLargest: [String] = []
    do {
        var old: OpaquePointer?
        try #require(sqlite3_open_v2(destination.path, &old, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(old) }
        try #require(sqlite3_wal_checkpoint_v2(old,nil,SQLITE_CHECKPOINT_TRUNCATE,nil,nil) == SQLITE_OK)
        var top: OpaquePointer?
        try #require(sqlite3_prepare_v2(old, "SELECT path FROM entries WHERE directory=0 AND files>0 AND bytes>0 ORDER BY bytes DESC,path LIMIT 50", -1, &top, nil) == SQLITE_OK)
        while sqlite3_step(top) == SQLITE_ROW { expectedLargest.append(String(cString: sqlite3_column_text(top,0))) }
        sqlite3_finalize(top)
        var exists: OpaquePointer?
        try #require(sqlite3_prepare_v2(old, "SELECT 1 FROM sqlite_master WHERE name='search_names'", -1, &exists, nil) == SQLITE_OK)
        let legacyFastSearch = sqlite3_step(exists) == SQLITE_ROW; sqlite3_finalize(exists)
        if legacyFastSearch {
            for needle in needles {
                var samples: [Double] = []
                for _ in 0..<6 {
                    let begin = Date()
                    var q: OpaquePointer?
                    let sql = """
                        WITH hits AS MATERIALIZED (
                          SELECT n.id,n.dir_id,n.name FROM search_fts CROSS JOIN search_names n ON n.id=search_fts.rowid
                          WHERE search_fts MATCH ? AND n.name LIKE ? ESCAPE '\\' ORDER BY search_fts.rowid LIMIT 101
                        ) SELECT e.path FROM hits h JOIN search_dirs d ON d.id=h.dir_id
                        JOIN entries e ON e.path=(CASE WHEN d.path='/' THEN '/' ELSE d.path||'/' END)||h.name ORDER BY h.id
                        """
                    try #require(sqlite3_prepare_v2(old,sql,-1,&q,nil) == SQLITE_OK)
                    for (i,text) in [DiskSearchTokens.match(needle),DiskFileQuery(text: needle).escapedPattern].enumerated() {
                        text.withCString { _ = sqlite3_bind_text(q,Int32(i+1),$0,-1,unsafeBitCast(-1,to: sqlite3_destructor_type.self)) }
                    }
                    var rc: Int32
                    repeat { rc = sqlite3_step(q) } while rc == SQLITE_ROW
                    sqlite3_finalize(q); try #require(rc == SQLITE_DONE)
                    samples.append(Date().timeIntervalSince(begin)*1000)
                }
                previousTimes[needle] = samples
            }
        }
    }
    let compactStart = Date()
    let store = try DiskAnalysisStore(url: destination, existing: true)
    let compactSeconds = Date().timeIntervalSince(compactStart)
    let afterBytes = try diskBytes()
    #expect(try store.largestFiles().map(\.path) == expectedLargest)
    print(String(format: "REAL_COMPACT_BENCH before_bytes=%lld after_bytes=%lld migration_s=%.3f", Int64(beforeBytes),Int64(afterBytes),compactSeconds)); fflush(stdout)
    let root = try #require(try store.metadata("root"))
    let countSQL = try store.prepare("SELECT COUNT(*) FROM entries"); defer { sqlite3_finalize(countSQL) }
    try #require(sqlite3_step(countSQL) == SQLITE_ROW)
    let count = sqlite3_column_int64(countSQL, 0)
    let migrationStart = Date(); try store.prepareFastSearch()
    print(String(format: "REAL_SEARCH_BENCH rows=%lld search_index_build_s=%.3f", count, Date().timeIntervalSince(migrationStart))); fflush(stdout)
    for needle in needles {
        let query = DiskFileQuery(text: needle)
        let oldStart = Date()
        let countQ = try store.prepare("SELECT COUNT(*) FROM entries WHERE parent IS NOT NULL AND name LIKE ? ESCAPE '\\'")
        try store.bind(query.escapedPattern, to: countQ, at: 1)
        try #require(sqlite3_step(countQ) == SQLITE_ROW)
        let matches = sqlite3_column_int64(countQ, 0); sqlite3_finalize(countQ)
        let oldQ = try store.prepare("SELECT \(DiskAnalysisStore.columns) FROM entries WHERE parent IS NOT NULL AND name LIKE ? ESCAPE '\\' ORDER BY bytes DESC,path LIMIT 100")
        try store.bind(query.escapedPattern, to: oldQ, at: 1)
        while sqlite3_step(oldQ) == SQLITE_ROW { _ = store.entry(oldQ) }
        sqlite3_finalize(oldQ)
        let oldMS = Date().timeIntervalSince(oldStart) * 1000
        var times: [Double] = []
        for _ in 0..<6 {
            let start = Date()
            let page = try #require(try store.searchPage(requestID: "benchmark", root: root, query: query, offset: 0))
            #expect(page.entries.count == min(100, Int(matches)))
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        print(String(format: "REAL_SEARCH_QUERY query=%@ matches=%lld fullscan_ms=%.3f new_first_ms=%.3f new_warm_median_ms=%.3f", needle, matches, oldMS, times[0], Array(times.dropFirst()).sorted()[2])); fflush(stdout)
        if let previous = previousTimes[needle] {
            print(String(format: "REAL_FAST_COMPARISON query=%@ previous_first_ms=%.3f previous_warm_ms=%.3f compact_first_ms=%.3f compact_warm_ms=%.3f",needle,previous[0],Array(previous.dropFirst()).sorted()[2],times[0],Array(times.dropFirst()).sorted()[2])); fflush(stdout)
        }
    }
}
