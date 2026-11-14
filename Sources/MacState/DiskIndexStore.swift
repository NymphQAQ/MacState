import Foundation
import Darwin
import SQLite3
import UniformTypeIdentifiers

extension DiskAnalysisEntry {
    mutating func setMetadata(_ info: stat) {
        logicalBytes = UInt64(max(0, info.st_size)); allocatedBytes = UInt64(max(0, info.st_blocks)) * 512
        modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        created = Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1e9
        device = Int64(info.st_dev); inode = Int64(clamping: info.st_ino); links = Int(info.st_nlink)
        fileExtension = (name as NSString).pathExtension.lowercased()
        if directory { kind = "folder" }
        else if info.st_mode & S_IFMT == S_IFLNK { kind = "link" }
        else { kind = DiskFileKind.classify(fileExtension) }
    }
}

enum DiskFileKind {
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]
    static func classify(_ suffix: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let saved = cache[suffix] { return saved }
        let type = UTType(filenameExtension: suffix)
        let result: String
        if type?.conforms(to: .image) == true { result = "image" }
        else if type?.conforms(to: .audio) == true { result = "audio" }
        else if type?.conforms(to: .movie) == true { result = "video" }
        else if type?.conforms(to: .text) == true { result = "text" }
        else if type?.conforms(to: .archive) == true { result = "archive" }
        else if type?.conforms(to: .pdf) == true { result = "document" }
        else if type?.conforms(to: .executable) == true { result = "application" }
        else { result = "other" }
        if cache.count < 4096 { cache[suffix] = result }
        return result
    }
}

extension DiskAnalysisStore {
    static let columns = "path, name, directory, browsable, bytes, files, skipped, pending, note, logical_bytes, allocated_bytes, modified, created, extension, kind, device, inode, links"

