import Foundation
import SQLite3

struct DiskFileSort: Equatable {
    let key: String
    let descending: Bool
    init(key: String = "", descending: Bool = false) {
        self.key = ["name", "size", "modified", "kind", "path"].contains(key) ? key : ""
        self.descending = descending
    }
    var direction: String { descending ? "DESC" : "ASC" }
    func expression(alias: String, path: String) -> String {
        switch key {
        case "name": return "\(alias).name COLLATE NOCASE"
        case "size": return "CASE WHEN \(alias).directory=1 THEN \(alias).bytes ELSE \(alias).logical_bytes END"
        case "modified": return "\(alias).modified"
        case "kind": return "\(alias).kind COLLATE NOCASE"
        case "path": return "\(path) COLLATE NOCASE"
        default: return "\(alias).id"
        }
    }
}

struct DiskFileQuery: Equatable {
    var text: String
    var kind: String
    var sort: DiskFileSort
    init(text: String = "", kind: String = "", sort: DiskFileSort = DiskFileSort()) {
        self.sort = sort
        self.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        self.kind = ["folder", "image", "audio", "video", "text", "archive", "document", "application", "link", "other"].contains(kind) ? kind : ""
    }
    var active: Bool { !text.isEmpty || !kind.isEmpty }
    var escapedPattern: String {
        "%" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }
}

/// Interleaving a separator turns adjacent filename characters into three-scalar
/// FTS tokens, including one-character terms. The residual LIKE predicate keeps
/// exact literal semantics even when a filename itself contains the separator.
enum DiskSearchTokens {
    static func encode(_ text: String) -> String {
        var bytes: [UInt8] = [1]
        bytes.reserveCapacity(text.utf8.count * 2 + 1)
        for byte in text.utf8 {
            if byte & 0xc0 != 0x80 && bytes.count > 1 { bytes.append(1) }
            bytes.append(byte)
        }
        bytes.append(1)
        return String(decoding: bytes, as: UTF8.self)
    }

    static func match(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let terms: [String]
        if scalars.count < 2 { terms = [encode(text)] }
        else {
            var seen = Set<String>()
            terms = zip(scalars, scalars.dropFirst()).compactMap { first, second in
                let pair = String(first) + "\u{1}" + String(second)
                return seen.insert(pair).inserted ? pair : nil
            }
        }
        // Intersect adjacent pairs without loading ubiquitous one-character
        // position lists. LIKE below checks the whole original substring.
        return terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
    }
}

