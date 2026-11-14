import AppKit
import Testing
@testable import MacState

private struct LocalNoCredentials: ScreenshotOCRCredentialStore {
    func read(_ id: UUID) throws -> String? { throw ScreenshotOCRTranslationError(message: "Local translation must not read keys") }
    func write(_ value: String?, for id: UUID) throws { throw ScreenshotOCRTranslationError(message: "Unexpected key write") }
}

@Suite(.serialized)
struct ScreenshotOCRLocalModelTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacStateLocalModels-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func mlx(_ root: URL) throws -> URL {
        let model = root.appendingPathComponent("models--fixture--mlx-model/snapshots/revision")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{\"quantization\":{\"bits\":4},\"architectures\":[\"FixtureForCausalLM\"]}".utf8).write(to: model.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: model.appendingPathComponent("tokenizer_config.json"))
        try Data("{}".utf8).write(to: model.appendingPathComponent("tokenizer.json"))
        try Data(repeating: 0, count: 32).write(to: model.appendingPathComponent("model.safetensors"))
        return model
    }

    @Test func discoveryDeduplicatesLinksAndRejectsIncompleteOrNonLanguageModels() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try mlx(root)
        let found = ScreenshotOCRLocalModels.discover(in: [root, model])
        #expect(found.count == 1)
        #expect(found.first?.name == "fixture/mlx-model")
        let link = root.appendingPathComponent("linked-model")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: model)
        #expect(ScreenshotOCRLocalModels.discover(in: [root, link]).count == 1)
        let index = model.appendingPathComponent("model.safetensors.index.json")
        try Data("{\"weight_map\":{\"weight\":\"missing.safetensors\"}}".utf8).write(to: index)
        #expect(ScreenshotOCRLocalModels.discover(in: [root]).isEmpty)
        try FileManager.default.removeItem(at: index)
        try Data("{\"quantization\":{\"bits\":4},\"architectures\":[\"WhisperForConditionalGeneration\"]}".utf8).write(to: model.appendingPathComponent("config.json"))
        #expect(ScreenshotOCRLocalModels.inspect(model) == nil)
    }

    @Test func ggufAndOllamaDiscoveryRequiresActualWeights() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let gguf = root.appendingPathComponent("chat.gguf")
        try Data("GGUFfixture".utf8).write(to: gguf)
        #expect(ScreenshotOCRLocalModels.discover(in: [root]).first?.format == .gguf)
        let cached = root.appendingPathComponent("blobs/hf-blob")
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("GGUFfixture".utf8).write(to: cached)
        let snapshot = root.appendingPathComponent("snapshots/revision")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let cachedLink = snapshot.appendingPathComponent("cached.gguf")
        try FileManager.default.createSymbolicLink(at: cachedLink, withDestinationURL: cached)
        #expect(ScreenshotOCRLocalModels.inspect(cachedLink)?.format == .gguf)
        #expect(ScreenshotOCRLocalModels.discover(in: [root]).count == 2)
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let blob = root.appendingPathComponent("blobs/" + digest.replacingOccurrences(of: ":", with: "-"))
        let manifest = root.appendingPathComponent("manifests/registry.ollama.ai/library/example/latest")
        for dir in [blob.deletingLastPathComponent(), manifest.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("GGUFfixture".utf8).write(to: blob)
        try JSONSerialization.data(withJSONObject: ["layers": [["mediaType": "application/vnd.ollama.image.model", "digest": digest]]]).write(to: manifest)
        let models = ScreenshotOCRLocalModels.discover(in: [root])
        #expect(models.count == 3)
        #expect(models.contains { $0.name == "example:latest" && $0.path == blob.path })
        try Data("not a model".utf8).write(to: gguf)
        try FileManager.default.removeItem(at: blob)
        try FileManager.default.removeItem(at: cached)
        #expect(ScreenshotOCRLocalModels.discover(in: [root]).isEmpty)
    }

    @Test func preferencesDecodeOldSettingsAndPersistLocalChoiceWithoutCredentials() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try mlx(root)
        let suite = "LocalModels-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("{\"profiles\":[]}".utf8), forKey: ScreenshotOCRTranslationSettings.defaultsKey)
        let preferences = ScreenshotOCRTranslationPreferences(defaults: defaults, credentials: LocalNoCredentials())
        #expect(preferences.settings.localModelPath == nil)
        var settings = preferences.settings
        settings.localModelPath = model.path; settings.localPython = "/usr/bin/python3"
        settings.modelDirectories = [root.path]
        try preferences.save(settings, keys: [:])
        #expect(preferences.settings == settings)
        #expect(preferences.settings.serviceName == "fixture/mlx-model")
        try FileManager.default.removeItem(at: model.appendingPathComponent("model.safetensors"))
        #expect(throws: ScreenshotOCRTranslationError.self) { try preferences.save(settings, keys: [:]) }
    }

    @Test @MainActor func localRoutingStreamsBeforeCompletionAndPreservesParagraphGeometry() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try mlx(root), worker = root.appendingPathComponent("fixture.py")
        let gate = root.appendingPathComponent("first-progress"), finished = root.appendingPathComponent("worker-finished")
        let gateLiteral = String(data: try JSONSerialization.data(withJSONObject: gate.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
        let finishedLiteral = String(data: try JSONSerialization.data(withJSONObject: finished.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
        try Data("""
        import json,sys,time,os
        from pathlib import Path
        request=json.loads(sys.stdin.readline())
        assert os.environ['HF_HUB_OFFLINE']=='1'
        assert request['format']=='MLX' and request['target']=='简体中文'
        for i,text in enumerate(request['texts']):
            print(json.dumps({'index':i,'text':'译','finish':None,'request_id':request['request_id']}),flush=True)
            deadline=time.monotonic()+30
            while not Path(\(gateLiteral)).exists():
                assert time.monotonic()<deadline
                time.sleep(.01)
            print(json.dumps({'index':i,'text':'译文'+str(i),'finish':'stop','request_id':request['request_id']}),flush=True)
        Path(\(finishedLiteral)).touch()
        print(json.dumps({'event':'finished','request_id':request['request_id']}),flush=True)
        """.utf8).write(to: worker)
        let suite = "LocalRouting-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ScreenshotOCRTranslationPreferences(defaults: defaults, credentials: LocalNoCredentials())
        try preferences.save(.init(localModelPath: model.path, localPython: "/usr/bin/python3"), keys: [:])
        let segments = [10.0, 100.0].map { y in
            let rect = NSRect(x: 8, y: y, width: 200, height: 30)
            return ScreenshotOCRTranslationSegment(text: "Hello", rect: rect, lineHeight: 14, sourceLines: [rect])
        }
        var sawFirst = false
        var completed:[Int]=[]
        let session = ScreenshotOCRLocalSession(); defer { session.shutdown() }
        let overlays = try await ScreenshotOCRTranslationRouter.translate(segments, target: "zh-Hans", preferences: preferences,
            localClient: .init(workerURL: worker, timeout: 45, pythonOverride: "/usr/bin/python3", session: session), onProgress: { _, _ in
                if !sawFirst {
                    sawFirst = true
                    #expect(!FileManager.default.fileExists(atPath: finished.path))
                    try? Data().write(to: gate)
                }
            },onSegmentComplete:{ completed.append($0) })
        #expect(sawFirst)
        #expect(completed==[0,1])
        #expect(overlays.map(\.text) == ["译文0", "译文1"])
        #expect(overlays.map(\.sourceRect) == segments.map(\.rect))
        #expect(overlays.map(\.sourceLines) == segments.map(\.sourceLines))
        #expect(overlays.map(\.sourceText) == segments.map { Optional($0.text) })
    }

    @Test @MainActor func localWorkerCancellationTimeoutAndTruncationAreFailures() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try mlx(root), worker = root.appendingPathComponent("fixture.py")
        let settings = ScreenshotOCRTranslationSettings(localModelPath: model.path, localPython: "/usr/bin/python3")
        let segments = [ScreenshotOCRTranslationSegment(text: "Hello", rect: .zero, lineHeight: 14)]
        try Data("import sys,time,json\nsys.stdin.readline()\ntime.sleep(10)\n".utf8).write(to: worker)
        let session = ScreenshotOCRLocalSession(); defer { session.shutdown() }
        let service = ScreenshotOCRLocalTranslationService(workerURL: worker, timeout: 5, pythonOverride: "/usr/bin/python3", session: session)
        let task = Task { try await service.translate(segments, target: "en", settings: settings) }
        try await Task.sleep(for: .milliseconds(60)); task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled local model returned results") }
        catch { #expect(error is CancellationError) }
        do {
            _ = try await ScreenshotOCRLocalTranslationService(workerURL: worker, timeout: 0.1, pythonOverride: "/usr/bin/python3", session: session).translate(segments, target: "en", settings: settings)
            Issue.record("Timed out local model returned results")
        } catch { #expect(error.localizedDescription.contains("超时")) }
        try Data("import sys,json\nrequest=json.loads(sys.stdin.readline())\nprint(json.dumps({'index':0,'text':'partial','finish':'length','request_id':request['request_id']}),flush=True)\n".utf8).write(to: worker)
        do { _ = try await service.translate(segments, target: "en", settings: settings); Issue.record("Truncation accepted") }
        catch { #expect(error.localizedDescription.contains("截断")) }
        try Data("import sys\nsys.stdin.readline()\n".utf8).write(to: worker)
        do { _ = try await service.translate(segments, target: "en", settings: settings); Issue.record("Early exit accepted") }
        catch { #expect(error.localizedDescription.contains("提前退出")) }
    }

    @Test @MainActor func nativeLocalSettingsFindModelsAndSaveWithoutChangingAPIProfiles() async throws {
        _ = NSApplication.shared
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try mlx(root)
        let suite = "LocalWindow-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ScreenshotOCRTranslationPreferences(defaults: defaults, credentials: LocalNoCredentials())
        let api = ScreenshotOCRLLMProfile(name: "Saved API", baseURL: "https://example.invalid/v1", model: "fixture")
        try preferences.save(.init(profiles: [api]), keys: [:])
        let controller = ScreenshotOCRTranslationSettingsWindow(preferences: preferences)
        defer { controller.close() }
        controller.service.selectItem(at: 1); controller.serviceChanged()
        controller.addModelDirectory(root)
        for _ in 0..<100 {
            if controller.localModel.itemTitles.contains(where: { $0.contains("fixture/mlx-model") }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let index = try #require(controller.localModel.itemTitles.firstIndex(where: { $0.contains("fixture/mlx-model") }))
        controller.localModel.selectItem(at: index)
        if let action = controller.localModel.action {
            NSApp.sendAction(action, to: controller.localModel.target, from: controller.localModel)
        }
        #expect(!controller.pythonField.isEditable)
        let view = try #require(controller.window?.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: "reports/ocr-managed-runtime-2026-10-29")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("local-settings.png"))
        controller.save()
        #expect(preferences.settings.localModelPath == model.path)
        #expect(preferences.settings.modelDirectories == [root.path])
        #expect(preferences.settings.selectedID == nil)
        #expect(preferences.settings.profiles == [api])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSTATE_TEST_LOCAL_PYTHON"] != nil))
    @MainActor func existingLocalMLXModelsTranslateFixedTextThroughSwiftStreaming() async throws {
        let python = try #require(ProcessInfo.processInfo.environment["MACSTATE_TEST_LOCAL_PYTHON"])
        #expect(python == ScreenshotOCRLocalRuntime.python.path)
        #expect(ScreenshotOCRLocalRuntime.isReady)
        let session = ScreenshotOCRLocalSession(); defer { session.shutdown() }
        let models = ScreenshotOCRLocalModels.discover(in: ScreenshotOCRLocalModels.roots()).filter { $0.format == .mlx }
        #expect(!models.isEmpty)
        var evidence: [[String: Any]] = []
        for model in models {
            let settings = ScreenshotOCRTranslationSettings(localModelPath: model.path, localPython: python)
            let rect = NSRect(x: 10, y: 20, width: 400, height: 30)
            let segment = ScreenshotOCRTranslationSegment(text: "Hello, welcome to MacState.", rect: rect, lineHeight: 14, sourceLines: [rect])
            var updates = 0
            let result = try await ScreenshotOCRLocalTranslationService(session: session).translate([segment], target: "zh-Hans", settings: settings,
                onProgress: { _, _ in updates += 1 })
            #expect(result.first?.text.contains("MacState") == true)
            #expect(result.first?.text != segment.text)
            #expect(result.first?.sourceRect == rect)
            #expect(updates > 1)
            let resident = await session.state()
            #expect(resident.pid != nil)
            let second = try await ScreenshotOCRLocalTranslationService(session: session).translate([segment], target: "zh-Hans", settings: settings)
            #expect(await session.state().pid == resident.pid)
            #expect(second.first?.text == result.first?.text)
            evidence.append(["model": model.name, "translation": result.first?.text ?? "", "updates": updates,
                             "process_reused": await session.state().pid == resident.pid])
        }
        let folder = URL(fileURLWithPath: "reports/ocr-managed-runtime-2026-10-29")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("real-model-results.json"))
    }
}
