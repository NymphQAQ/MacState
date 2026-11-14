import AppKit
import Darwin
import Testing
@testable import MacState

@Suite(.serialized)
struct ScreenshotOCRLocalSessionTests {
    private func fixture() throws -> (URL, URL, ScreenshotOCRTranslationSettings) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacStateSession-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = root.appendingPathComponent("model.gguf"), script = root.appendingPathComponent("worker.py")
        try Data("GGUFfixture".utf8).write(to: model)
        try Data("""
        import json,sys,os,time
        count=0
        for line in sys.stdin:
            request=json.loads(line); count+=1
            def emit(value):
                value['request_id']=request['request_id']
                print(json.dumps(value),flush=True)
            if request['texts'][0]=='wait':
                time.sleep(.25)
            print(json.dumps({'request_id':'stale-request','index':0,'text':'wrong old result','finish':'stop'}),flush=True)
            emit({'index':0,'text':str(os.getpid())+':'+str(count),'finish':'stop'})
            emit({'event':'finished'})
        """.utf8).write(to: script)
        return (root, script, .init(localModelPath: model.path, localPython: "/usr/bin/python3"))
    }
    private func segment(_ text: String = "Hello") -> [ScreenshotOCRTranslationSegment] {
        [.init(text: text, rect: .zero, lineHeight: 14)]
    }
    private func waitUntilUnloaded(_ session: ScreenshotOCRLocalSession) async throws {
        for _ in 0..<100 {
            if await session.state().pid == nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Model process was not unloaded")
    }

    @Test func consecutiveRequestsReuseProcessAndResetIdleDeadline() async throws {
        let (root, script, settings) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = ScreenshotOCRLocalSession(); defer { session.shutdown() }
        let service = ScreenshotOCRLocalTranslationService(workerURL: script, timeout: 5, idleTimeout: 0.4, session: session)
        let first = try await service.translate(segment(), target: "en", settings: settings)
        let pid = try #require(await session.state().pid)
        try await Task.sleep(for: .milliseconds(250))
        let second = try await service.translate(segment(), target: "en", settings: settings)
        #expect(await session.state().pid == pid)
        #expect(first.first?.text == "\(pid):1")
        #expect(second.first?.text == "\(pid):2")
        try await Task.sleep(for: .milliseconds(220))
        #expect(await session.state().pid == pid)
        try await waitUntilUnloaded(session)
        #expect(kill(pid, 0) == -1)
        let third = try await service.translate(segment(), target: "en", settings: settings)
        #expect(third.first?.text.hasSuffix(":1") == true)
    }

    @Test func idleTimerDoesNotKillActiveWorkAndBusyRequestsDoNotCancelIt() async throws {
        let (root, script, settings) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = ScreenshotOCRLocalSession(); defer { session.shutdown() }
        let service = ScreenshotOCRLocalTranslationService(workerURL: script, timeout: 5, idleTimeout: 0.05, session: session)
        let task = Task { try await service.translate(segment("wait"), target: "en", settings: settings) }
        for _ in 0..<100 {
            if await session.state().busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        do { _ = try await service.translate(segment(), target: "en", settings: settings); Issue.record("Expected busy rejection") }
        catch { #expect(error.localizedDescription.contains("正在翻译")) }
        #expect(try await task.value.first?.text.hasSuffix(":1") == true)
        try await waitUntilUnloaded(session)
    }

    @Test func switchingModelsExplicitReleaseAndCancellationRemoveTheirProcesses() async throws {
        let (root, script, settings) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = ScreenshotOCRLocalSession(); defer { session.shutdown() }
        let service = ScreenshotOCRLocalTranslationService(workerURL: script, timeout: 5, session: session)
        _ = try await service.translate(segment(), target: "en", settings: settings)
        let oldPID = try #require(await session.state().pid)
        let other = root.appendingPathComponent("other.gguf")
        try Data("GGUFfixture".utf8).write(to: other)
        var next = settings; next.localModelPath = other.path
        _ = try await service.translate(segment(), target: "en", settings: next)
        #expect(kill(oldPID, 0) == -1)
        #expect(await session.state().pid != oldPID)
        session.releaseMemory(); try await waitUntilUnloaded(session)
        let task = Task { try await service.translate(segment("wait"), target: "en", settings: settings) }
        for _ in 0..<100 {
            if await session.state().busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled request returned translation") }
        catch { #expect(error is CancellationError) }
        try await waitUntilUnloaded(session)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSTATE_TEST_PREPARE_RUNTIME"] == "1"))
    func prepareOwnedEnvironmentWithoutUsingAnotherProject() async throws {
        try await ScreenshotOCRLocalRuntime.prepare(repair: true)
        #expect(ScreenshotOCRLocalRuntime.isReady)
        let config = try String(contentsOf: ScreenshotOCRLocalRuntime.directory.appendingPathComponent("pyvenv.cfg"))
        #expect(config.contains("MacState/LocalPython"))
        #expect(config.contains("include-system-site-packages = false"))
        #expect(!config.contains("projects/"))
    }
}
