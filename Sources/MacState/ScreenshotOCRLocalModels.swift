import Foundation

struct ScreenshotOCRLocalModel: Equatable, Identifiable {
    enum Format: String, Codable { case mlx = "MLX", gguf = "GGUF" }
    let path: String
    let name: String
    let format: Format
    let bytes: Int64
    var id: String { path }
}

enum ScreenshotOCRLocalModels {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacState/Models")
    }
    static func roots(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var paths = ["Library/Application Support/MacState/Models", ".cache/huggingface/hub",
                     "Library/Caches/huggingface/hub", ".lmstudio/models", ".cache/lm-studio/models",
                     ".ollama/models", ".cache/modelscope/hub", "Models", "models",
                     "Library/Application Support/nomic.ai/GPT4All", ".local/share/jan/models"]
            .map { home.appendingPathComponent($0) }
        for key in ["HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE", "OLLAMA_MODELS"] {
            if let value = environment[key], value.hasPrefix("/") { paths.append(URL(fileURLWithPath: value)) }
        }
        if let value = environment["HF_HOME"], value.hasPrefix("/") {
            paths.append(URL(fileURLWithPath: value).appendingPathComponent("hub"))
        }
        return paths
    }
    static func json(_ url: URL) -> [String: Any]? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
    static func inspect(_ url: URL) -> ScreenshotOCRLocalModel? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        if url.pathExtension.lowercased() == "gguf" || path.lastPathComponent.hasPrefix("sha256-") {
            guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 4,
                  let file = try? FileHandle(forReadingFrom: path) else { return nil }
            defer { try? file.close() }
            guard (try? file.read(upToCount: 4)) == Data("GGUF".utf8) else { return nil }
            // Split GGUF files require all shards; let users select a complete single-file model.
            guard !url.lastPathComponent.contains("-of-") else { return nil }
            return .init(path: url.standardizedFileURL.path, name: url.deletingPathExtension().lastPathComponent,
                         format: .gguf, bytes: Int64(size))
        }
        guard let config = json(path.appendingPathComponent("config.json")),
              config["quantization"] is [String: Any] || path.path.lowercased().contains("mlx"),
              (config["architectures"] as? [String] ?? []).contains(where: { $0.contains("ForCausalLM") }),
              fm.fileExists(atPath: path.appendingPathComponent("tokenizer_config.json").path),
              ["tokenizer.json", "tokenizer.model"].contains(where: { fm.fileExists(atPath: path.appendingPathComponent($0).path) }) else { return nil }
        let index = path.appendingPathComponent("model.safetensors.index.json")
        let names: Set<String>
        if fm.fileExists(atPath: index.path) {
            guard let map = json(index)?["weight_map"] as? [String: String], !map.isEmpty else { return nil }
            names = Set(map.values)
        } else { names = ["model.safetensors"] }
        var bytes: Int64 = 0
        for name in names {
            guard !name.contains("/"), name.hasSuffix(".safetensors"),
                  let size = try? path.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 8 else { return nil }
            bytes += Int64(size)
        }
        let repository = path.deletingLastPathComponent().lastPathComponent == "snapshots" ?
            path.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent : path.lastPathComponent
        let name = repository.hasPrefix("models--") ? repository.dropFirst(8).replacingOccurrences(of: "--", with: "/") : repository
        return .init(path: path.path, name: name, format: .mlx, bytes: bytes)
    }
    static func discover(in roots: [URL]) -> [ScreenshotOCRLocalModel] {
        var visited = Set<String>(), models: [String: ScreenshotOCRLocalModel] = [:]
        // shortcut: bound large caches; add a model directory directly when it falls outside this scan budget.
        var remaining = 12_000
        func visit(_ url: URL, depth: Int) {
            guard remaining > 0, depth <= 6, !Task.isCancelled else { return }
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard visited.insert(canonical.path).inserted else { return }
            remaining -= 1
            if let model = inspect(url) { models[canonical.path] = model; return }
            if depth > 0, url.standardizedFileURL.path != canonical.path { return }
            if canonical.path.contains("/manifests/"), let manifest = json(canonical),
               let layers = manifest["layers"] as? [[String: Any]] {
                let components = canonical.path.components(separatedBy: "/manifests/")
                for layer in layers where layer["mediaType"] as? String == "application/vnd.ollama.image.model" {
                    guard let digest = layer["digest"] as? String,
                          digest.hasPrefix("sha256:"), digest.count == 71,
                          digest.dropFirst(7).allSatisfy({ $0.isHexDigit }),
                          let model = inspect(URL(fileURLWithPath: components[0]).appendingPathComponent("blobs/" + digest.replacingOccurrences(of: ":", with: "-"))) else { continue }
                    models[model.path] = .init(path: model.path,
                        name: canonical.deletingLastPathComponent().lastPathComponent + ":" + canonical.lastPathComponent,
                        format: .gguf, bytes: model.bytes)
                }
                return
            }
            guard let values = try? canonical.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true,
                  let children = try? FileManager.default.contentsOfDirectory(at: canonical,
                        includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for child in children.sorted(by: { $0.path < $1.path }) where
                !["blobs", ".git", "node_modules", ".venv"].contains(child.lastPathComponent) {
                visit(child, depth: depth + 1)
            }
        }
        for root in roots { visit(root, depth: 0) }
        return models.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func defaultPython() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ["Library/Application Support/MacState/LocalRuntime/bin/python3",
                          ".local/share/uv/tools/mlx-lm/bin/python3", ".venv/bin/python3"].map { home.appendingPathComponent($0).path }
            + ["/opt/homebrew/bin/python3", "/opt/homebrew/bin/python3.13", "/usr/local/bin/python3", "/usr/bin/python3"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? ""
    }
}
