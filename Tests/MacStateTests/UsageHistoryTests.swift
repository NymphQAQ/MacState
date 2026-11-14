import Foundation
import Testing
@testable import MacState

private func reading(_ t: Double, battery: Double? = 100, mode: UsagePowerMode = .battery,
                     power: Double? = 10, temperature: Double? = 40, app: String? = "A", uptime: Double? = nil) -> UsageReading {
    UsageReading(timestamp: 1_700_000_000 + t, uptime: uptime ?? t + 100,
                 battery: battery, mode: mode, power: power, temperature: temperature,
                 application: app.map { UsageApplication(id: $0, name: "应用 \($0)") })
}

@Test func usageWeightsPowerAndTemperatureByForegroundTime() {
    let recorder = UsageRecorder()
    recorder.record(reading(0, power: 10, temperature: 40))
    recorder.record(reading(10, power: 20, temperature: 60, app: "B"))
    recorder.record(reading(30, power: 30, temperature: 50, app: "B"))
    let session = recorder.payload().selected!
    #expect(session.activeDuration == 30)
    #expect(abs(session.averagePower! - 50.0 / 3) < 0.001)
    #expect(session.applications["A"]?.duration == 10)
    #expect(session.applications["A"]?.energy == 0) // whole-device watts never become application energy
    #expect(session.applications["A"]?.attributed == nil)
    #expect(session.applications["B"]?.duration == 20)
    #expect(session.applications["B"]?.temperatureTotal == 1200)
    #expect(session.applications["B"]?.maximumTemperature == 60)
    #expect(session.segments.count == 2)
}

@Test func usageAttributesCurrentIntervalToBackgroundApplicationsAndKeepsCoverage() {
    let recorder = UsageRecorder()
    func sample(_ t: Double, power: Double?, interval: Double = 10) -> UsageReading {
        UsageReading(timestamp: 1_700_000_000 + t, uptime: 100 + t, battery: 80, mode: .plugged,
                     power: 99, temperature: 40, application: UsageApplication(id: "foreground", name: "前台"),
                     applicationPowers: [UsageApplicationPower(application: UsageApplication(id: "background", name: "后台"), power: power, processCount: 3)], powerInterval: interval)
    }
    recorder.record(sample(0, power: 200)) // baseline, never integrated
    recorder.record(sample(10, power: 5))
    recorder.record(sample(30, power: 5, interval: 20))
    recorder.record(sample(40, power: nil))
    let stats = recorder.payload().selected!.applications["background"]!
    #expect(stats.duration == 0)
    #expect(stats.energy == 0)
    #expect(stats.attributed?.observedDuration == 40)
    #expect(stats.attributed?.cpuEnergy == 0)
    #expect(stats.attributed?.gpuEnergy == 0)
    #expect(stats.attributed?.combinedEnergy == 150)
    #expect(stats.attributed?.combinedDuration == 30)
    #expect(stats.attributed?.cpuDuration == 0)
    #expect(stats.attributed?.gpuDuration == 0)
    #expect(recorder.payload().averagePower == 99)
    recorder.record(sample(50, power: 200, interval: 20)) // stale counter window
    #expect(recorder.payload().selected!.applications["background"]!.attributed?.observedDuration == 40)
    recorder.interrupt()
    recorder.record(sample(5000, power: 200))
    #expect(recorder.payload().selected!.applications["background"]!.attributed?.combinedEnergy == 150)
}

@Test func usageMigratesLegacyHistoryWithoutRelabelingWholeDeviceEnergy() throws {
    let recorder = UsageRecorder()
    recorder.record(reading(0)); recorder.record(reading(10))
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(recorder.archive)) as? [String: Any])
    object["version"] = 1
    var sessions = try #require(object["sessions"] as? [[String: Any]])
    sessions[0].removeValue(forKey: "applicationPowerVersion")
    var apps = try #require(sessions[0]["applications"] as? [String: [String: Any]])
    apps["A"]?["energy"] = 100; apps["A"]?["powerDuration"] = 10
    sessions[0]["applications"] = apps; object["sessions"] = sessions
    let restored = UsageRecorder(archive: try JSONDecoder().decode(UsageArchive.self, from: JSONSerialization.data(withJSONObject: object)))
    #expect(restored.archive.sessions[0].applicationPowerVersion == nil)
    restored.record(reading(20))
    #expect(restored.archive.version == 5)
    #expect(restored.archive.sessions.count == 2)
    #expect(restored.archive.sessions[0].applications["A"]?.energy == 100)
    #expect(restored.archive.sessions[0].applications["A"]?.attributed == nil)
    #expect(restored.archive.sessions[0].endedAt != nil)
    #expect(restored.payload().selected?.applicationPowerVersion == 5)
}

