import Foundation
import SQLite3

extension DiskAnalysisStore {
    private func workbenchCategory(mode: String) -> String {
        if mode == "media" {
            return """
                CASE WHEN lower(extension) IN ('raw','dng','cr2','cr3','nef','arw','orf','rw2','raf','pef','srw') THEN 'raw'
                WHEN lower(extension)='gif' THEN 'gif'
                WHEN kind='video' OR lower(extension) IN ('mp4','mov','mkv','avi','webm','m4v') THEN CASE WHEN lower(name) LIKE '%screen%record%' OR name LIKE '%屏幕录制%' OR name LIKE '%录屏%' THEN 'recording' ELSE 'video' END
                WHEN kind='image' OR lower(extension) IN ('png','jpg','jpeg','heic','webp','tiff') THEN CASE WHEN lower(name) LIKE '%screenshot%' OR name LIKE '%截屏%' OR name LIKE '%截图%' THEN 'screenshot' ELSE 'image' END ELSE '' END
                """
        }
        return "kind"
    }
    func workbenchIndexed(requestID: String, queryID: String, mode: String, filter: DiskWorkbenchFilter, cancellation: DiskScanCancellation, progress: (String) -> Void = { _ in }) throws -> DiskWorkbenchReport {
        if mode == "developer" { return try developerFolders(requestID:requestID,queryID:queryID,filter:filter,cancellation:cancellation,progress:progress) }
        return try storageSnapshot(cancellation:cancellation) {
            var result = DiskWorkbenchReport(requestID:requestID,queryID:queryID,mode:mode,offset:filter.offset)
            let expression = workbenchCategory(mode:mode)
            let early: String
            switch mode {
            case "media": early = "id IN (SELECT id FROM file_records WHERE root=0 AND directory=0 AND files>0 AND (kind IN ('image','video') OR extension IN ('raw','dng','cr2','cr3','nef','arw','orf','rw2','raf','pef','srw','gif','mp4','mov','mkv','avi','webm','m4v','png','jpg','jpeg','heic','webp','tiff')))"
            case "permissions": early = "directory=1 AND (note<>'' OR skipped>0)"
            default: early = "0"
            }
            let category = mode == "media" && ["4k","large-video"].contains(filter.category) ? "video" : filter.category
            let categoryWhere = mode == "media" && category == "video" ? "category IN ('video','recording')" : "(?='' OR category=?)"
            let bindings = mode == "media" && category == "video" ? [filter.text,filter.text] : [category,category,filter.text,filter.text]
            let additional = mode == "media" && filter.category == "large-video" ? "AND logical_bytes>=1073741824" : ""
            progress("正在筛选候选元数据；不读取文件内容…")
            // Only compact matches are materialized, once. The page and totals reuse them.
            try execute("DROP TABLE IF EXISTS temp.workbench_matches; CREATE TEMP TABLE workbench_matches(id INTEGER PRIMARY KEY,path TEXT,category TEXT,bytes INTEGER,priority INTEGER);")
            let insert = try prepare("INSERT INTO workbench_matches SELECT id,path,category,bytes,CASE WHEN note LIKE '无法读取目录%' THEN 0 WHEN note<>'' THEN 1 ELSE 2 END FROM (SELECT id,path,bytes,note,logical_bytes,\(expression) AS category FROM entries WHERE \(early)) WHERE category<>'' AND \(categoryWhere) AND (?='' OR instr(lower(path),lower(?))>0) \(additional)")
            defer { sqlite3_finalize(insert) }
            for (i,value) in bindings.enumerated() { try bind(value,to:insert,at:Int32(i+1)) }
            guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
            progress("候选筛选完成，正在排列当前页…")
            let order = mode == "permissions" ? "priority,bytes DESC,path" : "bytes DESC,path"
            let columns = Self.columns.split(separator:",").map { "e." + $0.trimmingCharacters(in:.whitespaces) }.joined(separator:",")
            let q = try prepare("WITH page AS MATERIALIZED (SELECT * FROM workbench_matches ORDER BY \(order) LIMIT 101 OFFSET ?) SELECT \(columns),p.category FROM page p JOIN entries e ON e.id=p.id ORDER BY \(mode == "permissions" ? "p.priority," : "")p.bytes DESC,p.path")
            defer { sqlite3_finalize(q) }; try bind(String(filter.offset),to:q,at:1)
            while true {
                let step = sqlite3_step(q); if step == SQLITE_DONE { break }; guard step == SQLITE_ROW else { throw failure() }
                let e = entry(q), category = mode == "permissions" ? "limited" : string(q,18)
                result.rows.append(DiskWorkbenchRow(title:e.name,path:e.path,category:category,bytes:e.bytes,
                    detail:mode == "permissions" ? (e.note.isEmpty ? "后代存在遗漏；不一定是权限拒绝，可能为云端、挂载卷或深度限制。" : e.note) : "\(e.directory ? "目录累计占用" : "文件占用")\(e.skipped > 0 ? " · 受限 \(e.skipped) 项" : "")",entry:e))
            }
            result.hasMore=result.rows.count>100; result.rows=Array(result.rows.prefix(100))
            if filter.offset == 0 {
                progress("正在汇总已筛选项目；保留父子目录去重…")
                let stats = try prepare("SELECT path,category,bytes FROM workbench_matches ORDER BY path||'/'"); defer { sqlite3_finalize(stats) }
                var sums:[String:UInt64]=[:],counts:[String:Int]=[:],last:[String:String]=[:]
                var total:UInt64=0,outer=""
                while true {
                    let step=sqlite3_step(stats); if step==SQLITE_DONE{break};guard step==SQLITE_ROW else{throw failure()}
                    let path=string(stats,0),key=mode=="permissions" ? "limited" : string(stats,1),bytes=UInt64(max(0,sqlite3_column_int64(stats,2)))
                    if let parent=last[key], path.hasPrefix(parent+"/") {} else { sums[key,default:0]+=bytes; counts[key,default:0]+=1;last[key]=path }
                    if !outer.isEmpty && path.hasPrefix(outer+"/") {} else {total+=bytes;outer=path}
                }
                result.stats=sums.keys.sorted().map { DiskWorkbenchStat(key:$0,title:$0,bytes:sums[$0] ?? 0,count:counts[$0] ?? 0) }
                result.stats.insert(DiskWorkbenchStat(key:"total",title:"去重占用",bytes:total,count:counts.values.reduce(0,+)),at:0)
            }
            result.note = mode == "permissions" ? "当前磁盘读取能力检查通过；Full Disk Access 由存储卷页手动检测。此处列出索引中的受限/遗漏目录及原因，父目录包含后代累计遗漏；不是所有项目都代表未授权。不会自动申请或修改权限。" : "大型视频 ≥1 GiB；RAW/GIF 按后缀识别，截图/录屏按名称推断。4K 只显示读取到分辨率的文件；选择 4K 或点击识别本页按需读取属性，不生成缩略图，不下载云端文件。"
            return result
        }
    }
    func duplicateCandidates(requestID: String, queryID: String, filter: DiskWorkbenchFilter, cancellation: DiskScanCancellation, progress: (String) -> Void = { _ in }) throws -> DiskWorkbenchReport {
        try storageSnapshot(cancellation:cancellation) {
            var result=DiskWorkbenchReport(requestID:requestID,queryID:queryID,mode:"duplicates",offset:filter.offset)
            progress("正在按文件大小筛选重复候选；尚未读取内容…")
            let candidate = """
                n.root=0 AND n.directory=0 AND n.files>0 AND n.logical_bytes>0
                AND (n.links<=1 OR n.id=(SELECT MIN(k.id) FROM file_records k WHERE k.links>1 AND k.device=n.device AND k.inode=n.inode))
                AND EXISTS (SELECT 1 FROM file_records other WHERE other.root=0 AND other.directory=0 AND other.files>0 AND other.logical_bytes>0
                    AND other.logical_bytes=n.logical_bytes AND other.id<>n.id AND (other.device<>n.device OR other.inode<>n.inode))
                """
            let sql: String, values: [String]
            if filter.category.isEmpty && filter.text.isEmpty {
                // Rank integer IDs with the existing size index, then materialize only this page's paths.
                let columns = Self.columns.split(separator:",").map { "e." + $0.trimmingCharacters(in:.whitespaces) }.joined(separator:",")
                sql = """
                    WITH page AS MATERIALIZED (SELECT n.id,n.logical_bytes FROM file_records n WHERE \(candidate) ORDER BY n.logical_bytes DESC,n.id LIMIT 101 OFFSET ?)
                    SELECT \(columns),\(DiskStorageCategory.sql(record:"e",parent:"e.parent")) FROM page p JOIN entries e ON e.id=p.id ORDER BY p.logical_bytes DESC,p.id
                    """
                values=[String(filter.offset)]
            } else {
                sql = """
                    WITH hits AS (SELECT n.*,d.path AS parent,CASE WHEN d.path='/' THEN '/'||n.name ELSE d.path||'/'||n.name END AS path,\(DiskStorageCategory.sql(record:"n",parent:"d.path")) AS category
                        FROM file_records n JOIN directory_paths d ON d.id=n.dir_id WHERE \(candidate))
                    SELECT \(Self.columns),category FROM hits WHERE (?='' OR category=?) AND (?='' OR instr(lower(path),lower(?))>0)
                    ORDER BY logical_bytes DESC,path LIMIT 101 OFFSET ?
                    """
                values=[filter.category,filter.category,filter.text,filter.text,String(filter.offset)]
            }
            let q=try prepare(sql);defer{sqlite3_finalize(q)}
            for (i,value) in values.enumerated(){try bind(value,to:q,at:Int32(i+1))}
            while true {let step=sqlite3_step(q);if step==SQLITE_DONE{break};guard step==SQLITE_ROW else{throw failure()};let e=entry(q)
                result.rows.append(DiskWorkbenchRow(title:e.name,path:e.path,category:string(q,18),bytes:e.bytes,detail:"相同大小候选 · 文件大小 \(ByteCountFormatter.string(fromByteCount:Int64(clamping:e.logicalBytes),countStyle:.file)) · 尚未内容校验",entry:e))}
            result.hasMore=result.rows.count>100;result.rows=Array(result.rows.prefix(100))
            result.note="相同大小不等于重复。点击「校验本页」才读取本页候选内容并分块 SHA-256；硬链接只保留一个路径。跨页校验结果保存在独立扩展表，未校验的文件不认定为重复。保留至少一份原文件，清理需逐项确认。"
            return result
        }
    }
    func workbenchKnown(requestID: String, queryID: String, root: String, mode: String, filter: DiskWorkbenchFilter, insights: DiskInsightReport?, cancellation: DiskScanCancellation) throws -> DiskWorkbenchReport {
        var result=DiskWorkbenchReport(requestID:requestID,queryID:queryID,mode:mode,offset:filter.offset)
        let home=DiskInsightRules.home
        func mapped(_ path:String)->String{root==DiskInsightRules.data ? root+path : path}
        var rows:[DiskWorkbenchRow]=[]
        if mode=="browser" || mode=="chat" {
            let clients:[(String,[String])] = mode=="browser" ? [("Safari",["safari"]),("Chrome",["google.chrome","google/chrome","google chrome"]),("Edge",["microsoft.edge","microsoft edge"]),("Firefox",["firefox","mozilla"]),("Arc",["company.thebrowser","/arc/"])] : [("微信",["xinwechat","/wechat/","weixin"]),("Telegram",["telegram"]),("Discord",["discord"]),("Slack",["tinyspeck.slack","/slack/"]),("LINE",["naver.line","line.mac"]),("QQ",["com.tencent.qq","/qq/"]),("企业微信",["wxwork","wecom","wework"]) ]
            let items=(insights?.items ?? [])+(insights?.apps.flatMap(\.parts).filter{$0.section=="body"} ?? [])
            var seen=Set<String>()
            for item in items {
                if cancellation.isCancelled{throw Failure(message:"已取消。")}
                let match=(item.entry.path+"/"+item.owner+"/"+item.ownerID+"/").lowercased()
                if let client=clients.first(where:{ pair in pair.1.contains(where:match.contains)}),seen.insert(item.entry.path).inserted {
                    rows.append(DiskWorkbenchRow(title:item.entry.name,path:item.entry.path,category:client.0,bytes:item.entry.bytes,detail:"\(item.section) · \(item.shared ? "共享目录，不能直接归为独占" : "路径与应用归属规则")",entry:item.entry))
                }
            }
            for client in clients {let candidates=rows.filter{$0.category==client.0};result.stats.append(DiskWorkbenchStat(key:client.0,title:client.0,bytes:Self.uniqueSpace(candidates),count:candidates.count))}
            result.note="App 本体、缓存、配置、容器与支持目录汇总；只统计当前卷已索引目录，共享与未知归属可能影响准确性。聊天附件、浏览器配置及离线数据仅分析，需在应用内确认处理。"
        } else if mode=="system" {
            try storageSnapshot(cancellation:cancellation) {
                for base in [home+"/Library","/Library","/private/var"] {
                    for e in try insightChildren(mapped(base)) {
                        let name=e.name.lowercased(),category:String
                        if name=="caches"{category="Caches"}else if name=="logs"{category="Logs"}else if name=="application support"{category="Application Support"}else if ["containers","group containers"].contains(name){category="Containers"}else if name=="vm"{category="Swap"}else if name=="developer"{category="Developer Data"}else{category="其他系统数据"}
                        rows.append(DiskWorkbenchRow(title:e.name,path:e.path,category:category,bytes:e.bytes,detail:"受保护/应用数据目录，仅供分析\(e.skipped>0 ? " · 有受限项" : "")",entry:e))
                    }
                }
            }
            for key in ["Caches","Logs","Application Support","Containers","Swap","Developer Data","其他系统数据"] {let candidates=rows.filter{$0.category==key};result.stats.append(DiskWorkbenchStat(key:key,title:key,bytes:Self.uniqueSpace(candidates),count:candidates.count))}
            result.stats.insert(DiskWorkbenchStat(key:"total",title:"System Data · 目录估算",bytes:Self.uniqueSpace(rows),count:rows.count),at:0)
            result.note="System Data 为已索引的用户/系统 Library 与 /private/var 目录估算，不等同于 macOS 存储分类；快照、共享块和未索引目录可能导致差异。Swap 为 /private/var/vm 索引快照，变化快；禁止直接清理。"
        } else if mode=="backups" {
            let backups=try storageSnapshot(cancellation:cancellation){try insightChildren(mapped(home+"/Library/Application Support/MobileSync/Backup"))}
            var dates:[String:Double]=[:]
            for e in backups where e.directory {
                if cancellation.isCancelled{throw Failure(message:"已取消。")}
                let info=NSDictionary(contentsOf:URL(fileURLWithPath:e.path).appendingPathComponent("Info.plist")) as? [String:Any] ?? [:]
                let name=info["Device Name"] as? String ?? info["Display Name"] as? String ?? e.name
                let serial=info["Serial Number"] as? String ?? info["Unique Identifier"] as? String ?? e.name
                let time=(info["Last Backup Date"] as? Date)?.timeIntervalSince1970 ?? e.modified
                dates[serial]=max(dates[serial] ?? 0,time)
                rows.append(DiskWorkbenchRow(title:name,path:e.path,category:serial,bytes:e.bytes,detail:"设备备份 · \(info["Product Type"] as? String ?? "未知型号")",timestamp:time,entry:e))
            }
            for i in rows.indices {let age=Date().timeIntervalSince1970-rows[i].timestamp;rows[i].detail += rows[i].timestamp < (dates[rows[i].category] ?? 0) ? " · 同设备有更新备份（旧备份候选）" : age>180*86400 ? " · 超过 180 天，是否仍需要请确认" : " · 此设备最新已识别备份"}
            result.stats=[DiskWorkbenchStat(key:"total",title:"设备备份",bytes:Self.uniqueSpace(rows),count:rows.count)]
            result.note="仅本机 MobileSync 已索引备份；日期优先读取备份 Info.plist，缺失则为目录修改时间。旧备份只是候选，建议在 Finder 的管理备份中处理，不能据此断定可删除。"
        }
        let selected=rows.filter{(filter.category.isEmpty || $0.category==filter.category) && (filter.text.isEmpty || ($0.path+$0.title).localizedCaseInsensitiveContains(filter.text))}.sorted{$0.bytes>$1.bytes}
        result.rows=Array(selected.dropFirst(filter.offset).prefix(100));result.hasMore=selected.count>filter.offset+100
        return result
    }
    static func uniqueSpace(_ rows:[DiskWorkbenchRow])->UInt64 {
        var roots:[String]=[],total:UInt64=0
        for row in rows.sorted(by:{$0.path.count<$1.path.count}) where !row.path.isEmpty {
            if !roots.contains(where:{row.path==$0 || row.path.hasPrefix($0+"/")}){roots.append(row.path);total+=row.bytes}
        }
        return total
    }
    func historyItems(root:String,insights:DiskInsightReport?,tracked:[String] = [],cancellation:DiskScanCancellation)throws->[DiskWorkbenchRow]{
        var rows:[DiskWorkbenchRow]=[]
        try storageSnapshot(cancellation:cancellation){
            let home=root==DiskInsightRules.data ? root+DiskInsightRules.home : DiskInsightRules.home
            let q=try prepare("SELECT \(Self.columns) FROM entries WHERE id IN (SELECT id FROM file_records WHERE directory=1 AND bytes>=67108864 ORDER BY bytes DESC LIMIT 256)")
            defer{sqlite3_finalize(q)}
            while true{let step=sqlite3_step(q);if step==SQLITE_DONE{break};guard step==SQLITE_ROW else{throw failure()};let e=entry(q);rows.append(DiskWorkbenchRow(title:e.name,path:e.path,category:"directory",bytes:e.bytes,detail:e.skipped>0 || !e.note.isEmpty ? "受限" : "",entry:e))}
            for path in tracked where path==root || path.hasPrefix(root=="/" ? "/" : root+"/") {
                if let e=try indexedEntry(path),e.directory{rows.append(DiskWorkbenchRow(title:e.name,path:e.path,category:"directory",bytes:e.bytes,detail:e.skipped>0 || !e.note.isEmpty ? "受限" : "",entry:e))}
            }
            for base in [root,home,home+"/Library"] {
                for e in try insightChildren(base) where e.directory {rows.append(DiskWorkbenchRow(title:e.name,path:e.path,category:"directory",bytes:e.bytes,detail:e.skipped>0 || !e.note.isEmpty ? "受限" : "",entry:e))}
            }
        }
        for app in insights?.apps ?? [] {rows.append(DiskWorkbenchRow(title:app.name,path:app.path,category:"application",bytes:app.bytes,detail:"已归属占用，共享单列"))}
        return rows
    }
}
