import Foundation

struct ScreenshotOCRLocalTranslationService {
    var workerURL: URL? = Bundle.module.url(forResource: "translate", withExtension: "py", subdirectory: "LocalTranslation")
    var timeout: TimeInterval = 300
    var idleTimeout: TimeInterval = 300
    var pythonOverride: String?
    var session: ScreenshotOCRLocalSession = .shared

    func translate(_ segments: [ScreenshotOCRTranslationSegment], target: String?,
                   settings: ScreenshotOCRTranslationSettings, source: String? = nil,
                   onProgress: (@MainActor (Int, String) async -> Void)? = nil,
                   onSegmentComplete: (@MainActor (Int) async -> Void)? = nil) async throws -> [ScreenshotOCRTranslationOverlay] {
        try Task.checkCancellation()
        guard let path = settings.localModelPath,
              let model = ScreenshotOCRLocalModels.inspect(URL(fileURLWithPath: path)) else {
            throw ScreenshotOCRTranslationError(message: "本地模型不存在或文件不完整，请在翻译设置中重新选择。")
        }
        let python: String
        if let pythonOverride { python = pythonOverride }
        else if model.format == .mlx {
            guard ScreenshotOCRLocalRuntime.isReady else {
                throw ScreenshotOCRTranslationError(message: "MacState 独立 MLX-LM 环境尚未就绪，请在翻译设置中点击“准备环境”。")
            }
            python = ScreenshotOCRLocalRuntime.python.path
        } else { python = settings.localPython ?? ScreenshotOCRLocalModels.defaultPython() }
        guard FileManager.default.isExecutableFile(atPath: python), let workerURL else {
            throw ScreenshotOCRTranslationError(message: "找不到本地推理环境，请重新准备环境或选择 GGUF 运行环境。")
        }
        guard !segments.isEmpty, segments.reduce(0, { $0 + $1.text.utf8.count }) <= 128 * 1024 else {
            throw ScreenshotOCRTranslationError(message: "没有文字或文字过长，请先选中较短内容翻译。")
        }
        let detected = source ?? ScreenshotOCRTranslationLanguage.source(for: segments.map(\.text).joined(separator: "\n"))
        let target = target ?? ScreenshotOCRTranslationLanguage.defaultTarget(source: detected)
        let name = settings.localModelName ?? model.name
        let request: [String: Any] = ["path": model.path, "format": model.format.rawValue,
            "name": name, "texts": segments.map(\.text), "target": ScreenshotOCRTranslationLanguage.name(target),
            "hunyuan": name.lowercased().contains("hy-mt") || name.lowercased().contains("hunyuan"),
            "prompt": ScreenshotOCRLLMService.prompt(source: source, target: target)]
        let id = UUID()
        let stream = session.events(id: id, request: request, python: python, script: workerURL,
                                    timeout: timeout, idle: idleTimeout)
        do {
            return try await withTaskCancellationHandler {
                var translations: [Int: String] = [:], completed = Set<Int>(), finished = false
                for try await event in stream {
                    try Task.checkCancellation()
                    if let error = event["error"] as? String {
                        throw ScreenshotOCRTranslationError(message: error == "runtime" ?
                            "推理依赖缺失，请修复 MLX-LM 独立环境；GGUF 模型需要另选含 llama-cpp-python 的环境。" :
                            "本地模型加载或推理失败，请检查模型格式、文件完整性及可用内存。")
                    }
                    if event["event"] as? String == "finished" { finished = true; continue }
                    guard !finished, let index = event["index"] as? Int, segments.indices.contains(index),
                          let text = event["text"] as? String, text.utf8.count <= 2 * 1024 * 1024,
                          !completed.contains(index) else {
                        throw ScreenshotOCRTranslationError(message: "本地模型返回了无效的段落数据。")
                    }
                    if let finish = event["finish"] as? String {
                        translations[index] = try ScreenshotOCRLLMService.validated(text, finish: finish)
                        completed.insert(index)
                    }
                    if !text.isEmpty { await onProgress?(index, text) }
                    if completed.contains(index) {await onSegmentComplete?(index)}
                }
                try Task.checkCancellation()
                guard finished, completed.count == segments.count else {
                    throw ScreenshotOCRTranslationError(message: "本地模型提前退出，译文不完整，请重试。")
                }
                return segments.enumerated().map { index, segment in
                    .init(text: translations[index]!, sourceRect: segment.rect, sourceLineHeight: segment.lineHeight,
                          sourceLines: segment.sourceLines, sourceText: segment.text)
                }
            } onCancel: { session.cancel(id) }
        } catch {
            session.cancel(id)
            try Task.checkCancellation()
            throw error
        }
    }
}
