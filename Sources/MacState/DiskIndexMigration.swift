import Foundation
import Darwin
import SQLite3

extension DiskAnalysisStore {
    /// Build a replacement beside the original. No filesystem traversal and no
    /// destructive schema changes are made to the original database.
    static func migrateLegacyIndex(at url: URL) throws {
        var source: OpaquePointer?
        guard sqlite3_open_v2(url.path, &source, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = source.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开旧索引"
            sqlite3_close(source); throw Failure(message: message)
        }
        defer { sqlite3_close(source) }
        var probe: OpaquePointer?
        guard sqlite3_prepare_v2(source, "SELECT type FROM sqlite_master WHERE name='entries'", -1, &probe, nil) == SQLITE_OK else {
            throw Failure(message: "无法检查索引存储结构，原索引已保留。")
        }
        let legacy = sqlite3_step(probe) == SQLITE_ROW && sqlite3_column_text(probe, 0).map { String(cString: $0) } == "table"
        sqlite3_finalize(probe)
        guard legacy else { return }

        // Fold the old WAL in before replacement; an old WAL must never be
        // replayed onto the new main file. Fail safely if another writer owns it.
        sqlite3_busy_timeout(source, 3000)
        guard sqlite3_wal_checkpoint_v2(source, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK,
              sqlite3_exec(source, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw Failure(message: "索引正由其他任务使用，暂不能迁移。原索引已保留，请稍后重试。")
        }
        defer { if source != nil { sqlite3_exec(source, "ROLLBACK", nil, nil, nil) } }
        let staging = URL(fileURLWithPath: url.path + ".compact-pending")
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: staging.path + suffix) }
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: staging.path + suffix) } }

        // Keep the scope narrow so every target statement/handle is closed
        // before atomic promotion. An interrupted run simply retries from old.
        do {
            let target = try DiskAnalysisStore(url: staging, deferSizeIndexes: true)
            try target.finish(buildIndexes: false)
            let attach = try target.prepare("ATTACH DATABASE ? AS legacy")
            do { try target.bind(url.absoluteString + "?mode=ro", to: attach, at: 1) }
            catch { sqlite3_finalize(attach); throw error }
            let status = sqlite3_step(attach); sqlite3_finalize(attach)
            guard status == SQLITE_DONE else { throw target.failure() }
            try target.transaction {
                try target.execute("""
                    INSERT INTO directory_paths(path) SELECT DISTINCT COALESCE(parent,path) FROM legacy.entries;
                    INSERT INTO file_records(dir_id,root,name,directory,browsable,bytes,files,skipped,child_count,pending,note,logical_bytes,allocated_bytes,modified,created,extension,kind,device,inode,links)
                    SELECT d.id,l.parent IS NULL,l.name,l.directory,l.browsable,l.bytes,l.files,l.skipped,l.child_count,l.pending,l.note,l.logical_bytes,l.allocated_bytes,l.modified,l.created,l.extension,l.kind,l.device,l.inode,l.links
                    FROM legacy.entries l JOIN directory_paths d ON d.path=COALESCE(l.parent,l.path);
                    INSERT INTO metadata SELECT * FROM legacy.metadata;
                    INSERT INTO jobs SELECT * FROM legacy.jobs;
                    DELETE FROM metadata WHERE key='fastSearch';
                    """)
            }
            try target.finish()
            // Check every original attribute, not just record count or root sum.
            let fields = ["directory", "browsable", "bytes", "files", "skipped", "child_count", "pending", "note", "logical_bytes", "allocated_bytes", "modified", "created", "extension", "kind", "device", "inode", "links"]
            let mismatches = fields.map { "f.\($0) IS NOT l.\($0)" }.joined(separator: " OR ")
            let check = try target.prepare("""
                SELECT 1 WHERE (SELECT COUNT(*) FROM file_records)!=(SELECT COUNT(*) FROM legacy.entries)
                UNION ALL SELECT 1 FROM legacy.entries l
                LEFT JOIN directory_paths d ON d.path=COALESCE(l.parent,l.path)
                LEFT JOIN file_records f ON f.dir_id=d.id AND f.name=l.name AND f.root=(l.parent IS NULL)
                WHERE f.id IS NULL OR \(mismatches)
                OR l.path IS NOT (CASE WHEN f.root=1 THEN d.path WHEN d.path='/' THEN '/'||f.name ELSE d.path||'/'||f.name END)
                LIMIT 1
                """)
            let validation = sqlite3_step(check); sqlite3_finalize(check)
            guard validation == SQLITE_DONE else { throw Failure(message: "索引迁移校验未通过，原索引已保留。") }
            try target.execute("DETACH DATABASE legacy")
            try target.prepareFastSearch()
            try target.execute("INSERT INTO search_fts(search_fts) VALUES('integrity-check');")
            let integrity = try target.prepare("PRAGMA quick_check")
            let valid = sqlite3_step(integrity) == SQLITE_ROW && target.string(integrity, 0) == "ok"
            sqlite3_finalize(integrity)
            guard valid else { throw Failure(message: "新索引完整性检查失败，原索引已保留。") }
            guard sqlite3_wal_checkpoint_v2(target.database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK else { throw target.failure() }
        }
        // The reserved source lock prevented writes throughout the copy. Its
        // WAL was empty before the copy, and must still be empty at promotion.
        sqlite3_exec(source, "ROLLBACK", nil, nil, nil)
        guard sqlite3_wal_checkpoint_v2(source, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK else {
            throw Failure(message: "原索引日志仍在使用，已取消替换并保留原索引。")
        }
        sqlite3_close(source); source = nil
        guard rename(staging.path, url.path) == 0 else {
            throw Failure(message: "无法替换索引文件，原索引已保留：\(String(cString: strerror(errno)))")
        }
    }
}
