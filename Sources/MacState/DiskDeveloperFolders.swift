import Foundation
import SQLite3

enum DiskDeveloperFolders {
    static let defaults = ["Xcode", "DerivedData", "Archives", "CoreSimulator", "node_modules", ".npm", "npm", ".pnpm-store", "pnpm", "pnpm-store", ".yarn", "yarn", "pip", "com.docker.docker", ".docker", ".git", "build", "dist", "target", "models", ".venv", "venv", "Pods", ".gradle", ".m2", ".cargo", ".next", ".nuxt", ".output"]
    static var names: [String] { defaults + (UserDefaults.standard.stringArray(forKey: "storageDeveloperFolderNames") ?? []).filter { custom in !defaults.contains { $0.caseInsensitiveCompare(custom) == .orderedSame } } }
    static func add(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DiskAnalysisStore.Failure(message: "请输入单个文件夹名称，不能包含路径或换行，长度不超过 255 字节。")
        }
        if let existing = names.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return existing }
        var custom = UserDefaults.standard.stringArray(forKey: "storageDeveloperFolderNames") ?? []
        custom.append(name); UserDefaults.standard.set(custom, forKey: "storageDeveloperFolderNames")
        return name
    }
}

extension DiskAnalysisStore {
    /// Directory names only, from existing metadata. No filesystem enumeration.
    func developerFolders(requestID: String, queryID: String, filter: DiskWorkbenchFilter, cancellation: DiskScanCancellation, progress: (String) -> Void) throws -> DiskWorkbenchReport {
        try storageSnapshot(cancellation: cancellation) {
            var result = DiskWorkbenchReport(requestID: requestID, queryID: queryID, mode: "developer", offset: filter.offset)
            progress("正在匹配已索引的开发目录名称…")
            try execute("DROP TABLE IF EXISTS temp.developer_names; DROP TABLE IF EXISTS temp.developer_matches; CREATE TEMP TABLE developer_names(name TEXT PRIMARY KEY COLLATE NOCASE); CREATE TEMP TABLE developer_matches(id INTEGER PRIMARY KEY,path TEXT,category TEXT,bytes INTEGER);")
            let rule = try prepare("INSERT OR IGNORE INTO developer_names VALUES (?)")
            defer { sqlite3_finalize(rule) }
            for name in filter.developerNames {
                sqlite3_reset(rule); sqlite3_clear_bindings(rule); try bind(name, to: rule, at: 1)
                guard sqlite3_step(rule) == SQLITE_DONE else { throw failure() }
            }
            try execute("""
                INSERT INTO developer_matches
                SELECT f.id,CASE WHEN d.path='/' THEN '/'||f.name ELSE d.path||'/'||f.name END,r.name,f.bytes
                FROM file_records f JOIN directory_paths d ON d.id=f.dir_id
                JOIN developer_names r ON f.name=r.name COLLATE NOCASE
                WHERE f.root=0 AND f.kind='folder' AND f.directory=1;
                """)
            progress("正在汇总目录数量和占用；嵌套目录不重复相加…")
            let stats = try prepare("SELECT path,category,bytes FROM developer_matches ORDER BY path||'/'")
            defer { sqlite3_finalize(stats) }
            var sums: [String: UInt64] = [:], counts: [String: Int] = [:], last: [String: String] = [:]
            var total: UInt64 = 0, outer = "", count = 0
            while true {
                let step = sqlite3_step(stats); if step == SQLITE_DONE { break }; guard step == SQLITE_ROW else { throw failure() }
                let path = string(stats,0), key = string(stats,1), bytes = UInt64(max(0,sqlite3_column_int64(stats,2)))
                counts[key,default:0] += 1; count += 1
                if let parent = last[key], path.hasPrefix(parent + "/") {} else { sums[key,default:0] += bytes; last[key] = path }
                if !outer.isEmpty && path.hasPrefix(outer + "/") {} else { total += bytes; outer = path }
            }
            result.stats = [DiskWorkbenchStat(key:"total",title:"合计占用",bytes:total,count:count)] + filter.developerNames.map { DiskWorkbenchStat(key:$0,title:$0,bytes:sums[$0] ?? 0,count:counts[$0] ?? 0) }
            progress("正在按占用从大到小排列目录…")
            let columns = Self.columns.split(separator:",").map { "e." + $0.trimmingCharacters(in:.whitespaces) }.joined(separator:",")
            let q = try prepare("WITH page AS MATERIALIZED (SELECT * FROM developer_matches WHERE (?='' OR category=? COLLATE NOCASE) AND (?='' OR instr(lower(path),lower(?))>0) ORDER BY bytes DESC,path LIMIT 101 OFFSET ?) SELECT \(columns),p.category FROM page p JOIN entries e ON e.id=p.id ORDER BY p.bytes DESC,p.path")
            defer { sqlite3_finalize(q) }
            for (i,value) in [filter.category,filter.category,filter.text,filter.text,String(filter.offset)].enumerated() { try bind(value,to:q,at:Int32(i+1)) }
            while true {
                let step = sqlite3_step(q); if step == SQLITE_DONE { break }; guard step == SQLITE_ROW else { throw failure() }
                let e = entry(q)
                result.rows.append(DiskWorkbenchRow(title:e.name,path:e.path,category:string(q,18),bytes:e.bytes,detail:"目录累计占用\(e.skipped > 0 ? " · 存在未计入项" : "")",entry:e))
            }
            result.hasMore = result.rows.count > 100; result.rows = Array(result.rows.prefix(100))
            result.note = "按文件夹名称精确匹配（忽略大小写），包含嵌套目录；卡片统计整个卷，搜索只筛选下方列表。占用采用索引中的实际分配空间，同名嵌套目录和合计中的父子目录不重复相加；各卡片可能重叠，不能直接相加。这不是重复文件检测，也不代表可安全删除；权限受限目录可能统计不完整。models 匹配所有同名目录，不仅限 ComfyUI。"
            return result
        }
    }
}
