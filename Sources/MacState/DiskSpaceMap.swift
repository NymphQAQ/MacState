import Foundation
import SQLite3

struct DiskSpaceMapNode: Codable {
    let name: String
    let path: String
    let kind: String
    let bytes: UInt64
    let files: Int
    let browsable: Bool
    var synthetic = false
}

struct DiskSpaceMapPage: Codable {
    let requestID: String
    let mapID: String
    let path: String
    let mode: String
    var bytes: UInt64 = 0
    var files = 0
    var skipped = 0
    var omitted = 0
    var updated = Date().timeIntervalSince1970
    var breadcrumbs: [DiskDirectoryPage.Breadcrumb] = []
    var nodes: [DiskSpaceMapNode] = []
    var error = ""
}

extension DiskAnalysisStore {
    func spaceMap(requestID: String, mapID: String, path: String, root: String, mode: String,
                  cancellation: DiskScanCancellation) throws -> DiskSpaceMapPage {
        try withLock {
            sqlite3_progress_handler(database, 1000, { context in
                guard let context else { return 0 }
                return Unmanaged<DiskScanCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
            }, Unmanaged.passUnretained(cancellation).toOpaque())
            defer { sqlite3_progress_handler(database, 0, nil, nil); withExtendedLifetime(cancellation) {} }
            return try readSnapshot {
                guard path == root || path.hasPrefix(root == "/" ? "/" : root + "/"),
                      let directory = try directory(path: path) else {
                    throw Failure(message: "此目录不在可浏览的索引范围内，可能已移动或删除。请返回上一级刷新。")
                }
                var page = DiskSpaceMapPage(requestID: requestID, mapID: mapID, path: path, mode: mode,
                    bytes: directory.entry.bytes, files: directory.entry.files, skipped: directory.entry.skipped)
                var current: Directory? = directory
                while let node = current {
                    page.breadcrumbs.append(.init(name: node.entry.name, path: node.entry.path))
                    if node.entry.path == root { break }
                    current = try node.parent.flatMap { try self.directory(path: $0) }
                }
                page.breadcrumbs.reverse()
                if mode == "types" {
                    let q = try prepare("""
                        SELECT \(DiskStorageCategory.sql()) AS category,SUM(n.bytes),COUNT(*) FROM file_records n JOIN directory_paths d ON d.id=n.dir_id
                        WHERE n.root=0 AND n.directory=0 AND n.dir_id IN
                        (SELECT id FROM directory_paths WHERE path=? OR (path>=? AND path<?))
                        GROUP BY category ORDER BY SUM(n.bytes) DESC,category
                        """)
                    defer { sqlite3_finalize(q) }
                    try bind(path, to: q, at: 1)
                    let prefix = path == "/" ? "/" : path + "/"
                    try bind(prefix, to: q, at: 2); try bind(path == "/" ? "0" : path + "0", to: q, at: 3)
                    while true {
                        let result = sqlite3_step(q)
                        if result == SQLITE_DONE { break }
                        guard result == SQLITE_ROW else { throw failure() }
                        let kind = string(q, 0)
                        page.nodes.append(.init(name: kind, path: "", kind: kind,
                            bytes: UInt64(max(0, sqlite3_column_int64(q, 1))), files: Int(sqlite3_column_int64(q, 2)), browsable: false, synthetic: true))
                    }
                } else {
                    let q = try prepare("""
                        SELECT \(Self.columns) FROM entries WHERE id IN
                        (SELECT id FROM file_records WHERE root=0 AND dir_id=(SELECT id FROM directory_paths WHERE path=?)
                        ORDER BY bytes DESC,name LIMIT 256) ORDER BY bytes DESC,path
                        """)
                    defer { sqlite3_finalize(q) }; try bind(path, to: q, at: 1)
                    while true {
                        let result = sqlite3_step(q)
                        if result == SQLITE_DONE { break }
                        guard result == SQLITE_ROW else { throw failure() }
                        let item = entry(q)
                        page.nodes.append(.init(name: item.name, path: item.path, kind: item.directory ? "folder" : item.kind,
                            bytes: item.bytes, files: item.files, browsable: item.browsable))
                    }
                    page.omitted = max(0, directory.childCount - page.nodes.count)
                }
                let shown = page.nodes.reduce(UInt64(0)) { $0 &+ $1.bytes }
                if page.bytes > shown || page.omitted > 0 {
                    page.nodes.append(.init(name: mode == "types" ? "目录元数据" : "其他项目及目录元数据", path: "", kind: "metadata",
                        bytes: page.bytes > shown ? page.bytes - shown : 0,
                        files: max(0, page.files - page.nodes.reduce(0) { $0 + $1.files }), browsable: false, synthetic: true))
                }
                return page
            }
        }
    }
}
