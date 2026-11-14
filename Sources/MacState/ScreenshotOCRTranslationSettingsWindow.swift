import AppKit

private final class ScreenshotOCRSettingsForm: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ScreenshotOCRTranslationSettingsWindow: NSWindowController, NSWindowDelegate {
    let service = NSPopUpButton()
    let nameField = NSTextField(), addressField = NSTextField(), modelField = NSTextField()
    let keyField = NSSecureTextField()
    let api = NSPopUpButton()
    let localModel = NSPopUpButton()
    let pythonField = NSTextField()
    let feedback = NSTextField(wrappingLabelWithString: "")
    private let testButton = NSButton(title: "测试连接", target: nil, action: nil)
    private let removeButton = NSButton()
    private let environmentButton = NSButton()
    private let releaseButton = NSButton()
    private let runtimeHint = NSTextField(wrappingLabelWithString: "")
    private var runtimeTask: Task<Void, Never>?
    private var memoryObserver: NSObjectProtocol?
    private let preferences: ScreenshotOCRTranslationPreferences
    private var settings: ScreenshotOCRTranslationSettings
    private var editingID: UUID?
    private var keys: [UUID: String] = [:]
    private var keyLoaded = true
    private var testTask: Task<Void, Never>?
    private var testToken = UUID()
    private var localMode = false
    private var models: [ScreenshotOCRLocalModel] = []
    private var apiViews: [NSView] = [], localViews: [NSView] = []
    private let note = NSTextField(wrappingLabelWithString: "")
    private let modelPath = NSTextField(labelWithString: "")
    private var scanTask: Task<[ScreenshotOCRLocalModel], Never>?
    private var scanToken = UUID()
    var onSave: (() -> Void)?

