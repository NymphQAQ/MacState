import Foundation
import SQLite3

struct DiskWorkbenchRow: Codable {
    var title: String
    var path = ""
    var category = ""
    var bytes: UInt64 = 0
    var detail = ""
    var timestamp: Double = 0
    var delta: Int64? = nil
    var entry: DiskAnalysisEntry? = nil
    var hash = ""
    var width = 0
    var height = 0
    var totalBytes: UInt64? = nil
    var availableBytes: UInt64? = nil
    var previousBytes: UInt64? = nil
}
struct DiskWorkbenchStat: Codable { let key: String; let title: String; let bytes: UInt64; let count: Int }
struct DiskGrowthPoint: Codable {
    let timestamp: Double
    let indexedDelta: Int64
    let volumeDelta: Int64?
}
struct DiskGrowthSummary: Codable {
    let baseline: Double?
    let latest: Double
    var volumeDelta: Int64? = nil
    var indexedDelta: Int64? = nil
    var unmatchedCount = 0
    var resultCount = 0
    var largestChange: UInt64 = 0
    var trend: [DiskGrowthPoint] = []
}
struct DiskWorkbenchReport: Codable {
    let requestID: String
    let queryID: String
    let mode: String
    var rows: [DiskWorkbenchRow] = []
    var stats: [DiskWorkbenchStat] = []
    var points: [DiskWorkbenchRow] = []
    var offset = 0
    var hasMore = false
    var note = ""
    var error = ""
    var updated = Date().timeIntervalSince1970
    var growth: DiskGrowthSummary? = nil
}
struct DiskWorkbenchProgress: Codable { let requestID:String;let queryID:String;let message:String; var completed:Int? = nil; var total:Int? = nil }

struct DiskWorkbenchFilter {
    var category = ""
    var text = ""
    var offset = 0
    var growthHours = 24
    var growthDecreasing = false
    var captureGrowthSample = false
    var enrich = false
    var since: Double = 0
    var until: Double = 0
    var developerNames: [String] = []
}