@Test func usageExcludesSleepRestartAndMissingMeasurementIntervals() throws {
    let recorder = UsageRecorder()
    recorder.record(reading(0, power: nil, temperature: nil))
    recorder.record(reading(10, power: 0, temperature: 40))
    recorder.interrupt()
    recorder.record(reading(3610, battery: 80))
    recorder.record(reading(3620, battery: 80))
    let saved = try JSONDecoder().decode(UsageArchive.self, from: JSONEncoder().encode(recorder.archive))
    let restored = UsageRecorder(archive: saved)
    restored.record(reading(7220, battery: 70))
    restored.record(reading(7230, battery: 70))
    let session = restored.payload().selected!
    #expect(session.activeDuration == 30)
    #expect(session.powerDuration == 20)
    #expect(session.trackedBatteryDrop == 0)
    #expect(session.points.filter(\.gap).count == 2)
    #expect(session.theoreticalRuntime == nil)
}

@Test func usageDetectsSamplingGapsWithoutSleepNotifications() {
    let recorder = UsageRecorder()
    recorder.record(reading(0))
    recorder.record(reading(10, battery: 99, uptime: 100)) // uptime did not advance
    recorder.record(reading(80, battery: 90, uptime: 180)) // sampling gap
    recorder.record(reading(90, battery: 89, uptime: 190))
    #expect(recorder.payload().selected?.activeDuration == 10)
    #expect(recorder.payload().selected?.trackedBatteryDrop == 1)
}

@Test func usageSplitsPowerModesAndEstimatesOnlyObservedDischarge() {
    let recorder = UsageRecorder()
    for i in 0...30 { recorder.record(reading(Double(i * 10), battery: 100 - Double(i) / 10)) }
    #expect(recorder.payload().theoreticalRuntime == 10_000)
    recorder.record(reading(310, battery: 97, mode: .charging))
    recorder.record(reading(320, battery: 98, mode: .charging))
    #expect(recorder.archive.sessions.count == 2)
    #expect(recorder.archive.sessions[0].endedAt != nil)
    #expect(recorder.payload().selected?.activeDuration == 10)
    #expect(recorder.payload().theoreticalRuntime == nil)
}

@Test func usageDoesNotMixPowerSourcesOrFillUnknownValues() {
    let recorder = UsageRecorder()
    recorder.record(reading(0, power: 0))
    recorder.record(reading(5, power: 0))
    recorder.record(UsageReading(timestamp: 1_700_000_010, uptime: 110, battery: 99, mode: .battery,
                                 power: 50, powerSource: "另一种测量", temperature: .nan, application: nil))
    recorder.record(reading(20, power: nil))
    #expect(recorder.archive.sessions.count == 2)
    #expect(recorder.archive.sessions[0].averagePower == 0)
    #expect(recorder.payload().averagePower == 50)
    #expect(recorder.payload().selected?.powerDuration == 10)
    #expect(recorder.payload().selected?.points.last?.power == nil)
    #expect(reading(0, battery: -1, power: .infinity).battery == nil)
}

@Test func usageKeepsItsMeasurementSourceWhenAnotherSensorBecomesAvailable() {
    func snapshot(_ t: Double, system: Double?) -> Snapshot {
        Snapshot(timestamp: 1_700_000_000 + t, device: [:], metrics: [
            Metric(id: "battery", title: "", value: 80, unit: "%", source: ""),
            Metric(id: "batteryState", title: "", value: 0, unit: "powerState", source: ""),
            Metric(id: "systemPower", title: "", value: system, unit: "W", source: ""),
            Metric(id: "batteryPower", title: "", value: 5, unit: "W", source: ""),
            Metric(id: "uptime", title: "", value: t + 100, unit: "s", source: "")
        ], cores: [], processes: [], networks: [], volumes: [], sensors: [], collectionMS: 0, issues: [])
    }
    let recorder = UsageRecorder()
    recorder.record(UsageReading(snapshot: snapshot(0, system: nil), application: nil))
    recorder.record(UsageReading(snapshot: snapshot(10, system: 20), application: nil, preferredPowerSource: recorder.currentPowerSource))
    #expect(recorder.payload().averagePower == 5)
    #expect(recorder.payload().selected?.points.last?.power == 5)
    #expect(recorder.currentPowerSource == UsageReading.batteryPowerSource)
}

