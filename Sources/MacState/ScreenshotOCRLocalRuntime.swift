import Foundation
import Darwin

final class ScreenshotOCRChildProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
    }
    func stop(wait: Bool = false) {
        lock.lock(); cancelled = true
        let running = process.isRunning
        if running { process.terminate() }
        lock.unlock()
        if running {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock(); defer { lock.unlock() }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            if wait { process.waitUntilExit() }
        }
    }
}

enum ScreenshotOCRLocalRuntime {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacState")
    static let directory = root.appendingPathComponent("LocalRuntime")
    static let python = directory.appendingPathComponent("bin/python3")
    static let pythonDirectory = root.appendingPathComponent("LocalPython")
    static let version = "mlx-lm-0.29.1-mlx-0.32.4-v1"
    private static let marker = directory.appendingPathComponent("macstate-runtime.json")
    private static let lock = NSLock()
    private static var preparing = false
    private static var preparationCancelled = false
    private static var command: ScreenshotOCRChildProcess?

    static var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) &&
        ScreenshotOCRLocalModels.json(marker)?["version"] as? String == version
    }
    static func cancelPreparation() {
        lock.lock(); preparationCancelled = true; let child = command; lock.unlock()
        child?.stop()
    }
    private static func beginPreparation() throws {
        lock.lock(); defer { lock.unlock() }
        guard !preparing else { throw ScreenshotOCRTranslationError(message: "独立环境正在准备，请稍候。") }
        preparing = true; preparationCancelled = false
    }
    private static func endPreparation() {
        lock.lock(); preparing = false; command = nil; lock.unlock()
    }
    private static func setCommand(_ child: ScreenshotOCRChildProcess) throws {
        lock.lock(); defer { lock.unlock() }
        guard !preparationCancelled else { throw CancellationError() }
        command = child
    }
    static func prepare(repair: Bool = false,
                        progress: (@MainActor (String) -> Void)? = nil) async throws {
        if isReady && !repair { return }
        try beginPreparation(); defer { endPreparation() }
        #if !arch(arm64)
        throw ScreenshotOCRTranslationError(message: "MLX-LM 独立环境需要 Apple 芯片 Mac。")
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/uv").path, "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        guard let uv = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ScreenshotOCRTranslationError(message: "未找到 uv 环境安装工具，请先安装 uv 后重试。")
        }
        // Never overwrite a runtime directory redirected to another project.
        for url in [directory, pythonDirectory] {
            guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else {
                throw ScreenshotOCRTranslationError(message: "独立环境目录指向了其他位置，请先移开该链接。")
            }
        }
        ScreenshotOCRLocalSession.shared.shutdown()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: marker)
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("UV_") && !$0.key.hasPrefix("PIP_") && !$0.key.hasPrefix("PYTHON") }
        environment["UV_PYTHON_INSTALL_DIR"] = pythonDirectory.path
        environment["UV_NO_PROGRESS"] = "1"
        await progress?("正在准备 MacState 专用 Python…")
        try await run(uv, ["python", "install", "3.12", "--no-bin", "--no-config"], environment: environment)
        await progress?("正在创建独立运行环境…")
        try await run(uv, ["venv", "--python", "3.12", "--managed-python", "--allow-existing", "--no-project", "--no-config", directory.path], environment: environment)
        await progress?("正在安装 MLX-LM 依赖，不下载模型…")
        try await run(uv, ["pip", "install", "--python", python.path, "--no-config", "--default-index", "https://pypi.org/simple", "--only-binary", ":all:", "mlx-lm==0.29.1", "mlx==0.32.4", "transformers==5.21.0", "tokenizers==0.23.3"], environment: environment)
        await progress?("正在检查独立环境…")
        let check = "import sys,importlib.metadata as m; import mlx.core,mlx_lm; from pathlib import Path; assert Path(sys.base_prefix).resolve().is_relative_to(Path(sys.argv[1]).resolve()); assert m.version('mlx-lm')=='0.29.1'; assert m.version('mlx')=='0.32.4'"
        try await run(python.path, ["-I", "-c", check, pythonDirectory.path], environment: environment)
        try Task.checkCancellation()
        try JSONSerialization.data(withJSONObject: ["version": version]).write(to: marker, options: .atomic)
        await progress?("MacState 独立 MLX-LM 环境已就绪。")
        #endif
    }
    private static func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws {
        let child = ScreenshotOCRChildProcess()
        child.process.executableURL = URL(fileURLWithPath: executable)
        child.process.arguments = arguments; child.process.environment = environment
        child.process.standardInput = FileHandle.nullDevice
        child.process.standardOutput = FileHandle.nullDevice; child.process.standardError = FileHandle.nullDevice
        try setCommand(child)
        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                child.process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try child.start() }
                catch { child.process.terminationHandler = nil; continuation.resume(throwing: error) }
            }
        } onCancel: { child.stop() }
        try Task.checkCancellation()
        guard status == 0 else {
            throw ScreenshotOCRTranslationError(message: "独立环境准备失败，请检查网络和剩余磁盘空间后重试（\(status)）。")
        }
    }
}
