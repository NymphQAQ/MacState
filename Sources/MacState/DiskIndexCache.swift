import Foundation
import SQLite3

extension DiskAnalysisStore {
    static let cacheRecordFields = "id,dir_id,root,name,directory,browsable,bytes,files,skipped,child_count,pending,note,logical_bytes,allocated_bytes,modified,created,extension,kind,device,inode,links"

    /// The main database remains unchanged between explicit merges. TEMP views
    /// preserve the existing aggregate/hard-link writer against copy-on-write rows.
    func enableChangeCache(at url: URL, readOnly: Bool = false) throws {
        guard changeCacheURL == nil else { return }
        // ATTACH inherits the main connection's open flags. Existing main
        // indexes intentionally omit CREATE, so explicitly create a missing
        // cache with its own connection before attaching it.
        if !readOnly && !FileManager.default.fileExists(atPath: url.path) {
            var initial: OpaquePointer?
            let status = sqlite3_open_v2(url.path, &initial, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            guard status == SQLITE_OK else {
                let detail = initial.map { String(cString: sqlite3_errmsg($0)) } ?? "无法创建缓存文件"
                sqlite3_close(initial)
                throw Failure(message: "无法创建增量缓存：\(url.path)。\(detail)")
            }
            let initialized = sqlite3_exec(initial, "PRAGMA user_version=1;", nil, nil, nil)
            let detail = initial.map { String(cString: sqlite3_errmsg($0)) } ?? "初始化失败"
            sqlite3_close(initial)
            guard initialized == SQLITE_OK else { throw Failure(message: "无法初始化增量缓存：\(detail)") }
        }
        let attach = try prepare("ATTACH DATABASE ? AS delta")
        do { try bind(readOnly ? url.absoluteString + "?mode=ro" : url.path, to: attach, at: 1) }
        catch { sqlite3_finalize(attach); throw error }
        let status = sqlite3_step(attach); sqlite3_finalize(attach)
        guard status == SQLITE_DONE else { throw Failure(message: "无法打开增量缓存：\(url.path)。\(failure().message)") }
        if !readOnly {
            try execute("PRAGMA delta.journal_mode=WAL; PRAGMA delta.synchronous=NORMAL;")
            try execute("""
                CREATE TABLE IF NOT EXISTS delta.delta_paths(id INTEGER PRIMARY KEY AUTOINCREMENT,path TEXT NOT NULL UNIQUE);
                CREATE TABLE IF NOT EXISTS delta.delta_records(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,dir_id INTEGER NOT NULL,root INTEGER NOT NULL,
                    name TEXT NOT NULL,directory INTEGER NOT NULL,browsable INTEGER NOT NULL,
                    bytes INTEGER NOT NULL,files INTEGER NOT NULL,skipped INTEGER NOT NULL,
                    child_count INTEGER NOT NULL,pending INTEGER NOT NULL,note TEXT NOT NULL,
                    logical_bytes INTEGER NOT NULL,allocated_bytes INTEGER NOT NULL,
                    modified REAL NOT NULL,created REAL NOT NULL,extension TEXT NOT NULL,
                    kind TEXT NOT NULL,device INTEGER NOT NULL,inode INTEGER NOT NULL,links INTEGER NOT NULL,
                    UNIQUE(dir_id,root,name));
                CREATE INDEX IF NOT EXISTS delta.delta_children ON delta_records(dir_id,bytes DESC,name) WHERE root=0;
                CREATE INDEX IF NOT EXISTS delta.delta_identity ON delta_records(device,inode) WHERE links>1;
                CREATE INDEX IF NOT EXISTS delta.delta_kind ON delta_records(kind,id) WHERE root=0;
                CREATE INDEX IF NOT EXISTS delta.delta_largest ON delta_records(bytes DESC) WHERE directory=0 AND files>0 AND bytes>0;
                CREATE TABLE IF NOT EXISTS delta.removed_records(id INTEGER PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS delta.removed_paths(id INTEGER PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS delta.delta_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS delta.delta_jobs(path TEXT PRIMARY KEY,depth INTEGER NOT NULL,priority INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX IF NOT EXISTS delta.delta_job_order ON delta_jobs(priority DESC,depth,path);
                CREATE TABLE IF NOT EXISTS delta.delta_info(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                CREATE VIRTUAL TABLE IF NOT EXISTS delta.delta_fts USING fts5(tokens,content='',tokenize='trigram');
                CREATE TRIGGER IF NOT EXISTS delta.cache_count_insert AFTER INSERT ON delta_records BEGIN
                    UPDATE delta_info SET value=CAST(value AS INTEGER)+1 WHERE key='pendingRecords';
                END;
                CREATE TRIGGER IF NOT EXISTS delta.cache_count_delete AFTER DELETE ON delta_records BEGIN
                    UPDATE delta_info SET value=CAST(value AS INTEGER)-1 WHERE key='pendingRecords';
                END;
                CREATE TRIGGER IF NOT EXISTS delta.cache_removed_insert AFTER INSERT ON removed_records BEGIN
                    UPDATE delta_info SET value=CAST(value AS INTEGER)+1 WHERE key='pendingRecords';
                END;
                CREATE TRIGGER IF NOT EXISTS delta.cache_removed_delete AFTER DELETE ON removed_records BEGIN
                    UPDATE delta_info SET value=CAST(value AS INTEGER)-1 WHERE key='pendingRecords';
                END;
                CREATE TRIGGER IF NOT EXISTS delta.delta_search_insert AFTER INSERT ON delta_records WHEN new.root=0 BEGIN
                    INSERT INTO delta_fts(rowid,tokens) VALUES(new.id,macstate_search_tokens(new.name));
                END;
                CREATE TRIGGER IF NOT EXISTS delta.delta_search_delete AFTER DELETE ON delta_records WHEN old.root=0 BEGIN
                    INSERT INTO delta_fts(delta_fts,rowid,tokens) VALUES('delete',old.id,macstate_search_tokens(old.name));
                END;
                CREATE TRIGGER IF NOT EXISTS delta.delta_search_update AFTER UPDATE OF name,root ON delta_records BEGIN
                    INSERT INTO delta_fts(delta_fts,rowid,tokens) SELECT 'delete',old.id,macstate_search_tokens(old.name) WHERE old.root=0;
                    INSERT INTO delta_fts(rowid,tokens) SELECT new.id,macstate_search_tokens(new.name) WHERE new.root=0;
                END;
                """)
            let baseline = [try metadata("root") ?? "", try metadata("eventsUUID") ?? "", try metadata("completedAt") ?? "0"].joined(separator: "|")
            let probe = try prepare("SELECT value FROM delta.delta_info WHERE key='baseline'")
            let saved = sqlite3_step(probe) == SQLITE_ROW ? string(probe, 0) : nil
            sqlite3_finalize(probe)
            if saved != baseline {
                try transaction {
                    try execute("DELETE FROM delta.delta_records; DELETE FROM delta.removed_records; DELETE FROM delta.delta_paths; DELETE FROM delta.removed_paths; DELETE FROM delta.delta_metadata; DELETE FROM delta.delta_jobs; DELETE FROM delta.delta_info;")
                    let q = try prepare("INSERT INTO delta.delta_info VALUES('baseline',?)"); defer { sqlite3_finalize(q) }
                    try bind(baseline, to: q, at: 1)
                    guard sqlite3_step(q) == SQLITE_DONE else { throw failure() }
                    try execute("INSERT INTO delta.delta_jobs SELECT * FROM main.jobs;")
                }
            }
            try execute("INSERT OR REPLACE INTO delta.delta_info(key,value) SELECT 'pendingRecords',(SELECT COUNT(*) FROM delta.delta_records)+(SELECT COUNT(*) FROM delta.removed_records);")
            // Never recycle IDs that are still present in the immutable baseline.
            for (table, source) in [("delta_records", "file_records"), ("delta_paths", "directory_paths")] {
                try execute("INSERT INTO delta.sqlite_sequence(name,seq) SELECT '\(table)',(SELECT COALESCE(MAX(id),0) FROM main.\(source)) WHERE NOT EXISTS(SELECT 1 FROM delta.sqlite_sequence WHERE name='\(table)'); UPDATE delta.sqlite_sequence SET seq=MAX(seq,(SELECT COALESCE(MAX(id),0) FROM main.\(source))) WHERE name='\(table)';")
            }
        }
        let fields = Self.cacheRecordFields
        try execute("""
            CREATE TEMP VIEW file_records AS SELECT \(fields) FROM delta.delta_records
                UNION ALL SELECT \(fields) FROM main.file_records b
                WHERE NOT EXISTS(SELECT 1 FROM delta.delta_records c WHERE c.id=b.id)
                  AND NOT EXISTS(SELECT 1 FROM delta.removed_records r WHERE r.id=b.id);
            CREATE TEMP VIEW directory_paths AS SELECT id,path FROM delta.delta_paths
                UNION ALL SELECT id,path FROM main.directory_paths b
                WHERE NOT EXISTS(SELECT 1 FROM delta.delta_paths c WHERE c.id=b.id)
                  AND NOT EXISTS(SELECT 1 FROM delta.removed_paths r WHERE r.id=b.id);
            CREATE TEMP VIEW metadata AS SELECT key,value FROM delta.delta_metadata
                UNION ALL SELECT key,value FROM main.metadata b WHERE NOT EXISTS(SELECT 1 FROM delta.delta_metadata c WHERE c.key=b.key);
            CREATE TEMP VIEW jobs AS SELECT * FROM delta.delta_jobs;
            CREATE TEMP VIEW entries AS SELECT f.id,
                CASE WHEN f.root=1 THEN d.path WHEN d.path='/' THEN '/'||f.name ELSE d.path||'/'||f.name END AS path,
                CASE WHEN f.root=1 THEN NULL ELSE d.path END AS parent,
                f.name,f.directory,f.browsable,f.bytes,f.files,f.skipped,f.child_count,f.pending,f.note,
                f.logical_bytes,f.allocated_bytes,f.modified,f.created,f.extension,f.kind,f.device,f.inode,f.links
                FROM file_records f JOIN directory_paths d ON d.id=f.dir_id;
            """)
        if !readOnly {
            let names = fields.split(separator: ",").map(String.init)
            let values = names.map { $0 == "id" ? "CASE WHEN new.id>0 THEN new.id ELSE NULL END" : "new." + $0 }.joined(separator: ",")
            let updates = names.dropFirst().map { "\($0)=excluded.\($0)" }.joined(separator: ",")
            try execute("""
                CREATE TEMP TRIGGER cache_insert INSTEAD OF INSERT ON file_records BEGIN
                    INSERT INTO delta_records(\(fields)) VALUES(\(values));
                END;
                CREATE TEMP TRIGGER cache_update INSTEAD OF UPDATE ON file_records BEGIN
                    INSERT INTO delta_records(\(fields)) VALUES(\(values)) ON CONFLICT(id) DO UPDATE SET \(updates);
                END;
                CREATE TEMP TRIGGER cache_delete INSTEAD OF DELETE ON file_records BEGIN
                    DELETE FROM delta_records WHERE id=old.id;
                    INSERT OR IGNORE INTO removed_records VALUES(old.id);
                END;
                CREATE TEMP TRIGGER cache_path_insert INSTEAD OF INSERT ON directory_paths BEGIN
                    INSERT INTO delta_paths(path) VALUES(new.path);
                END;
                CREATE TEMP TRIGGER cache_path_delete INSTEAD OF DELETE ON directory_paths BEGIN
                    DELETE FROM delta_paths WHERE id=old.id;
                    INSERT OR IGNORE INTO removed_paths VALUES(old.id);
                END;
                CREATE TEMP TRIGGER cache_metadata_insert INSTEAD OF INSERT ON metadata BEGIN
                    INSERT OR REPLACE INTO delta_metadata VALUES(new.key,new.value);
                END;
                CREATE TEMP TRIGGER cache_job_delete INSTEAD OF DELETE ON jobs BEGIN
                    DELETE FROM delta_jobs WHERE path=old.path;
                END;
                """)
        }
        changeCacheURL = url; fastSearchReady = true
    }

    /// An independent read handle prevents directory/largest queries from waiting
    /// on the coordinator's writer lock. Both FTS candidate sets share this view.
    func queryView() throws -> DiskAnalysisStore {
        searchLock.lock(); defer { searchLock.unlock() }
        guard !isReadOnly, let url = storeURL else { return self }
        if let searchReader { return searchReader }
        let reader = try DiskAnalysisStore(url: url, existing: true, readOnly: true)
        if let cache = changeCacheURL { try reader.enableChangeCache(at: cache, readOnly: true) }
        reader.fastSearchReady = true
        searchReader = reader
        return reader
    }

    /// Heavy analyses own a read handle; they never hold the interactive search lock.
    func isolatedQueryView() throws -> DiskAnalysisStore {
        guard let url = storeURL else { return self }
        let reader = try DiskAnalysisStore(url:url,existing:true,readOnly:true)
        if let cache = changeCacheURL { try reader.enableChangeCache(at:cache,readOnly:true) }
        reader.fastSearchReady = true
        return reader
    }

    /// Pin the cache snapshot before main. Merge commits main before clearing
    /// cache, so a reader cannot observe an old baseline with an already-cleared
    /// delta. All statements that form one UI response share these snapshots.
    func readSnapshot<T>(_ body: () throws -> T) throws -> T {
        try withLock {
            guard isReadOnly, sqlite3_get_autocommit(database) != 0 else { return try body() }
            try execute("BEGIN DEFERRED;")
            do {
                if changeCacheURL != nil { try execute("SELECT key FROM delta.delta_info LIMIT 1;") }
                try execute("SELECT key FROM main.metadata LIMIT 1;")
                let result = try body()
                try execute("COMMIT;")
                return result
            } catch { try? execute("ROLLBACK;"); throw error }
        }
    }

    func pendingCacheRecords() throws -> Int {
        guard changeCacheURL != nil else { return 0 }
        return try withLock {
            let q = try prepare("SELECT CAST(value AS INTEGER) FROM delta.delta_info WHERE key='pendingRecords'")
            defer { sqlite3_finalize(q) }
            guard sqlite3_step(q) == SQLITE_ROW else { throw failure() }
            return Int(sqlite3_column_int64(q, 0))
        }
    }

    /// Commit final row images to main first; only afterwards clear the cache.
    /// A crash between commits safely replays the same images and tombstone IDs.
    /// The coordinator pauses mutations during merge; WAL readers keep searching.
    func mergeChangeCache() throws {
        guard changeCacheURL != nil else { return }
        try withLock {
            try execute("PRAGMA main.synchronous=FULL;")
            defer { try? execute("PRAGMA main.synchronous=NORMAL;") }
            let fields = Self.cacheRecordFields
            let updates = fields.split(separator: ",").dropFirst().map { "\($0)=excluded.\($0)" }.joined(separator: ",")
            try transaction {
                try execute("""
                    DELETE FROM main.file_records WHERE id IN (SELECT id FROM delta.removed_records);
                    DELETE FROM main.directory_paths WHERE id IN (SELECT id FROM delta.removed_paths);
                    INSERT INTO main.directory_paths(id,path) SELECT id,path FROM delta.delta_paths WHERE true
                        ON CONFLICT(id) DO UPDATE SET path=excluded.path;
                    INSERT INTO main.file_records(\(fields)) SELECT \(fields) FROM delta.delta_records WHERE true
                        ON CONFLICT(id) DO UPDATE SET \(updates);
                    DELETE FROM main.jobs;
                    INSERT INTO main.jobs SELECT * FROM delta.delta_jobs;
                    INSERT INTO main.metadata SELECT key,value FROM delta.delta_metadata WHERE true
                        ON CONFLICT(key) DO UPDATE SET value=excluded.value;
                    """)
            }
            // FULL makes the baseline durable before clearing its recovery data.
            try transaction {
                try execute("DELETE FROM delta.delta_records; DELETE FROM delta.removed_records; DELETE FROM delta.delta_paths; DELETE FROM delta.removed_paths; DELETE FROM delta.delta_metadata;")
                let q = try prepare("INSERT OR REPLACE INTO delta.delta_info VALUES('lastMerge',?)"); defer { sqlite3_finalize(q) }
                try bind(String(Date().timeIntervalSince1970), to: q, at: 1)
                guard sqlite3_step(q) == SQLITE_DONE else { throw failure() }
            }
            try execute("PRAGMA main.wal_checkpoint(PASSIVE);")
        }
    }

    func cacheLastMerged() throws -> Double {
        let q = try prepare("SELECT value FROM delta.delta_info WHERE key='lastMerge'")
        defer { sqlite3_finalize(q) }
        return sqlite3_step(q) == SQLITE_ROW ? Double(string(q, 0)) ?? 0 : 0
    }
}
