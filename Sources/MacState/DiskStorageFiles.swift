import Foundation
import SQLite3

enum DiskStorageCategory {
    static let keys = ["video", "image", "audio", "document", "archive", "application", "development", "model", "other"]
    /// Analysis rules stay separate from raw metadata and can evolve without
    /// rebuilding the filesystem index or reading file contents.
    static func sql(record: String = "n", parent: String = "d.path") -> String {
        let ext = "\(record).extension", kind = "\(record).kind"
        return """
            CASE
            WHEN instr(lower(\(parent)||'/'||\(record).name),'.app/')>0 OR \(kind)='application' THEN 'application'
            WHEN \(ext) IN ('gguf','ggml','safetensors','ckpt','pt','pth','onnx','tflite','mlmodel','mlpackage','h5','hdf5','pb','pkl','joblib','weights')
                OR (\(ext)='bin' AND (instr(lower(\(parent)),'/models/')>0 OR lower(\(parent)) LIKE '%/models')) THEN 'model'
            WHEN \(ext) IN ('swift','m','mm','h','hpp','c','cpp','cc','rs','go','py','pyc','js','jsx','ts','tsx','vue','svelte','java','class','jar','kt','kts','cs','rb','php','sh','zsh','bash','sql','html','css','scss','less','json','yaml','yml','toml','xml','lock','ipynb','wasm','o','a','so')
                OR lower(\(record).name) IN ('dockerfile','makefile','cmakelists.txt','gemfile','podfile','cargo.lock','package-lock.json','pnpm-lock.yaml','yarn.lock') THEN 'development'
            WHEN \(kind)='video' OR \(ext) IN ('mp4','mov','mkv','avi','webm','m4v','flv','ts','mpeg','mpg') THEN 'video'
            WHEN \(kind)='image' OR \(ext) IN ('jpg','jpeg','png','heic','heif','webp','gif','tiff','tif','bmp','raw','dng','cr2','cr3','nef','arw','svg','psd') THEN 'image'
            WHEN \(kind)='audio' OR \(ext) IN ('mp3','flac','wav','aac','m4a','aiff','aif','ogg','opus','wma') THEN 'audio'
            WHEN \(kind)='archive' OR \(ext) IN ('zip','7z','rar','tar','gz','bz2','xz','zst','dmg','iso','pkg') THEN 'archive'
            WHEN \(kind) IN ('document','text') OR \(ext) IN ('pdf','doc','docx','xls','xlsx','ppt','pptx','pages','numbers','key','epub','mobi','rtf','txt','md','csv','odt','ods','odp') THEN 'document'
            ELSE 'other' END
            """
    }
}

struct DiskTypeSummary: Codable {
    struct Category: Codable { let key: String; let files: Int; let bytes: UInt64; let logicalBytes: UInt64 }
    let requestID: String
    let queryID: String
    var categories: [Category] = []
    var directoryBytes: UInt64 = 0
    var skipped = 0
    var updated = Date().timeIntervalSince1970
    var error = ""
}

struct DiskLargeFilter {
    var category = ""
    var minimum: Int64 = 0
    var maximum: Int64 = 0
    var modifiedAfter: Double = 0
    var modifiedBefore: Double = 0
    var physical = false
    var descending = true
    var offset = 0
}

struct DiskLargePage: Codable {
    struct Row: Codable { let entry: DiskAnalysisEntry; let category: String }
    let requestID: String
    let queryID: String
    var offset = 0
    var hasMore = false
    var entries: [Row] = []
    var error = ""
}

extension DiskAnalysisStore {
    func storageSnapshot<T>(cancellation: DiskScanCancellation, body: () throws -> T) throws -> T {
        try withLock {
            sqlite3_progress_handler(database, 1000, { context in
                guard let context else { return 0 }
                return Unmanaged<DiskScanCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
            }, Unmanaged.passUnretained(cancellation).toOpaque())
            defer { sqlite3_progress_handler(database, 0, nil, nil); withExtendedLifetime(cancellation) {} }
            return try readSnapshot(body)
        }
    }