@Test func usagePersistsHistoryAndDeletingCurrentStartsFresh() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("usage.json")
    let recorder = UsageRecorder()
    recorder.record(reading(0)); recorder.record(reading(10))
    try UsagePersistence.save(recorder.archive, to: url)
    let restored = UsageRecorder(archive: try UsagePersistence.load(from: url))
    #expect(restored.payload().selected?.activeDuration == 10)
    let id = restored.archive.activeSessionID!
    #expect(restored.deleteSession(id: id))
    #expect(!restored.deleteSession(id: id))
    restored.record(reading(20))
    #expect(restored.archive.activeSessionID != id)
    #expect(restored.payload().selected?.activeDuration == 0)
    try Data("invalid".utf8).write(to: url)
    #expect(throws: (any Error).self) { try UsagePersistence.load(from: url) }
}

@Test func usagePersistenceAcceptsValidArchivesAboveTheLegacySizeLimit() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("usage.json")
    var data = try JSONEncoder().encode(UsageArchive())
    data.append(Data(repeating: 0x20, count: 32_000_000))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: url)
    #expect(try UsagePersistence.load(from: url).sessions.isEmpty)
}

@Test func usagePersistenceSplitsProcessRowsAndRestoresEachApplication() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("usage.json")
    var session = UsageSession(id: "split-session", startedAt: 1, updatedAt: 2, mode: .battery,
                               hasBattery: true, startBattery: 100, endBattery: 99)
    session.applications["a-empty"] = UsageApplicationStats(id: "a-empty", name: "Empty")
    var processes: [String: UsageProcessStats] = [:]
    for index in 0..<UsagePersistence.maximumProcessRowsPerShard + 1 {
        let id = "process-\(index)"
        processes[id] = UsageProcessStats(id: id, pid: Int32(index), parent: 0, name: id, path: "/\(id)",
                                          isMain: false, firstSeen: 1, lastSeen: 2, status: "ok")
    }
    session.applications["z-processes"] = UsageApplicationStats(id: "z-processes", name: "Processes", processes: processes)
    let archive = UsageArchive(activeSessionID: session.id, sessions: [session])

    try UsagePersistence.save(archive, to: url)
    try UsagePersistence.save(archive, to: url)
    let files = try FileManager.default.contentsOfDirectory(atPath: UsagePersistence.partsDirectory(for: url).path)
    #expect(files.count == 3) // Session record plus two process shards; no shard for the empty app.
    let restored = try UsagePersistence.load(from: url)
    #expect(restored.sessions.first?.applications["z-processes"]?.processes?.count == processes.count)
    #expect(restored.sessions.first?.applications["a-empty"]?.processes == nil)
}

@Test func usagePersistenceMigratesLegacyFileOnSave() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("usage.json")
    let session = UsageSession(id: "legacy-session", startedAt: 1, updatedAt: 2, mode: .battery,
                               hasBattery: true, startBattery: 100, endBattery: 99)
    let legacy = UsageArchive(activeSessionID: session.id, sessions: [session])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(legacy).write(to: url)

    let loaded = try UsagePersistence.load(from: url)
    try UsagePersistence.save(loaded, to: url)
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(manifest?["format"] as? String == "MacStateUsageSessionsV1")
    #expect(try UsagePersistence.load(from: url).sessions.map(\.id) == [session.id])
}

@Test func usageBoundsLongHistoriesAndKeepsRecentEndpoints() {
    let recorder = UsageRecorder()
    for i in 0...30_000 { recorder.record(reading(Double(i * 2), battery: 80)) }
    let session = recorder.payload().selected!
    #expect(session.points.count <= UsageRecorder.maximumPoints)
    #expect(session.points.count > 100)
    #expect(session.points.first?.timestamp == 1_700_000_000)
    #expect(session.points.last?.timestamp == 1_700_060_000)
    #expect(session.activeDuration == 60_000)
    for i in 1...35 {
        recorder.closeCurrent(); recorder.record(reading(60_000 + Double(i)))
    }
    #expect(recorder.archive.sessions.count == UsageRecorder.maximumSessions)
    #expect(recorder.payload().sessions.first?.active == true)
}
