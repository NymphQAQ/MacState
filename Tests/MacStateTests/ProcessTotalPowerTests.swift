import Foundation
import Testing
@testable import MacState

private func row(_ pid: Int32) -> ProcessRow {
    ProcessRow(pid: pid, parent: 1, name: "p\(pid)", path: "", user: "test", threads: 1,
               cpu: 0, memory: 0, resident: 0, readRate: 0, writeRate: 0, wakeups: 0, power: nil, status: "test")
}
private let cpuReadings: [Int32: ProcessEnergyReading] = [1: .init(power: 0.05, smoothedPower: 0.05, lifetimeEnergy: 10),
                                                        2: .init(power: 2, smoothedPower: 2, lifetimeEnergy: 10)]
private func frame(complete: Bool = true, orphan: Bool = false) -> GPUTimeInterval {
    GPUTimeInterval(percentages: [1: 75, 2: 25, 3: 0], nanoseconds: orphan ? [1: 1.5e9, 2: 0.5e9, 99: 2e9] : [1: 1.5e9, 2: 0.5e9],
                    complete: complete, start: 10, end: 12)
}

@Test func totalPowerIncludesMetalEnergyInsteadOfOnlyCpuCounter() {
    var rows = [row(1), row(2)]
    let summary = ProcessTotalPower().apply(cpu: cpuReadings, gpu: frame(), energy: .init(joules: 28, start: 10, end: 12), start: 10, end: 12, to: &rows)
    #expect(abs((rows[0].power ?? -1) - 10.55) < 1e-10)
    #expect(abs((rows[1].power ?? -1) - 5.5) < 1e-10)
    #expect(abs((summary.measuredPower ?? -1) - 16.05) < 1e-10)
}

@Test func orphanGpuTimeDoesNotInflateVisibleAppPower() {
    var rows = [row(1), row(2)]
    let summary = ProcessTotalPower().apply(cpu: cpuReadings, gpu: frame(orphan: true), energy: .init(joules: 28, start: 10, end: 12), start: 10, end: 12, to: &rows)
    #expect(abs((rows[0].power ?? -1) - 5.3) < 1e-10)
    #expect(abs((rows[1].power ?? -1) - 3.75) < 1e-10)
    #expect(summary.gpuUnattributedPower == 7)
}

@Test func missingGpuEnergyOrUnstableClientCannotMasqueradeAsAppTotal() {
    for energy in [GPUEnergyInterval(joules: nil, start: 10, end: 12), .init(joules: 28, start: 11, end: 13)] {
        var rows = [row(1), row(2), row(3)]
        let cpu = cpuReadings.merging([3: .init(power: 1, smoothedPower: 1, lifetimeEnergy: 1)]) { a, _ in a }
        _ = ProcessTotalPower().apply(cpu: cpu, gpu: frame(), energy: energy, start: 10, end: 12, to: &rows)
        #expect(rows[0].power == nil && rows[1].power == nil)
        #expect(rows[2].power == 1) // stable absence of GPU work is known zero
    }
    var rows = [row(1), row(2)]
    _ = ProcessTotalPower().apply(cpu: cpuReadings, gpu: frame(complete: false), energy: .init(joules: 28, start: 10, end: 12), start: 10, end: 12, to: &rows)
    #expect(rows.allSatisfy { $0.power == nil })
}

@Test func incompleteCpuDoesNotBecomeTotalAndEnergyIsIntegratedOnCounterWindow() {
    var rows = [row(1), row(2)]
    _ = ProcessTotalPower().apply(cpu: [1: cpuReadings[1]!], gpu: frame(), energy: .init(joules: 28, start: 10.02, end: 12.02), start: 10, end: 12, to: &rows)
    #expect(rows[1].power == nil)
    #expect(abs((rows[0].power ?? -1) * 2 - 21.1) < 1e-10)
}

@Test func gpuIntervalCoverageRejectsClientChurnAndKeepsUnlistedClients() {
    let tracker = ProcessGPUCounters()
    let first = GPUCounterSnapshot(available: true, clients: [.init(registryID: 1, pid: 1, times: [0]), .init(registryID: 99, pid: 99, times: [0])], timestamp: 10)
    _ = tracker.interval(first, identities: [1: 1], elapsed: 0)
    let second = GPUCounterSnapshot(available: true, clients: [.init(registryID: 1, pid: 1, times: [1_000_000_000]), .init(registryID: 99, pid: 99, times: [2_000_000_000])], timestamp: 12)
    let measured = tracker.interval(second, identities: [1: 1], elapsed: 99)
    #expect(measured.complete && measured.nanoseconds[99] == 2e9 && measured.percentages[1] == 50)
    let removed = tracker.interval(.init(available: true, clients: [second.clients[0]], timestamp: 14), identities: [1: 1], elapsed: 2)
    #expect(!removed.complete)
    let multi = tracker.interval(.init(available: true, clients: [second.clients[0]], timestamp: 16, deviceCount: 2), identities: [1: 1], elapsed: 2)
    #expect(!multi.complete && multi.percentages.isEmpty)
}

@Test func cpuOnlyHistoryMigrationPreservesEnergyAndStartsNewAlgorithm() throws {
    let recorder = UsageRecorder()
    let reading = UsageReading(timestamp: 100, uptime: 200, battery: nil, mode: .desktop, power: 30,
                               temperature: nil, application: nil,
                               applicationPowers: [.init(application: .init(id: "app", name: "App"), power: 5, processCount: 1)])
    recorder.record(reading)
    recorder.record(.init(timestamp: 102, uptime: 202, battery: nil, mode: .desktop, power: 30,
                         temperature: nil, application: nil, applicationPowers: reading.applicationPowers))
    var archive = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(recorder.archive)) as? [String: Any])
    archive["version"] = 4
    var sessions = try #require(archive["sessions"] as? [[String: Any]])
    sessions[0]["applicationPowerVersion"] = 4; archive["sessions"] = sessions
    let restored = UsageRecorder(archive: try JSONDecoder().decode(UsageArchive.self, from: JSONSerialization.data(withJSONObject: archive)))
    restored.record(.init(timestamp: 104, uptime: 204, battery: nil, mode: .desktop, power: 30, temperature: nil, application: nil))
    #expect(restored.archive.version == 5 && restored.archive.sessions.count == 2)
    #expect(restored.archive.sessions[0].applicationPowerVersion == 4)
    #expect(restored.archive.sessions[0].applications["app"]?.attributed?.combinedEnergy == 10)
    #expect(restored.archive.sessions[1].applicationPowerVersion == 5)
}
