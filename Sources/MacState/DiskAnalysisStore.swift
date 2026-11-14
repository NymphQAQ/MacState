import Foundation
import SQLite3

/// An unnamed SQLite database spills to disk and is deleted on close, including
/// process exit. Only the current page and SQLite's bounded page cache use RAM.
final class DiskAnalysisStore {
    struct Directory {
        let entry: DiskAnalysisEntry
        let parent: String?
        let childCount: Int
    }
    struct Failure: LocalizedError {
        let message: String
        let sqliteCode: Int32?

        init(message: String, sqliteCode: Int32? = nil) {
            self.message = message
            self.sqliteCode = sqliteCode
        }

        var errorDescription: String? { message }
    }
    var database: OpaquePointer?
    private var insertion: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    let storeURL: URL?
    let isReadOnly: Bool
    let searchLock = NSRecursiveLock()
    var searchReader: DiskAnalysisStore?
    var fastSearchReady = false
    var changeCacheURL: URL?
    private let deferredSizeIndexes: Bool
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Named stores survive app restarts. Temporary stores remain useful for fixtures.
    init(url: URL? = nil, existing: Bool = false, readOnly: Bool = false, deferSizeIndexes: Bool = false) throws {
        if existing && !readOnly, let url {
            do { try Self.migrateLegacyIndex(at: url) }
            catch { throw Failure(message: "索引优化未完成，原索引已保留。" + error.localizedDescription) }
        }
        deferredSizeIndexes = deferSizeIndexes && !existing && !readOnly
        storeURL = url; isReadOnly = readOnly
        guard sqlite3_open_v2(url?.path ?? "", &database, (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | (existing ? 0 : SQLITE_OPEN_CREATE)) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(database); database = nil; throw error
        }
        do {
            try execute("PRAGMA temp_store=FILE; PRAGMA cache_size=-8192; PRAGMA busy_timeout=3000;")
            if !readOnly {
                try registerSearchTokenizer()
                try execute("PRAGMA synchronous=NORMAL; PRAGMA journal_mode=WAL;")
            }
            if !existing && !readOnly {
                try createCompactSchema()
                if !deferredSizeIndexes { try createSizeIndexes() }
            }
            if !readOnly {
                insertion = try prepare("INSERT INTO file_records(dir_id,root,name,directory,browsable,bytes,files,skipped,child_count,pending,note,logical_bytes,allocated_bytes,modified,created,extension,kind,device,inode,links) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
                if !existing { try execute("BEGIN TRANSACTION;") }
            }
        } catch {
            sqlite3_finalize(insertion); insertion = nil
            sqlite3_close(database); database = nil; throw error
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_finalize(insertion); sqlite3_close(database)
    }

    /// Prepared once per store, reused by the high-volume baseline writer.
    func reusable(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] { return statement }
        let statement = try prepare(sql); statements[sql] = statement; return statement
    }
    func reset(_ statement: OpaquePointer) { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }

    func insert(_ entry: DiskAnalysisEntry, parent: String?, childCount: Int = 0, pending: Int = 0) throws {
        lock.lock(); defer { lock.unlock() }
        guard let insertion else { throw failure() }
        defer { sqlite3_reset(insertion); sqlite3_clear_bindings(insertion) }
        let location = parent ?? entry.path
        let directoryID = try ensureDirectoryPath(location)
        sqlite3_bind_int64(insertion, 1, directoryID)
        sqlite3_bind_int(insertion, 2, parent == nil ? 1 : 0)
        try bind(entry.name, to: insertion, at: 3)
        for (index, value) in [entry.directory ? 1 : 0, entry.browsable ? 1 : 0,
                               Int64(clamping: entry.bytes), Int64(entry.files), Int64(entry.skipped), Int64(childCount), Int64(pending)].enumerated() {
            guard sqlite3_bind_int64(insertion, Int32(index + 4), value) == SQLITE_OK else { throw failure() }
        }
        try bind(entry.note, to: insertion, at: 11)
        for (i, value) in [Int64(clamping: entry.logicalBytes), Int64(clamping: entry.allocatedBytes)].enumerated() {
            sqlite3_bind_int64(insertion, Int32(12 + i), value)
        }
        sqlite3_bind_double(insertion, 14, entry.modified); sqlite3_bind_double(insertion, 15, entry.created)
        try bind(entry.fileExtension, to: insertion, at: 16); try bind(entry.kind, to: insertion, at: 17)
        sqlite3_bind_int64(insertion, 18, entry.device); sqlite3_bind_int64(insertion, 19, entry.inode)
        sqlite3_bind_int64(insertion, 20, Int64(entry.links))
        guard sqlite3_step(insertion) == SQLITE_DONE else { throw failure() }
    }

    func createSizeIndexes() throws {
        try execute("CREATE INDEX IF NOT EXISTS children_by_size ON file_records(dir_id, bytes DESC, name ASC) WHERE root=0; CREATE INDEX IF NOT EXISTS largest_files ON file_records(bytes DESC) WHERE directory=0 AND files>0 AND bytes>0;")
        try execute("CREATE INDEX IF NOT EXISTS file_logical_size ON file_records(logical_bytes DESC,id) WHERE root=0 AND directory=0 AND files>0;")
    }

    func finish(buildIndexes: Bool = true) throws {
        lock.lock(); defer { lock.unlock() }
        if deferredSizeIndexes && buildIndexes { try createSizeIndexes() }
        if sqlite3_get_autocommit(database) == 0 { try execute("COMMIT;") }
    }

    func directory(path: String) throws -> Directory? {
        lock.lock(); defer { lock.unlock() }
        guard let id = try recordID(path) else { return nil }
        let query = try prepare("SELECT \(Self.columns), parent, child_count FROM entries WHERE id=? AND directory=1 AND browsable=1")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, id)
        switch sqlite3_step(query) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            let parent = sqlite3_column_type(query, 18) == SQLITE_NULL ? nil : string(query, 18)
            return Directory(entry: entry(query), parent: parent, childCount: Int(sqlite3_column_int64(query, 19)))
        default: throw failure()
        }
    }

    func children(path: String, offset: Int, sort: DiskFileSort = DiskFileSort()) throws -> [DiskAnalysisEntry] {
        lock.lock(); defer { lock.unlock() }
        let order = sort.expression(alias: "entries", path: "entries.path")
        let sql = sort.key.isEmpty
            ? "SELECT \(Self.columns) FROM entries WHERE id IN (SELECT id FROM file_records WHERE dir_id=(SELECT id FROM directory_paths WHERE path=?) AND root=0 ORDER BY bytes DESC,name LIMIT 100 OFFSET ?) ORDER BY bytes DESC,path"
            : "SELECT \(Self.columns) FROM entries WHERE id IN (SELECT id FROM file_records WHERE dir_id=(SELECT id FROM directory_paths WHERE path=?) AND root=0) ORDER BY \(order) \(sort.direction),id LIMIT 100 OFFSET ?"
        let query = try prepare(sql)
        defer { sqlite3_finalize(query) }
        try bind(path, to: query, at: 1)
        guard sqlite3_bind_int64(query, 2, Int64(offset)) == SQLITE_OK else { throw failure() }
        var entries: [DiskAnalysisEntry] = []
        while true {
            switch sqlite3_step(query) {
            case SQLITE_ROW: entries.append(entry(query))
            case SQLITE_DONE: return entries
            default: throw failure()
            }
        }
    }

    func contains(path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (try? recordID(path)) != nil
    }

    func entry(_ query: OpaquePointer) -> DiskAnalysisEntry {
        DiskAnalysisEntry(path: string(query, 0), name: string(query, 1),
                          directory: sqlite3_column_int(query, 2) != 0, browsable: sqlite3_column_int(query, 3) != 0,
                          bytes: UInt64(max(0, sqlite3_column_int64(query, 4))),
                          files: Int(sqlite3_column_int64(query, 5)), skipped: Int(sqlite3_column_int64(query, 6)),
                          pending: sqlite3_column_int64(query, 7) > 0, note: string(query, 8),
                          logicalBytes: UInt64(max(0, sqlite3_column_int64(query, 9))),
                          allocatedBytes: UInt64(max(0, sqlite3_column_int64(query, 10))),
                          modified: sqlite3_column_double(query, 11), created: sqlite3_column_double(query, 12),
                          fileExtension: string(query, 13), kind: string(query, 14),
                          device: sqlite3_column_int64(query, 15), inode: sqlite3_column_int64(query, 16), links: Int(sqlite3_column_int64(query, 17)))
    }

    func enqueue(path: String, depth: Int, priority: Bool) throws {
        let query = try reusable("INSERT INTO \(changeCacheURL == nil ? "jobs" : "delta.delta_jobs") VALUES (?, ?, ?) ON CONFLICT(path) DO UPDATE SET priority=MAX(priority,excluded.priority), depth=MIN(depth,excluded.depth)")
        defer { reset(query) }
        try bind(path, to: query, at: 1)
        sqlite3_bind_int64(query, 2, Int64(depth)); sqlite3_bind_int(query, 3, priority ? 1 : 0)
        guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
    }

    func nextJob(priorityOnly: Bool) throws -> (path: String, depth: Int)? {
        let query = try reusable("SELECT path, depth FROM jobs \(priorityOnly ? "WHERE priority=1" : "") ORDER BY priority DESC, depth, path LIMIT 1")
        defer { reset(query) }
        let result = sqlite3_step(query)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure() }
        let job = (path: string(query, 0), depth: Int(sqlite3_column_int64(query, 1)))
        let removal = try reusable("DELETE FROM jobs WHERE path=?")
        defer { reset(removal) }
        try bind(job.path, to: removal, at: 1)
        guard sqlite3_step(removal) == SQLITE_DONE else { throw failure() }
        return job
    }

    func prioritize(path: String) throws {
        let query = try prepare("UPDATE jobs SET priority=CASE WHEN path=? OR (path>=? AND path<?) THEN 1 ELSE 0 END")
        defer { sqlite3_finalize(query) }
        try bind(path, to: query, at: 1); try bind(path + "/", to: query, at: 2); try bind(path + "0", to: query, at: 3)
        guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
    }

    func directoryReadNote(path:String,note:String)throws{
        guard let id=try recordID(path) else{return}
        let q=try prepare("UPDATE file_records SET note=? WHERE id=? AND directory=1")
        defer{sqlite3_finalize(q)};try bind(note,to:q,at:1);sqlite3_bind_int64(q,2,id)
        guard sqlite3_step(q)==SQLITE_DONE else{throw failure()}
    }
    func addTotals(path: String, bytes: UInt64 = 0, files: Int = 0, skipped: Int = 0, children: Int = 0, pending: Int = 0) throws {
        guard let id = try recordID(path) else { return }
        let query = try reusable("UPDATE file_records SET bytes=bytes+?, files=files+?, skipped=skipped+?, child_count=child_count+?, pending=pending+? WHERE id=?")
        defer { reset(query) }
        for (i, value) in [Int64(clamping: bytes), Int64(files), Int64(skipped), Int64(children), Int64(pending)].enumerated() {
            sqlite3_bind_int64(query, Int32(i + 1), value)
        }
        sqlite3_bind_int64(query, 6, id)
        guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
    }

    func string(_ query: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(query, index).map { String(cString: $0) } ?? ""
    }

    func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) throws {
        let status = value.map { text in
            text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        } ?? sqlite3_bind_null(statement, index)
        guard status == SQLITE_OK else { throw failure() }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw failure()
        }
        return statement
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    func failure() -> Failure {
        Failure(message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开临时磁盘明细缓存",
                sqliteCode: database.map { sqlite3_extended_errcode($0) })
    }
}
