import AppKit
import WebKit
import ServiceManagement

@main
enum MacStateMain {
    static func main() {
        if DiskIndexMaintenance.runIfRequested(CommandLine.arguments) { return }
        if CommandLine.arguments.contains("--diagnose-glass") {
            print("Glass: native AppKit; screen capture: disabled; custom Metal renderer: disabled")
            return
        }
        if CommandLine.arguments.contains("--diagnose") || CommandLine.arguments.contains("--diagnose-energy") || CommandLine.arguments.contains("--energy-samples") {
            let args = CommandLine.arguments
            func argument(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
            let streaming = args.contains("--energy-samples")
            let count = streaming ? Int(argument("--energy-samples") ?? "") ?? 0 : 1
            let interval = Double(argument("--energy-interval") ?? "1") ?? 0
            guard (1...600).contains(count), interval.isFinite, (0.2...10).contains(interval) else {
                fputs("--energy-samples 1…600 --energy-interval 0.2…10\n", stderr); exit(1)
            }
            let collector = Collector()
            _ = collector.collect()
            let encoder = JSONEncoder(); encoder.outputFormatting = streaming ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
            for _ in 0..<count {
                Thread.sleep(forTimeInterval: interval)
                do {
                    let data = try encoder.encode(collector.collect())
                    FileHandle.standardOutput.write(data)
                    if streaming { FileHandle.standardOutput.write(Data([10])) }
                } catch { fputs("诊断输出失败：\(error)\n", stderr); exit(1) }
            }
            return
        }
        let appearanceSettings = UserDefaults.standard.data(forKey: "settings")
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }?.validated() ?? Settings()
        GlassMaterialPreferences.apply(opacity: appearanceSettings.glassOpacity)
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private var cleanupConfirmationActive = false
    private let fileInteractions = DiskFileInteractionController()
    private var window: NSWindow!
    private var sideMouseMonitor: Any?
    private var webView: WKWebView!
    private var mainContent: NSView!
    private var screenshotEditorPanel: ScreenshotEditorPanel?
    private var longCapturePresentation: ScreenshotLongCapturePresentation?
    private var screenshotPinnedWindows: [ScreenshotPinnedWindow] = []
    private var glassSurface: GlassSurfaceView?
    private var componentGlass: ComponentGlassHost?
    private var panelDragHandle: PanelDragHandle?
    private var sidebarDragHandle: PanelDragHandle?
    private var panelResizeHandle: PanelResizeHandle?
    private var items: [String: NSStatusItem] = [:]
    private var menuBarView: MenuBarView?
    private var menuPreviewVisible = false
    private var settings = Settings()
    private let collector = Collector()
    private let queue = DispatchQueue(label: "app.macstate.collect", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var snapshot: Snapshot?
    private var ready = false
    private var pendingOverview = false
    private var restoredNavigation = false
    private var samples: [HistorySample] = []
    private var webRoot: URL!
    private let encoder = JSONEncoder()
    private var panelSize = PanelGeometry.defaultSize
    private var panelOrigin: NSPoint?
    private var usage = UsageRecorder()
    private let usageApps = UsageAppCapture()
    private let usageSaveQueue = DispatchQueue(label: "app.macstate.usage-save", qos: .utility)
    private var usageVisible = false
    private var selectedUsageID: String?
    private var lastUsageSave: Double = 0
    private var lastUsageSend: Double = 0
    private var usageObservers: [NSObjectProtocol] = []
    private var usageSuspensions = Set<String>()
    private var usageSaveEnabled = true
    private var usageStartupError: String?
    private let screenshots = ScreenshotController()
    private let missionControlHotkey = MissionControlHotkey()
    private let displayBrightness = DisplayBrightnessController()
    private let diskAnalysis = DiskIndexService()

    private func handleFileInteraction(requestID: String, paths: [String], kind: String, application: String?) {
        guard ["open","preview","copy","names","paths","trash"].contains(kind) else { return }
        if kind == "trash", cleanupConfirmationActive { send(["message":"请先完成当前确认。","success":"false"],function:"receiveDiskInteractionResult"); return }
        if kind == "trash" { cleanupConfirmationActive = true }
        diskAnalysis.interactionEntries(paths:paths,requestID:requestID,forTrash:kind == "trash") { [weak self] result in
            guard let self else { return }
            func feedback(_ text: String, _ success: Bool = false) { self.send(["message":text,"success":success ? "true" : "false"],function:"receiveDiskInteractionResult") }
            switch result {
            case .failure(let error): if kind == "trash" { self.cleanupConfirmationActive = false }; feedback(error.localizedDescription)
            case .success(let entries):
                let urls = entries.map { URL(fileURLWithPath:$0.path) }
                switch kind {
                case "preview": self.fileInteractions.preview(urls)
                case "open": self.fileInteractions.open(urls,application:application) { if let error = $0 { feedback(error) } }
                case "copy", "names", "paths":
                    NSPasteboard.general.clearContents()
                    let copied: Bool
                    if kind == "copy" { copied = NSPasteboard.general.writeObjects(urls as [NSURL]) }
                    else { copied = NSPasteboard.general.setString(entries.map { kind == "names" ? $0.name : $0.path }.joined(separator:"\n"),forType:.string) }
                    feedback(copied ? "已拷贝 \(entries.count) 项" : "无法写入剪贴板。",copied)
                case "trash":
                    let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }
                    guard !entries.contains(where: { e in let path = URL(fileURLWithPath:e.path).resolvingSymlinksInPath().path; return running.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) }) else {
                        self.cleanupConfirmationActive = false; feedback("选中项包含正在运行的应用，请先退出该应用。"); return
                    }
                    let alert = NSAlert(); alert.messageText = "将 \(entries.count) 个项目移到废纸篓？"
                    alert.informativeText = "包含所选文件夹及其内容。不会永久删除，可在 Finder 的废纸篓恢复。"
                    let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:520,height:180)); scroll.hasVerticalScroller = true
                    let text = NSTextView(frame:scroll.bounds); text.isEditable = false; text.isSelectable = true; text.string = entries.map(\.path).joined(separator:"\n"); scroll.documentView = text; alert.accessoryView = scroll
                    alert.alertStyle = .warning; alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"移到废纸篓")
                    alert.beginSheetModal(for:self.window) { response in
                        self.cleanupConfirmationActive = false
                        if response == .alertSecondButtonReturn {
                            let operationID = "interaction-" + UUID().uuidString
                            self.diskAnalysis.trashInteractionEntries(entries,requestID:requestID,operationID:operationID)
                        } else { feedback("已取消。") }
                    }
                default: break
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = UserDefaults.standard.data(forKey: "settings"), let saved = try? JSONDecoder().decode(Settings.self, from: data) { settings = saved.validated() }
        displayBrightness.onUpdate = { [weak self] rows in self?.send(rows,function:"receiveDisplayBrightness") }
        missionControlHotkey.onStatusChange = { [weak self] _ in self?.sendHotkeyStatus() }
        missionControlHotkey.onOpenMissionControl = { [weak self] in self?.openMissionControl() }
        diskAnalysis.onStatuses = { [weak self] in self?.send($0, function: "receiveDiskIndexes") }
        diskAnalysis.onProgress = { [weak self] in self?.send($0, function: "receiveDiskAnalysis") }
        diskAnalysis.onDirectory = { [weak self] in self?.send($0, function: "receiveDiskDirectory") }
        diskAnalysis.onSpaceMap = { [weak self] in self?.send($0, function: "receiveDiskSpaceMap") }
        diskAnalysis.onFileTypes = { [weak self] in self?.send($0, function: "receiveDiskFileTypes") }
        diskAnalysis.onWorkbench = { [weak self] in self?.send($0,function:"receiveDiskWorkbench") }
        diskAnalysis.onWorkbenchProgress = { [weak self] request,query,message,completed,total in self?.send(DiskWorkbenchProgress(requestID:request,queryID:query,message:message,completed:completed,total:total),function:"receiveDiskWorkbenchProgress") }
        diskAnalysis.onInsights = { [weak self] in self?.send($0, function: "receiveDiskInsights") }
        diskAnalysis.onLargeFiles = { [weak self] in self?.send($0, function: "receiveDiskLargeFiles") }
        diskAnalysis.onFileAction = { [weak self] in self?.send($0, function: "receiveDiskFileAction") }
        diskAnalysis.onAccess = { [weak self] in self?.send($0.rawValue, function: "receiveDiskAccess") }
        if settings.commandTabOpensMissionControl { missionControlHotkey.setEnabled(true, requestAccess: false) }
        settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        encoder.outputFormatting = [.sortedKeys]
        do { usage = UsageRecorder(archive: try UsagePersistence.load(from: UsagePersistence.defaultURL)) }
        catch {
            let url = UsagePersistence.defaultURL
            let backup = url.deletingLastPathComponent().appendingPathComponent("usage-history-recovery-\(Int(Date().timeIntervalSince1970)).json")
            do { try UsagePersistence.preserveForRecovery(from: url, to: backup) }
            catch { usageSaveEnabled = false }
            usageStartupError = "使用记录读取失败，原文件已保留。\(usageSaveEnabled ? "已备份，开始新的记录。" : "暂时无法保存新的记录。")"
        }
        if let saved = UserDefaults.standard.dictionary(forKey: "panelSize"), let width = saved["width"] as? Double, let height = saved["height"] as? Double {
            panelSize = NSSize(width: width, height: height)
        }
        if let saved = UserDefaults.standard.dictionary(forKey: "panelOrigin"), let x = saved["x"] as? Double, let y = saved["y"] as? Double, x.isFinite, y.isFinite {
            panelOrigin = NSPoint(x: x, y: y)
        }
        createWindow()
        longCapturePresentation = ScreenshotLongCapturePresentation(window:window)
        screenshots.onLongCaptureStarted = { [weak self] selection in self?.longCapturePresentation?.begin(selection:selection) }
        screenshots.onLongCaptureEnded = { [weak self] in self?.longCapturePresentation?.end() }
        screenshots.onState = { [weak self] in self?.send($0,function:"receiveScreenshotState") }
        screenshots.onEditorImage = { [weak self] id,image in self?.presentScreenshotEditor(image,id:id) }
        screenshots.onPreview = { [weak self] in self?.showWindow(); self?.invoke("navigate('screenshot')") }
        screenshots.start()
        createStatusItems()
        installUsageObservers()
        startSampling()
        diskAnalysis.checkAccess()
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            showWindow()
            UserDefaults.standard.set(true, forKey: "hasLaunched")
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.cancel()
        screenshots.stop()
        ScreenshotOCRLocalSession.shared.shutdown()
        ScreenshotOCRLocalRuntime.cancelPreparation()
        missionControlHotkey.setEnabled(false, requestAccess: false)
        displayBrightness.restoreSoftwareBrightness()
        diskAnalysis.cancel()
        for observer in usageObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        persistUsage(force: true)
        usageSaveQueue.sync {}
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard settings.commandTabOpensMissionControl else { return }
        missionControlHotkey.setEnabled(true, requestAccess: false)
        sendHotkeyStatus()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }

    private func createWindow() {
        webRoot = Bundle.module.url(forResource: "Web", withExtension: nil)!
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "macstate")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        let panel = FloatingMonitorPanel(contentRect: NSRect(origin: .zero, size: panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.filePreviewController = fileInteractions
        panel.onDismiss = { [weak self] in self?.dismissPanel() }
        panel.onFullscreenChange = { [weak self] expanded in
            self?.invoke("window.receivePanelFullscreen(\(expanded))")
        }
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.isFloatingPanel = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isMovable = true; panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        window = panel
        sideMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
            guard let self, event.window === self.window, [3,4].contains(event.buttonNumber) else { return event }
            if event.type == .otherMouseDown { self.invoke("window.navigateHistory?.(\(event.buttonNumber == 3 ? -1 : 1))") }
            return nil
        }
        window.title = "MacState"
        window.minSize = PanelGeometry.minimumSize
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: panelSize))
        mainContent = content
        let components = ComponentGlassHost(frame: content.bounds)
        components.autoresizingMask = [.width, .height]
        components.configure(opacity: settings.glassOpacity, nativeLensEnabled: settings.nativeGlassEnabled)
        content.addSubview(components)
        componentGlass = components
        webView.frame = content.bounds; webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)
        let drag = PanelDragHandle(frame: .zero)
        drag.toolTip = "拖动标题区域移动窗口"
        drag.onDragEnd = { [weak self] in self?.rememberPanelPosition() }
        content.addSubview(drag)
        panelDragHandle = drag
        let sidebarDrag = PanelDragHandle(frame: .zero)
        sidebarDrag.toolTip = "拖动侧栏空白处移动窗口"
        sidebarDrag.onDragEnd = { [weak self] in self?.rememberPanelPosition() }
        content.addSubview(sidebarDrag)
        sidebarDragHandle = sidebarDrag
        let handle = PanelResizeHandle(frame: NSRect(x: panelSize.width - 22, y: 0, width: 22, height: 22))
        handle.autoresizingMask = [.minXMargin]
        handle.toolTip = "拖动调整悬浮窗大小"
        handle.onResizeEnd = { [weak self] in self?.rememberPanelSize(); self?.rememberPanelPosition() }
        content.addSubview(handle)
        panelResizeHandle = handle
        let surface = GlassSurfaceView(frame: content.frame, contentView: content, opacity: settings.glassOpacity)
        surface.configure(theme: settings.theme, opacity: settings.glassOpacity, nativeLensEnabled: settings.nativeGlassEnabled)
        glassSurface = surface
        window.contentView = surface
        webView.loadFileURL(webRoot.appendingPathComponent("index.html"), allowingReadAccessTo: webRoot)
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "显示 MacState", action: #selector(showWindow), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 MacState", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(); edit.submenu = editMenu
        for (title, action, key) in [("复制", "copy:", "c"), ("全选", "selectAll:", "a"), ("粘贴", "paste:", "v"), ("剪切", "cut:", "x")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        menu.addItem(edit); NSApp.mainMenu = menu
    }
    private func createStatusItems() {
        for item in items.values { NSStatusBar.system.removeStatusItem(item) }
        items.removeAll()
        // One status item removes the system's fixed spacing between separate items.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = ""
            let view = MenuBarView(frame: button.bounds)
            button.addSubview(view); menuBarView = view
            button.target = self; button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        items["menu"] = item
        updateStatus(snapshot)
    }
    private func updateStatus(_ data: Snapshot?) {
        guard let item = items["menu"], let button = item.button, let menuBarView else { return }
        item.length = menuBarView.configure(settings: settings, metrics: data?.metrics ?? [], height: button.bounds.height)
        var labels: [String] = []
        var tooltips: [String] = []
        for column in settings.resolvedMenuColumns {
            let metrics = data?.metrics ?? []
            let network = column.layout == "network"
            let values = column.metrics.map { metricID in MenuPresentation.value(metrics.first { $0.id == metricID }, hideFanUnit: settings.hideFanUnit) }
            let lines = network ? MenuPresentation.lines(id: "network", metrics: metrics) : (column.name, values.joined(separator: " "))
            labels.append("\(lines.0) \(lines.1)")
            tooltips += column.metrics.map { metricID in
                let metric = metrics.first { $0.id == metricID }
                return "\(metric?.title ?? metricID)：\(MenuPresentation.value(metric)) · \(metric?.source ?? "等待采样")"
            }
        }
        button.toolTip = tooltips.joined(separator: "\n") + "\n点击查看完整数据，右键打开菜单"
        button.setAccessibilityLabel(labels.joined(separator: ", "))
        sendMenuPreview()
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开监控面板", action: #selector(showOverview), keyEquivalent: "").target = self
            menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 MacState", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        } else {
            if window.isVisible { dismissPanel() } else { showWindow() }
        }
    }
    @objc private func showWindow() {
        missionControlHotkey.refreshAccess()
        if (window as? FloatingMonitorPanel)?.isExpanded != true { positionPanel() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        send(samples, function: "receiveHistory")
        if let snapshot { sendSnapshot(snapshot) }
    }
    @objc private func showSettings() { showWindow(); invoke("window.openSettings()") }
    @objc private func showOverview() { pendingOverview = true; showWindow(); sendPendingNavigation() }

    private func presentScreenshotEditor(_ image:CGImage,id:String) {
        guard screenshotEditorPanel == nil,let screen=window.screen ?? NSScreen.main else{return}
        let panel=ScreenshotEditorPanel(image:image,screen:screen)
        let editor=panel.editor
        editor.onPin={ [weak self] image,_ in
            guard let self else{return}
            let display=(self.window.screen ?? NSScreen.main)?.visibleFrame ?? screen.visibleFrame,factor=min(1,min(480/CGFloat(image.width),360/CGFloat(image.height)))
            let pinnedSize=NSSize(width:CGFloat(image.width)*factor,height:CGFloat(image.height)*factor)
            let pinned=ScreenshotPinnedWindow(image:image,frame:NSRect(x:display.midX-pinnedSize.width/2,y:display.midY-pinnedSize.height/2,width:pinnedSize.width,height:pinnedSize.height))
            pinned.onClosed={ [weak self,weak pinned] in self?.screenshotPinnedWindows.removeAll{$0 === pinned} }
            self.screenshotPinnedWindows.append(pinned);pinned.orderFrontRegardless()
        }
        editor.onFinish={ [weak self] image,action in
            guard let self else{return}
            self.dismissScreenshotPageEditor()
            if let image,action=="copy" || action=="save" {self.screenshots.finishEditor(image,id:id,action:action,window:self.window)}
        }
        panel.onClosed={ [weak self] in self?.screenshotEditorPanel=nil }
        screenshotEditorPanel=panel
        panel.makeKeyAndOrderFront(nil);panel.makeFirstResponder(editor);NSApp.activate(ignoringOtherApps:true)
    }
    private func dismissScreenshotPageEditor() {
        screenshotEditorPanel?.close()
    }
    private func positionPanel() {
        let savedScreen = panelOrigin.flatMap { origin in NSScreen.screens.first { $0.visibleFrame.contains(NSPoint(x: origin.x + panelSize.width / 2, y: origin.y + panelSize.height / 2)) } }
        guard let screen = savedScreen ?? items["menu"]?.button?.window?.screen ?? window.screen ?? NSScreen.main else { return }
        window.maxSize = screen.visibleFrame.size
        window.setFrame(PanelGeometry.frame(screen: screen.visibleFrame, size: panelSize, origin: panelOrigin), display: true)
    }
    private func sendGlassStatus() {
        send(!settings.nativeGlassEnabled ? "disabled" : glassSurface?.usesNativeGlass == true ? "native" : "unavailable", function: "receiveLensStatus")
        invoke("window.setComponentGlassEnabled(\(settings.nativeGlassEnabled && glassSurface?.usesNativeGlass == true))")
    }
    private func sendHotkeyStatus() { send(missionControlHotkey.status, function: "receiveHotkeyStatus") }
    private func openMissionControl() {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.exposelauncher")
            ?? URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            sendError("此 macOS 版本中找不到调度中心应用")
            return
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async { self?.sendError("无法打开调度中心：\(error.localizedDescription)") }
        }
    }
    private func rememberPanelSize() {
        guard (window as? FloatingMonitorPanel)?.isExpanded != true else { return }
        panelSize = window.frame.size
        UserDefaults.standard.set(["width": panelSize.width, "height": panelSize.height], forKey: "panelSize")
    }
    private func rememberPanelPosition() {
        guard (window as? FloatingMonitorPanel)?.isExpanded != true else { return }
        panelOrigin = window.frame.origin
        UserDefaults.standard.set(["x": window.frame.minX, "y": window.frame.minY], forKey: "panelOrigin")
    }
    func windowDidEndLiveResize(_ notification: Notification) { rememberPanelSize(); rememberPanelPosition() }
    private func dismissPanel() {
        if (window as? FloatingMonitorPanel)?.isExpanded == true { togglePanelFullscreen() }
        window.orderOut(nil); menuPreviewVisible = false
    }
    private func togglePanelFullscreen() {
        window.toggleFullScreen(nil)
    }

    private func startSampling() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: settings.interval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let sample = self.collector.collect()
            DispatchQueue.main.async { [weak self] in self?.receive(sample) }
        }
        timer = source; source.resume()
    }
    private func receive(_ sample: Snapshot) {
        snapshot = sample
        diskAnalysis.synchronize(sample.volumes)
        if usageSuspensions.isEmpty {
            usage.record(UsageReading(snapshot: sample, application: usageApps.current(), preferredPowerSource: usage.currentPowerSource,
                                      applicationPowers: usageApps.powers(in: sample)))
        }
        persistUsage()
        samples.append(HistorySample(timestamp: sample.timestamp, metrics: sample.metrics))
        // Bound history by elapsed time and maximum number of samples.
        samples.removeAll { $0.timestamp < sample.timestamp - settings.historySeconds }
        if samples.count > 600 { samples.removeFirst(samples.count - 600) }
        updateStatus(sample)
        if window.isVisible { sendSnapshot(sample) }
        if window.isVisible, usageVisible, sample.timestamp - lastUsageSend >= 5 { sendUsage() }
    }
    private func installUsageObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String, Bool)] = [
            (NSWorkspace.willSleepNotification, "system", true), (NSWorkspace.didWakeNotification, "system", false),
            (NSWorkspace.screensDidSleepNotification, "screen", true), (NSWorkspace.screensDidWakeNotification, "screen", false),
            (NSWorkspace.sessionDidResignActiveNotification, "session", true), (NSWorkspace.sessionDidBecomeActiveNotification, "session", false)
        ]
        for (name, reason, suspended) in events {
            usageObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if suspended { self.usageSuspensions.insert(reason) } else { self.usageSuspensions.remove(reason) }
                self.usage.interrupt(); self.persistUsage(force: true)
            })
        }
    }
    private func persistUsage(force: Bool = false) {
        guard usageSaveEnabled else { return }
        let now = Date().timeIntervalSince1970
        guard force || now - lastUsageSave >= 30 else { return }
        lastUsageSave = now
        let archive = usage.archive
        usageSaveQueue.async { [weak self] in
            do { try UsagePersistence.save(archive, to: UsagePersistence.defaultURL) }
            catch {
                DispatchQueue.main.async { self?.sendError("使用记录保存失败：\(error.localizedDescription)") }
            }
        }
    }
    private func sendUsage() {
        lastUsageSend = Date().timeIntervalSince1970
        send(usage.payload(selectedID: selectedUsageID), function: "receiveUsage")
    }
    private func invoke(_ script: String) {
        guard ready else { return }
        webView.evaluateJavaScript(script) { _, error in
            if let error { NSLog("MacState WebView: %@", error.localizedDescription) }
        }
    }
    private func send<T: Encodable>(_ value: T, function: String) {
        do {
            let data = try encoder.encode(value)
            invoke("window.\(function)(\(String(decoding: data, as: UTF8.self)))")
        } catch { sendError("数据编码失败：\(error.localizedDescription)") }
    }
    private func sendSnapshot(_ data: Snapshot) { send(data, function: "receiveSnapshot") }
    private func sendPendingNavigation() {
        if ready, !restoredNavigation {
            restoredNavigation = true
            send(UserDefaults.standard.string(forKey: "lastPage") ?? "overview", function: "restorePage")
        }
        guard ready, pendingOverview else { return }
        invoke("window.openOverview()"); pendingOverview = false
    }
    private func sendMenuPreview() {
        guard ready, window.isVisible, menuPreviewVisible, let menuBarView, let png = menuBarView.previewPNG() else { return }
        send("data:image/png;base64," + png.base64EncodedString(), function: "receiveMenuPreview")
    }
    private func sendError(_ message: String) { send(message, function: "showError") }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        diskAnalysis.resend()
        sendGlassStatus()
        sendHotkeyStatus()
        send(settings, function: "receiveSettings")
        send(NSFontManager.shared.availableFontFamilies.sorted(), function: "receiveFonts")
        send(samples, function: "receiveHistory")
        if let snapshot { sendSnapshot(snapshot) }
        sendPendingNavigation()
        if let usageStartupError { sendError(usageStartupError) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.isFileURL, url.standardizedFileURL.path.hasPrefix(webRoot.path + "/"), navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url, url.isFileURL, url.path.hasPrefix(webRoot.path + "/"),
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "ready":
            diskAnalysis.resend()
            ready = true; send(settings, function: "receiveSettings"); send(samples, function: "receiveHistory")
            send(fileInteractions.applications(),function:"receiveDiskOpenApplications")
            send(DiskDeveloperFolders.names,function:"receiveDeveloperFolders")
            screenshots.state()
            sendGlassStatus()
            sendHotkeyStatus()
            send(NSFontManager.shared.availableFontFamilies.sorted(), function: "receiveFonts")
            if let snapshot { sendSnapshot(snapshot) }
            sendPendingNavigation()
        case "navigation":
            if let page = body["page"] as? String,
               ["overview", "processes", "sensors", "network", "storage", "usage", "misc", "screenshot", "settings"].contains(page) {
                UserDefaults.standard.set(page, forKey: "lastPage")
            }
        case "getDisplayBrightness": displayBrightness.refresh()
        case "retryDisplayBrightness": displayBrightness.retryHardware()
        case "setDisplayBrightness":
            if let id = body["id"] as? String, !id.isEmpty, id.count <= 160,
               let percent = body["percent"] as? Double {
                displayBrightness.set(id:id,percent:percent)
            }
        case "getScreenshotState": screenshots.state()
        case "captureScreenshot": screenshots.capture(mode:body["mode"] as? String ?? "region",display:body["display"] as? Int ?? 1)
        case "cancelScreenshot": screenshots.cancel()
        case "saveScreenshotSettings":
            if let value=body["settings"],let data=try? JSONSerialization.data(withJSONObject:value),let config=try? JSONDecoder().decode(ScreenshotSettings.self,from:data){screenshots.saveSettings(config)}
        case "screenshotDirectory": screenshots.chooseDirectory(window:window)
        case "resetScreenshotShortcuts": screenshots.resetShortcuts()
        case "suspendScreenshotShortcuts": screenshots.suspendShortcuts(body["suspended"] as? Bool ?? false)
        case "editScreenshotRecord": if let id=body["id"] as? String{screenshots.openEditor(id)}
        case "copyScreenshotRecord":
            if let id = body["id"] as? String { screenshots.copyRecord(id) }
        case "revealScreenshot": if let id=body["id"] as? String{screenshots.reveal(id)}
        case "trashScreenshot": if let id=body["id"] as? String{screenshots.trash(id,window:window)}
        case "openScreenshotPermission":
            if let url=URL(string:"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"){NSWorkspace.shared.open(url)}
        case "checkDiskAccess":
            diskAnalysis.checkAccess { _ in }
        case "openDiskAccessSettings":
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"),
               !NSWorkspace.shared.open(url) {
                sendError("无法打开权限设置，请自行前往系统设置 → 隐私与安全 → 完全磁盘访问权限。")
            }
        case "menuPreview":
            let visible = (body["visible"] as? Bool ?? false) && window.isVisible
            let changed = visible != menuPreviewVisible
            menuPreviewVisible = visible
            if changed { sendMenuPreview() }
        case "saveSettings":
            do {
                guard let value = body["settings"] else { return }
                let updated = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: value)).validated()
                if updated.launchAtLogin != settings.launchAtLogin {
                    do {
                        if updated.launchAtLogin { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch { sendError("开机启动设置失败：\(error.localizedDescription)"); send(settings, function: "receiveSettings"); return }
                }
                let hotkeyChanged = updated.commandTabOpensMissionControl != settings.commandTabOpensMissionControl
                let intervalChanged = updated.interval != settings.interval
                let menuChanged = updated.resolvedMenuColumns.map(\.id) != settings.resolvedMenuColumns.map(\.id)
                settings = updated
                glassSurface?.configure(theme: settings.theme, opacity: settings.glassOpacity, nativeLensEnabled: settings.nativeGlassEnabled)
                componentGlass?.configure(opacity: settings.glassOpacity, nativeLensEnabled: settings.nativeGlassEnabled)
                UserDefaults.standard.set(try encoder.encode(settings), forKey: "settings")
                if hotkeyChanged || settings.commandTabOpensMissionControl {
                    missionControlHotkey.setEnabled(settings.commandTabOpensMissionControl, requestAccess: false)
                }
                if menuChanged { createStatusItems() }
                else { updateStatus(snapshot) }
                if intervalChanged { startSampling() }
                sendGlassStatus()
                sendHotkeyStatus()
                send(settings, function: "receiveSettings")
            } catch { sendError("设置保存失败：\(error.localizedDescription)") }
        case "refresh":
            missionControlHotkey.refreshAccess()
            sendHotkeyStatus()
            if let snapshot { sendSnapshot(snapshot); send(samples, function: "receiveHistory") }
        case "retryMissionControlHotkey":
            missionControlHotkey.refreshAccess()
            sendHotkeyStatus()
        case "openMissionControlAccessSettings":
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"),
               !NSWorkspace.shared.open(url) {
                sendError("无法打开权限设置，请自行前往系统设置 → 隐私与安全 → 设备控制和数据访问（旧版为辅助功能）。")
            }
        case "syncDiskIndexCache":
            if let path = body["volumePath"] as? String { diskAnalysis.synchronizeCache(volumePath: path) }
        case "setDiskSynchronizationPaused":
            if let path = body["volumePath"] as? String, let paused = body["paused"] as? Bool {
                diskAnalysis.setSynchronizationPaused(volumePath: path, paused: paused)
            }
        case "rebuildDiskIndex":
            if let path = body["volumePath"] as? String { diskAnalysis.rebuild(volumePath: path) }
        case "startDiskAnalysis":
            guard let path = body["volumePath"] as? String, let requestID = body["requestID"] as? String,
                  !requestID.isEmpty, requestID.count <= 128 else { return }
            guard let volume = Hardware.volumes().first(where: { $0.path == path }) else {
                send(["requestID": requestID, "message": "存储卷已断开，请刷新后重新分析。"], function: "diskAnalysisFailed")
                return
            }
            diskAnalysis.start(volume: volume, requestID: requestID)
        case "cancelDiskAnalysis":
            if let requestID = body["requestID"] as? String { diskAnalysis.cancel(requestID: requestID) }
        case "searchDiskIndex":
            if let requestID = body["requestID"] as? String {
                diskAnalysis.search(requestID: requestID, text: body["text"] as? String ?? "", kind: body["kind"] as? String ?? "", offset: body["offset"] as? Int ?? 0, sort: DiskFileSort(key: body["sortKey"] as? String ?? "", descending: body["sortDescending"] as? Bool ?? false))
            }
        case "diskDirectory":
            if let path = body["path"] as? String, let requestID = body["requestID"] as? String {
                diskAnalysis.browse(path: path, requestID: requestID, offset: body["offset"] as? Int ?? 0, sort: DiskFileSort(key: body["sortKey"] as? String ?? "", descending: body["sortDescending"] as? Bool ?? false))
            }
        case "addDeveloperFolder":
            do {
                let name = try DiskDeveloperFolders.add(body["name"] as? String ?? "")
                send(DiskDeveloperFolders.names,function:"receiveDeveloperFolders")
                send(["name":name,"error":""],function:"receiveDeveloperFolderAdded")
            } catch { send(["name":"","error":error.localizedDescription],function:"receiveDeveloperFolderAdded") }
        case "diskAppIcons":
            if let requestID=body["requestID"] as? String,let queryID=body["queryID"] as? String,let paths=body["paths"] as? [String] {
                diskAnalysis.appIcons(requestID:requestID,queryID:queryID,paths:Array(paths.prefix(100))) { [weak self] result in self?.send(result,function:"receiveDiskAppIcons") }
            }
        case "diskWorkbench":
            if let requestID=body["requestID"] as? String,let queryID=body["queryID"] as? String,
               let mode=body["mode"] as? String,["developer","duplicates","media","browser","chat","system","snapshots","backups","cloud","history","growth","permissions"].contains(mode){
                let growthHours = body["growthHours"] as? Int ?? 24
                var filter = DiskWorkbenchFilter(
                    category: String((body["category"] as? String ?? "").prefix(128)),
                    text: String((body["text"] as? String ?? "").prefix(512)),
                    offset: max(0, min(100_000_000, body["offset"] as? Int ?? 0)),
                    growthHours: [0, 1, 6, 24, 168, 720].contains(growthHours) ? growthHours : 24,
                    growthDecreasing: body["growthDecreasing"] as? Bool ?? false,
                    captureGrowthSample: body["captureGrowthSample"] as? Bool ?? false,
                    enrich: body["enrich"] as? Bool ?? false,
                    since: max(0, body["since"] as? Double ?? 0),
                    until: max(0, body["until"] as? Double ?? 0)
                )
                if mode == "developer" { filter.developerNames = DiskDeveloperFolders.names }
                diskAnalysis.workbench(requestID:requestID,queryID:queryID,mode:mode,filter:filter)
            }
        case "cancelDiskWorkbench": diskAnalysis.cancelWorkbench()
        case "copyWorkbenchEntry":
            if let requestID=body["requestID"] as? String,let path=body["path"] as? String{
                diskAnalysis.workbenchURL(requestID:requestID,path:path){[weak self] url in
                    NSPasteboard.general.clearContents();let success=NSPasteboard.general.setString(url.path,forType:.string)
                    self?.send(DiskFileActionResult(requestID:requestID,operationID:body["operationID"] as? String ?? "",path:path,success:success,message:success ? "已复制路径。" : "无法复制路径。"),function:"receiveDiskFileAction")
                }
            }
        case "revealWorkbenchEntry":
            if let requestID=body["requestID"] as? String,let path=body["path"] as? String{diskAnalysis.workbenchURL(requestID:requestID,path:path){url in NSWorkspace.shared.activateFileViewerSelecting([url])}}
        case "cancelStorageExport": diskAnalysis.cancelStorageExport()
        case "exportStorage":
            if let requestID=body["requestID"] as? String{
                let format=body["format"] as? String=="csv" ? "csv" : "json",source=body["source"] as? String ?? "analysis"
                let panel=NSSavePanel();panel.nameFieldStringValue="MacState-Storage-\(source)-\(Int(Date().timeIntervalSince1970)).\(format)"
                panel.beginSheetModal(for:window){[weak self] response in
                    guard let self else{return}
                    guard response == .OK,let url=panel.url else{self.send(DiskFileActionResult(requestID:requestID,operationID:"storage-export",path:"",success:false,message:"已取消导出。"),function:"receiveStorageExport");return}
                    let category=body["category"] as? String ?? ""
                    let filter=DiskLargeFilter(category:DiskStorageCategory.keys.contains(category) ? category : "",minimum:max(0,body["minimum"] as? Int64 ?? 0),maximum:max(0,body["maximum"] as? Int64 ?? 0),modifiedAfter:max(0,body["modifiedAfter"] as? Double ?? 0),modifiedBefore:max(0,body["modifiedBefore"] as? Double ?? 0),physical:body["physical"] as? Bool ?? false,descending:body["descending"] as? Bool ?? true,offset:0)
                    self.diskAnalysis.exportStorageData(requestID:requestID,source:source,format:format,url:url,filter:filter,analysisMode:body["analysisMode"] as? String ?? "types",analysisPath:body["analysisPath"] as? String ?? "",mapMode:body["mapMode"] as? String ?? "folders",analysisOffset:max(0,body["analysisOffset"] as? Int ?? 0)){[weak self] result in
                        let success:Bool,message:String
                        switch result{case .success:success=true;message="已导出至 \(url.path)";case .failure(let error):success=false;message="导出失败："+error.localizedDescription}
                        self?.send(DiskFileActionResult(requestID:requestID,operationID:"storage-export",path:url.path,success:success,message:message),function:"receiveStorageExport")
                    }
                }
            }
        case "diskInsights":
            if let requestID = body["requestID"] as? String, let queryID = body["queryID"] as? String,
               requestID.count <= 128, queryID.count <= 128 { diskAnalysis.storageInsights(requestID: requestID, queryID: queryID) }
        case "trashDiskCleanup":
            if let requestID = body["requestID"] as? String, let queryID = body["queryID"] as? String,
               let operationID = body["operationID"] as? String, let paths = body["paths"] as? [String], !cleanupConfirmationActive {
                cleanupConfirmationActive = true
                func runningIDs() -> Set<String> { Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }) }
                diskAnalysis.cleanupCandidates(requestID: requestID, queryID: queryID, paths: paths, running: runningIDs()) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.cleanupConfirmationActive = false
                        self.send(DiskFileActionResult(requestID: requestID, operationID: operationID, path: "", success: false, message: error.localizedDescription), function: "receiveDiskFileAction")
                    case .success(let items):
                        let alert = NSAlert(); alert.alertStyle = .warning
                        alert.messageText = "将 \(items.count) 个项目移到废纸篓？"
                        let bytes = items.reduce(UInt64(0)) { $0 + $1.entry.bytes }
                        alert.informativeText = "索引占用约 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))。不会立即释放磁盘空间。缓存可能重新下载；疑似残留可能包含个人数据。目录内文件将整体移入废纸篓，可在 Finder 恢复。"
                        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 180)); scroll.hasVerticalScroller = true
                        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 180)); text.isEditable = false; text.isSelectable = true
                        text.string = items.map { "[\($0.risk == "high" ? "高风险" : $0.risk == "review" ? "需确认" : "缓存")] \($0.entry.path)" }.joined(separator: "\n\n")
                        text.font = .systemFont(ofSize: 11); text.isVerticallyResizable = true; text.textContainer?.containerSize = NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude); text.sizeToFit(); scroll.documentView = text; alert.accessoryView = scroll
                        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移到废纸篓")
                        alert.beginSheetModal(for: self.window) { [weak self] response in
                            guard let self else { return }; self.cleanupConfirmationActive = false
                            if response == .alertSecondButtonReturn { self.diskAnalysis.cleanup(items, requestID: requestID, queryID: queryID, operationID: operationID, running: runningIDs()) }
                            else { self.send(DiskFileActionResult(requestID: requestID, operationID: operationID, path: "", success: false, message: "已取消。"), function: "receiveDiskFileAction") }
                        }
                    }
                }
            }
        case "diskFileTypes", "diskLargeFiles":
            if let requestID = body["requestID"] as? String, let queryID = body["queryID"] as? String,
               requestID.count <= 128, queryID.count <= 128 {
                var filter: DiskLargeFilter?
                if action == "diskLargeFiles" {
                    let category = body["category"] as? String ?? ""
                    filter = DiskLargeFilter(category: DiskStorageCategory.keys.contains(category) ? category : "",
                        minimum: max(0, body["minimum"] as? Int64 ?? 0), maximum: max(0, body["maximum"] as? Int64 ?? 0),
                        modifiedAfter: max(0, body["modifiedAfter"] as? Double ?? 0), modifiedBefore: max(0, body["modifiedBefore"] as? Double ?? 0),
                        physical: body["physical"] as? Bool ?? false, descending: body["descending"] as? Bool ?? true,
                        offset: max(0, body["offset"] as? Int ?? 0))
                }
                diskAnalysis.storageFiles(requestID: requestID, queryID: queryID, filter: filter)
            }
        case "pauseStorageAnalysis": diskAnalysis.pauseVisibleAnalysis()
        case "cancelDiskStorageQuery": diskAnalysis.cancelStorageQuery()
        case "getDiskOpenApplications": send(fileInteractions.applications(), function:"receiveDiskOpenApplications")
        case "addDiskOpenApplication": fileInteractions.addApplication(window:window) { [weak self] in guard let self else { return }; self.send(self.fileInteractions.applications(),function:"receiveDiskOpenApplications") }
        case "removeDiskOpenApplication":
            if let path = body["path"] as? String { fileInteractions.removeApplication(path); send(fileInteractions.applications(),function:"receiveDiskOpenApplications") }
        case "diskFileInteraction":
            if let requestID = body["requestID"] as? String, let paths = body["paths"] as? [String], let kind = body["kind"] as? String {
                if kind == "menu" {
                    let x = body["x"] as? Double ?? 0, y = body["y"] as? Double ?? 0
                    guard x.isFinite, y.isFinite, paths.count <= 1000, !paths.isEmpty else { return }
                    fileInteractions.onAction = { [weak self] action, app in self?.handleFileInteraction(requestID:requestID,paths:paths,kind:action,application:app) }
                    let point = NSPoint(x:max(0,min(webView.bounds.width,x)),y:webView.isFlipped ? y : webView.bounds.height-y)
                    fileInteractions.menu(at:point,in:webView)
                } else { handleFileInteraction(requestID:requestID,paths:paths,kind:kind,application:nil) }
            }
        case "copyDiskEntry":
            if let path = body["path"] as? String, let requestID = body["requestID"] as? String {
                diskAnalysis.indexedURL(path: path, requestID: requestID) { [weak self] result in
                    let success: Bool, message: String
                    switch result {
                    case .success(let url):
                        NSPasteboard.general.clearContents(); success = NSPasteboard.general.setString(url.path, forType: .string)
                        message = success ? "已复制文件路径。" : "无法写入剪贴板，请重试。"
                    case .failure(let error): success = false; message = error.localizedDescription
                    }
                    self?.send(DiskFileActionResult(requestID: requestID, operationID: body["operationID"] as? String ?? "", path: path, success: success, message: message), function: "receiveDiskFileAction")
                }
            }
        case "trashDiskEntry", "trashDiskDuplicate":
            if let path = body["path"] as? String, let requestID = body["requestID"] as? String,
               let operationID = body["operationID"] as? String {
                diskAnalysis.fileTrashCandidate(path: path, requestID: requestID, duplicate: action == "trashDiskDuplicate") { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure(let error): self.send(DiskFileActionResult(requestID: requestID, operationID: operationID, path: path, success: false, message: error.localizedDescription), function: "receiveDiskFileAction")
                    case .success(let entry):
                        let alert = NSAlert()
                        alert.messageText = "将“\(entry.name)”移到废纸篓？"
                        alert.informativeText = "\(entry.path)\n\n文件大小：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.logicalBytes), countStyle: .file))\n不会永久删除，可从 Finder 的废纸篓恢复。"
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移到废纸篓")
                        alert.beginSheetModal(for: self.window) { [weak self] response in
                            guard let self else { return }
                            if response == .alertSecondButtonReturn { self.diskAnalysis.performFileTrash(entry, requestID: requestID, operationID: operationID, duplicate: action == "trashDiskDuplicate") }
                            else { self.send(DiskFileActionResult(requestID: requestID, operationID: operationID, path: path, success: false, message: "已取消。"), function: "receiveDiskFileAction") }
                        }
                    }
                }
            }
        case "diskSpaceMap":
            if let requestID = body["requestID"] as? String, let mapID = body["mapID"] as? String,
               requestID.count <= 128, mapID.count <= 128 {
                diskAnalysis.spaceMap(requestID: requestID, mapID: mapID, path: body["path"] as? String ?? "", mode: body["mode"] as? String ?? "folders")
            }
        case "cancelDiskSpaceMap": diskAnalysis.cancelSpaceMap()
        case "revealDiskEntry":
            if let path = body["path"] as? String, let requestID = body["requestID"] as? String {
                diskAnalysis.reveal(path: path, requestID: requestID) { url in
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        case "usageHistory":
            usageVisible = body["visible"] as? Bool ?? true
            selectedUsageID = body["sessionID"] as? String
            if usageVisible { sendUsage() }
        case "newUsage":
            usage.closeCurrent(); selectedUsageID = nil
            if let snapshot { usage.record(UsageReading(snapshot: snapshot, application: usageApps.current(), applicationPowers: usageApps.powers(in: snapshot))) }
            persistUsage(force: true); sendUsage()
        case "deleteUsage":
            if let id = body["sessionID"] as? String, usage.deleteSession(id: id) {
                selectedUsageID = nil
                if let snapshot { usage.record(UsageReading(snapshot: snapshot, application: usageApps.current(), applicationPowers: usageApps.powers(in: snapshot))) }
                persistUsage(force: true); sendUsage()
            }
        case "exportUsage": exportUsage()
        case "glassAppearance":
            var appearance = settings
            if let opacity = body["opacity"] as? Double { appearance.glassOpacity = opacity }
            if let theme = body["theme"] as? String { appearance.theme = theme }
            appearance = appearance.validated()
            glassSurface?.configure(theme: appearance.theme, opacity: appearance.glassOpacity, nativeLensEnabled: settings.nativeGlassEnabled)
            componentGlass?.configure(opacity: appearance.glassOpacity, nativeLensEnabled: settings.nativeGlassEnabled)
        case "glassLayout":
            guard let value = body["layout"], let data = try? JSONSerialization.data(withJSONObject: value), let layout = try? JSONDecoder().decode(GlassLayout.self, from: data) else { return }
            componentGlass?.update(layout.components)
            if let region = layout.dragRegion?.rectangles(in: webView.bounds)?.clip {
                panelDragHandle?.frame = NSRect(x: region.minX, y: webView.bounds.height - region.maxY, width: region.width, height: region.height)
                panelDragHandle?.isHidden = false
            } else { panelDragHandle?.isHidden = true }
            if let region = layout.sidebarDragRegion?.rectangles(in: webView.bounds)?.clip {
                sidebarDragHandle?.frame = NSRect(x: region.minX, y: webView.bounds.height - region.maxY, width: region.width, height: region.height)
                sidebarDragHandle?.isHidden = false
            } else { sidebarDragHandle?.isHidden = true }
        case "resetHistory": samples.removeAll(); invoke("window.receiveHistory([])")
        case "export": exportSnapshot()
        case "quit": NSApp.terminate(nil)
        case "closePanel": dismissPanel()
        case "toggleFullscreen": togglePanelFullscreen()
        case "openMissionControl": openMissionControl()
        default: break
        }
    }
    private func exportSnapshot() {
        guard let snapshot else { sendError("等待第一次采样后再导出"); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MacState-\(Int(snapshot.timestamp)).json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try self.encoder.encode(snapshot).write(to: url, options: .atomic) }
            catch { self.sendError("导出失败：\(error.localizedDescription)") }
        }
    }
    private func exportUsage() {
        let payload = usage.payload(selectedID: selectedUsageID)
        guard let session = payload.selected else { sendError("等待采样后再导出使用记录"); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MacState-Usage-\(Int(session.startedAt)).json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try self.encoder.encode(payload).write(to: url, options: .atomic) }
            catch { self.sendError("记录导出失败：\(error.localizedDescription)") }
        }
    }
}
