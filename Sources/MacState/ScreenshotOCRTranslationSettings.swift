import Foundation
import LocalAuthentication
import Security

enum ScreenshotOCRAPIProtocol: String, Codable, CaseIterable {
    case openAI, anthropic, gemini, azure
    var title: String {
        switch self {
        case .openAI: return "OpenAI 兼容"
        case .anthropic: return "Claude / Anthropic"
        case .gemini: return "Google Gemini"
        case .azure: return "Azure OpenAI"
        }
    }
}

struct ScreenshotOCRLLMProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var api: ScreenshotOCRAPIProtocol = .openAI
    var baseURL: String
    var model = ""

    static let presets: [Self] = [
        .init(name: "OpenAI", baseURL: "https://api.openai.com/v1"),
        .init(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1"),
        .init(name: "通义千问 / 阿里百炼", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
        .init(name: "Kimi / Moonshot", baseURL: "https://api.moonshot.cn/v1"),
        .init(name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4"),
        .init(name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1"),
        .init(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1"),
        .init(name: "Claude", api: .anthropic, baseURL: "https://api.anthropic.com/v1"),
        .init(name: "Gemini", api: .gemini, baseURL: "https://generativelanguage.googleapis.com/v1beta"),
        .init(name: "Azure OpenAI", api: .azure, baseURL: ""),
        .init(name: "本机服务 / Ollama", baseURL: "http://localhost:11434/v1"),
        .init(name: "自定义服务", baseURL: "")
    ]
}

struct ScreenshotOCRTranslationSettings: Codable, Equatable {
    var profiles: [ScreenshotOCRLLMProfile] = []
    var selectedID: UUID?
    var localModelPath: String?
    var localModelName: String?
    var localPython: String?
    var modelDirectories: [String]?
    var selected: ScreenshotOCRLLMProfile? { profiles.first { $0.id == selectedID } }
    var serviceName: String {
        if let selected { return selected.name }
        if let localModelPath {
            return localModelName ?? ScreenshotOCRLocalModels.inspect(URL(fileURLWithPath: localModelPath))?.name ?? "本地大语言模型"
        }
        return "本机离线翻译"
    }
    static let defaultsKey = "ocr.translation.services.v1"

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }
}

struct ScreenshotOCRTranslationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol ScreenshotOCRCredentialStore {
    func read(_ id: UUID) throws -> String?
    func write(_ value: String?, for id: UUID) throws
}

struct ScreenshotOCRKeychain: ScreenshotOCRCredentialStore {
    private func query(_ id: UUID) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.macstate.ocr.translation",
         kSecAttrAccount as String: id.uuidString,
         kSecUseAuthenticationContext as String: context]
    }
    func read(_ id: UUID) throws -> String? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw failure(status) }
        return key
    }
    func write(_ value: String?, for id: UUID) throws {
        let request = query(id)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = request.merging(attributes) { _, new in new }
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insertion as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> ScreenshotOCRTranslationError {
        .init(message: "无法访问此服务的钥匙串密钥（\(status)），请重新输入密钥后保存。")
    }
}

final class ScreenshotOCRTranslationPreferences {
    let defaults: UserDefaults
    let credentials: any ScreenshotOCRCredentialStore
    init(defaults: UserDefaults = .standard,
         credentials: any ScreenshotOCRCredentialStore = ScreenshotOCRKeychain()) {
        self.defaults = defaults; self.credentials = credentials
    }
    var settings: ScreenshotOCRTranslationSettings { .load(from: defaults) }

    func save(_ settings: ScreenshotOCRTranslationSettings, keys: [UUID: String]) throws {
        guard settings.selectedID == nil || (settings.selected != nil && settings.localModelPath == nil),
              Set(settings.profiles.map(\.id)).count == settings.profiles.count else {
            throw ScreenshotOCRTranslationError(message: "请选择有效的翻译服务。")
        }
        for profile in settings.profiles { _ = try ScreenshotOCRLLMService.endpoint(for: profile) }
        if let path = settings.localModelPath {
            guard ScreenshotOCRLocalModels.inspect(URL(fileURLWithPath: path)) != nil else {
                throw ScreenshotOCRTranslationError(message: "请选择文件完整的本地 MLX 或 GGUF 模型。")
            }
        }
        let data = try JSONEncoder().encode(settings)
        let removed = Set(self.settings.profiles.map(\.id)).subtracting(settings.profiles.map(\.id))
        let changed = Set(keys.keys).intersection(settings.profiles.map(\.id)).union(removed)
        var previous: [UUID: String] = [:]
        for id in changed { if let key = try credentials.read(id) { previous[id] = key } }
        var written: [UUID] = []
        do {
            for id in changed {
                try credentials.write(removed.contains(id) ? nil : keys[id], for: id)
                written.append(id)
            }
        } catch {
            var restored = true
            for id in written {
                do { try credentials.write(previous[id], for: id) }
                catch { restored = false }
            }
            if !restored {
                throw ScreenshotOCRTranslationError(message: "配置未保存，且部分密钥未能恢复，请重新输入受影响服务的密钥。")
            }
            throw error
        }
        defaults.set(data, forKey: ScreenshotOCRTranslationSettings.defaultsKey)
    }
}

enum ScreenshotOCRTranslationRouter {
    static func translate(_ segments: [ScreenshotOCRTranslationSegment], target: String?,
                          preferences: ScreenshotOCRTranslationPreferences,
                          client: ScreenshotOCRLLMService = .init(),source:String?=nil,
                          localClient: ScreenshotOCRLocalTranslationService = .init(),
                          onProgress:(@MainActor (Int,String) async->Void)?=nil,
                          onSegmentComplete:(@MainActor (Int) async->Void)?=nil) async throws -> [ScreenshotOCRTranslationOverlay] {
        let settings = preferences.settings
        if settings.selectedID == nil, settings.localModelPath != nil {
            return try await localClient.translate(segments, target: target, settings: settings,
                                                   source: source, onProgress: onProgress,onSegmentComplete:onSegmentComplete)
        }
        if let id = settings.selectedID {
            guard let profile = settings.selected, profile.id == id else {
                throw ScreenshotOCRTranslationError(message: "翻译服务已不存在，请重新打开翻译设置。")
            }
            let key = try preferences.credentials.read(id) ?? ""
            return try await client.translate(segments,target:target,profile:profile,apiKey:key,
                                              source:source,onProgress:onProgress,onSegmentComplete:onSegmentComplete)
        }
        if #available(macOS 26.0, *) {
            return try await ScreenshotOCRTranslationService.translate(segments,target:target,
                                                                       source:source,onProgress:onProgress,onSegmentComplete:onSegmentComplete)
        }
        throw ScreenshotOCRTranslationError(message: "系统离线翻译需要 macOS 26；也可在翻译设置中选择本地大语言模型或 API 服务。")
    }
}
