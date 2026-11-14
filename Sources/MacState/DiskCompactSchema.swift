import Foundation
import SQLite3

extension DiskAnalysisStore {
    /// Paths are shared by all siblings. Integer row IDs keep every secondary
    /// index small; the compatibility view materializes paths only for results.
    func createCompactSchema() throws {
        try execute("""
            CREATE TABLE directory_paths(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE);
            CREATE TABLE file_records(
                id INTEGER PRIMARY KEY, dir_id INTEGER NOT NULL, root INTEGER NOT NULL,
                name TEXT NOT NULL, directory INTEGER NOT NULL, browsable INTEGER NOT NULL,
                bytes INTEGER NOT NULL, files INTEGER NOT NULL, skipped INTEGER NOT NULL,
                child_count INTEGER NOT NULL, pending INTEGER NOT NULL, note TEXT NOT NULL,
                logical_bytes INTEGER NOT NULL, allocated_bytes INTEGER NOT NULL,
                modified REAL NOT NULL, created REAL NOT NULL, extension TEXT NOT NULL,
                kind TEXT NOT NULL, device INTEGER NOT NULL, inode INTEGER NOT NULL, links INTEGER NOT NULL,
                UNIQUE(dir_id,root,name)
            );
            CREATE INDEX file_identity ON file_records(device,inode) WHERE links>1;
            CREATE INDEX file_kind ON file_records(kind,id) WHERE root=0;
            CREATE INDEX root_record ON file_records(dir_id) WHERE root=1;
            CREATE VIEW entries AS SELECT f.id,
                CASE WHEN f.root=1 THEN d.path WHEN d.path='/' THEN '/'||f.name ELSE d.path||'/'||f.name END AS path,
                CASE WHEN f.root=1 THEN NULL ELSE d.path END AS parent,
                f.name,f.directory,f.browsable,f.bytes,f.files,f.skipped,f.child_count,f.pending,f.note,
                f.logical_bytes,f.allocated_bytes,f.modified,f.created,f.extension,f.kind,f.device,f.inode,f.links
                FROM file_records f JOIN directory_paths d ON d.id=f.dir_id;
            CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            CREATE TABLE jobs(path TEXT PRIMARY KEY,depth INTEGER NOT NULL,priority INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX job_order ON jobs(priority DESC,depth,path);
            PRAGMA user_version=2;
            """)
    }

    func directoryPathID(_ path: String) throws -> Int64? {
        let q = try reusable("SELECT id FROM directory_paths WHERE path=?")
        defer { reset(q) }; try bind(path, to: q, at: 1)
        switch sqlite3_step(q) {
        case SQLITE_ROW: return sqlite3_column_int64(q, 0)
        case SQLITE_DONE: return nil
        default: throw failure()
        }
    }

    func ensureDirectoryPath(_ path: String) throws -> Int64 {
        // Do not cache IDs across transactions: rollback can invalidate an ID.
        if let id = try directoryPathID(path) { return id }
        let q = try reusable("INSERT INTO directory_paths(path) VALUES(?)")
        defer { reset(q) }; try bind(path, to: q, at: 1)
        guard sqlite3_step(q) == SQLITE_DONE else { throw failure() }
        guard let id = try directoryPathID(path) else { throw failure() }
        return id
    }

    func recordID(_ path: String) throws -> Int64? {
        let parent = (path as NSString).deletingLastPathComponent
        let q = try reusable("SELECT id FROM file_records WHERE dir_id=(SELECT id FROM directory_paths WHERE path=?) AND name=? AND root=0")
        defer { reset(q) }
        try bind(parent, to: q, at: 1); try bind((path as NSString).lastPathComponent, to: q, at: 2)
        switch sqlite3_step(q) {
        case SQLITE_ROW: return sqlite3_column_int64(q, 0)
        case SQLITE_DONE: break
        default: throw failure()
        }
        // The volume label may differ from the actual root basename.
        let root = try reusable("SELECT f.id FROM file_records f JOIN directory_paths d ON d.id=f.dir_id WHERE f.root=1 AND d.path=?")
        defer { reset(root) }; try bind(path, to: root, at: 1)
        switch sqlite3_step(root) {
        case SQLITE_ROW: return sqlite3_column_int64(root, 0)
        case SQLITE_DONE: return nil
        default: throw failure()
        }
    }
}
