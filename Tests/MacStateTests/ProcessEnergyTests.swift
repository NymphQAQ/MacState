import Foundation
import Testing
@testable import MacState

private func counter(_ pid: Int32 = 1, _ energy: UInt64?, start: UInt64 = 10) -> ProcessEnergyCounter {
    ProcessEnergyCounter(pid: pid, start: start, energyNJ: energy)
}

@Test func powerEnergyUsesNanojouleDeltasIncludingValidZero() {
    let ledger = ProcessEnergyLedger()
    let baseline = ledger.sample([counter(1, 9_000_000_000), counter(2, 0), counter(3, nil)], elapsed: 0)
    #expect(baseline[1]?.power == nil && baseline[1]?.lifetimeEnergy == 9)
    #expect(baseline[3] == nil)
    let values = ledger.sample([counter(1, 15_000_000_000), counter(2, 0)], elapsed: 2)
    #expect(values[1]?.power == 3 && values[1]?.smoothedPower == 3)
    #expect(values[2]?.power == 0)
    // Subtract integer counters before Double conversion, preserving small
    // deltas even after an extremely long process lifetime.
    let large = UInt64.max - 1_000_000
    _ = ledger.sample([counter(4, large)], elapsed: 1)
    #expect(ledger.sample([counter(4, large + 1000)], elapsed: 1)[4]?.power == 0.000001)
}

@Test func powerEnergyRejectsPidReuseCounterResetLostDataAndSleep() {
    let ledger = ProcessEnergyLedger()
    _ = ledger.sample([counter(1, 1_000_000_000)], elapsed: 0)
    #expect(ledger.sample([counter(1, 3_000_000_000, start: 20)], elapsed: 1)[1]?.power == nil)
    #expect(ledger.sample([counter(1, 2_000_000_000, start: 20)], elapsed: 1)[1]?.power == nil)
    #expect(ledger.sample([counter(1, 4_000_000_000, start: 20)], elapsed: 1)[1]?.power == 2)
    #expect(ledger.sample([counter(1, nil)], elapsed: 1).isEmpty)
    #expect(ledger.sample([counter(1, 5_000_000_000)], elapsed: 1)[1]?.power == nil)
    #expect(ledger.sample([counter(1, 100_000_000_000)], elapsed: 60)[1]?.power == nil)
    #expect(ledger.sample([counter(1, 102_000_000_000)], elapsed: 1)[1]?.power == 2)
    #expect(ledger.sample([counter(1, 103_000_000_000)], elapsed: .nan)[1]?.power == nil)
    _ = ledger.sample([], elapsed: 1)
    #expect(ledger.sample([counter(1, 104_000_000_000)], elapsed: 1)[1]?.power == nil)
}

@Test func powerSmoothingHasThirtySecondTimeConstantIndependentOfInterval() {
    func result(interval: Double) -> Double {
        let ledger = ProcessEnergyLedger()
        var energy: UInt64 = 0
        _ = ledger.sample([counter(1, energy)], elapsed: 0)
        _ = ledger.sample([counter(1, energy)], elapsed: 1) // establish 0 W
        var last: Double = 0
        for _ in 0..<Int(30 / interval) {
            energy += UInt64(10e9 * interval)
            let reading = ledger.sample([counter(1, energy)], elapsed: interval)[1]!
            #expect(reading.power == 10)
            last = reading.smoothedPower!
        }
        return last
    }
    #expect(abs(result(interval: 1) - 10 * (1 - exp(-1))) < 1e-10)
    #expect(abs(result(interval: 1) - result(interval: 2)) < 1e-10)
}

@Test func rawProcessEnergyIsIndependentOfDevicePowerAndSmoothing() {
    let recorder = UsageRecorder()
    let app = UsageApplication(id: "app", name: "App")
    func reading(_ t: Double, watts: Double, interval: Double) -> UsageReading {
        UsageReading(timestamp: 100 + t, uptime: 200 + t, battery: nil, mode: .desktop,
                     power: 500, temperature: nil, application: nil,
                     applicationPowers: [UsageApplicationPower(application: app, power: watts, processCount: 2, measuredProcessCount: 2)],
                     powerInterval: interval)
    }
    recorder.record(reading(0, watts: 999, interval: 2))
    // Wall-clock collection duration varies; integrate the actual counter
    // interval, not the time between the resulting JSON snapshots.
    recorder.record(reading(2.1, watts: 5, interval: 2))
    recorder.record(reading(4.0, watts: 10, interval: 2))
    let stats = recorder.payload().selected!.applications["app"]!.attributed!
    #expect(stats.combinedEnergy == 30 && stats.combinedDuration == 4)
    #expect(stats.measuredProcessCount == 2 && stats.scoredProcessCount == nil)
    #expect(recorder.payload().selected!.energy == 2000) // independent device
}

@Test func oldScoreSessionsKeepTheirIdentityAndEnergyAfterMigration() throws {
    let recorder = UsageRecorder()
    recorder.record(UsageReading(timestamp: 10, uptime: 100, battery: nil, mode: .desktop,
                                 power: 30, temperature: nil, application: nil,
                                 applicationPowers: [UsageApplicationPower(application: UsageApplication(id: "app", name: "App"), power: 5, processCount: 1)]))
    recorder.record(UsageReading(timestamp: 20, uptime: 110, battery: nil, mode: .desktop,
                                 power: 30, temperature: nil, application: nil,
                                 applicationPowers: [UsageApplicationPower(application: UsageApplication(id: "app", name: "App"), power: 5, processCount: 1)]))
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(recorder.archive)) as? [String: Any])
    object["version"] = 3
    var sessions = try #require(object["sessions"] as? [[String: Any]])
    sessions[0]["applicationPowerVersion"] = 3; object["sessions"] = sessions
    let restored = UsageRecorder(archive: try JSONDecoder().decode(UsageArchive.self, from: JSONSerialization.data(withJSONObject: object)))
    restored.record(UsageReading(timestamp: 30, uptime: 120, battery: nil, mode: .desktop,
                                 power: 30, temperature: nil, application: nil))
    #expect(restored.archive.version == 5 && restored.archive.sessions.count == 2)
    #expect(restored.archive.sessions[0].applicationPowerVersion == 3)
    #expect(restored.archive.sessions[0].applications["app"]?.attributed?.combinedEnergy == 50)
    #expect(restored.archive.sessions[0].endedAt != nil)
    #expect(restored.archive.sessions[1].applicationPowerVersion == 5)
}