    init(preferences: ScreenshotOCRTranslationPreferences) {
        self.preferences = preferences; settings = preferences.settings
        localMode = settings.localModelPath != nil && settings.selectedID == nil
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 464),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OCR 翻译设置"; window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        let form = ScreenshotOCRSettingsForm(frame: NSRect(x: 0, y: 0, width: 560, height: 464))
        let glass = GlassSurfaceView(frame: form.bounds, contentView: form, opacity: 1)
        glass.configure(theme: "dark", opacity: 1)
        window.contentView = glass
        @discardableResult func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat,
                   size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: size, weight: weight)
            label.textColor = .labelColor
            label.frame = NSRect(x: x, y: y, width: width, height: 24)
            form.addSubview(label)
            return label
        }
        label("OCR 翻译设置", 24, 16, 420, size: 18, weight: .semibold)
        label("系统翻译、本地大语言模型或 API 服务。", 24, 44, 510, size: 11)
        label("翻译服务", 24, 82, 84)
        service.frame = NSRect(x: 114, y: 76, width: 338, height: 28)
        service.target = self; service.action = #selector(serviceChanged)
        service.identifier = .init("ocrTranslationService")
        form.addSubview(service)
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "添加翻译服务")!,
                           target: self, action: #selector(addService(_:)))
        add.frame = NSRect(x: 460, y: 76, width: 32, height: 28); form.addSubview(add)
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "删除此服务")
        removeButton.target = self; removeButton.action = #selector(removeService)
        removeButton.frame = NSRect(x: 500, y: 76, width: 32, height: 28); form.addSubview(removeButton)
        for (title, field, top, identifier) in [
            ("服务名称", nameField, 122.0, "ocrServiceName"),
            ("接口地址", addressField, 194.0, "ocrServiceURL"),
            ("模型 ID", modelField, 230.0, "ocrServiceModel"),
            ("API Key", keyField, 266.0, "ocrServiceKey")
        ] {
            apiViews.append(label(title, 24, top + 6, 84))
            field.frame = NSRect(x: 114, y: top, width: 418, height: 28)
            field.font = .systemFont(ofSize: 12)
            field.identifier = .init(identifier)
            form.addSubview(field)
            apiViews.append(field)
        }
        apiViews.append(label("接口协议", 24, 164, 84))
        api.addItems(withTitles: ScreenshotOCRAPIProtocol.allCases.map(\.title))
        api.frame = NSRect(x: 114, y: 158, width: 418, height: 28); form.addSubview(api)
        apiViews.append(api)
        addressField.placeholderString = "基础地址或完整 API 地址"
        modelField.placeholderString = "填写平台提供的模型 ID 或部署名称"
        keyField.placeholderString = "本机服务或无鉴权接口可留空"
        localViews.append(label("本地模型", 24, 128, 84))
        localModel.frame = NSRect(x: 114, y: 122, width: 328, height: 28)
        localModel.target = self; localModel.action = #selector(localModelChanged)
        localModel.identifier = .init("ocrLocalModel")
        localModel.setAccessibilityLabel("本地翻译模型")
        form.addSubview(localModel); localViews.append(localModel)
        modelPath.frame = NSRect(x: 114, y: 156, width: 418, height: 28)
        modelPath.font = .systemFont(ofSize: 10); modelPath.textColor = .secondaryLabelColor
        modelPath.lineBreakMode = .byTruncatingMiddle
        form.addSubview(modelPath); localViews.append(modelPath)
        for (title, action, x, y, width) in [
            ("刷新", #selector(refreshModels), 450.0, 122.0, 82.0),
            ("添加模型目录…", #selector(chooseModelDirectory), 114.0, 190.0, 146.0),
            ("打开模型目录", #selector(openModelDirectory), 270.0, 190.0, 140.0)
        ] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded; button.frame = NSRect(x: x, y: y, width: width, height: 28)
            form.addSubview(button); localViews.append(button)
        }
        localViews.append(label("运行环境", 24, 236, 84))
        environmentButton.title = "准备环境"; environmentButton.bezelStyle = .rounded
        environmentButton.target = self; environmentButton.action = #selector(prepareEnvironment)
        environmentButton.toolTip = "准备或修复 MacState 独立环境，会先释放已加载的本地模型。"
        environmentButton.frame = NSRect(x: 450, y: 230, width: 82, height: 28)
        form.addSubview(environmentButton); localViews.append(environmentButton)
        pythonField.frame = NSRect(x: 114, y: 230, width: 328, height: 28)
        pythonField.font = .systemFont(ofSize: 11); pythonField.identifier = .init("ocrLocalPython")
        pythonField.setAccessibilityLabel("本地推理 Python 路径")
        pythonField.placeholderString = "选择已安装推理引擎的 Python"
        form.addSubview(pythonField); localViews.append(pythonField)
        runtimeHint.font = .systemFont(ofSize: 11); runtimeHint.textColor = .secondaryLabelColor
        runtimeHint.frame = NSRect(x: 114, y: 266, width: 418, height: 38)
        form.addSubview(runtimeHint); localViews.append(runtimeHint)
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 24, y: 310, width: 508, height: 44); form.addSubview(note)
        feedback.font = .systemFont(ofSize: 11); feedback.textColor = .secondaryLabelColor
        feedback.frame = NSRect(x: 24, y: 358, width: 508, height: 40); form.addSubview(feedback)
        for (button, title, action, x, width) in [
            (testButton, "测试连接", #selector(testConnection), 24.0, 110.0),
            (releaseButton, "释放内存", #selector(releaseMemory), 144.0, 110.0),
            (NSButton(), "取消", #selector(cancel), 344.0, 88.0),
            (NSButton(), "保存", #selector(save), 444.0, 88.0)
        ] {
            button.title = title; button.target = self; button.action = action
            button.bezelStyle = .rounded
            button.frame = NSRect(x: x, y: 410, width: width, height: 30)
            if title == "保存" { button.keyEquivalent = "\r" }
            if title == "取消" { button.keyEquivalent = "\u{1b}" }
            form.addSubview(button)
        }
        testButton.toolTip = "向当前配置发送一条测试文本，不发送截图或 OCR 内容。"
        releaseButton.toolTip = "立即停止本地翻译并释放模型内存，不删除磁盘上的模型文件。"
        releaseButton.identifier = .init("ocrReleaseLocalModel")
        memoryObserver = NotificationCenter.default.addObserver(forName: ScreenshotOCRLocalSession.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateRuntimeControls() }
        }
        rebuildServices(); loadFields()
        if localMode { refreshModels() }
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) } }
    func windowWillClose(_ notification: Notification) {
        testTask?.cancel(); testToken = UUID(); scanTask?.cancel(); scanToken = UUID()
        runtimeTask?.cancel()
    }

    private func rebuildServices() {
        service.removeAllItems()
        service.addItem(withTitle: "本机离线翻译")
        service.addItem(withTitle: "本地大语言模型")
        service.addItems(withTitles: settings.profiles.map(\.name))
        let selected = localMode ? 1 : settings.profiles.firstIndex { $0.id == settings.selectedID }.map { $0 + 2 } ?? 0
        service.selectItem(at: selected)
    }
    private func stashFields() {
        if localMode {
            if !usesManagedMLX { settings.localPython = pythonField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
            return
        }
        guard let index = settings.profiles.firstIndex(where: { $0.id == editingID }) else { return }
        settings.profiles[index].name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.profiles[index].baseURL = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.profiles[index].model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.profiles[index].api = ScreenshotOCRAPIProtocol.allCases[max(0, api.indexOfSelectedItem)]
        if keyLoaded || !keyField.stringValue.isEmpty { keys[settings.profiles[index].id] = keyField.stringValue }
    }
    private func loadFields() {
        testTask?.cancel(); testToken = UUID()
        for view in apiViews { view.isHidden = localMode }
        for view in localViews { view.isHidden = !localMode }
        releaseButton.isHidden = !localMode
        note.stringValue = localMode ?
            "自动查找 Hugging Face、LM Studio、Ollama 及 Models 等常用目录中的完整 MLX / GGUF 模型。可把模型放进软件模型目录后刷新，或添加已有目录。翻译全程在本机进行。" :
            "选择 API 服务后，仅在点击翻译时发送识别文字，不发送截图。密钥独立保存在系统钥匙串。源语言和目标语言可在翻译按钮前选择。"
        pythonField.stringValue = settings.localPython ?? ScreenshotOCRLocalModels.defaultPython()
        let profile = settings.selected
        editingID = profile?.id
        nameField.stringValue = profile?.name ?? ""
        addressField.stringValue = profile?.baseURL ?? ""
        modelField.stringValue = profile?.model ?? ""
        api.selectItem(at: ScreenshotOCRAPIProtocol.allCases.firstIndex(of: profile?.api ?? .openAI) ?? 0)
        keyField.stringValue = ""
        keyLoaded = true
        feedback.stringValue = profile == nil ? "本机翻译使用已安装的系统语言包，不联网。点击 ＋ 添加 API 服务。" :
            "填写模型 ID 和密钥后，可先发送一条测试文本验证连接。"
        if let profile {
            do { keyField.stringValue = try keys[profile.id] ?? preferences.credentials.read(profile.id) ?? "" }
            catch { keyLoaded = false; feedback.stringValue = error.localizedDescription }
        }
        for field in [nameField, addressField, modelField, keyField] { field.isEnabled = profile != nil }
        api.isEnabled = profile != nil; removeButton.isEnabled = profile != nil
        testButton.isEnabled = profile != nil
        testButton.title = localMode ? "测试翻译" : "测试连接"
        testButton.toolTip = localMode ? "使用当前本地模型翻译一条固定测试文本，不发送截图。" : "向当前配置发送一条测试文本，不发送截图或 OCR 内容。"
        if localMode { rebuildModels() }
    }
    @objc func serviceChanged() {
        stashFields()
        localMode = service.indexOfSelectedItem == 1
        settings.selectedID = service.indexOfSelectedItem > 1 ? settings.profiles[service.indexOfSelectedItem - 2].id : nil
        if !localMode { settings.localModelPath = nil }
        rebuildServices(); loadFields()
        if localMode { refreshModels() }
    }
    @objc private func addService(_ sender: NSButton) {
        let menu = NSMenu()
        for (index, profile) in ScreenshotOCRLLMProfile.presets.enumerated() {
            let item = menu.addItem(withTitle: profile.name, action: #selector(addPreset(_:)), keyEquivalent: "")
            item.tag = index; item.target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }
    @objc private func addPreset(_ sender: NSMenuItem) { addProfile(ScreenshotOCRLLMProfile.presets[sender.tag]) }
    func addProfile(_ preset: ScreenshotOCRLLMProfile) {
        stashFields()
        var profile = preset; profile.id = UUID()
        localMode = false; settings.localModelPath = nil
        settings.profiles.append(profile); settings.selectedID = profile.id
        rebuildServices(); loadFields()
    }
    @objc private func removeService() {
        if let id = settings.selectedID {
            keys.removeValue(forKey: id); settings.profiles.removeAll { $0.id == id }
        }
        settings.selectedID = nil; rebuildServices(); loadFields()
    }
    @objc func save() {
        stashFields()
        if localMode && settings.localModelPath == nil {
            feedback.stringValue = "请先选择文件完整的本地模型。"; return
        }
        do {
            try preferences.save(settings, keys: keys)
            testTask?.cancel(); testToken = UUID()
            onSave?(); close()
        } catch { feedback.stringValue = error.localizedDescription }
    }
    @objc private func cancel() { testTask?.cancel(); testToken = UUID(); close() }
    @objc private func testConnection() {
        stashFields()
        let profile = settings.selected
        guard profile != nil || (localMode && settings.localModelPath != nil) else { return }
        let key = profile.flatMap { keys[$0.id] } ?? ""
        let localSettings = settings
        testTask?.cancel(); testToken = UUID(); let token = testToken
        feedback.stringValue = "正在发送测试文本…"; testButton.isEnabled = false
        testTask = Task { @MainActor [weak self] in
            do {
                let segment = ScreenshotOCRTranslationSegment(text: "Hello", rect: .zero, lineHeight: 12)
                let result: [ScreenshotOCRTranslationOverlay]
                if let profile {
                    result = try await ScreenshotOCRLLMService().translate([segment], target: "zh-Hans", profile: profile, apiKey: key)
                } else {
                    result = try await ScreenshotOCRLocalTranslationService().translate([segment], target: "zh-Hans", settings: localSettings)
                }
                guard let self, self.testToken == token else { return }
                self.feedback.stringValue = "连接成功：\(result.first?.text.prefix(100) ?? "")"
                self.testButton.isEnabled = true
            } catch {
                guard let self, self.testToken == token else { return }
                self.feedback.stringValue = "连接失败：\(error.localizedDescription)"
                self.testButton.isEnabled = true
            }
        }
    }

    private func rebuildModels() {
        localModel.removeAllItems()
        localModel.addItems(withTitles: models.map {
            "\($0.name) · \($0.format.rawValue) · \(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))"
        })
        if let index = models.firstIndex(where: { $0.path == settings.localModelPath }) {
            settings.localModelName = models[index].name
            localModel.selectItem(at: index)
        } else if let path = settings.localModelPath {
            localModel.addItem(withTitle: "已选模型不可用：\(URL(fileURLWithPath: path).lastPathComponent)")
            localModel.selectItem(at: models.count)
        } else if let first = models.first {
            settings.localModelPath = first.path; settings.localModelName = first.name; localModel.selectItem(at: 0)
        } else { localModel.addItem(withTitle: "未找到完整的 MLX / GGUF 模型") }
        localModel.isEnabled = !models.isEmpty
        modelPath.stringValue = settings.localModelPath ?? "添加已有模型目录，或打开模型目录放入模型后刷新。"
        modelPath.toolTip = modelPath.stringValue
        feedback.stringValue = "找到 \(models.count) 个完整模型；选定后可测试翻译。"
        testButton.isEnabled = settings.localModelPath.flatMap { path in models.first { $0.path == path } } != nil
        updateRuntimeControls()
    }
    @objc private func localModelChanged() {
        guard models.indices.contains(localModel.indexOfSelectedItem) else { return }
        testTask?.cancel(); testToken = UUID()
        settings.localModelPath = models[localModel.indexOfSelectedItem].path
        settings.localModelName = models[localModel.indexOfSelectedItem].name
        rebuildModels()
    }
    @objc func refreshModels() {
        scanTask?.cancel(); scanToken = UUID(); let token = scanToken
        let roots = (settings.modelDirectories ?? []).map { URL(fileURLWithPath: $0) } + ScreenshotOCRLocalModels.roots()
        let scan = Task.detached(priority: .utility) { ScreenshotOCRLocalModels.discover(in: roots) }
        scanTask = scan; feedback.stringValue = "正在查找常用目录中的本地模型…"
        Task { @MainActor [weak self] in
            let models = await scan.value
            guard let self, self.scanToken == token else { return }
            self.models = models
            if self.localMode { self.rebuildModels() }
        }
    }
    func addModelDirectory(_ url: URL) {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var directories = settings.modelDirectories ?? []
        if !directories.contains(path) { directories.append(path) }
        settings.modelDirectories = directories
        refreshModels()
    }
    @objc private func chooseModelDirectory() {
        let panel = NSOpenPanel()
        panel.title = "添加本地模型目录或 GGUF 文件"; panel.canChooseDirectories = true
        panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.level = .screenSaver
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { for url in panel.urls { self?.addModelDirectory(url) } }
        }
    }
    @objc private func openModelDirectory() {
        do {
            try FileManager.default.createDirectory(at: ScreenshotOCRLocalModels.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(ScreenshotOCRLocalModels.directory)
        } catch { feedback.stringValue = "无法打开模型目录：\(error.localizedDescription)" }
    }
    @objc private func choosePython() {
        let panel = NSOpenPanel(); panel.title = "选择已安装推理引擎的 Python"
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.showsHiddenFiles = true
        panel.level = .screenSaver
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.pythonField.stringValue = url.path }
        }
    }
    private var usesManagedMLX: Bool {
        guard let path = settings.localModelPath else { return true }
        return ScreenshotOCRLocalModels.inspect(URL(fileURLWithPath: path))?.format != .gguf
    }
    private func updateRuntimeControls() {
        guard localMode else { return }
        let managed = usesManagedMLX
        pythonField.isEditable = !managed
        pythonField.toolTip = managed ? ScreenshotOCRLocalRuntime.directory.path : settings.localPython
        if managed {
            pythonField.stringValue = ScreenshotOCRLocalRuntime.isReady ? "MacState 独立 MLX-LM · 已就绪" : "MacState 独立 MLX-LM · 未准备"
        } else { pythonField.stringValue = settings.localPython ?? ScreenshotOCRLocalModels.defaultPython() }
        environmentButton.title = managed ? (ScreenshotOCRLocalRuntime.isReady ? "修复环境" : "准备环境") : "选择…"
        environmentButton.action = managed ? #selector(prepareEnvironment) : #selector(choosePython)
        environmentButton.isEnabled = runtimeTask == nil
        runtimeHint.stringValue = managed ? "连续翻译复用已加载模型，空闲 5 分钟后自动释放。准备环境只安装独立 Python 和推理依赖，不下载模型。" : "GGUF 需要包含 llama-cpp-python 的环境；模型同样空闲 5 分钟后释放。MLX 模型使用 MacState 独立环境。"
    }
    @objc private func prepareEnvironment() {
        guard runtimeTask == nil else { return }
        testTask?.cancel(); testToken = UUID(); testButton.isEnabled = false
        environmentButton.isEnabled = false
        runtimeTask = Task { @MainActor [weak self] in
            do {
                try await ScreenshotOCRLocalRuntime.prepare(repair: true) { [weak self] message in self?.feedback.stringValue = message }
            } catch { self?.feedback.stringValue = error.localizedDescription }
            guard let self else { return }
            self.runtimeTask = nil; self.updateRuntimeControls()
            self.testButton.isEnabled = self.settings.localModelPath != nil
        }
    }
    @objc func releaseMemory() {
        testTask?.cancel(); testToken = UUID()
        ScreenshotOCRLocalSession.shared.releaseMemory()
        feedback.stringValue = "已请求释放本地模型内存，磁盘模型文件保留。"
    }
}
