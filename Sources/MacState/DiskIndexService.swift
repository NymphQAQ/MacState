import Foundation
import Darwin
import CoreServices
import CryptoKit
import SQLite3

struct DiskIndexStatus: Codable {
    let volumePath: String
    let state: String
    let files: Int
    let directories: Int
    let bytes: UInt64
    let elapsed: Double
    let currentPath: String
    let message: String
    let updated: Double
    let ready: Bool
    var completedAt: Double = 0
    var buildElapsed: Double = 0
    var readConcurrency: Int = 0
    var pendingChanges: Int = 0
    var lastMerged: Double = 0
    var merging: Bool = false
    var synchronizationPaused = false
    var manualSynchronization = false
}

/// One coordinator owns persistent indexes and event cursors. All filesystem and
/// SQL work is off main; UI queries share the bounded SQLite cache, never arrays
/// of the entire volume. Streams continue while the panel is closed.
final class DiskIndexService {
    var onStatuses: (([DiskIndexStatus]) -> Void)?
    var onProgress: ((DiskAnalysisProgress) -> Void)?
    var onDirectory: ((DiskDirectoryPage) -> Void)?
    var onSpaceMap: ((DiskSpaceMapPage) -> Void)?
    var onFileTypes: ((DiskTypeSummary) -> Void)?
    var onWorkbench: ((DiskWorkbenchReport) -> Void)?
    var onWorkbenchProgress: ((String,String,String,Int?,Int?) -> Void)?
    private var workbenchCancellation = DiskScanCancellation()
    private var storageCatalog: DiskStorageCatalog?
    private var storageCatalogError = ""
    private var historyScheduled: [String:Double] = [:]
    private var historyTimer: DispatchSourceTimer?
    private let historyQueries = DispatchQueue(label: "app.macstate.storage-history", qos: .utility)
    private let exportQueries = DispatchQueue(label:"app.macstate.storage-export",qos:.utility)
    private var exportCancellation = DiskScanCancellation()
    private var lastWorkbench: DiskWorkbenchReport?
    private let cloudMetadata = DiskCloudMetadata()
    var onInsights: ((DiskInsightReport) -> Void)?
    private var insightReport: DiskInsightReport?
    var onLargeFiles: ((DiskLargePage) -> Void)?
    var onFileAction: ((DiskFileActionResult) -> Void)?
    var onAccess: ((DiskAccessStatus) -> Void)?
    private let queue = DispatchQueue(label: "app.macstate.file-index", qos: .utility)
    private let workbenchQueries = DispatchQueue(label: "app.macstate.storage-analysis", qos: .utility)
    private let queries = DispatchQueue(label: "app.macstate.file-index-query", qos: .userInitiated)
    private let fileActions = DispatchQueue(label: "app.macstate.file-actions", qos: .utility)
    private var volumes: [String: IndexedVolume] = [:]
    private var selection: (volume: String, request: String, path: String, offset: Int)?
    private var fileQuery = DiskFileQuery()
    private var queryCancellation = DiskScanCancellation()
    private var mapCancellation = DiskScanCancellation()
    private var storageCancellation = DiskScanCancellation()
    private var access: DiskAccessStatus = .unknown
    private var desired: [VolumeRow] = []
    private let baseURL: URL
    init(baseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacState/DiskIndexes/v1", isDirectory: true)) {
        self.baseURL = baseURL
        do { storageCatalog = try DiskStorageCatalog(url: baseURL.deletingLastPathComponent().appendingPathComponent("storage-extras.sqlite")) }
        catch { storageCatalogError = error.localizedDescription }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now()+3600, repeating: 3600)
        timer.setEventHandler { [weak self] in guard let self else{return};for volume in self.volumes.values{self.scheduleStorageHistory(volume)} }
        timer.resume();historyTimer = timer
    }
    deinit { historyTimer?.cancel() }


    func synchronize(_ rows: [VolumeRow]) {
        queue.async { [self] in
            let changed = desired.map(\.path) != rows.map(\.path)
            desired = rows
            guard changed else { return }
            for (path, volume) in volumes where !rows.contains(where: { $0.path == path }) {
                volume.stop(); volumes.removeValue(forKey: path)
            }
            if access == .granted { ensureVolumes() }
        }
    }
    func checkAccess(_ completion: @escaping (DiskAccessStatus) -> Void = { _ in }) {
        queue.async { [self] in
            access = DiskAccess.check()
            if access == .granted {
                for (path, volume) in volumes where volume.status.state == "failed" { volume.stop(); volumes.removeValue(forKey: path) }
                ensureVolumes()
            }
            else { for volume in volumes.values { volume.stop() }; volumes.removeAll(); publish() }
            let status = access
            DispatchQueue.main.async { [weak self] in self?.onAccess?(status); completion(status) }
        }
    }
    private func ensureVolumes() {
        for row in desired where volumes[row.path] == nil {
            let volume = IndexedVolume(volume: row, baseURL: baseURL, queue: queue)
            volume.setSynchronizationPaused(UserDefaults.standard.bool(forKey: volume.synchronizationPreferenceKey))
            volumes[row.path] = volume
            volume.beforeRebuild = { [weak self] in
                guard let self else { return }
                if self.selection?.volume == row.path { self.selection = nil }
                self.queryCancellation.cancel(); self.mapCancellation.cancel(); self.storageCancellation.cancel(); self.workbenchCancellation.cancel(); self.workbenchQueries.sync {}; self.queries.sync {}; self.historyQueries.sync {}; self.exportCancellation.cancel(); self.exportQueries.sync {}
            }
            volume.onChange = { [weak self, weak volume] in
                guard let self else { return }
                self.publish()
                if let volume { self.scheduleStorageHistory(volume) }
                // Do not enqueue the same search on every progress publication.
                if !self.fileQuery.active || volume?.status.state == "ready" { self.refreshSelection() }
            }
            volume.start()
        }
        publish()
    }
    private func publish() {
        let values = volumes.values.map(\.status).sorted { $0.volumePath < $1.volumePath }
        DispatchQueue.main.async { [weak self] in self?.onStatuses?(values) }
    }
    func resend() { queue.async { [self] in publish(); refreshSelection() } }
    func start(volume: VolumeRow, requestID: String) {
        queue.async { [self] in
            guard access == .granted, let index = volumes[volume.path], index.status.ready else {
                DispatchQueue.main.async { [weak self] in self?.onProgress?(DiskAnalysisProgress(requestID: requestID,
                    volumePath: volume.path, rootPath: volume.path, state: "failed", files: 0, directories: 0,
                    bytes: 0, skipped: 0, elapsed: 0, currentPath: "", message: "索引尚未就绪，请先检查权限并等待后台索引完成。", largest: [])) }
                return
            }
            fileQuery = DiskFileQuery(); selection = (volume.path, requestID, index.root.path, 0); refreshSelection()
        }
    }
    func browse(path: String, requestID: String, offset: Int, sort: DiskFileSort = DiskFileSort()) {
        queue.async { [self] in
            guard var selected = selection, selected.request == requestID else { return }
            if let store=volumes[selected.volume]?.store,let catalog=storageCatalog {
                let key=store.storeURL?.lastPathComponent ?? selected.volume
                historyQueries.async{do{let reader=try store.queryView();if try reader.withLock({try reader.directory(path:path)}) != nil{try catalog.track(volume:key,path:path)}}catch{}}
            }
            fileQuery = DiskFileQuery(sort: sort); selected.path = path; selected.offset = offset; selection = selected; refreshSelection()
        }
    }
    func search(requestID: String, text: String, kind: String, offset: Int, sort: DiskFileSort = DiskFileSort()) {
        queue.async { [self] in
            guard var selected = selection, selected.request == requestID else { return }
            fileQuery = DiskFileQuery(text: text, kind: kind, sort: sort); selected.offset = offset; selection = selected; refreshSelection()
        }
    }
    func cancel(requestID: String) { queue.async { [self] in if selection?.request == requestID { selection = nil; queryCancellation.cancel(); mapCancellation.cancel(); storageCancellation.cancel(); workbenchCancellation.cancel() } } }
    func cancel() { queue.async { [self] in for volume in volumes.values { volume.stop() }; volumes.removeAll(); selection = nil; queryCancellation.cancel(); mapCancellation.cancel(); storageCancellation.cancel(); workbenchCancellation.cancel() } }
    func cancelStorageQuery() { queue.async { [self] in storageCancellation.cancel() } }
    func storageFiles(requestID: String, queryID: String, filter: DiskLargeFilter?) {
        queue.async { [self] in
            storageCancellation.cancel()
            let token = DiskScanCancellation(); storageCancellation = token
            guard access == .granted, let selected = selection, selected.request == requestID,
                  let volume = volumes[selected.volume], volume.status.ready, let store = volume.store else {
                let error = "索引暂不可用，请返回存储卷检查权限与索引状态。"
                DispatchQueue.main.async { [weak self] in
                    if filter != nil { self?.onLargeFiles?(DiskLargePage(requestID: requestID, queryID: queryID, error: error)) }
                    else { self?.onFileTypes?(DiskTypeSummary(requestID: requestID, queryID: queryID, error: error)) }
                }
                return
            }
            let root = volume.root.path
            workbenchQueries.async { [weak self] in
                guard !token.isCancelled else { return }
                if let filter {
                    let result: DiskLargePage
                    do { result = try store.isolatedQueryView().largePage(requestID: requestID, queryID: queryID, filter: filter, cancellation: token) }
                    catch { result = DiskLargePage(requestID: requestID, queryID: queryID, error: error.localizedDescription) }
                    DispatchQueue.main.async { [weak self] in if !token.isCancelled { self?.onLargeFiles?(result) } }
                } else {
                    let result: DiskTypeSummary
                    do { result = try store.isolatedQueryView().fileTypes(requestID: requestID, queryID: queryID, root: root, cancellation: token) }
                    catch { result = DiskTypeSummary(requestID: requestID, queryID: queryID, error: error.localizedDescription) }
                    DispatchQueue.main.async { [weak self] in if !token.isCancelled { self?.onFileTypes?(result) } }
                }
            }
        }
    }
    private func scheduleStorageHistory(_ volume: IndexedVolume) {
        guard access == .granted, volume.status.ready, !volume.status.synchronizationPaused,
              let store=volume.store, let catalog=storageCatalog else{return}
        let path=volume.volume.path,now=Date().timeIntervalSince1970
        guard now-(historyScheduled[path] ?? 0)>=3600 else{return};historyScheduled[path]=now
        let catalogVolume=store.storeURL?.lastPathComponent ?? path
        let status=volume.status,root=volume.root.path
        let used = recordedVolumeUsage(path: path)
        do { try store.ensureStorageInsightRules() } catch { storageCatalogError=error.localizedDescription;historyScheduled[path]=0;return }
        historyQueries.async { [weak self] in
            do {
                guard now-(try catalog.latest(volume:catalogVolume))>=3600 else{return}
                try Self.recordStorageSample(store: store, catalog: catalog, volume: catalogVolume,
                    root: root, status: status, used: used, cancellation: DiskScanCancellation())
            }catch{self?.queue.async{[weak self] in self?.historyScheduled[path]=0;self?.storageCatalogError="历史采样失败："+error.localizedDescription}}
        }
    }
    private func recordedVolumeUsage(path: String) -> UInt64 {
        guard let row = desired.first(where: { $0.path == path }) else { return 0 }
        return row.total - min(row.total, row.available)
    }

    private static func recordStorageSample(store: DiskAnalysisStore, catalog: DiskStorageCatalog, volume: String,
                                            root: String, status: DiskIndexStatus, used: UInt64,
                                            cancellation: DiskScanCancellation) throws {
        let reader = try store.isolatedQueryView()
        let insight = try reader.insights(requestID: "history", queryID: UUID().uuidString, root: root, cancellation: cancellation)
        let items = try reader.historyItems(root: root, insights: insight, tracked: try catalog.tracked(volume: volume), cancellation: cancellation)
        guard !cancellation.isCancelled else { throw CancellationError() }
        try catalog.record(volume: volume, status: status, used: used, items: items)
    }
    func pauseVisibleAnalysis() {
        queue.async { [self] in queryCancellation.cancel(); mapCancellation.cancel(); storageCancellation.cancel(); workbenchCancellation.cancel(); lastWorkbench=nil }
        DispatchQueue.main.async { [weak self] in self?.cloudMetadata.cancel() }
    }
    func cancelWorkbench(){
        queue.async{[self] in workbenchCancellation.cancel();lastWorkbench=nil}
        DispatchQueue.main.async{[weak self] in self?.cloudMetadata.cancel()}
    }
    func workbench(requestID:String,queryID:String,mode:String,filter:DiskWorkbenchFilter){
        queue.async{[self] in
            workbenchCancellation.cancel();let token=DiskScanCancellation();workbenchCancellation=token
            lastWorkbench=nil
            guard access == .granted,let selected=selection,selected.request==requestID,let volume=volumes[selected.volume],volume.status.ready,let store=volume.store else{
                DispatchQueue.main.async{[weak self] in self?.onWorkbench?(DiskWorkbenchReport(requestID:requestID,queryID:queryID,mode:mode,error:"索引或权限暂不可用，请返回存储卷检查。"))};return
            }
            if ["browser","chat"].contains(mode){do{try store.ensureStorageInsightRules()}catch{storageCatalogError=error.localizedDescription}}
            let root=volume.root.path,path=selected.volume,status=volume.status,catalog=storageCatalog,catalogError=storageCatalogError
            let catalogVolume=store.storeURL?.lastPathComponent ?? path
            let captureGrowth = mode == "growth" && filter.captureGrowthSample
            if captureGrowth {
                do { try store.ensureStorageInsightRules() }
                catch {
                    let response = DiskWorkbenchReport(requestID: requestID, queryID: queryID, mode: mode, error: error.localizedDescription)
                    DispatchQueue.main.async { [weak self] in if !token.isCancelled { self?.onWorkbench?(response) } }
                    return
                }
            }
            let used = recordedVolumeUsage(path: path)
            if mode=="cloud"{
                DispatchQueue.main.async{[weak self] in
                    guard !token.isCancelled else{return}
                    self?.cloudMetadata.load(requestID:requestID,queryID:queryID,filter:filter,local:status){[weak self] report in
                        guard !token.isCancelled else{return};self?.onWorkbench?(report);self?.queue.async{[weak self] in self?.lastWorkbench=report}
                    }
                };return
            }
            workbenchQueries.async{[weak self] in
                guard !token.isCancelled else{return}
                func progress(_ message:String, _ completed:Int? = nil, _ total:Int? = nil) {
                    DispatchQueue.main.async{[weak self] in if !token.isCancelled{self?.onWorkbenchProgress?(requestID,queryID,message,completed,total)}}
                }
                progress("正在准备独立分析连接…")
                var report=DiskWorkbenchReport(requestID:requestID,queryID:queryID,mode:mode)
                do {
                    let reader = mode == "growth" ? nil : try store.isolatedQueryView()
                    progress("正在查询索引；无需重新扫描磁盘…")
                    if ["history","growth"].contains(mode){
                        guard let catalog else{throw DiskAnalysisStore.Failure(message:catalogError)}
                        if mode == "growth" {
                            if captureGrowth, let self {
                                progress("正在记录当前占用…")
                                try self.historyQueries.sync {
                                    guard !token.isCancelled else { throw CancellationError() }
                                    try Self.recordStorageSample(store: store, catalog: catalog, volume: catalogVolume,
                                        root: root, status: status, used: used, cancellation: token)
                                }
                            }
                            report = try catalog.growth(requestID: requestID, queryID: queryID, volume: catalogVolume,
                                root: root, filter: filter, cancellation: token)
                        } else if filter.since>0 && filter.until==filter.since {
                            report.rows=try catalog.sampleDetails(volume:catalogVolume,timestamp:filter.since);report.note="历史快照详情；应用与目录视角可能重叠。"
                        }else{report=try catalog.history(requestID:requestID,queryID:queryID,volume:catalogVolume,filter:filter)}
                    }else if mode=="snapshots"{report=try DiskSnapshotReader.report(requestID:requestID,queryID:queryID,volume:root,cancellation:token)}
                    else if let reader, ["developer","media","permissions"].contains(mode){report=try reader.workbenchIndexed(requestID:requestID,queryID:queryID,mode:mode,filter:filter,cancellation:token,progress:{ progress($0) })}
                    else if let reader, mode=="duplicates"{report=try reader.duplicateCandidates(requestID:requestID,queryID:queryID,filter:filter,cancellation:token,progress:{ progress($0) })}
                    else if let reader {
                        let insight:DiskInsightReport?
                        if ["browser","chat"].contains(mode){insight=try reader.insights(requestID:requestID,queryID:queryID,root:root,cancellation:token)}else{insight=nil}
                        report=try reader.workbenchKnown(requestID:requestID,queryID:queryID,root:root,mode:mode,filter:filter,insights:insight,cancellation:token)
                    }
                    if ["duplicates","media"].contains(mode),let catalog,let reader{
                        let batchCount=report.rows.count
                        for i in report.rows.indices {
                            guard !token.isCancelled else{throw DiskAnalysisStore.Failure(message:"已取消。")}
                            guard let e=report.rows[i].entry else{continue}
                            if filter.enrich || (mode=="media" && filter.category=="4k"){
                                let message="\(mode=="duplicates" ? "校验内容" : "识别属性") \(i+1)/\(batchCount)：\(e.name)"
                                progress(message,i,batchCount)
                                do{
                                    if mode=="duplicates"{report.rows[i].hash=try DiskStorageContent.hash(entry:e,volume:catalogVolume,catalog:catalog,cancellation:token)}
                                    else{let size=try DiskStorageContent.media(entry:e,volume:catalogVolume,catalog:catalog,cancellation:token);report.rows[i].width=size.0;report.rows[i].height=size.1}
                                }catch{report.rows[i].detail=error.localizedDescription}
                                progress("已处理 \(i+1)/\(batchCount) 个文件",i+1,batchCount)
                            }else{
                                if let opened=try? DiskStorageContent.openEntry(e){
                                    defer{Darwin.close(opened.0)}
                                    if let cached=try catalog.enrichment(volume:catalogVolume,entry:e,changed:opened.1.changed){report.rows[i].hash=cached.0;report.rows[i].width=cached.1;report.rows[i].height=cached.2}
                                }
                            }
                        }
                        if mode=="duplicates"{
                            let hashes=Set(report.rows.map(\.hash).filter{!$0.isEmpty}),originalPaths=Set(report.rows.map(\.path))
                            for hash in hashes {
                                for peer in try catalog.hashPeers(volume:catalogVolume,hash:hash) where !originalPaths.contains(peer) && report.rows.count<500{
                                    guard !token.isCancelled else{break}
                                    guard let e=try reader.withLock({try reader.indexedEntry(peer)}),let opened=try? DiskStorageContent.openEntry(e) else{continue}
                                    defer{Darwin.close(opened.0)}
                                    if let cache=try catalog.enrichment(volume:catalogVolume,entry:e,changed:opened.1.changed),cache.0==hash{report.rows.append(DiskWorkbenchRow(title:e.name,path:e.path,category:e.kind,bytes:e.bytes,detail:"来自其他已校验页面",entry:e,hash:hash))}
                                }
                            }
                            let counts=Dictionary(grouping:report.rows.filter{!$0.hash.isEmpty},by:{$0.hash}).mapValues{Set($0.compactMap{$0.entry.map{"\($0.device):\($0.inode)"}}).count}
                            for i in report.rows.indices where !report.rows[i].hash.isEmpty{report.rows[i].detail=(counts[report.rows[i].hash] ?? 0)>1 ? "SHA-256 相同，已验证重复内容（不同文件身份）" : "已校验；已校验文件中暂未找到其他相同内容"}
                            report.rows.sort{($0.hash.isEmpty ? "~" : $0.hash)<($1.hash.isEmpty ? "~" : $1.hash)}
                        }else{
                            for i in report.rows.indices where report.rows[i].width>0{report.rows[i].detail += " · \(report.rows[i].width) × \(report.rows[i].height)"}
                            if filter.category=="4k"{report.rows=report.rows.filter{max($0.width,$0.height)>=3840};report.note += " 每批检查 100 个视频；本页为空仍可继续下一批，未读到属性不算 4K。"}
                        }
                    }else if ["duplicates","media"].contains(mode) && catalog==nil{report.note += " 扩展数据库不可用："+catalogError}
                }catch{report.error=error.localizedDescription}
                let response=report
                self?.queue.async{[weak self] in guard let self,!token.isCancelled,self.selection?.request==requestID else{return};self.lastWorkbench=response
                    DispatchQueue.main.async{[weak self] in if !token.isCancelled{self?.onWorkbench?(response)}}
                }
            }
        }
    }
    func workbenchURL(requestID:String,path:String,completion:@escaping(URL)->Void){
        queue.async{[self] in
            guard selection?.request==requestID,let report=lastWorkbench,report.requestID==requestID,
                  !path.isEmpty,report.rows.contains(where:{$0.path==path}) else{return}
            DispatchQueue.main.async{completion(URL(fileURLWithPath:path))}
        }
    }
    func cancelStorageExport(){queue.async{[self] in exportCancellation.cancel()}}
    func exportStorageData(requestID:String,source:String,format:String,url:URL,filter:DiskLargeFilter,analysisMode:String,analysisPath:String,mapMode:String,analysisOffset:Int,completion:@escaping(Result<Void,Error>)->Void){
        queue.async{[self] in
            guard access == .granted,let selected=selection,selected.request==requestID,let volume=volumes[selected.volume],let store=volume.store else{DispatchQueue.main.async{completion(.failure(DiskAnalysisStore.Failure(message:"当前索引或权限不可用。")))};return}
            exportCancellation.cancel();let token=DiskScanCancellation();exportCancellation=token
            let rows=desired,catalog=storageCatalog,report=lastWorkbench,insights=insightReport,root=volume.root.path,path=selected.volume,query=fileQuery,progress=volume.progress(requestID:requestID)
            let catalogVolume=store.storeURL?.lastPathComponent ?? path
            exportQueries.async{
                let result=Result{
                    let reader=try store.isolatedQueryView()
                    var map:DiskSpaceMapPage?,directory:DiskDirectoryPage?,large:DiskLargePage?
                    if source=="analysis",analysisMode=="map"{
                        map=try reader.spaceMap(requestID:requestID,mapID:"export",path:analysisPath.isEmpty ? root : analysisPath,root:root,mode:mapMode=="types" ? "types" : "folders",cancellation:token)
                    }else if source=="analysis",analysisMode=="directory"{
                        directory=query.active ? try reader.searchPage(requestID:requestID,root:root,query:query,offset:selected.offset,cancellation:token) : DiskAnalysisResult(progress:progress,store:reader).page(path:selected.path,offset:selected.offset,sort:query.sort)
                    }else if source=="analysis",analysisMode=="large"{
                        var current=filter;current.offset=analysisOffset;large=try reader.largePage(requestID:requestID,queryID:"export",filter:current,cancellation:token)
                    }
                    if source=="analysis",format != "csv",map != nil || directory != nil || large != nil{
                        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                        if let map{try encoder.encode(map).write(to:url,options:.atomic)}else if let directory{try encoder.encode(directory).write(to:url,options:.atomic)}else if let large{try encoder.encode(large).write(to:url,options:.atomic)};return
                    }
                    if source=="analysis",format != "csv",analysisMode=="workbench",let report{
                        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(report).write(to:url,options:.atomic);return
                    }
                    if source=="analysis",format != "csv",analysisMode=="apps",let insights{
                        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(insights).write(to:url,options:.atomic);return
                    }
                    try DiskStorageExporter.rows(url:url,format:format){emit in
                        if source=="volumes"{
                            for row in rows{try emit(DiskWorkbenchRow(title:row.name,path:row.path,category:"volume",bytes:row.total-min(row.total,row.available),detail:"存储卷",totalBytes:row.total,availableBytes:row.available))}
                        }else if source=="history"{
                            guard let catalog else{throw DiskAnalysisStore.Failure(message:"历史数据库不可用。")};try catalog.walkHistory(volume:catalogVolume,displayVolume:root,cancellation:token,emit:emit)
                        }else if source=="large"{
                            var query=filter;query.offset=0
                            while true{
                                if token.isCancelled{throw DiskAnalysisStore.Failure(message:"已取消导出。")}
                                let page=try reader.largePage(requestID:requestID,queryID:"export",filter:query,cancellation:token)
                                if !page.error.isEmpty{throw DiskAnalysisStore.Failure(message:page.error)}
                                for row in page.entries{try emit(DiskWorkbenchRow(title:row.entry.name,path:row.entry.path,category:row.category,bytes:row.entry.bytes,detail:"大文件筛选结果",timestamp:row.entry.modified,entry:row.entry))}
                                if !page.hasMore{break};query.offset+=100
                            }
                        }else if let map{for row in map.nodes{try emit(DiskWorkbenchRow(title:row.name,path:row.path,category:row.kind,bytes:row.bytes,detail:"空间地图 · \(row.files) 个文件"))}}
                        else if let directory{for e in directory.entries{try emit(DiskWorkbenchRow(title:e.name,path:e.path,category:e.kind,bytes:e.bytes,detail:"当前目录/搜索页",timestamp:e.modified,entry:e))}}
                        else if let large{for row in large.entries{try emit(DiskWorkbenchRow(title:row.entry.name,path:row.entry.path,category:row.category,bytes:row.entry.bytes,detail:"当前大文件页",timestamp:row.entry.modified,entry:row.entry))}}
                        else if analysisMode=="workbench",let report{for stat in report.stats{try emit(DiskWorkbenchRow(title:stat.title,category:"summary",bytes:stat.bytes,detail:"\(stat.count) 项 · 汇总"))};for row in report.rows{try emit(row)}}
                        else if analysisMode=="apps",let insights{for app in insights.apps{try emit(DiskWorkbenchRow(title:app.name,path:app.path,category:"application",bytes:app.bytes,detail:"已归属总占用，共享单列"))};for item in insights.items{try emit(DiskWorkbenchRow(title:item.entry.name,path:item.entry.path,category:item.section,bytes:item.entry.bytes,detail:item.reason,entry:item.entry))}}
                        else{
                            let summary=try reader.fileTypes(requestID:requestID,queryID:"export",root:root,cancellation:token)
                            for row in summary.categories{try emit(DiskWorkbenchRow(title:row.key,path:root,category:row.key,bytes:row.bytes,detail:"\(row.files) 个文件 · 逻辑大小 \(row.logicalBytes)"))}
                        }
                    }
                }
                DispatchQueue.main.async{completion(result)}
            }
        }
    }
    func appIcons(requestID: String, queryID: String, paths: [String], completion: @escaping (DiskAppIconReport) -> Void) {
        queue.async { [self] in
            guard access == .granted, selection?.request == requestID, let report = insightReport, report.queryID == queryID else { return }
            let wanted = Set(paths)
            let apps = report.apps.filter { wanted.contains($0.path) }
            DiskAppIcons.shared.load(apps) { icons in completion(DiskAppIconReport(requestID:requestID,queryID:queryID,icons:icons)) }
        }
    }
    func storageInsights(requestID: String, queryID: String) {
        queue.async { [self] in
            storageCancellation.cancel(); insightReport = nil
            let token = DiskScanCancellation(); storageCancellation = token
            guard access == .granted, let selected = selection, selected.request == requestID,
                  let volume = volumes[selected.volume], volume.status.ready, let store = volume.store else {
                DispatchQueue.main.async { [weak self] in self?.onInsights?(DiskInsightReport(requestID: requestID, queryID: queryID, error: "索引暂不可用，请返回存储卷检查权限。")) }; return
            }
            do { try store.ensureStorageInsightRules() }
            catch {
                let result = DiskInsightReport(requestID: requestID, queryID: queryID, error: error.localizedDescription)
                DispatchQueue.main.async { [weak self] in self?.onInsights?(result) }; return
            }
            let root = volume.root.path
            workbenchQueries.async { [weak self] in
                let result: DiskInsightReport
                do { result = try store.isolatedQueryView().insights(requestID: requestID, queryID: queryID, root: root, cancellation: token) }
                catch { result = DiskInsightReport(requestID: requestID, queryID: queryID, error: error.localizedDescription) }
                self?.queue.async { [weak self] in
                    guard let self, !token.isCancelled, self.selection?.request == requestID else { return }
                    self.insightReport = result
                    DispatchQueue.main.async { [weak self] in if !token.isCancelled { self?.onInsights?(result) } }
                }
            }
        }
    }
    func cleanupCandidates(requestID: String, queryID: String, paths: [String], running: Set<String>, completion: @escaping (Result<[DiskInsightItem], Error>) -> Void) {
        queue.async { [self] in
            guard access == .granted, selection?.request == requestID, let report = insightReport,
                  report.requestID == requestID, report.queryID == queryID, !storageCancellation.isCancelled,
                  !paths.isEmpty, paths.count <= 100 else {
                DispatchQueue.main.async { completion(.failure(DiskAnalysisStore.Failure(message: "分析已变化或选择超过 100 项，请刷新并重新预览。"))) }; return
            }
            let candidates = report.items.filter { paths.contains($0.entry.path) }
            fileActions.async {
                let result = Result { () throws -> [DiskInsightItem] in
                    guard Set(candidates.map { $0.entry.path }) == Set(paths) else { throw DiskAnalysisStore.Failure(message: "选择中包含非分析项目。") }
                    let sorted = candidates.sorted { $0.entry.path.count < $1.entry.path.count }
                    var unique: [DiskInsightItem] = []
                    for item in sorted where !unique.contains(where: { item.entry.path.hasPrefix($0.entry.path + "/") }) {
                        try DiskCleanupSafety.validate(item, running: running); unique.append(item)
                    }
                    return unique
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
    func cleanup(_ items: [DiskInsightItem], requestID: String, queryID: String, operationID: String, running: Set<String>) {
        // Revalidate the native report and all identities after the confirmation.
        cleanupCandidates(requestID: requestID, queryID: queryID, paths: items.map { $0.entry.path }, running: running) { [weak self] validated in
            guard let self else { return }
            switch validated {
            case .failure(let error): self.onFileAction?(DiskFileActionResult(requestID: requestID, operationID: operationID, path: "", success: false, message: error.localizedDescription))
            case .success(let candidates):
                self.queue.async { [self] in
                    guard self.access == .granted, let selected = self.selection, selected.request == requestID,
                          self.insightReport?.queryID == queryID, !self.storageCancellation.isCancelled else {
                        DispatchQueue.main.async { [weak self] in self?.onFileAction?(DiskFileActionResult(requestID: requestID, operationID: operationID, path: "", success: false, message: "页面或权限状态已改变，清理已取消。")) }; return
                    }
                    let volumePath = selected.volume
                    self.fileActions.async { [weak self] in
                        var moved: [String] = [], errors: [String] = []
                        for item in candidates {
                            do {
                                try DiskCleanupSafety.validate(item, running: running)
                                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.entry.path), resultingItemURL: nil)
                                moved.append(item.entry.path)
                            } catch { errors.append("\(item.entry.name)：\(error.localizedDescription)") }
                        }
                        let paths = moved, failures = errors
                        self?.queue.async { [weak self] in
                            guard let self else { return }
                            for path in paths { self.volumes[volumePath]?.didTrash(path: path) }
                            self.insightReport = nil
                            let message = "已移入废纸篓 \(paths.count) 项；不会立即释放磁盘空间，可在 Finder 恢复。" + (failures.isEmpty ? "" : "\n未处理：" + failures.joined(separator: "\n"))
                            let result = DiskFileActionResult(requestID: requestID, operationID: operationID, path: "", success: failures.isEmpty, message: message)
                            DispatchQueue.main.async { [weak self] in self?.onFileAction?(result) }
                        }
                    }
                }
            }
        }
    }
    func fileTrashCandidate(path:String,requestID:String,duplicate:Bool,completion:@escaping(Result<DiskAnalysisEntry,Error>)->Void){
        if !duplicate{trashCandidate(path:path,requestID:requestID,completion:completion);return}
        queue.async{[self] in
            guard access == .granted,let selected=selection,selected.request==requestID,
                  let report=lastWorkbench,report.mode=="duplicates",report.requestID==requestID,
                  let target=report.rows.first(where:{$0.path==path}),!target.hash.isEmpty,
                  let keeper=report.rows.first(where:{$0.hash==target.hash}),keeper.path != path,
                  let store=volumes[selected.volume]?.store,let catalog=storageCatalog else{
                DispatchQueue.main.async{completion(.failure(DiskAnalysisStore.Failure(message:"只能处理已校验的重复副本，保留项不可删除；请重新校验。")))};return
            }
            let catalogVolume=store.storeURL?.lastPathComponent ?? selected.volume
            fileActions.async{
                let result=Result{()->DiskAnalysisEntry in
                    let reader=try store.queryView()
                    guard let e=try reader.withLock({try reader.indexedEntry(path)}),let k=try reader.withLock({try reader.indexedEntry(keeper.path)}),e.device != k.device || e.inode != k.inode else{throw DiskAnalysisStore.Failure(message:"保留副本已不存在或为同一硬链接，请刷新。")}
                    try DiskFileSafety.validate(e)
                    let token=DiskScanCancellation()
                    guard try DiskStorageContent.hash(entry:e,volume:catalogVolume,catalog:catalog,cancellation:token)==target.hash,
                          try DiskStorageContent.hash(entry:k,volume:catalogVolume,catalog:catalog,cancellation:token)==target.hash else{throw DiskAnalysisStore.Failure(message:"重复文件或保留副本内容已变化，停止清理。")}
                    return e
                }
                DispatchQueue.main.async{completion(result)}
            }
        }
    }
    func performFileTrash(_ entry:DiskAnalysisEntry,requestID:String,operationID:String,duplicate:Bool){
        if !duplicate{trash(entry,requestID:requestID,operationID:operationID);return}
        fileTrashCandidate(path:entry.path,requestID:requestID,duplicate:true){[weak self] result in
            switch result{case .success(let checked):self?.trash(checked,requestID:requestID,operationID:operationID)
            case .failure(let error):self?.onFileAction?(DiskFileActionResult(requestID:requestID,operationID:operationID,path:entry.path,success:false,message:error.localizedDescription))}
        }
    }
    func trashCandidate(path: String, requestID: String, completion: @escaping (Result<DiskAnalysisEntry, Error>) -> Void) {
        queue.async { [self] in
            guard access == .granted, let selected = selection, selected.request == requestID,
                  let volume = volumes[selected.volume], let store = volume.store,
                  path.hasPrefix(volume.root.path == "/" ? "/" : volume.root.path + "/") else {
                DispatchQueue.main.async { completion(.failure(DiskAnalysisStore.Failure(message: "文件不在当前可访问索引中。"))) }; return
            }
            queries.async {
                let result = Result { () throws -> DiskAnalysisEntry in
                    let reader = try store.queryView()
                    guard let entry = try reader.withLock({ try reader.indexedEntry(path) }) else { throw DiskAnalysisStore.Failure(message: "索引中已无此文件，请刷新。") }
                    try DiskFileSafety.validate(entry)
                    return entry
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
    func trash(_ entry: DiskAnalysisEntry, requestID: String, operationID: String) {
        queue.async { [self] in
            guard access == .granted, let selected = selection, selected.request == requestID else {
                let result = DiskFileActionResult(requestID: requestID, operationID: operationID, path: entry.path, success: false, message: "分析页面或权限状态已改变，操作已取消。")
                DispatchQueue.main.async { [weak self] in self?.onFileAction?(result) }; return
            }
            let volumePath = selected.volume
            fileActions.async { [weak self] in
                let result = Result { try DiskFileSafety.validate(entry); try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil) }
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    let success: Bool, message: String
                    switch result {
                    case .success: success = true; message = "已移到废纸篓，可从 Finder 恢复。"; self.volumes[volumePath]?.didTrash(path: entry.path)
                    case .failure(let error): success = false; message = error.localizedDescription
                    }
                    let response = DiskFileActionResult(requestID: requestID, operationID: operationID, path: entry.path, success: success, message: message)
                    DispatchQueue.main.async { [weak self] in self?.onFileAction?(response) }
                }
            }
        }
    }
    func cancelSpaceMap() { queue.async { [self] in mapCancellation.cancel() } }
    func spaceMap(requestID: String, mapID: String, path: String, mode: String) {
        queue.async { [self] in
            mapCancellation.cancel()
            let token = DiskScanCancellation(); mapCancellation = token
            guard access == .granted, let selected = selection, selected.request == requestID,
                  let volume = volumes[selected.volume], volume.status.ready, let store = volume.store else {
                let page = DiskSpaceMapPage(requestID: requestID, mapID: mapID, path: path, mode: mode,
                    error: "文件索引暂不可用，请返回存储卷查看索引和磁盘访问状态。")
                DispatchQueue.main.async { [weak self] in self?.onSpaceMap?(page) }
                return
            }
            let root = volume.root.path, mode = mode == "types" ? "types" : "folders"
            let requestedPath = path.isEmpty ? root : URL(fileURLWithPath: path).standardizedFileURL.path
            let catalog = storageCatalog, catalogVolume = store.storeURL?.lastPathComponent ?? selected.volume
            workbenchQueries.async { [weak self] in
                guard !token.isCancelled else { return }
                let page: DiskSpaceMapPage
                do {
                    let reader = try store.isolatedQueryView()
                    page = try reader.spaceMap(requestID: requestID, mapID: mapID, path: requestedPath, root: root, mode: mode, cancellation: token)
                    if page.error.isEmpty, !token.isCancelled { try? catalog?.track(volume: catalogVolume, path: requestedPath) }
                } catch {
                    page = DiskSpaceMapPage(requestID: requestID, mapID: mapID, path: requestedPath, mode: mode, error: error.localizedDescription)
                }
                guard !token.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    guard !token.isCancelled else { return }
                    self?.onSpaceMap?(page)
                }
            }
        }
    }
    func rebuild(volumePath: String) {
        queue.async { [self] in
            guard access == .granted, let volume = volumes[volumePath] else { return }
            volume.rebuild()
        }
    }
    func synchronizeCache(volumePath: String) {
        queue.async { [self] in
            guard access == .granted else { return }
            volumes[volumePath]?.requestSynchronization()
        }
    }
    func setSynchronizationPaused(volumePath: String, paused: Bool) {
        queue.async { [self] in
            guard access == .granted, let volume = volumes[volumePath], volume.status.ready else { return }
            UserDefaults.standard.set(paused, forKey: volume.synchronizationPreferenceKey)
            volume.setSynchronizationPaused(paused)
        }
    }
    private func refreshSelection() {
        guard let selected = selection, let volume = volumes[selected.volume], let store = volume.store, volume.status.ready else { return }
        queryCancellation.cancel()
        let cancellation = DiskScanCancellation(); queryCancellation = cancellation
        let identity = volume.progress(requestID: selected.request), query = fileQuery
        guard let reader = try? store.queryView() else { return }
        queries.async { [weak self] in
            guard !cancellation.isCancelled else { return }
            let payload = try? reader.readSnapshot { () -> (DiskAnalysisProgress, DiskDirectoryPage?) in
                let progress = DiskAnalysisProgress(requestID: identity.requestID, volumePath: identity.volumePath, rootPath: identity.rootPath,
                    state: identity.state, files: identity.files, directories: identity.directories, bytes: identity.bytes,
                    skipped: identity.skipped, elapsed: identity.elapsed, currentPath: identity.currentPath,
                    message: identity.message, largest: try reader.largestFiles())
                let result = DiskAnalysisResult(progress: progress, store: reader)
                let page = query.active
                    ? try reader.searchPage(requestID: selected.request, root: identity.rootPath, query: query, offset: selected.offset, cancellation: cancellation)
                    : result.page(path: selected.path, offset: selected.offset, sort: query.sort) ?? result.page(path: identity.rootPath, sort: query.sort)
                return (progress, page)
            }
            guard let (progress, page) = payload else { return }
            self?.queue.async { [weak self] in
                guard !cancellation.isCancelled, let self, self.selection?.request == selected.request,
                      self.selection?.path == selected.path, self.selection?.offset == selected.offset, self.fileQuery == query else { return }
                DispatchQueue.main.async { [weak self] in
                    guard !cancellation.isCancelled else { return }
                    self?.onProgress?(progress); if let page { self?.onDirectory?(page) }
                }
            }
        }
    }
    private static func validateInteractionDuplicate(_ entry: DiskAnalysisEntry, report: DiskWorkbenchReport, reader: DiskAnalysisStore, catalog: DiskStorageCatalog?, volume: String) throws {
        guard let catalog, let target = report.rows.first(where: { $0.path == entry.path }), !target.hash.isEmpty,
              let keeper = report.rows.first(where: { $0.hash == target.hash }), keeper.path != entry.path,
              let kept = try reader.withLock({ try reader.indexedEntry(keeper.path) }),
              kept.device != entry.device || kept.inode != entry.inode else { throw DiskAnalysisStore.Failure(message: "保留项或未校验文件不可删除，请重新校验重复内容。") }
        let token = DiskScanCancellation()
        guard try DiskStorageContent.hash(entry:entry,volume:volume,catalog:catalog,cancellation:token) == target.hash,
              try DiskStorageContent.hash(entry:kept,volume:volume,catalog:catalog,cancellation:token) == target.hash else { throw DiskAnalysisStore.Failure(message: "原文件或保留副本已变化，停止清理。") }
    }
    func interactionEntries(paths: [String], requestID: String, forTrash: Bool = false, completion: @escaping (Result<[DiskAnalysisEntry], Error>) -> Void) {
        queue.async { [self] in
            guard access == .granted, let selected = selection, selected.request == requestID,
                  let volume = volumes[selected.volume], let store = volume.store, !paths.isEmpty, paths.count <= 1000 else {
                DispatchQueue.main.async { completion(.failure(DiskAnalysisStore.Failure(message: "页面或磁盘访问状态已改变，请重新选择。"))) }; return
            }
            let root = volume.root.path, duplicateReport = lastWorkbench?.mode == "duplicates" ? lastWorkbench : nil, catalog = storageCatalog, catalogVolume = store.storeURL?.lastPathComponent ?? selected.volume
            fileActions.async {
                let result = Result { () throws -> [DiskAnalysisEntry] in
                    let reader = try store.queryView()
                    var entries: [DiskAnalysisEntry] = []
                    for path in Set(paths).sorted(by: { $0.count < $1.count }) {
                        guard path == root || path.hasPrefix(root == "/" ? "/" : root + "/"),
                              let entry = try reader.withLock({ try reader.indexedEntry(path) }) else { throw DiskAnalysisStore.Failure(message: "索引中已无此项目：" + path) }
                        if forTrash {
                            if entries.contains(where: { $0.directory && path.hasPrefix($0.path + "/") }) { continue }
                            guard path != root else { throw DiskAnalysisStore.Failure(message: "存储卷根目录不可移到废纸篓。") }
                            try DiskFileSafety.validate(entry)
                            if let duplicateReport { try Self.validateInteractionDuplicate(entry, report:duplicateReport, reader:reader, catalog:catalog, volume:catalogVolume) }
                            if entry.directory { try reader.validateInteractionDirectory(entry.path) }
                        }
                        entries.append(entry)
                    }
                    return entries
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
    func trashInteractionEntries(_ entries: [DiskAnalysisEntry], requestID: String, operationID: String) {
        queue.async { [self] in
            guard access == .granted, let selected = selection, selected.request == requestID,
                  let store = volumes[selected.volume]?.store else { return }
            let volumePath = selected.volume, duplicateReport = lastWorkbench?.mode == "duplicates" ? lastWorkbench : nil, catalog = storageCatalog, catalogVolume = store.storeURL?.lastPathComponent ?? selected.volume
            fileActions.async { [weak self] in
                var moved: [String] = [], errors: [String] = []
                for entry in entries {
                    do {
                        try DiskFileSafety.validate(entry)
                        if let duplicateReport { try Self.validateInteractionDuplicate(entry, report:duplicateReport, reader:store.queryView(), catalog:catalog, volume:catalogVolume) }
                        if entry.directory { try store.queryView().validateInteractionDirectory(entry.path) }
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
                        moved.append(entry.path)
                    } catch { errors.append(entry.name + "：" + error.localizedDescription) }
                }
                let paths = moved, failures = errors
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    for path in paths { self.volumes[volumePath]?.didTrash(path: path) }
                    let result = DiskFileActionResult(requestID: requestID, operationID: operationID, path: "", success: !paths.isEmpty,
                        message: "已移到废纸篓 \(paths.count) 项。" + (failures.isEmpty ? "" : "\n未处理：" + failures.joined(separator: "\n")))
                    DispatchQueue.main.async { [weak self] in self?.onFileAction?(result) }
                }
            }
        }
    }
    func reveal(path: String, requestID: String, completion: @escaping (URL) -> Void) {
        indexedURL(path: path, requestID: requestID) { result in if case .success(let url) = result { completion(url) } }
    }
    func indexedURL(path: String, requestID: String, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            guard let selected = selection, selected.request == requestID,
                  let store = volumes[selected.volume]?.store, let reader = try? store.queryView() else {
                DispatchQueue.main.async { completion(.failure(DiskAnalysisStore.Failure(message: "文件索引暂不可用，请返回存储卷刷新。"))) }; return
            }
            queries.async {
                let result: Result<URL, Error> = reader.contains(path: path) ? .success(URL(fileURLWithPath: path)) : .failure(DiskAnalysisStore.Failure(message: "索引中已无此文件，请刷新。"))
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

}

final class IndexedVolume {
    let root: URL
    let volume: VolumeRow
    private let queue: DispatchQueue
    private let databaseURL: URL
    private var indexStorage: (root: String, directory: String)?
    private let readers = DispatchQueue(label: "app.macstate.index-readers", qos: .utility, attributes: .concurrent)
    private let readConcurrency: Int
    private let directoryReader: DiskIndexDirectoryReader.Read
    private var updateCancellation = DiskScanCancellation()
    private final class UpdateTask {
        let path: String
        let recursive: Bool
        var missing: Set<String>
        init(path: String, recursive: Bool, missing: Set<String>) { self.path = path; self.recursive = recursive; self.missing = missing }
    }
    private var activeUpdates: [String: UpdateTask] = [:]
    var store: DiskAnalysisStore?
    var onChange: (() -> Void)?
    var beforeRebuild: (() -> Void)?
    private var session: DiskScanSession?
    private var events: DiskIndexEvents?
    private var state = "waiting", message = "", currentPath = ""
    private var files = 0, directories = 0, skipped = 0
    private var bytes: UInt64 = 0, cursor: UInt64 = 0
    private var started = Date(), updated = Date.distantPast, lastPublish = Date.distantPast
    private var complete = false, historyDone = false, stopped = false
    private var completedAt: Double = 0, buildElapsed: Double = 0
    private var verificationPaths = Set<String>()
    private var verificationActive = false
    private var verificationReason = ""
    private var device: dev_t = 0
    private var eventIdentity = ""
    private var mountPath = ""
    private var relativeRoot = "/"
    private var dirty = Set<String>()
    private var debounce: DispatchWorkItem?
    private var draining = false
    private var checkpoint: DiskIndexCheckpoint?
    private var dirtyOrder: [String] = []
    private var dirtyHead = 0
    private var cacheURL: URL { URL(fileURLWithPath: databaseURL.path + ".changes.sqlite") }
    private var generation = UUID()
    private var watchRevision = UUID()
    private var synchronizationPaused = false
    private var manualSynchronization = false
    private var canSynchronize: Bool { !synchronizationPaused || manualSynchronization }
    var synchronizationPreferenceKey: String { "diskIndexPaused." + databaseURL.lastPathComponent }

    init(volume: VolumeRow, baseURL: URL, queue: DispatchQueue, rootOverride: URL? = nil, readConcurrency: Int = min(8, max(4, ProcessInfo.processInfo.activeProcessorCount - 2)),
         directoryReader: @escaping DiskIndexDirectoryReader.Read = DiskIndexDirectoryReader.read) {
        self.directoryReader = directoryReader
        self.readConcurrency = min(8, max(1, readConcurrency))
        self.volume = volume; self.queue = queue; root = rootOverride ?? DiskAnalysisScanner.scanRoot(volumePath: volume.path)
        let uuid = (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString ?? root.path
        let key = SHA256.hash(data: Data(uuid.utf8)).map { String(format: "%02x", $0) }.joined()
        databaseURL = baseURL.appendingPathComponent(key + ".sqlite")
    }
    var status: DiskIndexStatus {
        DiskIndexStatus(volumePath: volume.path, state: state, files: files, directories: directories, bytes: bytes,
            elapsed: state == "indexing" ? Date().timeIntervalSince(started) : 0, currentPath: currentPath,
            message: (state == "ready" && !canSynchronize ? [] : [message, verificationReason]).filter { !$0.isEmpty }.joined(separator: " "),
            updated: updated == .distantPast ? 0 : updated.timeIntervalSince1970,
            ready: complete && ["ready", "updating", "verifying"].contains(state),
            completedAt: completedAt, buildElapsed: buildElapsed, readConcurrency: readConcurrency,
            pendingChanges: dirty.count + activeUpdates.count,
            synchronizationPaused: synchronizationPaused, manualSynchronization: manualSynchronization)
    }
    func progress(requestID: String) -> DiskAnalysisProgress {
        let syncMessage = manualSynchronization ? "正在手动同步文件变化。"
            : synchronizationPaused ? "自动同步已暂停，可继续使用已有索引。"
            : state == "verifying" ? "正在核对目录变化，现有索引可以使用。"
            : state == "updating" ? "正在分批同步文件变化，搜索可以继续使用。" : "已读取本地索引，文件变化会自动同步。"
        return DiskAnalysisProgress(requestID: requestID, volumePath: volume.path, rootPath: root.path, state: "completed",
            files: files, directories: directories, bytes: bytes, skipped: skipped, elapsed: 0, currentPath: root.path,
            message: syncMessage, largest: [])
    }
    func start() {
        stopped = false; started = Date()
        do {
            try configureDevice()
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let cachePath = databaseURL.deletingLastPathComponent().path
            let resolved = realpath(cachePath, nil)
            let directory = resolved.map { String(cString: $0) } ?? cachePath
            free(resolved)
            let paths = mountPath == "/System/Volumes/Data" ? [directory, mountPath + directory] : [directory]
            indexStorage = paths.first {
                $0.hasPrefix(root.path == "/" ? "/" : root.path + "/") && $0 != root.path
            }.map { directory in
                let parent = (directory as NSString).deletingLastPathComponent
                let storageRoot = parent != root.path && DiskLocalPolicy.isIndexStorage(parent) ? parent : directory
                return (storageRoot, directory)
            }
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                state = "preparing"; message = "正在检查并优化已有索引，无需重新扫描磁盘。"; publish(force: true)
            }
            let savedIndex = FileManager.default.fileExists(atPath: databaseURL.path) ? try openSavedIndex() : nil
            if let saved = savedIndex,
               try saved.metadata("schema") == "1", try saved.metadata("root") == root.path,
               try saved.metadata("eventsUUID") == eventIdentity,
               let value = try saved.metadata("cursor"), let cursor = UInt64(value),
               let entry = try saved.withLock({ try saved.indexedEntry(root.path) }) {
                self.store = saved; self.cursor = cursor; files = entry.files; bytes = entry.bytes; skipped = entry.skipped
                directories = Int(try saved.metadata("directories") ?? "0") ?? 0
                updated = Date(timeIntervalSince1970: Double(try saved.metadata("updated") ?? "0") ?? 0)
                completedAt = Double(try saved.metadata("completedAt") ?? "0") ?? 0
                buildElapsed = Double(try saved.metadata("buildElapsed") ?? "0") ?? 0
                if try saved.metadata("fastSearch") != "3" {
                    state = "preparing"; message = "正在从已有文件属性构建快速搜索索引，无需重新扫描磁盘。"; publish(force: true)
                }
                try saved.prepareFastSearch()
                try installMaintenance(on: saved)
                self.cursor = UInt64(try saved.metadata("cursor") ?? "0") ?? cursor
                updated = Date(timeIntervalSince1970: Double(try saved.metadata("updated") ?? "0") ?? 0)
                reloadTotals()
                message = ""; complete = true; state = "updating"
                if let indexStorage {
                    // Read its parent first to replace the legacy skipped directory row.
                    markDirty((indexStorage.root as NSString).deletingLastPathComponent)
                    requestVerification(indexStorage.root, reason: "正在核对 MacState 索引文件的占用。")
                }
                if synchronizationPaused { state = "ready" }
                else { try resumeEventWatch() }
                publish(force: true)
            } else { try beginBuild() }
        } catch { fail(error.localizedDescription) }
    }
    private func configureDevice() throws {
        var info = stat()
        guard DiskLocalPolicy.exclusion(root.path) == nil, DiskLocalPolicy.isLocalVolume(root.path),
              lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw DiskAnalysisStore.Failure(message: "仅为可访问的本地存储卷建立索引。")
        }
        device = info.st_dev
        var mount = statfs()
        guard statfs(root.path, &mount) == 0 else { throw DiskAnalysisStore.Failure(message: "无法读取卷挂载信息。") }
        mountPath = withUnsafePointer(to: mount.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        relativeRoot = root.path == mountPath ? "/" : root.path.hasPrefix(mountPath + "/") ? String(root.path.dropFirst(mountPath.count)) : root.path
        guard let identity = DiskIndexEvents.identity(device: device) else { throw DiskAnalysisStore.Failure(message: "无法读取此卷的文件事件日志标识。") }
        eventIdentity = identity
    }
    private func watch(liveOnly: Bool = false) throws {
        historyDone = liveOnly
        watchRevision = UUID()
        let version = watchRevision
        events = try DiskIndexEvents(device: device, since: liveOnly ? UInt64(kFSEventStreamEventIdSinceNow) : cursor, queue: queue, relativePath: relativeRoot) { [weak self] batch in
            guard let self, !self.stopped, self.watchRevision == version else { return }
            self.receive(batch)
        }
    }
    private func resumeEventWatch() throws {
        let latestEvent = DiskIndexEvents.currentID(device: device)
        if latestEvent > 0 && cursor > latestEvent {
            requestVerification(root.path, reason: "文件事件游标已回退，保留现有索引并核对整个卷。")
            cursor = latestEvent
            if manualSynchronization { historyDone = true }
            else { try watch(liveOnly: true) }
            drain()
        } else {
            try watch()
            if !manualSynchronization, indexStorage != nil { scheduleDrain() }
        }
    }
    private func stopEventWatch() {
        watchRevision = UUID()
        events?.stop()
        events = nil
    }
    private func beginBuild() throws {
        store = nil; complete = false; historyDone = false; state = "indexing"; message = ""
        completedAt = 0; buildElapsed = 0; verificationActive = false; verificationReason = ""; verificationPaths.removeAll()
        files = 0; directories = 0; bytes = 0; skipped = 0; started = Date()
        for url in [databaseURL, cacheURL] {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        cursor = DiskIndexEvents.currentID(device: device)
        try watch(liveOnly: true) // Watch before traversal; all changes during the baseline are replayed.
        let version = generation
        let scan = DiskScanSession(scanner: DiskAnalysisScanner(), root: root, volumePath: volume.path,
            name: volume.name, requestID: UUID().uuidString, cancellation: DiskScanCancellation(), storeURL: databaseURL, backgroundReaders: readConcurrency)
        session = scan
        scan.onProgress = { [weak self] value in
            self?.queue.async { [weak self] in
                guard let self, self.generation == version, !self.stopped else { return }
                self.files = value.files; self.directories = value.directories; self.bytes = value.bytes
                self.skipped = value.skipped; self.currentPath = value.currentPath; self.publish()
            }
        }
        let baselineCursor = cursor
        scan.onCompletion = { [weak self] result in
            self?.queue.async { [weak self] in
                guard let self, self.generation == version, !self.stopped else { return }
                self.session = nil
                guard result.progress.state == "completed", let cache = result.store else {
                    self.fail(result.progress.message.isEmpty ? "索引建立未完成，下次启动会重新建立。" : result.progress.message); return
                }
                do {
                    self.store = cache
                    self.state = "preparing"; self.message = "目录遍历已完成，正在批量构建快速搜索索引。"; self.publish(force: true)
                    try cache.prepareFastSearch()
                    self.message = ""
                    try cache.transaction {
                        try cache.setMetadata("schema", "1"); try cache.setMetadata("root", self.root.path)
                        try cache.setMetadata("eventsUUID", self.eventIdentity)
                        try cache.setMetadata("cursor", String(baselineCursor))
                        try cache.setMetadata("directories", String(result.progress.directories))
                        self.completedAt = Date().timeIntervalSince1970; self.buildElapsed = Date().timeIntervalSince(self.started)
                        try cache.setMetadata("completedAt", String(self.completedAt))
                        try cache.setMetadata("buildElapsed", String(self.buildElapsed))
                    }
                    try self.installMaintenance(on: cache)
                    self.complete = true; self.state = "updating"
                    self.markIndexStorageDirty()
                    if self.synchronizationPaused {
                        self.stopEventWatch()
                        self.state = "ready"
                    }
                    self.publish(force: true); self.drain()
                } catch { self.fail(error.localizedDescription) }
            }
        }
        scan.start(); publish(force: true)
    }
    func stop() {
        manualSynchronization = false
        stopped = true; generation = UUID(); watchRevision = UUID(); updateCancellation.cancel(); activeUpdates.removeAll(); debounce?.cancel(); debounce = nil
        checkpoint?.stop(); checkpoint = nil
        events?.stop(); events = nil; session?.cancel(); session = nil
    }
    func rebuild() {
        beforeRebuild?()
        stop(); dirty.removeAll(); dirtyOrder.removeAll(); dirtyHead = 0; verificationPaths.removeAll(); draining = false; complete = false; store = nil; generation = UUID(); startFresh()
    }
    private func startFresh() {
        stopped = false; historyDone = false; updateCancellation = DiskScanCancellation()
        do { try configureDevice(); try beginBuild() } catch { fail(error.localizedDescription) }
    }
    /// Mapping/exclusion happens before interpreting path-scoped recovery flags.
    /// Ordinary changes and coalesced events never delete a usable index.
    func receive(_ batch: [DiskIndexEvents.Event]) {
        guard !stopped, state != "failed", !complete || canSynchronize else { return }
        var useful = false
        for event in batch {
            cursor = max(cursor, event.id)
            if event.flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                historyDone = true
                useful = true
                if manualSynchronization {
                    stopEventWatch()
                    break
                }
                continue
            }
            let relative = event.path.hasPrefix("/") ? event.path : "/" + event.path
            let raw = mountPath == "/" ? relative : mountPath + (relative == "/" ? "" : relative)
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            let recovery = DiskIndexEvents.recovery(event.flags)
            // Dropped events / ID wrap are stream-wide and must be handled even
            // if the path points outside the indexed subtree. Coalescing is local.
            if recovery == .verifyVolume || recovery == .eventsWrapped {
                requestVerification(root.path, reason: "文件事件日志不完整，正在保留索引并核对整个卷。")
                useful = true
                if recovery == .eventsWrapped {
                    if manualSynchronization {
                        stopEventWatch()
                        cursor = DiskIndexEvents.currentID(device: device)
                        historyDone = true
                        break
                    } else {
                        do { try restartLiveWatch() } catch { fail(error.localizedDescription); return }
                    }
                }
                continue
            }
            guard path == root.path || path.hasPrefix(root.path + "/"), DiskLocalPolicy.exclusion(path) == nil else { continue }
            // These files are counted by directory reads. Their own writes
            // must never schedule another write to the same index.
            if isIndexStorageWrite(path) { continue }
            if recovery == .rootChanged {
                do {
                    let previousDevice = device, previousIdentity = eventIdentity
                    try configureDevice()
                    guard device == previousDevice, eventIdentity == previousIdentity else {
                        fail("存储卷或事件日志已改变，旧索引已保留；请重新检查后建立此卷的新索引。"); return
                    }
                    if !manualSynchronization { try restartLiveWatch() }
                    requestVerification(root.path, reason: "卷挂载状态发生变化，正在核对现有索引。")
                } catch { fail("存储卷暂不可用，已保留索引。请重新检查。") ; return }
                useful = true; continue
            }
            if recovery == .verifySubtree {
                requestVerification(path, reason: "系统合并了目录变化，正在局部核对；首次索引不会重建。")
                useful = true; continue
            }
            let parent = path == root.path ? path : (path as NSString).deletingLastPathComponent
            if parent == root.path || parent.hasPrefix(root.path + "/") { markDirty(parent) }
            if event.flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { markDirty(path) }
            useful = true
        }
        guard useful, complete else { return }
        markIndexStorageDirty()
        state = verificationActive ? "verifying" : "updating"; scheduleDrain(); publish()
    }
    private func isIndexStorageWrite(_ path: String) -> Bool {
        guard let indexStorage, path == indexStorage.root || path.hasPrefix(indexStorage.root + "/") else { return false }
        if path == indexStorage.root || path == indexStorage.directory { return true }
        let parent = (path as NSString).deletingLastPathComponent
        return (parent == indexStorage.root || parent == indexStorage.directory) &&
            [".sqlite", ".sqlite-wal", ".sqlite-shm", ".sqlite-journal"].contains(where: path.hasSuffix)
    }
    private func markIndexStorageDirty() {
        guard let indexStorage else { return }
        markDirty(indexStorage.root)
        markDirty(indexStorage.directory)
    }
    private func restartLiveWatch() throws {
        events?.stop(); events = nil
        cursor = DiskIndexEvents.currentID(device: device)
        try watch(liveOnly: true)
    }
    private func requestVerification(_ path: String, reason: String) {
        // Parent scopes subsume pending children. Actual recursion uses the
        // on-disk jobs table, not a million-item in-memory list.
        if !verificationPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            verificationPaths = verificationPaths.filter { !$0.hasPrefix(path + "/") }
            verificationPaths.insert(path)
        }
        verificationActive = true; verificationReason = reason
    }
    private func scheduleDrain() {
        guard canSynchronize, debounce == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.debounce = nil
            self?.drain()
        }
        debounce = work; queue.asyncAfter(deadline: .now() + 2, execute: work)
    }
    private func drain() {
        guard !stopped, complete, state != "failed", canSynchronize, !draining,
              !manualSynchronization || historyDone else { return }
        draining = true; drainOne()
    }
    private func overlapsActive(_ path: String) -> Bool {
        activeUpdates.keys.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
    }
    private func drainOne() {
        guard !stopped, let store else { draining = false; return }
        var pending: (path: String, recursive: Bool)?
        do {
            if !verificationPaths.isEmpty {
                try store.transaction {
                    for path in verificationPaths {
                        try store.enqueue(path: path, depth: path.dropFirst(root.path.count).split(separator: "/").count, priority: false)
                    }
                }
            }
                verificationPaths.removeAll()
            while activeUpdates.count < readConcurrency {
                let ordinary = nextDirty()
                let recursive = ordinary == nil ? try store.transaction { try store.nextJob(priorityOnly: false) } : nil
                guard let path = ordinary ?? recursive?.path else { break }
                pending = (path, recursive != nil)
                if overlapsActive(path) {
                    if let recursive { try store.withLock { try store.enqueue(path: path, depth: recursive.depth, priority: false) } }
                    break
                }
                if try store.withLock({ try store.indexedEntry(path)?.browsable == true }) {
                    let task = UpdateTask(path: path, recursive: recursive != nil, missing: try store.withLock { try store.childPaths(path) })
                    activeUpdates[path] = task; currentPath = path
                    state = verificationActive ? "verifying" : "updating"
                    readDirectory(task)
                }
                pending = nil
            }
            if !activeUpdates.isEmpty { return }
            // If no reader is active, all queued paths above have been consumed.
            // Only now is it safe to checkpoint the delivered event cursor.
            draining = false
            try store.transaction {
                try store.setMetadata("cursor", String(cursor))
                try store.setMetadata("updated", String(Date().timeIntervalSince1970))
            }
            if message == Self.lockRetryMessage { message = "" }
            updated = Date(); verificationActive = false; verificationReason = ""
            if manualSynchronization && historyDone {
                manualSynchronization = false
                stopEventWatch()
            }
            state = historyDone ? "ready" : "updating"; reloadTotals(); publish(force: true)
        } catch { handleIncrementalError(error, operation: "调度或保存进度", pending: pending) }
    }
    private func readDirectory(_ task: UpdateTask) {
        let version = generation, token = updateCancellation, device = device, rootPath = root.path
        readers.async { [weak self] in
            guard let self else { return }
            let capacity = DispatchSemaphore(value: 2)
            let result = self.directoryReader(task.path, rootPath, device, token) { batch in
                capacity.wait()
                self.queue.async { [weak self] in
                    defer { capacity.signal() }
                    guard let self, self.generation == version, !self.stopped,
                          self.activeUpdates[task.path] === task else { return }
                    do { try self.consume(batch, task: task); self.reloadTotals(); self.publish() }
                    catch { self.handleIncrementalError(error, operation: "写入") }
                }
            }
            self.queue.async { [weak self] in
                guard let self, self.generation == version, !self.stopped,
                      self.activeUpdates[task.path] === task else { return }
                if case .finished = result, !task.missing.isEmpty {
                    self.removeMissingChildren(task)
                    return
                }
                do {
                    if let store = self.store {
                        try store.transaction {
                            switch result {
                            case .finished: try store.directoryReadNote(path:task.path,note:"")
                            case .missing: try store.removeIndexedTree(task.path, root: rootPath)
                            case .unreadable: try store.directoryReadNote(path:task.path,note:"无法读取目录：权限、ACL 或读取错误，保留上次索引。 "); self.message = "部分目录暂时无法读取，保留上次索引；下次文件变化时重试。"
                            case .skipped: break
                            }
                        }
                    }
                    self.activeUpdates.removeValue(forKey: task.path)
                    self.reloadTotals(); self.publish(); self.drainOne()
                } catch { self.handleIncrementalError(error, operation: "更新") }
            }
        }
    }
    private func removeMissingChildren(_ task: UpdateTask) {
        guard !stopped, activeUpdates[task.path] === task, let store else { return }
        do {
            // Yield between groups of removed children. Each subtree remains
            // atomic so totals and hard-link accounting cannot become partial.
            try store.transaction {
                for _ in 0..<32 {
                    guard let path = task.missing.popFirst() else { break }
                    try store.removeIndexedTree(path, root: root.path)
                }
            }
            reloadTotals(); publish()
            if task.missing.isEmpty {
                activeUpdates.removeValue(forKey: task.path); drainOne()
            } else {
                queue.async { [weak self] in self?.removeMissingChildren(task) }
            }
        } catch { handleIncrementalError(error, operation: "删除同步") }
    }
    private static let lockRetryMessage = "索引数据库暂时被占用，正在等待重试。"

    private func handleIncrementalError(_ error: Error, operation: String, pending: (path: String, recursive: Bool)? = nil) {
        guard let code = (error as? DiskAnalysisStore.Failure)?.sqliteCode,
              (code & 0xff) == SQLITE_BUSY || (code & 0xff) == SQLITE_LOCKED else {
            fail("增量索引\(operation)失败：\(error.localizedDescription)")
            return
        }
        requeueInterruptedUpdates(pending: pending)
        state = verificationActive ? "verifying" : "updating"
        if message != Self.lockRetryMessage { NSLog("增量索引等待写锁（%@，SQLite %d）", operation, code) }
        message = Self.lockRetryMessage
        scheduleDrain()
        publish(force: true)
    }
    private func requeueInterruptedUpdates(pending: (path: String, recursive: Bool)? = nil) {
        // Restart affected directory reads so their pending deletions reflect committed data.
        updateCancellation.cancel()
        updateCancellation = DiskScanCancellation()
        var interrupted = activeUpdates.values.map { (path: $0.path, recursive: $0.recursive) }
        if let pending { interrupted.append(pending) }
        activeUpdates.removeAll()
        for task in interrupted {
            if task.recursive { requestVerification(task.path, reason: verificationReason) }
            else { markDirty(task.path) }
        }
        draining = false
        debounce?.cancel(); debounce = nil
    }
    private func consume(_ batch: [DiskIndexDirectoryReader.Item], task: UpdateTask) throws {
        guard let store else { return }
        try store.transaction {
            for item in batch {
                task.missing.remove(item.path)
                guard let entry = item.entry else { continue }
                let inserted = try store.upsertIndexedEntry(entry, root: root.path)
                if task.recursive, entry.browsable {
                    try store.enqueue(path: entry.path, depth: entry.path.dropFirst(root.path.count).split(separator: "/").count, priority: false)
                } else if inserted { markDirty(entry.path) }
            }
        }
    }
    private func reloadTotals() {
        guard let store else { return }
        if let entry = try? store.withLock({ try store.indexedEntry(root.path) }) { files = entry.files; bytes = entry.bytes; skipped = entry.skipped }
        directories = Int((try? store.metadata("directories")) ?? "0") ?? 0
    }
    private func publish(force: Bool = false) {
        let now = Date(); guard force || now.timeIntervalSince(lastPublish) >= 0.5 else { return }
        lastPublish = now; onChange?()
    }
    /// Consume a prior dual-database cache exactly once before exposing the
    /// single-database reader. FULL commit precedes cache retirement; retries
    /// after a crash reapply final row images safely, including event cursors.
    private func openSavedIndex() throws -> DiskAnalysisStore {
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            do {
                let legacy = try DiskAnalysisStore(url: databaseURL, existing: true)
                try legacy.prepareFastSearch()
                try legacy.enableChangeCache(at: cacheURL)
                try legacy.mergeChangeCache()
            } // Close every attached handle before retiring the cache files.
            for suffix in ["", "-wal", "-shm"] {
                let path = cacheURL.path + suffix
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            }
        }
        return try DiskAnalysisStore(url: databaseURL, existing: true)
    }
    private func installMaintenance(on store: DiskAnalysisStore) throws {
        try store.createSizeIndexes()
        _ = try store.queryView()
        // Only disable commit-time auto-checkpoint after the background handle
        // has opened successfully. A busy reader postpones PASSIVE checkpoint.
        let version = generation
        checkpoint = try DiskIndexCheckpoint(url: databaseURL) { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, self.generation == version, !self.stopped, self.complete,
                      self.state != "failed", self.indexStorage != nil else { return }
                self.markIndexStorageDirty()
                self.scheduleDrain()
            }
        }
        try store.execute("PRAGMA wal_autocheckpoint=0;")
    }
    func requestSynchronization() {
        guard !stopped, complete, state != "failed" else { return }
        if synchronizationPaused {
            guard !manualSynchronization else { return }
            manualSynchronization = true
            state = "updating"
            markIndexStorageDirty()
            do { try resumeEventWatch() }
            catch { fail(error.localizedDescription); return }
            events?.flush()
            publish(force: true)
            checkpoint?.request()
            return
        }
        events?.flush()
        debounce?.cancel(); debounce = nil
        markIndexStorageDirty()
        drain()
        checkpoint?.request()
    }
    func setSynchronizationPaused(_ paused: Bool) {
        guard synchronizationPaused != paused || manualSynchronization else { return }
        synchronizationPaused = paused
        manualSynchronization = false
        guard complete, !stopped, state != "failed" else { return }
        if paused {
            stopEventWatch()
            requeueInterruptedUpdates()
            state = "ready"
        } else if events == nil {
            state = "updating"
            do { try resumeEventWatch() }
            catch { fail(error.localizedDescription); return }
        }
        publish(force: true)
    }
    func didTrash(path: String) {
        guard !stopped, let store else { return }
        if !canSynchronize {
            markDirty((path as NSString).deletingLastPathComponent)
            return
        }
        do { try store.transaction { try store.removeIndexedTree(path, root: root.path) }; reloadTotals() }
        catch { message = "文件已移入废纸篓，索引将在后台核对后更新。" }
        markDirty((path as NSString).deletingLastPathComponent); scheduleDrain(); publish(force: true)
    }
    private func markDirty(_ path: String) {
        if dirty.insert(path).inserted { dirtyOrder.append(path) }
    }
    /// FIFO plus a membership set coalesces repeated events in O(1). Do not
    /// collapse ordinary child paths into parents: parent scans are not recursive.
    private func nextDirty() -> String? {
        let end = dirtyOrder.count
        while dirtyHead < end {
            let path = dirtyOrder[dirtyHead]; dirtyHead += 1
            guard dirty.contains(path) else { continue }
            if overlapsActive(path) { dirtyOrder.append(path); continue }
            dirty.remove(path)
            if dirtyHead > 4096 && dirtyHead * 2 > dirtyOrder.count {
                dirtyOrder.removeFirst(dirtyHead); dirtyHead = 0
            }
            return path
        }
        if dirty.isEmpty { dirtyOrder.removeAll(keepingCapacity: true); dirtyHead = 0 }
        return nil
    }
    private func fail(_ text: String) {
        manualSynchronization = false
        debounce?.cancel(); debounce = nil; draining = false
        updateCancellation.cancel(); activeUpdates.removeAll(); checkpoint?.stop(); checkpoint = nil
        state = "failed"; message = text; events?.stop(); events = nil; publish(force: true)
    }
}