/// Enrichment and history are independent of the metadata index. Never used
/// by the filesystem scanner, and never silently initiates content hashing.
final class DiskStorageCatalog {
    private struct HistoryKey: Hashable {
        let path: String
        let kind: String
    }

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw DiskAnalysisStore.Failure(message: "无法打开存储扩展数据库。") }
        do {
            try execute("""
                PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=3000; PRAGMA cache_size=-4096;
                CREATE TABLE IF NOT EXISTS file_enrichment(
                    volume TEXT NOT NULL,path TEXT NOT NULL,device INTEGER,inode INTEGER,size INTEGER,modified REAL,changed REAL,
                    hash TEXT NOT NULL DEFAULT '',width INTEGER NOT NULL DEFAULT 0,height INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(volume,path));
                CREATE INDEX IF NOT EXISTS enriched_hash ON file_enrichment(volume,hash) WHERE hash<>'';
                CREATE TABLE IF NOT EXISTS storage_samples(id INTEGER PRIMARY KEY,volume TEXT NOT NULL,time REAL NOT NULL,bytes INTEGER,used INTEGER,files INTEGER,directories INTEGER,limited INTEGER);
                CREATE INDEX IF NOT EXISTS storage_sample_time ON storage_samples(volume,time);
                CREATE TABLE IF NOT EXISTS storage_sample_items(sample INTEGER NOT NULL REFERENCES storage_samples(id),path TEXT NOT NULL,title TEXT,kind TEXT,bytes INTEGER,PRIMARY KEY(sample,path));
                CREATE TABLE IF NOT EXISTS storage_sample_entities(id INTEGER PRIMARY KEY,volume TEXT NOT NULL,path TEXT NOT NULL,title TEXT NOT NULL,kind TEXT NOT NULL,UNIQUE(volume,path,title,kind));
                CREATE TABLE IF NOT EXISTS storage_sample_values(sample INTEGER NOT NULL REFERENCES storage_samples(id),entity INTEGER NOT NULL REFERENCES storage_sample_entities(id),bytes INTEGER NOT NULL,PRIMARY KEY(sample,entity)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS storage_tracked_paths(volume TEXT NOT NULL,path TEXT NOT NULL,PRIMARY KEY(volume,path)) WITHOUT ROWID;
                CREATE VIEW IF NOT EXISTS storage_history_items AS SELECT v.sample,e.path,e.title,e.kind,v.bytes FROM storage_sample_values v JOIN storage_sample_entities e ON e.id=v.entity
                    UNION ALL SELECT sample,path,title,kind,bytes FROM storage_sample_items WHERE sample NOT IN (SELECT DISTINCT sample FROM storage_sample_values);
                PRAGMA foreign_keys=ON;
                """)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    func execute(_ sql: String) throws { guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw failure() } }
    private func failure() -> DiskAnalysisStore.Failure { DiskAnalysisStore.Failure(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "扩展数据库不可用。") }
    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var q: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&q,nil) == SQLITE_OK, let q else { throw failure() }
        for (i,value) in values.enumerated() { sqlite3_bind_text(q,Int32(i+1),value,-1,transient) }
        return q
    }
    private func text(_ q: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(q,i).map { String(cString:$0) } ?? "" }
    private func done(_ q: OpaquePointer) throws { guard sqlite3_step(q) == SQLITE_DONE else { throw failure() } }
    func enrichment(volume: String, entry: DiskAnalysisEntry, changed: Double) throws -> (String,Int,Int)? {
        lock.lock(); defer { lock.unlock() }
        let q = try statement("SELECT hash,width,height FROM file_enrichment WHERE volume=? AND path=? AND device=? AND inode=? AND size=? AND modified=? AND changed=?",[volume,entry.path,String(entry.device),String(entry.inode),String(entry.logicalBytes),String(entry.modified),String(changed)])
        defer { sqlite3_finalize(q) }
        return sqlite3_step(q) == SQLITE_ROW ? (text(q,0),Int(sqlite3_column_int(q,1)),Int(sqlite3_column_int(q,2))) : nil
    }
    func saveEnrichment(volume: String, entry: DiskAnalysisEntry, changed: Double, hash: String? = nil, width: Int? = nil, height: Int? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let old = try enrichment(volume: volume, entry: entry, changed: changed)
        let q = try statement("INSERT OR REPLACE INTO file_enrichment(volume,path,device,inode,size,modified,changed,hash,width,height) VALUES(?,?,?,?,?,?,?,?,?,?)",[volume,entry.path,String(entry.device),String(entry.inode),String(entry.logicalBytes),String(entry.modified),String(changed),hash ?? old?.0 ?? "",String(width ?? old?.1 ?? 0),String(height ?? old?.2 ?? 0)])
        defer { sqlite3_finalize(q) }; try done(q)
    }
    func track(volume:String,path:String)throws{
        lock.lock();defer{lock.unlock()}
        let q=try statement("INSERT OR IGNORE INTO storage_tracked_paths(volume,path) VALUES(?,?)",[volume,path]);defer{sqlite3_finalize(q)};try done(q)
    }
    func tracked(volume:String)throws->[String]{
        lock.lock();defer{lock.unlock()}
        let q=try statement("SELECT path FROM storage_tracked_paths WHERE volume=?",[volume]);defer{sqlite3_finalize(q)}
        var paths:[String]=[];while sqlite3_step(q)==SQLITE_ROW{paths.append(text(q,0))};return paths
    }
    func walkHistory(volume:String,displayVolume:String,cancellation:DiskScanCancellation,emit:(DiskWorkbenchRow)throws->Void)throws{
        lock.lock();defer{lock.unlock()}
        let q=try statement("SELECT s.time,i.path,i.title,i.kind,i.bytes FROM storage_samples s JOIN storage_history_items i ON i.sample=s.id WHERE s.volume=? UNION ALL SELECT time,volume,'存储卷','volume',bytes FROM storage_samples WHERE volume=? ORDER BY 1,2",[volume,volume]);defer{sqlite3_finalize(q)}
        while true{if cancellation.isCancelled{throw DiskAnalysisStore.Failure(message:"已取消导出。")};let step=sqlite3_step(q);if step==SQLITE_DONE{break};guard step==SQLITE_ROW else{throw failure()}
            try emit(DiskWorkbenchRow(title:text(q,2),path:text(q,3)=="volume" ? displayVolume : text(q,1),category:text(q,3),bytes:UInt64(max(0,sqlite3_column_int64(q,4))),detail:"历史采样",timestamp:sqlite3_column_double(q,0)))}
    }
    func hashPeers(volume:String,hash:String)throws->[String]{
        lock.lock();defer{lock.unlock()}
        let q=try statement("SELECT path FROM file_enrichment WHERE volume=? AND hash=? ORDER BY path LIMIT 200",[volume,hash]);defer{sqlite3_finalize(q)}
        var paths:[String]=[];while sqlite3_step(q)==SQLITE_ROW{paths.append(text(q,0))};return paths
    }
    func latest(volume: String) throws -> Double {
        lock.lock(); defer { lock.unlock() }
        let q = try statement("SELECT MAX(time) FROM storage_samples WHERE volume=?",[volume]); defer { sqlite3_finalize(q) }
        return sqlite3_step(q) == SQLITE_ROW ? sqlite3_column_double(q,0) : 0
    }
    func record(volume: String, status: DiskIndexStatus, used: UInt64, items: [DiskWorkbenchRow]) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            let now = Date().timeIntervalSince1970
            let q = try statement("INSERT INTO storage_samples(volume,time,bytes,used,files,directories,limited) VALUES(?,?,?,?,?,?,?)",[volume,String(now),String(status.bytes),String(used),String(status.files),String(status.directories),String(items.filter { $0.detail.contains("受限") }.count)])
            defer { sqlite3_finalize(q) }; try done(q)
            let id = sqlite3_last_insert_rowid(db)
            let entity=try statement("INSERT OR IGNORE INTO storage_sample_entities(volume,path,title,kind) VALUES(?,?,?,?)")
            let item=try statement("INSERT OR REPLACE INTO storage_sample_values(sample,entity,bytes) SELECT ?,id,? FROM storage_sample_entities WHERE volume=? AND path=? AND title=? AND kind=?")
            defer{sqlite3_finalize(entity);sqlite3_finalize(item)}
            var recorded = Set<HistoryKey>()
            for row in items where recorded.insert(HistoryKey(path: row.path, kind: row.category)).inserted {
                let values=[volume,row.path,row.title,row.category]
                for (i,value) in values.enumerated(){sqlite3_bind_text(entity,Int32(i+1),value,-1,transient)}
                try done(entity);sqlite3_reset(entity);sqlite3_clear_bindings(entity)
                for (i,value) in ([String(id),String(row.bytes)]+values).enumerated(){sqlite3_bind_text(item,Int32(i+1),value,-1,transient)}
                try done(item);sqlite3_reset(item);sqlite3_clear_bindings(item)
            }
            let pruneValues=try statement("DELETE FROM storage_sample_values WHERE sample IN (SELECT id FROM storage_samples WHERE time<?)",[String(now-90*86400)]);defer{sqlite3_finalize(pruneValues)};try done(pruneValues)
            let prune = try statement("DELETE FROM storage_sample_items WHERE sample IN (SELECT id FROM storage_samples WHERE time<?)",[String(now-90*86400)]); defer { sqlite3_finalize(prune) }; try done(prune)
            let pruneSamples = try statement("DELETE FROM storage_samples WHERE time<?",[String(now-90*86400)]); defer { sqlite3_finalize(pruneSamples) }; try done(pruneSamples)
            try execute("COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
    }
    func history(requestID: String, queryID: String, volume: String, filter: DiskWorkbenchFilter, displayVolume: String = "") throws -> DiskWorkbenchReport {
        lock.lock(); defer { lock.unlock() }
        var result = DiskWorkbenchReport(requestID:requestID,queryID:queryID,mode:"history",offset:filter.offset)
        let points = try statement("SELECT time,bytes,used,files,directories FROM storage_samples WHERE volume=? AND time>=? AND (CAST(? AS REAL)=0 OR time<=?) ORDER BY time",[volume,String(filter.since > 0 ? filter.since : Date().timeIntervalSince1970-90*86400),String(filter.until),String(filter.until)])
        defer { sqlite3_finalize(points) }
        while sqlite3_step(points) == SQLITE_ROW {
            let time = sqlite3_column_double(points,0),bytes = UInt64(max(0,sqlite3_column_int64(points,1)))
            result.points.append(DiskWorkbenchRow(title:Date(timeIntervalSince1970:time).formatted(),path:displayVolume,category:"volume",bytes:bytes,detail:"卷已用 \(ByteCountFormatter.string(fromByteCount: sqlite3_column_int64(points,2),countStyle:.file)) · \(sqlite3_column_int64(points,3)) 文件 · \(sqlite3_column_int64(points,4)) 目录",timestamp:time))
        }
        guard !result.points.isEmpty else { result.note="尚无历史记录。索引就绪后自动记录，此后每小时采样；不推测过去的数据。"; return result }
        result.rows = Array(result.points.reversed().dropFirst(filter.offset).prefix(100)); result.hasMore = result.points.count > filter.offset+100
        // Bound chart payload to one representative sample per roughly equal interval.
        if result.points.count > 240 { let stride = max(1,result.points.count/239); let all = result.points; result.points = all.enumerated().filter { $0.offset % stride == 0 }.map(\.element); if result.points.last?.timestamp != all.last?.timestamp, let last = all.last { result.points.append(last) } }
        result.note="真实索引采样，保留 90 天；范围为主要目录、最大 256 个目录、手动浏览目录与已归属应用。曲线为索引文件占用，卷已用空间包含快照、共享空间与未索引数据。点击记录可查看当时目录/应用占用。"
        return result
    }

    func growth(requestID: String, queryID: String, volume: String, root: String,
                filter: DiskWorkbenchFilter, cancellation: DiskScanCancellation) throws -> DiskWorkbenchReport {
        lock.lock(); defer { lock.unlock() }
        var report = DiskWorkbenchReport(requestID: requestID, queryID: queryID, mode: "growth", offset: filter.offset)
        let latestQuery = try statement("""
            SELECT id,time,bytes,used FROM storage_samples WHERE volume=? ORDER BY time DESC,id DESC LIMIT 1
            """, [volume])
        defer { sqlite3_finalize(latestQuery) }
        let latestStep = sqlite3_step(latestQuery)
        if latestStep == SQLITE_DONE { return report }
        guard latestStep == SQLITE_ROW else { throw failure() }
        let latestID = sqlite3_column_int64(latestQuery, 0)
        let latestTime = sqlite3_column_double(latestQuery, 1)
        let target = latestTime - Double(filter.growthHours) * 3600
        let baselineQuery = try statement("""
            SELECT id,time,bytes,used FROM storage_samples WHERE volume=? AND time<?
            ORDER BY ABS(time-CAST(? AS REAL)),time DESC,id DESC LIMIT 1
            """, [volume, String(latestTime), String(target)])
        defer { sqlite3_finalize(baselineQuery) }
        let baselineStep = sqlite3_step(baselineQuery)
        if baselineStep == SQLITE_DONE {
            report.growth = DiskGrowthSummary(baseline: nil, latest: latestTime)
            return report
        }
        guard baselineStep == SQLITE_ROW else { throw failure() }
        let baselineID = sqlite3_column_int64(baselineQuery, 0)
        let baselineTime = sqlite3_column_double(baselineQuery, 1)
        let latestUsed = sqlite3_column_int64(latestQuery, 3), baselineUsed = sqlite3_column_int64(baselineQuery, 3)
        let baselineIndexed = sqlite3_column_int64(baselineQuery, 2)
        var summary = DiskGrowthSummary(
            baseline: baselineTime, latest: latestTime,
            volumeDelta: latestUsed > 0 && baselineUsed > 0 ? latestUsed - baselineUsed : nil,
            indexedDelta: sqlite3_column_int64(latestQuery, 2) - baselineIndexed
        )
        let trendQuery = try statement("""
            SELECT time,bytes,used FROM storage_samples
            WHERE volume=? AND time>=? AND time<=?
            ORDER BY time,id
            """, [volume, String(baselineTime), String(latestTime)])
        defer { sqlite3_finalize(trendQuery) }
        while !cancellation.isCancelled {
            let step = sqlite3_step(trendQuery)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw failure() }
            let used = sqlite3_column_int64(trendQuery, 2)
            summary.trend.append(DiskGrowthPoint(
                timestamp: sqlite3_column_double(trendQuery, 0),
                indexedDelta: sqlite3_column_int64(trendQuery, 1) - baselineIndexed,
                volumeDelta: baselineUsed > 0 && used > 0 ? used - baselineUsed : nil
            ))
        }
        let before = try growthItems(sample: baselineID, cancellation: cancellation)
        let after = try growthItems(sample: latestID, cancellation: cancellation)
        func matches(_ key: HistoryKey, _ row: DiskWorkbenchRow) -> Bool {
            key.path != root && (filter.category.isEmpty || key.kind == filter.category) &&
                (filter.text.isEmpty || key.path.localizedCaseInsensitiveContains(filter.text) ||
                    row.title.localizedCaseInsensitiveContains(filter.text))
        }
        var changes: [DiskWorkbenchRow] = []
        for (key, var row) in after where matches(key, row) {
            guard !cancellation.isCancelled else { throw CancellationError() }
            guard let previous = before[key] else { summary.unmatchedCount += 1; continue }
            let delta = Int64(clamping: row.bytes) - Int64(clamping: previous.bytes)
            guard filter.growthDecreasing ? delta < 0 : delta > 0 else { continue }
            row.previousBytes = previous.bytes
            row.delta = delta
            changes.append(row)
        }
        for (key, row) in before where after[key] == nil && matches(key, row) {
            summary.unmatchedCount += 1
        }
        if filter.text.isEmpty {
            let directoryDeltas = Dictionary(uniqueKeysWithValues: changes.filter { $0.category == "directory" }
                .map { ($0.path, $0.delta ?? 0) })
            var redundant = Set<String>()
            for (path, delta) in directoryDeltas {
                var parent = (path as NSString).deletingLastPathComponent
                while !parent.isEmpty && parent != "/" && parent != path {
                    if directoryDeltas[parent] == delta { redundant.insert(parent) }
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
            changes.removeAll { $0.category == "directory" && redundant.contains($0.path) }
        }
        changes.sort {
            let left = ($0.delta ?? 0).magnitude, right = ($1.delta ?? 0).magnitude
            return left == right ? ($0.path, $0.category) < ($1.path, $1.category) : left > right
        }
        summary.resultCount = changes.count
        summary.largestChange = changes.first?.delta?.magnitude ?? 0
        report.growth = summary
        report.rows = Array(changes.dropFirst(filter.offset).prefix(100))
        report.hasMore = changes.count > filter.offset + 100
        return report
    }

    private func growthItems(sample: Int64, cancellation: DiskScanCancellation) throws -> [HistoryKey: DiskWorkbenchRow] {
        let id = String(sample)
        let q = try statement("""
            SELECT e.path,e.title,e.kind,v.bytes FROM storage_sample_values v
            JOIN storage_sample_entities e ON e.id=v.entity WHERE v.sample=?
            UNION ALL
            SELECT path,title,kind,bytes FROM storage_sample_items WHERE sample=?
            AND NOT EXISTS (SELECT 1 FROM storage_sample_values WHERE sample=?)
            ORDER BY path,kind,bytes DESC,title
            """, [id, id, id])
        defer { sqlite3_finalize(q) }
        var items: [HistoryKey: DiskWorkbenchRow] = [:]
        while !cancellation.isCancelled {
            let step = sqlite3_step(q)
            if step == SQLITE_DONE { return items }
            guard step == SQLITE_ROW else { throw failure() }
            let key = HistoryKey(path: text(q, 0), kind: text(q, 2))
            if items[key] == nil {
                items[key] = DiskWorkbenchRow(title: text(q, 1), path: key.path, category: key.kind,
                    bytes: UInt64(max(0, sqlite3_column_int64(q, 3))))
            }
        }
        throw CancellationError()
    }
    func sampleDetails(volume: String, timestamp: Double) throws -> [DiskWorkbenchRow] {
        lock.lock(); defer { lock.unlock() }
        let q = try statement("SELECT path,title,kind,bytes FROM storage_history_items WHERE sample=(SELECT id FROM storage_samples WHERE volume=? AND time=? LIMIT 1) ORDER BY bytes DESC",[volume,String(timestamp)]); defer { sqlite3_finalize(q) }
        var rows:[DiskWorkbenchRow]=[]
        while sqlite3_step(q)==SQLITE_ROW { rows.append(DiskWorkbenchRow(title:text(q,1),path:text(q,0),category:text(q,2),bytes:UInt64(max(0,sqlite3_column_int64(q,3))),detail:"当时记录的占用")) }
        return rows
    }
}
