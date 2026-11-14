import AppKit
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit

struct ScreenshotSettings: Codable {
    var destination = "both"
    var directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/MacState").path
    var format = "png"
    var prefix = "MacState"
    var delay = 0
    var pointer = false
    var shadow = true
    var preview = true
    var shortcuts = ScreenshotHotkeys.defaults
    func validated() -> Self {
        var result = self
        if !["both","clipboard","file"].contains(destination) { result.destination = "both" }
        if !["png","jpg"].contains(format) { result.format = "png" }
        result.delay = max(0,min(30,delay))
        result.prefix = String(prefix.filter { $0 != "/" && $0 != ":" && !$0.isNewline }.prefix(60))
        if result.prefix.isEmpty { result.prefix = "MacState" }
        if !directory.hasPrefix("/") { result.directory = ScreenshotSettings().directory }
        for mode in ScreenshotHotkeys.modes where result.shortcuts[mode] == nil { result.shortcuts[mode] = ScreenshotHotkeys.defaults[mode] }
        return result
    }
}
struct ScreenshotRecord: Codable {
    let id: String
    let date: Double
    let mode: String
    let path: String
    var outputPath: String
    let thumbnail: String
    let width: Int
    let height: Int
}
struct ScreenshotState: Encodable {
    let settings: ScreenshotSettings
    let permission: Bool
    let busy: Bool
    let canCancel: Bool
    let message: String
    let hotkeyError: String
    let records: [ScreenshotRecord]
    let displays: [String]
}
final class ScreenshotController {
    var onState: ((ScreenshotState) -> Void)?
    var onEditorImage: ((String,CGImage) -> Void)?
    var onLongCaptureStarted: ((CGRect) -> Void)?
    var onLongCaptureEnded: (() -> Void)?
    var onPreview: (() -> Void)?
    private(set) var settings: ScreenshotSettings
    private var records: [ScreenshotRecord] = []
    private let worker = DispatchQueue(label:"MacState.screenshot",qos:.userInitiated)
    private let hotkeys = ScreenshotHotkeys()
    private let base: URL
    private var busy = false, message = "", hotkeyError = ""
    private var process: Process?
    private var pending: DispatchWorkItem?
    private var generation = UUID()
    private var directRegionCapture = false
    private let regionPicker = ScreenshotRegionPicker()
    private var longCapture: ScreenshotLongCapture?
    private let defaults: UserDefaults
    private let permissionCheck: () -> Bool
    init(base: URL? = nil, defaults: UserDefaults = .standard, permissionCheck: @escaping () -> Bool = CGPreflightScreenCaptureAccess) {
        self.defaults = defaults; self.permissionCheck = permissionCheck
        self.base = base ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("MacState/Screenshots",isDirectory:true)
        settings = defaults.data(forKey:"screenshotSettings").flatMap { try? JSONDecoder().decode(ScreenshotSettings.self,from:$0) }?.validated() ?? ScreenshotSettings()
        if let data = try? Data(contentsOf:self.base.appendingPathComponent("history.json")), let saved = try? JSONDecoder().decode([ScreenshotRecord].self,from:data) {
            records = Array(saved.filter { URL(fileURLWithPath:$0.path).deletingLastPathComponent().standardizedFileURL == self.base.standardizedFileURL }.prefix(100))
        }
    }
    func start() {
        hotkeys.onCapture = { [weak self] in self?.capture(mode:$0,display:1) }
        hotkeyError = hotkeys.install(settings.shortcuts)
    }
    func stop() { cancel(); hotkeys.stop() }
    func state() {
        onState?(ScreenshotState(settings:settings,permission:permissionCheck(),busy:busy,canCancel:pending != nil || process != nil || directRegionCapture || regionPicker.active || longCapture != nil,message:message,hotkeyError:hotkeyError,records:records,displays:NSScreen.screens.enumerated().map { "显示器 \($0.offset+1) · \($0.element.localizedName)" }))
    }
    func saveSettings(_ candidate: ScreenshotSettings) {
        let next = candidate.validated(), old = settings
        let error = hotkeys.install(next.shortcuts)
        if !error.isEmpty { _ = hotkeys.install(old.shortcuts); hotkeyError = error; message = "快捷键未保存，请更换组合后重试。"; state(); return }
        settings = next; hotkeyError = ""
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data,forKey:"screenshotSettings") }
        message = "截屏设置已保存。"; state()
    }
    func chooseDirectory(window: NSWindow) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath:settings.directory); panel.prompt = "选择保存目录"
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            var next = self.settings; next.directory = url.path; self.saveSettings(next)
        }
    }
    func resetShortcuts() { var next = settings; next.shortcuts = ScreenshotHotkeys.defaults; saveSettings(next) }
    func suspendShortcuts(_ suspended: Bool) { if suspended { hotkeys.stop() } else { hotkeyError = hotkeys.install(settings.shortcuts); state() } }
    func cancel() {
        generation = UUID(); pending?.cancel(); pending = nil; directRegionCapture = false; regionPicker.dismiss()
        let currentLong=longCapture;longCapture=nil;currentLong?.cancel()
        if currentLong != nil {onLongCaptureEnded?()}
        if let process, process.isRunning { process.terminate() }
        process = nil; busy = false; message = "已取消截屏。"; state()
    }
    func capture(mode: String, display: Int) {
        guard ScreenshotHotkeys.modes.contains(mode) else { return }
        guard !busy else { message = "请等待当前截屏或文字识别完成。"; state(); return }
        guard permissionCheck() else { message = "未获得屏幕录制权限。请手动前往系统设置授权，再点击重新检测；不会自动申请权限。"; state(); return }
        busy = true; generation = UUID(); let token = generation, config = settings
        message = config.delay>0 ? "将在 \(config.delay) 秒后截屏；不会隐藏任何窗口。" : "正在截屏；Esc 可取消区域或窗口选择。"; state()
        let task = DispatchWorkItem { [weak self] in self?.beginCapture(mode:mode,display:display,config:config,token:token) }
        pending = task; state(); DispatchQueue.main.asyncAfter(deadline:.now()+Double(config.delay),execute:task)
    }
    private func beginCapture(mode: String, display: Int, config: ScreenshotSettings, token: UUID, allowFastRegionCapture: Bool = true) {
        guard token == generation else { return }; pending = nil
        if mode == "region", allowFastRegionCapture, #available(macOS 15.2, *) {
            let frames = NSScreen.screens.map(\.frame)
            guard !frames.isEmpty else { finishError("未找到可截取的显示器。",token:token); return }
            directRegionCapture = true; message = "正在冻结屏幕画面…"; state()
            let group = DispatchGroup(), lock = NSLock()
            var images: [Int:CGImage] = [:]
            for (index, frame) in frames.enumerated() {
                group.enter()
                SCScreenshotManager.captureImage(in: ScreenshotCaptureCoordinates.quartzRect(appKitRect:frame,primaryScreenTop:NSScreen.screens.first?.frame.maxY ?? 0)) { image, _ in
                    if let image { lock.lock(); images[index] = image; lock.unlock() }
                    group.leave()
                }
            }
            worker.async { [weak self] in
                group.wait(); lock.lock(); let captured = images; lock.unlock()
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.directRegionCapture = false
                    if captured.count == frames.count && captured.values.allSatisfy({ Double($0.width)*Double($0.height) <= 100_000_000 }) {
                        self.presentRegionPicker(frames:frames.enumerated().compactMap { index, frame in captured[index].map { (frame,$0) } },mode:mode,config:config,token:token)
                    } else {
                        // Older capture backends remain the recovery path if ScreenCaptureKit cannot freeze every display.
                        self.beginCapture(mode:mode,display:display,config:config,token:token,allowFastRegionCapture:false)
                    }
                }
            }
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacState-Capture-"+UUID().uuidString,isDirectory:true)
        do { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true) }
        catch { finishError(error.localizedDescription,token:token); return }
        // One system invocation captures all displays at the same instant. No window hiding.
        let screenFrames = NSScreen.screens.map(\.frame)
        let count = mode == "region" || (mode == "screen" && display == 0) ? max(1,screenFrames.count) : 1
        let urls = (0..<count).map { folder.appendingPathComponent("screen-\($0).png") }
        var args = ["-x","-t","png"]
        if mode == "region" { /* Freeze all displays before showing the color/selection overlay. */ }
        else if mode == "window" { args += ["-i","-w"]; if !config.shadow { args.append("-o") } }
        else { if display != 0 { args += ["-D",String(max(1,min(NSScreen.screens.count,display)))] }; if config.pointer { args.append("-C") } }
        args += urls.map(\.path)
        let task = Process(); task.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture"); task.arguments = args
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] completed in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.generation == token else { try? FileManager.default.removeItem(at:folder); return }
                self.process = nil; self.message = mode == "region" ? "正在准备框选…" : "正在保存截图…"; self.state()
                self.worker.async {
                    defer { try? FileManager.default.removeItem(at:folder) }
                    do {
                        guard completed.terminationStatus == 0 else { throw CocoaError(.userCancelled) }
                        // Keep display/frame correspondence; never shift later screens into missing slots.
                        let data = try urls.map { try Data(contentsOf:$0) }
                        if mode == "region" {
                            let images = try data.map { try self.image($0) }
                            guard images.count == screenFrames.count else { throw CocoaError(.fileReadUnknown) }
                            let frames = Array(zip(screenFrames,images))
                            DispatchQueue.main.async { [self] in
                                guard self.generation == token else { return }
                                self.presentRegionPicker(frames:frames,mode:mode,config:config,token:token)
                            }
                        } else { self.saveCaptured(data,mode:mode,config:config,token:token) }
                    } catch {
                        DispatchQueue.main.async { self.finishError(error is CocoaError && (error as? CocoaError)?.code == .userCancelled ? "截屏已取消。" : "截屏失败：\(error.localizedDescription)",token:token) }
                    }
                }
            }
        }
        process = task
        do { try task.run(); state() } catch { try? FileManager.default.removeItem(at:folder); finishError(error.localizedDescription,token:token) }
    }
    private func presentRegionPicker(frames: [(NSRect,CGImage)], mode: String, config: ScreenshotSettings, token: UUID) {
        regionPicker.start(frames:frames,onLongCapture:{ [weak self] rect,first in
            guard let self,self.generation==token else{return}
            self.onLongCaptureStarted?(rect)
            self.message="长截屏进行中：可自动或手动向下滚动，点击完成后拼接。";self.state()
            self.longCapture=ScreenshotLongCapture(rect:rect,first:first) { [weak self] image,error in
                guard let self,self.generation==token else{return}
                self.longCapture=nil
                self.onLongCaptureEnded?()
                if let error {self.finishError("长截图合成失败："+error,token:token);return}
                guard let image else{self.cancel();return}
                self.message="正在合成长截图并保存…";self.state()
                self.worker.async {
                    do {self.saveCaptured([try self.encoded(image,format:"png")],mode:"long",config:config,token:token)}
                    catch {DispatchQueue.main.async {self.finishError(error.localizedDescription,token:token)}}
                }
            }
        }) { [weak self] selected in
            guard let self,self.generation == token else { return }
            guard let selected else { self.cancel(); return }
            let action=self.regionPicker.outputAction
            if action == "pin" {self.busy=false;self.message="截图已固定，可拖动位置或关闭。";self.state();return}
            var outputConfig=config
            if action == "save" {outputConfig.destination="file";outputConfig.preview=false}
            if action == "copy" {outputConfig.destination="clipboard";outputConfig.preview=false}
            self.message = "正在保存截图…"; self.state()
            self.worker.async {
                do { self.saveCaptured([try self.encoded(selected,format:"png")],mode:mode,config:outputConfig,token:token) }
                catch { DispatchQueue.main.async { self.finishError(error.localizedDescription,token:token) } }
            }
        }
        message = "拖动框选，实时显示 HEX / RGB；C 拷贝色值，Esc 或右键取消。"; state()
    }
    /// Runs on the image worker; only commits visible state on the main thread.
    private func saveCaptured(_ data: [Data], mode: String, config: ScreenshotSettings, token: UUID) {
        var created: [ScreenshotRecord] = []
        do {
            for image in data { created.append(try makeRecord(data:image,mode:mode,config:config,output:nil,saveConfigured:config.destination != "clipboard")) }
            DispatchQueue.main.async {
                guard self.generation == token else { self.removeCached(created); return }
                self.busy = false; self.addRecords(created)
                if config.destination != "file",let last = created.last,let image = NSImage(contentsOfFile:last.path) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
                }
                let destination = config.destination == "clipboard" ? "已复制，原图保留在本机最近截图中。" : config.destination == "both" ? "已保存并复制。" : "已保存到指定目录。"
                self.message = "已截取 \(created.count) 张图片。"+destination; self.state()
                if config.preview,!created.isEmpty { self.onPreview?() }
            }
        } catch {
            DispatchQueue.main.async {
                if self.generation == token { self.addRecords(created) } else { self.removeCached(created) }
                self.finishError(error.localizedDescription,token:token)
            }
        }
    }
    private func finishError(_ text: String, token: UUID) { guard token == generation else { return }; process = nil; directRegionCapture = false; busy = false; message = text; state() }
    private func image(_ data: Data) throws -> CGImage {
        guard data.count <= 64*1024*1024, let source = CGImageSourceCreateWithData(data as CFData,nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width>0,height>0, Double(width)*Double(height)<=100_000_000,
              let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw NSError(domain:"Screenshot",code:1,userInfo:[NSLocalizedDescriptionKey:"图片无效或超过 64 MiB / 1 亿像素限制。"] ) }
        return image
    }
    private func encoded(_ image: CGImage, format: String) throws -> Data {
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data,format == "jpg" ? UTType.jpeg.identifier as CFString : UTType.png.identifier as CFString,1,nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(output,image,[kCGImageDestinationLossyCompressionQuality:0.94] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }; return data as Data
    }
    private func makeRecord(data: Data, mode: String, config: ScreenshotSettings, output: URL?, saveConfigured: Bool) throws -> ScreenshotRecord {
        let cg = try image(data), id = UUID().uuidString
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let cached = base.appendingPathComponent(id+".png")
        try encoded(cg,format:"png").write(to:cached,options:.atomic)
        var destination = output
        do {
        if destination == nil && saveConfigured {
            let folder = URL(fileURLWithPath:config.directory,isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
            destination = folder.appendingPathComponent(config.prefix+"_"+formatter.string(from:Date())+"_"+String(id.prefix(5))+"."+config.format)
        }
        if let destination { try encoded(cg,format:destination.pathExtension.lowercased() == "jpg" || destination.pathExtension.lowercased() == "jpeg" ? "jpg" : "png").write(to:destination,options:.atomic) }
        } catch { try? FileManager.default.removeItem(at:cached); throw error }
        let source = CGImageSourceCreateWithData(data as CFData,nil)!
        let thumb = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:240] as CFDictionary)
        let thumbnail = try thumb.map { "data:image/png;base64," + (try encoded($0,format:"png")).base64EncodedString() } ?? ""
        return ScreenshotRecord(id:id,date:Date().timeIntervalSince1970,mode:mode,path:cached.path,outputPath:destination?.path ?? "",thumbnail:thumbnail,width:cg.width,height:cg.height)
    }
    private func persist() {
        let copy = records, url = base.appendingPathComponent("history.json")
        worker.async { [weak self] in do { try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); try JSONEncoder().encode(copy).write(to:url,options:.atomic) } catch { DispatchQueue.main.async { [weak self] in self?.message = "最近截图记录保存失败：\(error.localizedDescription)"; self?.state() } } }
    }
    private func addRecords(_ added: [ScreenshotRecord]) {
        records.insert(contentsOf:added,at:0)
        if records.count>100 { let expired = Array(records.dropFirst(100)); records = Array(records.prefix(100)); removeCached(expired) }
        persist()
    }
    private func removeCached(_ list: [ScreenshotRecord]) { worker.async { for item in list { try? FileManager.default.removeItem(atPath:item.path) } } }
    func openEditor(_ id: String) {
        guard !busy,let record=records.first(where:{$0.id==id}) else{return}
        busy=true;message="正在载入截图…";state()
        worker.async { [weak self] in
            guard let self else{return}
            do {
                let data=try Data(contentsOf:URL(fileURLWithPath:record.path)),image=try self.image(data)
                DispatchQueue.main.async {self.busy=false;self.message="";self.state();self.onEditorImage?(id,image)}
            } catch {DispatchQueue.main.async {self.busy=false;self.message="截图载入失败：\(error.localizedDescription)";self.state()}}
        }
    }
    func finishEditor(_ image: CGImage,id: String,action: String,window: NSWindow) {
        guard !busy,records.contains(where:{$0.id==id}) else{return}
        if action=="copy" {
            saveEditedOutput(image,id:id,action:"copy",output:nil)
            return
        }
        guard action=="save" else{return}
        let panel=NSSavePanel();panel.allowedContentTypes=settings.format=="jpg" ? [.jpeg]:[.png];panel.nameFieldStringValue=settings.prefix+"-标注."+settings.format;panel.directoryURL=URL(fileURLWithPath:settings.directory)
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self,response == .OK,let url=panel.url else{return}
            self.saveEditedOutput(image,id:id,action:"save",output:url)
        }
    }
    /// Shared pipeline for editor outputs. Like a new region capture, each
    /// successful copy or save gets its own local cache, thumbnail, history ID
    /// and state notification; editing never overwrites the source record.
    func saveEditedOutput(_ image: CGImage,id: String,action: String,output: URL?) {
        guard !busy,records.contains(where:{$0.id==id}),
              (action=="copy" && output == nil) || (action=="save" && output != nil) else{return}
        busy=true;message=action=="copy" ? "正在复制并记录标注副本…" : "正在保存标注副本…";state()
        let config=settings
        worker.async { [weak self] in
            guard let self else{return}
            do {
                let data=try self.encoded(image,format:"png")
                let record=try self.makeRecord(data:data,mode:"edited",config:config,output:output,saveConfigured:false)
                DispatchQueue.main.async {
                    self.busy=false
                    self.addRecords([record])
                    if action=="copy" {
                        let clipboardImage=NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))
                        NSPasteboard.general.clearContents()
                        let copied=NSPasteboard.general.writeObjects([clipboardImage])
                        self.message=copied ? "图片已复制，标注副本已加入最近截图。" : "标注副本已加入最近截图，但写入剪贴板失败。"
                    } else {
                        self.message="标注副本已保存并加入最近截图，原图未修改。"
                    }
                    self.state()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy=false
                    self.message=(action=="copy" ? "复制并记录标注副本失败：" : "保存失败：")+error.localizedDescription
                    self.state()
                }
            }
        }
    }
    func copyRecord(_ id: String) {
        guard !busy, let record = records.first(where:{$0.id == id}) else { return }
        busy = true; message = "正在复制截图…"; state()
        worker.async { [weak self] in
            guard let self else { return }
            do {
                let data = try Data(contentsOf:URL(fileURLWithPath:record.path)); _ = try self.image(data)
                DispatchQueue.main.async {
                    if let image = NSImage(data:data) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) }
                    self.busy = false; self.message = "图片已复制。"; self.state()
                }
            } catch { DispatchQueue.main.async { self.busy = false; self.message = error.localizedDescription; self.state() } }
        }
    }
    func reveal(_ id: String) {
        guard let record = records.first(where:{$0.id == id}) else { return }
        let path = !record.outputPath.isEmpty && FileManager.default.fileExists(atPath:record.outputPath) ? record.outputPath : record.path
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)])
    }
    func trash(_ id: String, window: NSWindow) {
        guard !busy, let record = records.first(where:{$0.id == id}) else { return }
        let alert = NSAlert(); alert.messageText = "将这张截图移到废纸篓？"; alert.informativeText = "本机最近截图和保存的文件将移到废纸篓，可在访达中恢复。\n"+(record.outputPath.isEmpty ? record.path : record.outputPath); alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"移到废纸篓")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self,response == .alertSecondButtonReturn else { return }
            self.busy = true; self.message = "正在移到废纸篓…"; self.state()
            self.worker.async {
                do {
                    for path in Set([record.path,record.outputPath]).filter({!$0.isEmpty}) where FileManager.default.fileExists(atPath:path) { try FileManager.default.trashItem(at:URL(fileURLWithPath:path),resultingItemURL:nil) }
                    DispatchQueue.main.async { self.records.removeAll {$0.id == id}; self.persist(); self.busy = false; self.message = "已移到废纸篓。"; self.state() }
                } catch { DispatchQueue.main.async { self.busy = false; self.message = error.localizedDescription; self.state() } }
            }
        }
    }
}
