import Foundation
import Darwin

/// Spotlight/iCloud metadata only. Does not enumerate provider folders or ask
/// FileManager to download an item; permissions remain entirely user managed.
final class DiskCloudMetadata {
    private var query:NSMetadataQuery?
    private var observer:NSObjectProtocol?
    private var timeout:Timer?
    private var cancellation=DiskScanCancellation()
    func cancel(){
        cancellation.cancel();timeout?.invalidate();timeout=nil
        if let observer{NotificationCenter.default.removeObserver(observer)};observer=nil
        query?.stop();query=nil
    }
    func load(requestID:String,queryID:String,filter:DiskWorkbenchFilter,local:DiskIndexStatus,completion:@escaping(DiskWorkbenchReport)->Void){
        cancel();let token=DiskScanCancellation();cancellation=token;let query=NSMetadataQuery();self.query=query
        query.searchScopes=[FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents").path,NSMetadataQueryUbiquitousDocumentsScope,NSMetadataQueryUbiquitousDataScope]
        query.predicate=NSPredicate(value:true)
        query.sortDescriptors=[NSSortDescriptor(key:NSMetadataItemFSNameKey,ascending:true)]
        observer=NotificationCenter.default.addObserver(forName:NSNotification.Name.NSMetadataQueryDidFinishGathering,object:query,queue:.main){[weak self] _ in
            guard let self,self.query===query else{return}
            query.disableUpdates()
            let items=(0..<query.resultCount).compactMap{query.result(at:$0) as? NSMetadataItem}
            DispatchQueue.global(qos:.utility).async{[weak self] in
            var report=DiskWorkbenchReport(requestID:requestID,queryID:queryID,mode:"cloud",offset:filter.offset)
            var matches=0,downloaded=0,placeholders=0,localBytes:UInt64=0,logicalBytes:UInt64=0
            for item in items {
                guard !token.isCancelled else{return}
                guard let url=item.value(forAttribute:NSMetadataItemURLKey) as? URL else{continue}
                guard DiskInsightRules.logical(url.path).hasPrefix(DiskInsightRules.home+"/Library/Mobile Documents/") else{continue}
                let values=try? url.resourceValues(forKeys:[.isRegularFileKey,.isUbiquitousItemKey,.ubiquitousItemDownloadingStatusKey,.fileAllocatedSizeKey])
                guard values?.isRegularFile != false else{continue}
                var info=stat();let present=lstat(url.path,&info)==0 && info.st_flags&UInt32(SF_DATALESS)==0
                let cloudOnly=values?.ubiquitousItemDownloadingStatus == .notDownloaded || !present
                let category=cloudOnly ? "placeholder" : "downloaded"
                let size=(item.value(forAttribute:NSMetadataItemFSSizeKey) as? NSNumber)?.uint64Value ?? 0
                let allocated=cloudOnly ? UInt64(0) : UInt64(max(0,values?.fileAllocatedSize ?? 0))
                if cloudOnly{placeholders+=1;logicalBytes+=size}else{downloaded+=1};localBytes+=allocated
                let name=item.value(forAttribute:NSMetadataItemFSNameKey) as? String ?? url.lastPathComponent
                guard (filter.category.isEmpty || filter.category==category),(filter.text.isEmpty || (name+url.path).localizedCaseInsensitiveContains(filter.text)) else{continue}
                if matches>=filter.offset && report.rows.count<100{report.rows.append(DiskWorkbenchRow(title:name,path:url.path,category:category,bytes:allocated,detail:cloudOnly ? "云端占位文件 · 未下载，物理占用不计入" : "已下载 iCloud 文件 · 云端状态由系统元数据提供",timestamp:(item.value(forAttribute:NSMetadataItemFSContentChangeDateKey) as? Date)?.timeIntervalSince1970 ?? 0))}
                matches+=1
            }
            report.hasMore=matches>filter.offset+100
            report.stats=[DiskWorkbenchStat(key:"local",title:"所选卷本地索引",bytes:local.bytes,count:local.files),DiskWorkbenchStat(key:"downloaded",title:"已下载 iCloud",bytes:localBytes,count:downloaded),DiskWorkbenchStat(key:"placeholder",title:"云端占位（逻辑大小）",bytes:logicalBytes,count:placeholders)]
            report.note="当前用户 iCloud 系统元数据，可能受 Spotlight、账户或权限限制；不包含其他云提供方。普通本地文件请在「文件」页浏览。已下载占用为系统属性估算；占位文件不下载、不加入本地索引，不提供直接清理。"
            let response=report
            DispatchQueue.main.async{[weak self] in guard let self,self.query===query,!token.isCancelled else{return};self.cancel();completion(response)}
            }
        }
        timeout=Timer.scheduledTimer(withTimeInterval:12,repeats:false){[weak self] _ in
            guard let self,self.query===query else{return};self.cancel()
            completion(DiskWorkbenchReport(requestID:requestID,queryID:queryID,mode:"cloud",error:"iCloud 元数据暂不可用或尚未完成汇集。请自行检查 iCloud 登录、Spotlight 与系统权限后重试。不会申请权限或下载文件。"))
        }
        if !query.start(){cancel();completion(DiskWorkbenchReport(requestID:requestID,queryID:queryID,mode:"cloud",error:"系统无法启动 iCloud 元数据查询。"))}
    }
}