extension DiskAnalysisStore {
    func registerSearchTokenizer() throws {
        let status = sqlite3_create_function_v2(database, "macstate_search_tokens", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS, nil, { context, count, arguments in
            guard count == 1, let value = arguments?[0], let raw = sqlite3_value_text(value) else {
                sqlite3_result_null(context); return
            }
            let encoded = DiskSearchTokens.encode(String(cString: raw))
            encoded.withCString { sqlite3_result_text(context, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }, nil, nil, nil)
        guard status == SQLITE_OK else { throw failure() }
    }

    /// Build only from saved metadata, never rescan the filesystem. Bulk creation
    /// follows traversal; triggers maintain the small name catalogue thereafter.
    func prepareFastSearch() throws {
        try withLock {
            if fastSearchReady { return }
            if try metadata("fastSearch") != "3" {
                try transaction {
                    try execute("""
                        DROP TRIGGER IF EXISTS search_insert;
                        DROP TRIGGER IF EXISTS search_delete;
                        DROP TRIGGER IF EXISTS search_update;
                        DROP TABLE IF EXISTS search_fts;
                        CREATE VIRTUAL TABLE search_fts USING fts5(tokens, content='', tokenize='trigram');
                        INSERT INTO search_fts(rowid,tokens) SELECT id,macstate_search_tokens(name) FROM file_records WHERE root=0;
                        CREATE TRIGGER search_insert AFTER INSERT ON file_records WHEN new.root=0 BEGIN
                            INSERT INTO search_fts(rowid,tokens) VALUES(new.id,macstate_search_tokens(new.name));
                        END;
                        CREATE TRIGGER search_delete AFTER DELETE ON file_records WHEN old.root=0 BEGIN
                            INSERT INTO search_fts(search_fts,rowid,tokens) VALUES('delete',old.id,macstate_search_tokens(old.name));
                        END;
                        CREATE TRIGGER search_update AFTER UPDATE OF name,root ON file_records BEGIN
                            INSERT INTO search_fts(search_fts,rowid,tokens) SELECT 'delete',old.id,macstate_search_tokens(old.name) WHERE old.root=0;
                            INSERT INTO search_fts(rowid,tokens) SELECT new.id,macstate_search_tokens(new.name) WHERE new.root=0;
                        END;
                        """)
                    try setMetadata("fastSearch", "3")
                }
            }
            fastSearchReady = true
        }
    }

    /// 101 candidates replace a full COUNT + full-result sort. Resolve full paths
    /// and metadata for this page only. A WAL reader does not lock out the writer.
    func searchPage(requestID: String, root: String, query: DiskFileQuery, offset: Int,
                    cancellation: DiskScanCancellation? = nil) throws -> DiskDirectoryPage? {
        guard cancellation?.isCancelled != true else { return nil }
        if !fastSearchReady { try prepareFastSearch() }
        guard cancellation?.isCancelled != true else { return nil }
        let reader = try queryView()
        return try reader.readSnapshot {
            try reader.searchStoredPage(requestID: requestID, root: root, query: query, offset: offset, cancellation: cancellation)
        }
    }

    private func searchStoredPage(requestID: String, root: String, query: DiskFileQuery, offset: Int,
                                  cancellation: DiskScanCancellation?) throws -> DiskDirectoryPage? {
        try withLock {
            if let cancellation {
                sqlite3_progress_handler(database, 1000, { context in
                    guard let context else { return 0 }
                    return Unmanaged<DiskScanCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
                }, Unmanaged.passUnretained(cancellation).toOpaque())
            }
            defer { sqlite3_progress_handler(database, 0, nil, nil); withExtendedLifetime(cancellation) {} }
            guard cancellation?.isCancelled != true, let directory = try directory(path: root) else { return nil }
            // Encoded names support short Unicode terms too; phrase quoting keeps
            // spaces and operator-looking names literal, verified against LIKE.
            let trigram = !query.text.isEmpty
            var conditions: [String] = ["n.root=0"]
            if trigram { conditions.append("search_fts MATCH ?") }
            if !query.text.isEmpty { conditions.append("n.name LIKE ? ESCAPE '\\'") }
            if !query.kind.isEmpty { conditions.append("n.kind=?") }
            let start = max(0, offset / 100 * 100)
            let qualifiedColumns = Self.columns.split(separator: ",").map { "e." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ",")
            let sortValue = query.sort.key.isEmpty ? (trigram ? "search_fts.rowid" : "n.id") : query.sort.expression(alias: "n", path: "((SELECT path FROM directory_paths WHERE id=n.dir_id)||'/'||n.name)")
            let direction = query.sort.direction
            let source = trigram ? "search_fts CROSS JOIN file_records n ON n.id=search_fts.rowid" : "file_records n"
            let sql = """
                WITH hits AS MATERIALIZED (
                    SELECT n.id, \(sortValue) AS sort_value FROM \(source) WHERE \(conditions.joined(separator: " AND ")) ORDER BY \(sortValue) \(direction)\(query.sort.key.isEmpty ? "" : ",n.id") LIMIT 101 OFFSET ?
                ) SELECT \(qualifiedColumns) FROM hits h JOIN entries e ON e.id=h.id ORDER BY h.sort_value COLLATE NOCASE \(direction),h.id
                """
            let q = try prepare(sql)
            defer { sqlite3_finalize(q) }
            var index: Int32 = 1
            if trigram { try bind(DiskSearchTokens.match(query.text), to: q, at: index); index += 1 }
            if !query.text.isEmpty { try bind(query.escapedPattern, to: q, at: index); index += 1 }
            if !query.kind.isEmpty { try bind(query.kind, to: q, at: index); index += 1 }
            sqlite3_bind_int64(q, index, Int64(start))
            var rows: [DiskAnalysisEntry] = []
            while true {
                switch sqlite3_step(q) {
                case SQLITE_ROW: rows.append(entry(q))
                case SQLITE_DONE:
                    let more = rows.count > 100
                    let count = start + rows.count
                    if more { rows.removeLast() }
                    return DiskDirectoryPage(requestID: requestID, path: root, bytes: directory.entry.bytes,
                        files: directory.entry.files, skipped: directory.entry.skipped, entryCount: count, offset: start,
                        entries: rows, breadcrumbs: [.init(name: directory.entry.name, path: root)], filtered: true, countIsExact: !more, searchText: query.text, searchKind: query.kind, sortKey: query.sort.key, sortDescending: query.sort.descending)
                default:
                    if cancellation?.isCancelled == true { return nil }
                    throw failure()
                }
            }
        }
    }
}
