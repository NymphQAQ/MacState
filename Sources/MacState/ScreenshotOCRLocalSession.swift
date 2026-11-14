import Foundation
import Darwin

final class ScreenshotOCRLocalSession: @unchecked Sendable {
    static let shared = ScreenshotOCRLocalSession()
    static let changed = Notification.Name("MacStateLocalTranslationMemoryChanged")
    struct State { let pid: Int32?; let model: String?; let busy: Bool }
    private struct Worker {
        let id = UUID()
        let child: ScreenshotOCRChildProcess
        let input: Pipe
        let output: Pipe
        let key: [String]
        let model: String
    }
    private let queue = DispatchQueue(label: "MacState.localTranslation.session")
    private var worker: Worker?
    private var active: (id: UUID, continuation: AsyncThrowingStream<[String: Any], Error>.Continuation)?
    private var lastID: UUID?
    private var idleTimer: DispatchWorkItem?, requestTimer: DispatchWorkItem?

    func state() async -> State {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: .init(pid: worker?.child.process.isRunning == true ? worker?.child.process.processIdentifier : nil,
                                                     model: worker?.model, busy: active != nil))
            }
        }
    }
    func releaseMemory() { queue.async { [self] in stop() } }
    func shutdown() { queue.sync { stop() } }
    func reconcile(modelPath: String?) {
        queue.async { [self] in if worker?.key.first != modelPath { stop() } }
    }
    func cancel(_ id: UUID) {
        queue.async { [self] in
            if active?.id == id || (active == nil && lastID == id) { stop() }
        }
    }
    func events(id: UUID, request: [String: Any], python: String, script: URL,
                timeout: TimeInterval, idle: TimeInterval) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] state in if case .cancelled = state { self?.cancel(id) } }
            queue.async { [self] in
                guard active == nil else {
                    continuation.finish(throwing: ScreenshotOCRTranslationError(message: "本地模型正在翻译，请稍后重试。")); return
                }
                do {
                    idleTimer?.cancel(); idleTimer = nil
                    let key = [request["path"] as? String ?? "", python, script.path]
                    if worker?.key != key || worker?.child.process.isRunning != true {
                        stop()
                        worker = try start(key: key, model: request["name"] as? String ?? "本地模型")
                    }
                    active = (id, continuation); lastID = id
                    let deadline = DispatchWorkItem { [weak self] in
                        guard let self, self.active?.id == id else { return }
                        self.stop(error: ScreenshotOCRTranslationError(message: "本地模型响应超时，请缩短内容或选择较小的模型。"))
                    }
                    requestTimer = deadline; queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
                    var message = request; message["request_id"] = id.uuidString
                    var input = try JSONSerialization.data(withJSONObject: message)
                    guard input.count <= 256 * 1024 else { throw ScreenshotOCRTranslationError(message: "文字过长，请先选择较短内容翻译。") }
                    input.append(10)
                    try worker!.input.fileHandleForWriting.write(contentsOf: input)
                    publish()
                    // The reader schedules this timeout only after the request's finished event.
                    idleDuration = idle
                } catch { stop(error: error); continuation.finish(throwing: error) }
            }
        }
    }
    private var idleDuration: TimeInterval = 300
    private func start(key: [String], model: String) throws -> Worker {
        let child = ScreenshotOCRChildProcess(), input = Pipe(), output = Pipe()
        child.process.executableURL = URL(fileURLWithPath: key[1])
        child.process.arguments = ["-I", "-u", key[2], "--persistent"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY"] { environment[key] = "1" }
        child.process.environment = environment
        child.process.standardInput = input; child.process.standardOutput = output
        child.process.standardError = FileHandle.nullDevice
        let worker = Worker(child: child, input: input, output: output, key: key, model: model)
        try child.start()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                var pending = Data(), chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &chunk, chunk.count)
                    if count == 0 { break }
                    if count < 0 { if errno == EINTR { continue }; throw CocoaError(.fileReadUnknown) }
                    pending.append(contentsOf: chunk.prefix(count))
                    guard pending.count <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    while let end = pending.firstIndex(of: 10) {
                        let line = pending.prefix(upTo: end); pending.removeSubrange(...end)
                        guard let event = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
                        self?.queue.async { [weak self] in self?.receive(event, from: worker.id) }
                    }
                }
                child.process.waitUntilExit()
                self?.queue.async { [weak self] in
                    guard let self, self.worker?.id == worker.id else { return }
                    self.stop(error: ScreenshotOCRTranslationError(message: "本地模型提前退出，译文不完整，请重试。"))
                }
            } catch {
                self?.queue.async { [weak self] in
                    guard let self, self.worker?.id == worker.id else { return }
                    self.stop(error: ScreenshotOCRTranslationError(message: "本地推理环境返回了无效的数据。"))
                }
            }
            try? output.fileHandleForReading.close()
        }
        return worker
    }
    private func receive(_ event: [String: Any], from workerID: UUID) {
        guard worker?.id == workerID, let active,
              event["request_id"] as? String == active.id.uuidString else { return }
        active.continuation.yield(event)
        if event["event"] as? String == "finished" {
            requestTimer?.cancel(); requestTimer = nil
            self.active = nil; active.continuation.finish()
            let timer = DispatchWorkItem { [weak self] in
                if self?.active == nil && self?.lastID == active.id { self?.stop() }
            }
            idleTimer = timer; queue.asyncAfter(deadline: .now() + idleDuration, execute: timer)
            publish()
        }
    }
    private func stop(error: Error = CancellationError()) {
        idleTimer?.cancel(); idleTimer = nil; requestTimer?.cancel(); requestTimer = nil
        let old = worker; worker = nil
        active?.continuation.finish(throwing: error); active = nil; lastID = nil
        old?.child.stop(wait: true)
        try? old?.input.fileHandleForWriting.close()
        publish()
    }
    private func publish() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
}
