import Foundation

enum DiskStorageExporter {
    static func rows(url:URL,format:String,walk:((DiskWorkbenchRow)throws->Void)throws->Void)throws{
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".MacState-export-"+UUID().uuidString+".tmp")
        guard FileManager.default.createFile(atPath:temporary.path,contents:nil) else{throw DiskAnalysisStore.Failure(message:"无法创建导出文件。")}
        defer{try? FileManager.default.removeItem(at:temporary)}
        let handle=try FileHandle(forWritingTo:temporary);defer{try? handle.close()}
        func write(_ text:String)throws{try handle.write(contentsOf:Data(text.utf8))}
        let encoder=JSONEncoder();var first=true
        if format=="csv"{try write("\u{FEFF}名称,路径,分类,实际占用字节,逻辑大小字节,时间,变化字节,容量字节,可用字节,说明,内容哈希,宽,高\n")}else{try write("[\n")}
        try walk{row in
            if format=="csv"{
                func quote(_ value:String)->String{"\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\""}
                let values=[row.title,row.path,row.category,String(row.bytes),row.entry.map{String($0.logicalBytes)} ?? "",String(row.timestamp),row.delta.map{String($0)} ?? "",row.totalBytes.map{String($0)} ?? "",row.availableBytes.map{String($0)} ?? "",row.detail,row.hash,String(row.width),String(row.height)]
                try write(values.enumerated().map{index,value in
                    let safe=[0,1,2,9,10].contains(index) && ["=","+","-","@","\t","\r"].contains(where:value.hasPrefix) ? "'"+value : value
                    return quote(safe)
                }.joined(separator:",")+"\n")
            }else{
                if !first{try write(",\n")};try handle.write(contentsOf:encoder.encode(row));first=false
            }
        }
        if format != "csv"{try write("\n]\n")};try handle.synchronize();try handle.close()
        if FileManager.default.fileExists(atPath:url.path){_ = try FileManager.default.replaceItemAt(url,withItemAt:temporary)}else{try FileManager.default.moveItem(at:temporary,to:url)}
    }
}
