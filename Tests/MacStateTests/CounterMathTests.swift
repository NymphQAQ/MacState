import Testing
import Foundation
@testable import MacState
import SystemBridge

@Test func cpuUsesIntervalRatherThanLifetime() {
    #expect(CounterMath.cpu([20, 10, 70, 0], previous: nil) == nil)
    #expect(CounterMath.cpu([40, 20, 140, 0], previous: [20, 10, 70, 0]) == 30)
}

@Test func cpuHandles32BitWrap() {
    let old: [UInt64] = [0xffff_fffa, 0, 100, 0]
    #expect(CounterMath.cpu([4, 0, 110, 0], previous: old) == 50)
}

@Test func unavailableAndResetCountersDoNotBecomeZero() {
    #expect(CounterMath.rate(200, previous: nil, elapsed: 2) == nil)
    #expect(CounterMath.rate(50, previous: 200, elapsed: 2) == nil)
    #expect(CounterMath.rate(200, previous: 100, elapsed: 0) == nil)
    #expect(CounterMath.rate(400, previous: 200, elapsed: 2) == 100)
    #expect(CounterMath.rate(200, previous: 200, elapsed: 2) == 0)
}

@Test func settingsRetainAStatusItemAndRejectInvalidIntervals() {
    var settings = Settings()
    settings.menuMetrics = ["invalid", "gpu", "gpu"]
    settings.interval = -1; settings.theme = "unsupported"
    #expect(settings.validated().menuMetrics == ["gpu"])
    #expect(settings.validated().interval == 2)
    #expect(settings.validated().theme == "dark")
    settings.menuMetrics = []
    #expect(settings.validated().menuMetrics == ["cpu"])
}

@Test func liveCollectorEnumeratesOwnProcessAndProvidesSystemMetrics() throws {
    let sample = Collector().collect()
    #expect(sample.cores.count > 0)
    #expect(sample.processes.contains { $0.pid == getpid() })
    #expect((sample.metrics.first { $0.id == "memoryTotal" }?.value ?? 0) > 0)
    #expect(sample.metrics.first { $0.id == "cpu" }?.value == nil)
    #expect(sample.processes.allSatisfy { $0.gpu == nil })
    _ = try JSONEncoder().encode(sample)
}

@Test func processCPUTimeIsConvertedFromMachTicksToNanoseconds() throws {
    func selfCPU() throws -> UInt64 {
        var pointer: UnsafeMutablePointer<MSProcess>?
        let count = Int(ms_processes(&pointer))
        let rows = try #require(pointer)
        defer { ms_free(rows) }
        return try #require(UnsafeBufferPointer(start: rows, count: count).first { $0.pid == getpid() }).cpu_ns
    }
    let old = try selfCPU()
    let start = ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - start < 0.15 { _ = ms_sysctl("hw.memsize") }
    let delta = try selfCPU() - old
    #expect(delta > 50_000_000)
    #expect(delta < 2_000_000_000)
}
