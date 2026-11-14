import Foundation
import Testing
@testable import MacState

private func usageProcess(_ pid: Int32, parent: Int32 = 1, start: UInt64? = nil, power: Double? = nil, name: String = "Worker") -> ProcessRow {
    ProcessRow(pid: pid, parent: parent, name: name, path: "/Apps/Test.app/Contents/\(pid)", user: "test", threads: 1,
               cpu: 0, memory: 0, resident: 0, readRate: 0, writeRate: 0, wakeups: 0,
               power: power, startIdentity: start, status: "fixture")
}

private func groupedReading(_ t: Double, _ processes: [ProcessRow]) -> UsageReading {
    let root = UsageAppRoot(pid: 100, bundlePath: "/Apps/Test.app", application: UsageApplication(id: "test", name: "Test"))
    return UsageReading(timestamp: 1000 + t, uptime: 2000 + t, battery: nil, mode: .desktop,
                        power: 100, temperature: nil, application: nil,
                        applicationPowers: ApplicationPowerGrouping.group(processes, roots: [root]), powerInterval: 2)
}

@Test func processHistoryKeepsExitedChildrenAndSeparatesReusedPids() throws {
    let recorder = UsageRecorder()
    func rows(_ helper: Double?, generation: UInt64 = 2000, includeHelper: Bool = true) -> [ProcessRow] {
        [usageProcess(100, start: 1000, power: 2, name: "Main"),
         usageProcess(102, parent: 100, start: 3000, power: nil, name: "Restricted")]
        + (includeHelper ? [usageProcess(101, parent: 100, start: generation, power: helper)] : [])
    }
    recorder.record(groupedReading(0, rows(nil)))
    recorder.record(groupedReading(2, rows(3)))
    recorder.record(groupedReading(4, rows(0)))
    recorder.record(groupedReading(6, rows(nil, includeHelper: false)))
    recorder.record(groupedReading(8, rows(4, generation: 4000)))
    let stats = try #require(recorder.payload().selected?.applications["test"])
    let records = try #require(stats.processes)
    #expect(records.count == 4)
    let main = try #require(records["100:bsd:1000"])
    let first = try #require(records["101:bsd:2000"]), second = try #require(records["101:bsd:4000"])
    #expect(main.isMain && main.energy == 16 && main.powerDuration == 8)
    #expect(!first.isMain && first.parentID == main.id)
    #expect(first.energy == 6 && first.powerDuration == 4 && first.observedDuration == 4 && first.lastPower == 0)
    #expect(first.lastSeen == 1004 && second.firstSeen == 1008 && second.energy == 8)
    #expect(records["102:bsd:3000"]?.powerDuration == 0 && records["102:bsd:3000"]?.lastPower == nil)
    #expect(stats.attributed?.combinedDuration == 0) // partial app, independent readable children
    let saved = try JSONDecoder().decode(UsageArchive.self, from: JSONEncoder().encode(recorder.archive))
    #expect(saved.sessions[0].applications["test"]?.processes?[first.id]?.energy == 6)
    #expect(saved.sessions[0].applications["test"]?.processes?[second.id]?.energy == 8)
}

@Test func unknownProcessIdentityNeverMergesAcrossAbsenceOrRecorderRestart() throws {
    let recorder = UsageRecorder()
    let worker = usageProcess(101, parent: 100, power: nil)
    recorder.record(groupedReading(0, [worker])); recorder.record(groupedReading(2, [worker]))
    #expect(recorder.payload().selected?.applications["test"]?.processes?.count == 1)
    recorder.record(groupedReading(4, [])); recorder.record(groupedReading(6, [worker]))
    #expect(recorder.payload().selected?.applications["test"]?.processes?.count == 2)
    let restored = UsageRecorder(archive: try JSONDecoder().decode(UsageArchive.self, from: JSONEncoder().encode(recorder.archive)))
    restored.record(groupedReading(8, [worker]))
    #expect(restored.payload().selected?.applications["test"]?.processes?.count == 3)
}

@Test func processHistoryExcludesSleepAndRejectsStaleEnergyIntervals() throws {
    let recorder = UsageRecorder()
    let rows = [usageProcess(100, start: 1000, power: 1)]
    recorder.record(groupedReading(0, rows)); recorder.record(groupedReading(2, rows))
    recorder.interrupt(); recorder.record(groupedReading(4000, rows))
    recorder.record(groupedReading(4002, rows))
    let stats = try #require(recorder.payload().selected?.applications["test"]?.processes?["100:bsd:1000"])
    #expect(stats.energy == 4 && stats.powerDuration == 4 && stats.observedDuration == 4)
    recorder.record(groupedReading(4012, rows)) // 2 s counter / 10 s wall interval
    let after = recorder.payload().selected?.applications["test"]?.processes?["100:bsd:1000"]
    #expect(after?.energy == 4 && after?.powerDuration == 4 && after?.observedDuration == 14 && after?.lastPower == nil)
}

@Test func groupingRetainsAllAncestryAndMainRolesForProcessDetails() throws {
    let root = UsageAppRoot(pid: 100, bundlePath: "/Apps/Test.app", application: .init(id: "test", name: "Test"))
    var child = usageProcess(102, parent: 101, start: 3000, power: nil)
    child = ProcessRow(pid: child.pid, parent: child.parent, name: child.name, path: "/usr/bin/detached", user: child.user,
        threads: child.threads, cpu: nil, memory: nil, resident: nil, readRate: nil, writeRate: nil, wakeups: nil,
        power: nil, startIdentity: 3000, status: "restricted")
    let rows = [usageProcess(100, start: 1000, power: 2), usageProcess(101, parent: 100, start: 2000, power: 3), child]
    let group = try #require(ApplicationPowerGrouping.group(rows, roots: [root]).first { $0.application.id == "test" })
    #expect(group.processes?.count == 3 && group.processCount == 3)
    #expect(group.processes?.filter(\.isMain).map(\.pid) == [100])
    #expect(group.processes?.first { $0.pid == 102 }?.parent == 101)
    #expect(group.processes?.first { $0.pid == 102 }?.power == nil && group.power == nil)
}
