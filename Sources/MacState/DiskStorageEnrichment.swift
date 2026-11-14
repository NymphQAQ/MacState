import Foundation
import Darwin
import CryptoKit
import AVFoundation
import ImageIO

/// Only explicitly requested candidate files are opened. fstat on the actual
/// descriptor prevents following a replaced leaf or reading cloud placeholders.
enum DiskStorageContent {
    struct Identity { let changed:Double; let modified:Double; let size:UInt64; let device:Int64; let inode:Int64 }
    static func identity(_ fd:Int32,entry:DiskAnalysisEntry)throws->Identity{
        var value=stat()
        guard fstat(fd,&value)==0,(value.st_mode&S_IFMT)==S_IFREG,value.st_flags&UInt32(SF_DATALESS)==0,
              Int64(value.st_dev)==entry.device,Int64(clamping:value.st_ino)==entry.inode,UInt64(max(0,value.st_size))==entry.logicalBytes else{throw DiskAnalysisStore.Failure(message:"文件身份改变、不是普通文件或属于云端占位文件。")}
        let modified=Double(value.st_mtimespec.tv_sec)+Double(value.st_mtimespec.tv_nsec)/1e9
        guard abs(modified-entry.modified)<0.000001 else{throw DiskAnalysisStore.Failure(message:"文件已修改，请同步索引后重试。")}
        return Identity(changed:Double(value.st_ctimespec.tv_sec)+Double(value.st_ctimespec.tv_nsec)/1e9,modified:modified,size:entry.logicalBytes,device:entry.device,inode:entry.inode)
    }
    static func openEntry(_ entry:DiskAnalysisEntry)throws->(Int32,Identity){
        guard !entry.directory, !DiskLocalPolicy.isIndexStorage(entry.path), DiskLocalPolicy.exclusion(entry.path) == nil,
              DiskLocalPolicy.isLocalVolume(entry.path) else {
            throw DiskAnalysisStore.Failure(message: "只读取已索引的本地普通文件，跳过活动索引文件与云映射目录。")
        }
        let fd=open(entry.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
        guard fd>=0 else{throw DiskAnalysisStore.Failure(message:"无法读取该文件，请自行检查权限。")}
        do{return (fd,try identity(fd,entry:entry))}catch{close(fd);throw error}
    }
    static func hash(entry:DiskAnalysisEntry,volume:String,catalog:DiskStorageCatalog,cancellation:DiskScanCancellation)throws->String{
        let (fd,before)=try openEntry(entry);defer{close(fd)}
        if let cache=try catalog.enrichment(volume:volume,entry:entry,changed:before.changed),!cache.0.isEmpty{return cache.0}
        var digest=SHA256(),buffer=[UInt8](repeating:0,count:1024*1024),total:UInt64=0
        while true{
            if cancellation.isCancelled{throw DiskAnalysisStore.Failure(message:"已取消内容校验。")}
            let count=buffer.withUnsafeMutableBytes{Darwin.read(fd,$0.baseAddress,$0.count)}
            if count==0{break};if count<0{if errno==EINTR{continue};throw DiskAnalysisStore.Failure(message:"读取失败。")}
            digest.update(data:Data(buffer[0..<count]));total+=UInt64(count)
        }
        let after=try identity(fd,entry:entry)
        guard total==before.size,after.changed==before.changed else{throw DiskAnalysisStore.Failure(message:"校验时文件发生变化，结果已丢弃。")}
        let hash=digest.finalize().map{String(format:"%02x",$0)}.joined()
        try catalog.saveEnrichment(volume:volume,entry:entry,changed:after.changed,hash:hash)
        return hash
    }
    final class DimensionsBox: @unchecked Sendable {
        private let lock=NSLock();private var value:(Int,Int)?
        func set(_ size:(Int,Int)){lock.lock();value=size;lock.unlock()}
        func get()->(Int,Int)?{lock.lock();defer{lock.unlock()};return value}
    }
    static func media(entry:DiskAnalysisEntry,volume:String,catalog:DiskStorageCatalog,cancellation:DiskScanCancellation)throws->(Int,Int){
        let(fd,before)=try openEntry(entry);defer{close(fd)}
        if let cache=try catalog.enrichment(volume:volume,entry:entry,changed:before.changed),cache.1>0{return(cache.1,cache.2)}
        let url=URL(fileURLWithPath:entry.path)
        var dimensions:(Int,Int)?
        if ["video","recording"].contains(entry.kind) || ["mp4","mov","mkv","avi","webm","m4v"].contains(entry.fileExtension.lowercased()){
            let box=DimensionsBox(),semaphore=DispatchSemaphore(value:0)
            let task=Task{
                defer{semaphore.signal()}
                do{
                    let asset=AVURLAsset(url:url)
                    guard let track=try await asset.loadTracks(withMediaType:.video).first else{return}
                    let size=try await track.load(.naturalSize),transform=try await track.load(.preferredTransform)
                    let displayed=size.applying(transform)
                    box.set((Int(abs(displayed.width)),Int(abs(displayed.height))))
                }catch{}
            }
            var waited=0
            while semaphore.wait(timeout:.now()+0.1) == .timedOut {
                waited+=1
                if cancellation.isCancelled || waited>=30{task.cancel();throw DiskAnalysisStore.Failure(message:cancellation.isCancelled ? "已取消属性读取。" : "媒体属性读取超时，未强行解码。")}
            }
            dimensions=box.get()
        }else if let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
                 let values=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                 let width=values[kCGImagePropertyPixelWidth] as? NSNumber,let height=values[kCGImagePropertyPixelHeight] as? NSNumber{dimensions=(width.intValue,height.intValue)}
        let after=try identity(fd,entry:entry)
        guard before.changed==after.changed,let dimensions,dimensions.0>0,dimensions.1>0 else{throw DiskAnalysisStore.Failure(message:"无法读取可靠分辨率，或文件已改变。")}
        try catalog.saveEnrichment(volume:volume,entry:entry,changed:after.changed,width:dimensions.0,height:dimensions.1)
        return dimensions
    }
}

enum DiskSnapshotReader {
    /// Read-only command with a bounded run time; no sudo, thinning or deletion.
    static func output(_ executable:String,_ arguments:[String],cancellation:DiskScanCancellation)throws->Data{
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("MacState-Snapshot-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let stdout=directory.appendingPathComponent("stdout"),stderr=directory.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath:stdout.path,contents:nil),FileManager.default.createFile(atPath:stderr.path,contents:nil) else{throw DiskAnalysisStore.Failure(message:"无法创建快照信息缓冲区。")}
        let out=try FileHandle(forWritingTo:stdout),err=try FileHandle(forWritingTo:stderr)
        defer{try? out.close();try? err.close()}
        let process=Process();process.executableURL=URL(fileURLWithPath:executable);process.arguments=arguments;process.standardOutput=out;process.standardError=err
        try process.run();let deadline=Date().addingTimeInterval(5)
        while process.isRunning && Date()<deadline && !cancellation.isCancelled{Thread.sleep(forTimeInterval:0.05)}
        if process.isRunning{process.terminate();throw DiskAnalysisStore.Failure(message:"快照读取已取消或超时。")}
        process.waitUntilExit();try out.close();try err.close()
        guard process.terminationStatus==0 else{
            let data=try Data(contentsOf:stderr)
            throw DiskAnalysisStore.Failure(message:String(data:data.prefix(65536),encoding:.utf8) ?? "系统未提供快照数据；请自行检查权限。")
        }
        let size=(try FileManager.default.attributesOfItem(atPath:stdout.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size<=4*1024*1024 else{throw DiskAnalysisStore.Failure(message:"快照列表超过安全读取范围。")}
        return try Data(contentsOf:stdout)
    }

    static func report(requestID:String,queryID:String,volume:String,cancellation:DiskScanCancellation)throws->DiskWorkbenchReport{
        var report=DiskWorkbenchReport(requestID:requestID,queryID:queryID,mode:"snapshots")
        let data=try output("/usr/sbin/diskutil",["apfs","listSnapshots",volume,"-plist"],cancellation:cancellation)
        let dictionary=try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] ?? [:]
        let snapshots=dictionary["Snapshots"] as? [[String:Any]] ?? []
        for value in snapshots{
            let name=value["Name"] as? String ?? value["SnapshotName"] as? String ?? "未命名快照"
            let uuid=value["SnapshotUUID"] as? String ?? value["UUID"] as? String ?? ""
            let purgeable=(value["Purgeable"] as? Bool).map{$0 ? "系统标记可清除" : "系统未标记可清除"} ?? "可清除状态未知"
            report.rows.append(DiskWorkbenchRow(title:name,category:name.hasPrefix("com.apple.TimeMachine") ? "Time Machine" : "其他 APFS 快照",detail:"\(uuid) · \(purgeable) · 独占占用/可释放空间未知"))
        }
        report.stats=[DiskWorkbenchStat(key:"snapshots",title:"全部本地快照",bytes:0,count:snapshots.count),DiskWorkbenchStat(key:"time-machine",title:"Time Machine 快照",bytes:0,count:report.rows.filter{$0.category=="Time Machine"}.count)]
        report.note="APFS 快照共享数据块，系统列表不提供可靠的每快照独占占用或删除后释放量；因此不显示虚假的大小合计。此页只读，不删除或瘦身快照，不申请管理员权限。"
        return report
    }
}