    func metadata(_ key: String) throws -> String? {
        try withLock {
            let q = try prepare("SELECT value FROM metadata WHERE key=?"); defer { sqlite3_finalize(q) }
            try bind(key, to: q, at: 1)
            return sqlite3_step(q) == SQLITE_ROW ? string(q, 0) : nil
        }
    }
    func setMetadata(_ key: String, _ value: String) throws {
        let q = try prepare("INSERT OR REPLACE INTO metadata VALUES (?, ?)"); defer { sqlite3_finalize(q) }
        try bind(key, to: q, at: 1); try bind(value, to: q, at: 2)
        guard sqlite3_step(q) == SQLITE_DONE else { throw failure() }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do { let result = try body(); try execute("COMMIT"); return result }
            catch { try? execute("ROLLBACK"); throw error }
        }
    }
    func checkpointBuild() throws {
        try withLock { try execute("COMMIT; PRAGMA wal_checkpoint(PASSIVE); BEGIN TRANSACTION;") }
    }
    func indexedEntry(_ path: String) throws -> DiskAnalysisEntry? {
        guard let id = try recordID(path) else { return nil }
        let q = try prepare("SELECT \(Self.columns) FROM entries WHERE id=?"); defer { sqlite3_finalize(q) }
        sqlite3_bind_int64(q, 1, id)
        return sqlite3_step(q) == SQLITE_ROW ? entry(q) : nil
    }
    func childPaths(_ path: String) throws -> Set<String> {
        let q = try prepare("SELECT path FROM entries WHERE id IN (SELECT id FROM file_records WHERE dir_id=(SELECT id FROM directory_paths WHERE path=?) AND root=0)"); defer { sqlite3_finalize(q) }
        try bind(path, to: q, at: 1)
        var result = Set<String>()
        while sqlite3_step(q) == SQLITE_ROW { result.insert(string(q, 0)) }
        return result
    }
    func largestFiles() throws -> [DiskAnalysisEntry] {
        try withLock {
            let sql = "SELECT \(Self.columns) FROM entries WHERE directory=0 AND files>0 AND bytes>0 ORDER BY bytes DESC, path LIMIT 50"
            let q = try prepare(sql)
            defer { sqlite3_finalize(q) }
            var result: [DiskAnalysisEntry] = []
            while true {
                switch sqlite3_step(q) {
                case SQLITE_ROW: result.append(entry(q))
                case SQLITE_DONE: return result
                default: throw failure()
                }
            }
        }
    }
    private func adjustAncestors(parent: String?, root: String, bytes: Int64, files: Int, skipped: Int, children: Int) throws {
        guard bytes != 0 || files != 0 || skipped != 0 || children != 0 else { return }
        var path = parent
        while let current = path, current == root || current.hasPrefix(root == "/" ? "/" : root + "/") {
            guard let id = try recordID(current) else { break }
            let q = try reusable("UPDATE file_records SET bytes=MAX(0,bytes+?), files=MAX(0,files+?), skipped=MAX(0,skipped+?), child_count=MAX(0,child_count+?) WHERE id=?")
            defer { reset(q) }
            sqlite3_bind_int64(q, 1, bytes); sqlite3_bind_int64(q, 2, Int64(files))
            sqlite3_bind_int64(q, 3, Int64(skipped)); sqlite3_bind_int64(q, 4, Int64(current == parent ? children : 0))
            sqlite3_bind_int64(q, 5, id)
            guard sqlite3_step(q) == SQLITE_DONE else { throw failure() }
            if current == root { break }
            path = (current as NSString).deletingLastPathComponent
        }
    }
    private func adjustDirectoryCount(_ change: Int) throws {
        let count = Int(try metadata("directories") ?? "0") ?? 0
        try setMetadata("directories", String(max(0, count + change)))
    }
    /// Metadata, FTS and ancestor totals share the caller transaction. The event
    /// cursor is checkpointed by the coordinator after all work has drained.
    func removeIndexedTree(_ path: String, root: String) throws {
        guard path != root, let old = try indexedEntry(path) else { return }
        guard let id = try recordID(path) else { return }
        let predicate = "id=? OR dir_id IN (SELECT id FROM directory_paths WHERE path=? OR (path>=? AND path<?))"
        func bindTree(_ q: OpaquePointer) throws {
            sqlite3_bind_int64(q, 1, id)
            try bind(path, to: q, at: 2); try bind(path + "/", to: q, at: 3); try bind(path + "0", to: q, at: 4)
        }
        let q = try prepare("SELECT SUM(directory) FROM file_records WHERE \(predicate)")
        defer { sqlite3_finalize(q) }; try bindTree(q)
        guard sqlite3_step(q) == SQLITE_ROW else { throw failure() }
        let directories = Int(sqlite3_column_int64(q, 0))
        let ids = try prepare("SELECT DISTINCT device,inode FROM file_records WHERE links>1 AND (\(predicate))")
        defer { sqlite3_finalize(ids) }; try bindTree(ids)
        var identities: [(Int64, Int64)] = []
        while sqlite3_step(ids) == SQLITE_ROW { identities.append((sqlite3_column_int64(ids, 0), sqlite3_column_int64(ids, 1))) }
        let removal = try prepare("DELETE FROM file_records WHERE \(predicate)")
        defer { sqlite3_finalize(removal) }; try bindTree(removal)
        guard sqlite3_step(removal) == SQLITE_DONE else { throw failure() }
        // Paths remain shared while descendants are deleted; remove orphaned
        // subtree paths only afterwards, without touching live sibling paths.
        let paths = try prepare("DELETE FROM directory_paths WHERE (path=? OR (path>=? AND path<?)) AND NOT EXISTS(SELECT 1 FROM file_records WHERE dir_id=directory_paths.id)")
        defer { sqlite3_finalize(paths) }
        try bind(path, to: paths, at: 1); try bind(path + "/", to: paths, at: 2); try bind(path + "0", to: paths, at: 3)
        guard sqlite3_step(paths) == SQLITE_DONE else { throw failure() }
        try adjustAncestors(parent: (path as NSString).deletingLastPathComponent, root: root,
                            bytes: -Int64(clamping: old.bytes), files: -old.files, skipped: -old.skipped, children: -1)
        try adjustDirectoryCount(-directories)
        for (device, inode) in identities { try normalizeLinks(device: device, inode: inode, root: root) }
    }
    private func normalizeLinks(device: Int64, inode: Int64, root: String) throws {
        let q = try prepare("SELECT \(Self.columns) FROM entries WHERE id IN (SELECT id FROM file_records WHERE links>1 AND device=? AND inode=?) ORDER BY path")
        defer { sqlite3_finalize(q) }
        sqlite3_bind_int64(q, 1, device); sqlite3_bind_int64(q, 2, inode)
        var entries: [DiskAnalysisEntry] = []
        while sqlite3_step(q) == SQLITE_ROW { entries.append(entry(q)) }
        for (i, item) in entries.enumerated() {
            let wanted = i == 0 ? item.allocatedBytes : 0
            if item.bytes == wanted { continue }
            guard let id = try recordID(item.path) else { continue }
            let update = try prepare("UPDATE file_records SET bytes=? WHERE id=?"); defer { sqlite3_finalize(update) }
            sqlite3_bind_int64(update, 1, Int64(clamping: wanted)); sqlite3_bind_int64(update, 2, id)
            guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
            try adjustAncestors(parent: (item.path as NSString).deletingLastPathComponent, root: root,
                bytes: Int64(clamping: wanted) - Int64(clamping: item.bytes), files: 0, skipped: 0, children: 0)
        }
    }
    func upsertIndexedEntry(_ incoming: DiskAnalysisEntry, root: String) throws -> Bool {
        var item = incoming
        let old = try indexedEntry(item.path)
        if let old, old.directory == item.directory, old.browsable == item.browsable,
           old.modified == item.modified, old.logicalBytes == item.logicalBytes,
           old.allocatedBytes == item.allocatedBytes, old.inode == item.inode, old.links == item.links,
           old.skipped == item.skipped, old.note == item.note, old.created == item.created,
           old.device == item.device { return false }
        if let old, !old.directory, !item.directory, old.inode == item.inode,
           old.device == item.device, old.links <= 1, item.links <= 1 {
            // A content/size/time change does not alter the filename catalogue.
            // Keep its row ID and avoid deleting/reinserting the FTS name token.
            guard let id = try recordID(item.path) else { throw failure() }
            let update = try reusable("UPDATE file_records SET bytes=?,files=?,skipped=?,note=?,logical_bytes=?,allocated_bytes=?,modified=?,created=?,kind=?,links=?,browsable=? WHERE id=?")
            defer { reset(update) }
            sqlite3_bind_int64(update, 1, Int64(clamping: item.bytes))
            sqlite3_bind_int64(update, 2, Int64(item.files)); sqlite3_bind_int64(update, 3, Int64(item.skipped))
            try bind(item.note, to: update, at: 4)
            sqlite3_bind_int64(update, 5, Int64(clamping: item.logicalBytes))
            sqlite3_bind_int64(update, 6, Int64(clamping: item.allocatedBytes))
            sqlite3_bind_double(update, 7, item.modified); sqlite3_bind_double(update, 8, item.created)
            try bind(item.kind, to: update, at: 9)
            sqlite3_bind_int64(update, 10, Int64(item.links)); sqlite3_bind_int(update, 11, item.browsable ? 1 : 0)
            sqlite3_bind_int64(update, 12, id)
            guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
            try adjustAncestors(parent: (item.path as NSString).deletingLastPathComponent, root: root,
                bytes: Int64(clamping: item.bytes) - Int64(clamping: old.bytes),
                files: item.files - old.files, skipped: item.skipped - old.skipped, children: 0)
            return false
        }
        if let old, old.directory, item.directory, old.browsable, item.browsable, old.inode == item.inode {
            // Preserve children, aggregate totals and pending state when only a
            // directory's own metadata changed.
            let delta = Int64(clamping: item.allocatedBytes) - Int64(clamping: old.allocatedBytes)
            guard let id = try recordID(item.path) else { throw failure() }
            let update = try prepare("UPDATE file_records SET bytes=MAX(0,bytes+?), allocated_bytes=?, logical_bytes=?, modified=?, created=? WHERE id=?")
            defer { sqlite3_finalize(update) }
            sqlite3_bind_int64(update, 1, delta); sqlite3_bind_int64(update, 2, Int64(clamping: item.allocatedBytes))
            sqlite3_bind_int64(update, 3, Int64(clamping: item.logicalBytes)); sqlite3_bind_double(update, 4, item.modified)
            sqlite3_bind_double(update, 5, item.created); sqlite3_bind_int64(update, 6, id)
            guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
            try adjustAncestors(parent: (item.path as NSString).deletingLastPathComponent, root: root, bytes: delta, files: 0, skipped: 0, children: 0)
            return false
        }
        if old != nil { try removeIndexedTree(item.path, root: root) }
        if item.links > 1, !item.directory { item.bytes = 0 }
        let parent = (item.path as NSString).deletingLastPathComponent
        try insert(item, parent: parent)
        try adjustAncestors(parent: parent, root: root, bytes: Int64(clamping: item.bytes), files: item.files, skipped: item.skipped, children: 1)
        if item.directory { try adjustDirectoryCount(1) }
        if item.links > 1, !item.directory {
            let update = try prepare("UPDATE file_records SET logical_bytes=?,allocated_bytes=?,modified=?,created=? WHERE device=? AND inode=? AND links>1")
            defer { sqlite3_finalize(update) }
            sqlite3_bind_int64(update, 1, Int64(clamping: item.logicalBytes)); sqlite3_bind_int64(update, 2, Int64(clamping: item.allocatedBytes))
            sqlite3_bind_double(update, 3, item.modified); sqlite3_bind_double(update, 4, item.created)
            sqlite3_bind_int64(update, 5, item.device); sqlite3_bind_int64(update, 6, item.inode)
            guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
            try normalizeLinks(device: item.device, inode: item.inode, root: root)
        }
        return item.browsable
    }
}