    func fileTypes(requestID: String, queryID: String, root: String, cancellation: DiskScanCancellation) throws -> DiskTypeSummary {
        try storageSnapshot(cancellation: cancellation) {
            var result = DiskTypeSummary(requestID: requestID, queryID: queryID)
            let q = try prepare("""
                SELECT \(DiskStorageCategory.sql()) AS category,COUNT(*),SUM(n.bytes),SUM(n.logical_bytes)
                FROM file_records n JOIN directory_paths d ON d.id=n.dir_id WHERE n.root=0 AND n.directory=0
                GROUP BY category ORDER BY SUM(n.bytes) DESC,category
                """)
            defer { sqlite3_finalize(q) }
            while true {
                let status = sqlite3_step(q)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw failure() }
                result.categories.append(.init(key: string(q, 0), files: Int(sqlite3_column_int64(q, 1)),
                    bytes: UInt64(max(0, sqlite3_column_int64(q, 2))), logicalBytes: UInt64(max(0, sqlite3_column_int64(q, 3)))))
            }
            for key in DiskStorageCategory.keys where !result.categories.contains(where: { $0.key == key }) {
                result.categories.append(.init(key: key, files: 0, bytes: 0, logicalBytes: 0))
            }
            if let entry = try indexedEntry(root) {
                let sum = result.categories.reduce(UInt64(0)) { $0 &+ $1.bytes }
                result.directoryBytes = entry.bytes > sum ? entry.bytes - sum : 0
                result.skipped = entry.skipped
            }
            return result
        }
    }

    func largePage(requestID: String, queryID: String, filter: DiskLargeFilter, cancellation: DiskScanCancellation) throws -> DiskLargePage {
        try storageSnapshot(cancellation: cancellation) {
            let size = filter.physical ? "n.bytes" : "n.logical_bytes", direction = filter.descending ? "DESC" : "ASC"
            var predicates = ["n.root=0", "n.directory=0", "n.files>0", "\(size)>=?"]
            if filter.physical { predicates.append("n.bytes>0") }
            if filter.maximum > 0 { predicates.append("\(size)<=?") }
            if filter.modifiedAfter > 0 { predicates.append("n.modified>=?") }
            if filter.modifiedBefore > 0 { predicates.append("n.modified<?") }
            if !filter.category.isEmpty { predicates.append("(\(DiskStorageCategory.sql()))=?") }
            let columns = Self.columns.split(separator: ",").map { "e." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ",")
            let q = try prepare("""
                WITH hits AS MATERIALIZED (
                    SELECT n.id,\(size) AS size,\(DiskStorageCategory.sql()) AS category
                    FROM file_records n JOIN directory_paths d ON d.id=n.dir_id
                    WHERE \(predicates.joined(separator: " AND ")) ORDER BY \(size) \(direction),n.id LIMIT 101 OFFSET ?
                ) SELECT \(columns),h.category FROM hits h JOIN entries e ON e.id=h.id ORDER BY h.size \(direction),h.id
                """)
            defer { sqlite3_finalize(q) }
            var index: Int32 = 1
            sqlite3_bind_int64(q, index, max(0, filter.minimum)); index += 1
            if filter.maximum > 0 { sqlite3_bind_int64(q, index, filter.maximum); index += 1 }
            if filter.modifiedAfter > 0 { sqlite3_bind_double(q, index, filter.modifiedAfter); index += 1 }
            if filter.modifiedBefore > 0 { sqlite3_bind_double(q, index, filter.modifiedBefore); index += 1 }
            if !filter.category.isEmpty { try bind(filter.category, to: q, at: index); index += 1 }
            let offset = max(0, filter.offset / 100 * 100)
            sqlite3_bind_int64(q, index, Int64(offset))
            var result = DiskLargePage(requestID: requestID, queryID: queryID, offset: offset)
            while true {
                let status = sqlite3_step(q)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw failure() }
                result.entries.append(.init(entry: entry(q), category: string(q, 18)))
            }
            result.hasMore = result.entries.count > 100
            if result.hasMore { result.entries.removeLast() }
            return result
        }
    }
}
