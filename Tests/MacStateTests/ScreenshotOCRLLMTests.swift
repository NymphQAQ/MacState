import AppKit
import Foundation
import Testing
@testable import MacState

private final class OCRMemoryCredentials: ScreenshotOCRCredentialStore {
    var values: [UUID: String] = [:]
    var failReadOn: UUID?
    var failedWrites = Set<Int>()
    var writes = 0
    func read(_ id: UUID) throws -> String? {
        if id == failReadOn { throw ScreenshotOCRTranslationError(message: "fixture keychain failure") }
        return values[id]
    }
    func write(_ value: String?, for id: UUID) throws {
        writes += 1
        if failedWrites.contains(writes) { throw ScreenshotOCRTranslationError(message: "fixture keychain failure") }
        values[id] = value
    }
}

private final class OCRMockAPI: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    static var delay = 0.0
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.handler
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [self] in
            lock.lock(); let cancelled = stopped; lock.unlock()
            guard !cancelled else { return }
            do {
                let handler = try #require(handler)
                let data = try handler(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                               httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

@Suite(.serialized)
struct ScreenshotOCRLLMTests {
    private func profile(_ api: ScreenshotOCRAPIProtocol = .openAI,
                         url: String = "https://example.invalid/v1") -> ScreenshotOCRLLMProfile {
        .init(name: "Fixture", api: api, baseURL: url, model: "test-model")
    }
    private func response(_ api: ScreenshotOCRAPIProtocol, text: String, finish: String? = nil) throws -> Data {
        let body: [String: Any]
        switch api {
        case .openAI, .azure:
            body = ["choices": [["message": ["content": text], "finish_reason": finish ?? "stop"]]]
        case .anthropic:
            body = ["content": [["type": "thinking", "thinking": "hidden"], ["type": "text", "text": text]],
                    "stop_reason": finish ?? "end_turn"]
        case .gemini:
            body = ["candidates": [["content": ["parts": [["thought": true, "text": "hidden"], ["text": text]]],
                                     "finishReason": finish ?? "STOP"]]]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    @Test func apiProtocolsUseCorrectEndpointsHeadersAndTextOnlyBodies() throws {
        for api in ScreenshotOCRAPIProtocol.allCases {
            let p = profile(api)
            let request = try ScreenshotOCRLLMService.request(profile: p, apiKey: "fixture-secret",
                text: "Original OCR text", target: "zh-Hans")
            #expect(request.httpMethod == "POST")
            let data = try #require(request.httpBody)
            let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(!(String(data: data, encoding: .utf8) ?? "").contains("fixture-secret"))
            switch api {
            case .openAI, .azure:
                #expect(request.url?.path == "/v1/chat/completions")
                #expect(request.value(forHTTPHeaderField: api == .azure ? "api-key" : "Authorization") ==
                    (api == .azure ? "fixture-secret" : "Bearer fixture-secret"))
                #expect((body["messages"] as? [[String: String]])?.last?["content"] == "Original OCR text")
            case .anthropic:
                #expect(request.url?.path == "/v1/messages")
                #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-secret")
                #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
                #expect(body["max_tokens"] as? Int == 8192)
            case .gemini:
                #expect(request.url?.path == "/v1/models/test-model:generateContent")
                #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "fixture-secret")
                #expect(body["systemInstruction"] != nil)
            }
        }
    }

    @Test func customEndpointsPreservePathsAndRejectCredentialsInURLs() throws {
        for (base, path) in [
            ("https://api.example.com", "/v1/chat/completions"),
            ("https://api.example.com/compatible-mode/v1/", "/compatible-mode/v1/chat/completions"),
            ("https://api.example.com/api/paas/v4", "/api/paas/v4/chat/completions"),
            ("https://api.example.com/v1/chat/completions", "/v1/chat/completions"),
            ("https://api.example.com/v1/chat/completions/", "/v1/chat/completions"),
            ("http://localhost:11434/v1", "/v1/chat/completions")
        ] { #expect(try ScreenshotOCRLLMService.endpoint(for: profile(url: base)).path == path) }
        let azure = try ScreenshotOCRLLMService.endpoint(for: profile(.azure,
            url: "https://example.azure.com/openai/deployments/test/chat/completions?api-version=2024-10-21"))
        #expect(azure.query == "api-version=2024-10-21")
        #expect(azure.path == "/openai/deployments/test/chat/completions")
        #expect(try ScreenshotOCRLLMService.endpoint(for: profile(.azure,
            url: "https://example.openai.azure.com")).path == "/openai/v1/chat/completions")
        #expect(try ScreenshotOCRLLMService.endpoint(for: profile(.anthropic,
            url: "https://example.invalid/proxy")).path == "/proxy/v1/messages")
        for bad in ["http://remote.example/v1", "file:///tmp/key", "https://user:secret@example.com/v1",
                    "https://example.com/v1?key=secret", "https://example.com/v1#key"] {
            #expect(throws: ScreenshotOCRTranslationError.self) { try ScreenshotOCRLLMService.endpoint(for: profile(url: bad)) }
        }
    }

    @Test func responsesFilterThinkingRejectTruncationAndDoNotExposeServerSecrets() throws {
        let http = HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!
        for api in ScreenshotOCRAPIProtocol.allCases {
            #expect(try ScreenshotOCRLLMService.translation(from: response(api, text: "完整译文"), response: http, api: api) == "完整译文")
            let truncated = api == .gemini ? "MAX_TOKENS" : (api == .anthropic ? "max_tokens" : "length")
            #expect(throws: ScreenshotOCRTranslationError.self) {
                try ScreenshotOCRLLMService.translation(from: response(api, text: "partial", finish: truncated), response: http, api: api)
            }
            #expect(throws: ScreenshotOCRTranslationError.self) {
                try ScreenshotOCRLLMService.translation(from: Data("{}".utf8), response: http, api: api)
            }
            #expect(throws: ScreenshotOCRTranslationError.self) {
                try ScreenshotOCRLLMService.translation(from: response(api, text: "partial", finish: "tool_use"), response: http, api: api)
            }
        }
        let denied = HTTPURLResponse(url: http.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        do {
            _ = try ScreenshotOCRLLMService.translation(from: Data("fixture-secret Original OCR".utf8), response: denied, api: .openAI)
            Issue.record("Expected authentication error")
        } catch {
            #expect(!error.localizedDescription.contains("fixture-secret"))
            #expect(!error.localizedDescription.contains("Original OCR"))
        }
    }

    @Test @MainActor func networkTranslationPreservesSeparateParagraphsAndCoordinates() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OCRMockAPI.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); OCRMockAPI.handler = nil }
        for api in ScreenshotOCRAPIProtocol.allCases {
            var requests = 0
            OCRMockAPI.delay = 0
            OCRMockAPI.handler = { request in
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                requests += 1
                return try response(api, text: "译文段落\(requests)")
            }
            let segments = (0..<3).map { index in
                let frame = NSRect(x: 10, y: 20 + index * 80, width: 200, height: 30)
                return ScreenshotOCRTranslationSegment(text: "Paragraph \(index)", rect: frame,
                    lineHeight: 14, sourceLines: [frame])
            }
            let translated = try await ScreenshotOCRLLMService(session: session).translate(
                segments, target: "zh-Hans", profile: profile(api), apiKey: "fixture-secret")
            #expect(requests == 3)
            #expect(translated.map(\.text) == ["译文段落1", "译文段落2", "译文段落3"])
            #expect(translated.map(\.sourceRect) == segments.map(\.rect))
            #expect(translated.map(\.sourceLines) == segments.map(\.sourceLines))
            #expect(translated.map(\.sourceText) == segments.map { Optional($0.text) })
        }
    }

    @Test @MainActor func cancelledTranslationDoesNotReturnLateResults() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OCRMockAPI.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); OCRMockAPI.handler = nil; OCRMockAPI.delay = 0 }
        OCRMockAPI.delay = 0.4
        OCRMockAPI.handler = { _ in try response(.openAI, text: "too late") }
        let client = ScreenshotOCRLLMService(session: session)
        let task = Task { try await client.translate([
            .init(text: "Hello", rect: .zero, lineHeight: 12)
        ], target: "zh-Hans", profile: profile(), apiKey: "fixture") }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled request returned a result") }
        catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }

    @Test @MainActor func selectedServiceRoutesTranslationWithItsSavedCredential() async throws {
        let suite = "OCR-LLM-route-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = OCRMemoryCredentials()
        let store = ScreenshotOCRTranslationPreferences(defaults: defaults, credentials: credentials)
        let selected = profile(.anthropic)
        try store.save(.init(profiles: [profile(), selected], selectedID: selected.id),
                       keys: [selected.id: "selected-secret"])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OCRMockAPI.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); OCRMockAPI.handler = nil }
        var requests = 0
        OCRMockAPI.handler = { request in
            requests += 1
            #expect(request.url?.path == "/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "selected-secret")
            return try response(.anthropic, text: "你好")
        }
        let translated = try await ScreenshotOCRTranslationRouter.translate([
            .init(text: "Hello", rect: NSRect(x: 1, y: 2, width: 100, height: 20), lineHeight: 14)
        ], target: "zh-Hans", preferences: store, client: .init(session: session))
        #expect(requests == 1)
        #expect(translated.first?.text == "你好")
    }

    @Test func settingsPersistMultipleProfilesWithoutPlaintextSecretsAndRemoveCredentials() throws {
        let suite = "OCR-LLM-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = OCRMemoryCredentials()
        let store = ScreenshotOCRTranslationPreferences(defaults: defaults, credentials: credentials)
        #expect(store.settings.selected == nil)
        let first = profile(), second = profile(.gemini)
        let settings = ScreenshotOCRTranslationSettings(profiles: [first, second], selectedID: second.id)
        try store.save(settings, keys: [first.id: "first-secret", second.id: "second-secret"])
        #expect(store.settings == settings)
        #expect(credentials.values[second.id] == "second-secret")
        let data = try #require(defaults.data(forKey: ScreenshotOCRTranslationSettings.defaultsKey))
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains("secret"))
        var offline = settings; offline.selectedID = nil; offline.profiles.removeLast()
        try store.save(offline, keys: [:])
        #expect(store.settings.selectedID == nil)
        #expect(credentials.values[second.id] == nil)
        #expect(credentials.values[first.id] == "first-secret")
    }

    @Test func failedCredentialSavePreservesPreviousSettings() throws {
        let suite = "OCR-LLM-failure-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = OCRMemoryCredentials()
        let store = ScreenshotOCRTranslationPreferences(defaults: defaults, credentials: credentials)
        let first = profile(), second = profile(.gemini)
        let original = ScreenshotOCRTranslationSettings(profiles: [first, second], selectedID: first.id)
        let originalKeys = [first.id: "original-secret", second.id: "second-secret"]
        try store.save(original, keys: originalKeys)
        credentials.writes = 0; credentials.failedWrites = [2]
        #expect(throws: ScreenshotOCRTranslationError.self) {
            try store.save(.init(profiles: [first, second], selectedID: second.id),
                           keys: [first.id: "updated-secret", second.id: "new-secret"])
        }
        #expect(store.settings == original)
        #expect(credentials.values == originalKeys)
        credentials.writes = 0; credentials.failedWrites = [2, 3]
        do {
            try store.save(original, keys: [first.id: "updated", second.id: "updated"])
            Issue.record("Expected rollback error")
        } catch { #expect(error.localizedDescription.contains("部分密钥未能恢复")) }
        #expect(store.settings == original)
    }

    @Test @MainActor func closingDraftAndUnavailableKeyDoNotEraseSavedCredentials() throws {
        _ = NSApplication.shared
        let suite = "OCR-LLM-draft-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = OCRMemoryCredentials()
        let store = ScreenshotOCRTranslationPreferences(defaults: defaults, credentials: credentials)
        let saved = profile()
        let original = ScreenshotOCRTranslationSettings(profiles: [saved], selectedID: saved.id)
        try store.save(original, keys: [saved.id: "preserved-secret"])
        let draft = ScreenshotOCRTranslationSettingsWindow(preferences: store)
        draft.addProfile(profile(.gemini)); draft.keyField.stringValue = "unsaved-secret"
        draft.close()
        #expect(store.settings == original)
        #expect(credentials.values == [saved.id: "preserved-secret"])
        credentials.failReadOn = saved.id
        let controller = ScreenshotOCRTranslationSettingsWindow(preferences: store)
        defer { controller.close() }
        #expect(controller.keyField.stringValue.isEmpty)
        controller.nameField.stringValue = "Renamed"
        controller.save()
        #expect(store.settings.selected?.name == "Renamed")
        #expect(credentials.values[saved.id] == "preserved-secret")
    }

    @Test @MainActor func nativeSettingsSaveServiceAndRenderCompactForm() throws {
        _ = NSApplication.shared
        let suite = "OCR-LLM-window-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = OCRMemoryCredentials()
        let store = ScreenshotOCRTranslationPreferences(defaults: defaults, credentials: credentials)
        let controller = ScreenshotOCRTranslationSettingsWindow(preferences: store)
        defer { controller.close() }
        controller.addProfile(profile(.anthropic))
        controller.nameField.stringValue = "我的翻译服务"
        controller.modelField.stringValue = "my-model"
        controller.keyField.stringValue = "fixture-secret"
        #expect(controller.keyField.cell is NSSecureTextFieldCell)
        let view = try #require(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let folder = URL(fileURLWithPath: "reports/ocr-local-models-2026-10-29")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("api-settings.png"))
        controller.save()
        #expect(store.settings.selected?.name == "我的翻译服务")
        #expect(store.settings.selected?.api == .anthropic)
        #expect(store.settings.selected?.model == "my-model")
        #expect(credentials.values[store.settings.selectedID!] == "fixture-secret")
    }
}
