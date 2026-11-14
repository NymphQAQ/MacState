import Foundation

struct ProcessEnergyCounter {
    let pid: Int32
    let start: UInt64
    let energyNJ: UInt64?
}

struct ProcessEnergyReading {
    let power: Double?
    let smoothedPower: Double?
    let lifetimeEnergy: Double
}

struct ProcessPowerSummary: Codable {
    let measuredProcesses: Int
    let totalProcesses: Int
    let measuredPower: Double?
    var source = "power · proc_pid_rusage · ri_energy_nj"
    var gpuDevicePower: Double? = nil
    var gpuAttributedPower: Double? = nil
    var gpuUnattributedPower: Double? = nil
    var gpuStatus: String? = nil
}

/// power's nJ delta / elapsed time and 30-second EWMA, with generation checks
/// so PID reuse, counter reset and sleep never inherit another interval.
final class ProcessEnergyLedger {
    private var previous: [Int32: ProcessEnergyCounter] = [:]
    private var averages: [Int32: Double] = [:]

    func sample(_ counters: [ProcessEnergyCounter], elapsed: Double) -> [Int32: ProcessEnergyReading] {
        let validInterval = elapsed.isFinite && elapsed > 0 && elapsed <= 30
        let alpha = validInterval ? 1 - exp(-elapsed / 30) : 1
        var readings: [Int32: ProcessEnergyReading] = [:]
        var next: [Int32: ProcessEnergyCounter] = [:]
        var nextAverages: [Int32: Double] = [:]
        for counter in counters {
            guard counter.start > 0, let energy = counter.energyNJ else { continue }
            next[counter.pid] = counter
            var watts: Double?, smoothed: Double?
            if validInterval, let old = previous[counter.pid], old.start == counter.start,
               let before = old.energyNJ, energy >= before {
                watts = Double(energy - before) / 1e9 / elapsed
                if let watts {
                    let average = averages[counter.pid] ?? watts
                    smoothed = average + alpha * (watts - average)
                    nextAverages[counter.pid] = smoothed
                }
            }
            readings[counter.pid] = ProcessEnergyReading(power: watts, smoothedPower: smoothed,
                                                        lifetimeEnergy: Double(energy) / 1e9)
        }
        previous = next; averages = nextAverages
        return readings
    }

    static func apply(_ readings: [Int32: ProcessEnergyReading], to rows: inout [ProcessRow]) -> ProcessPowerSummary {
        for i in rows.indices {
            let value = readings[rows[i].pid]
            rows[i].power = value?.power
            rows[i].smoothedPower = value?.smoothedPower
            rows[i].lifetimeEnergy = value?.lifetimeEnergy
            rows[i].cpuPower = nil; rows[i].gpuPower = nil
            rows[i].kernelPower = nil; rows[i].energyImpact = nil
        }
        let values = rows.compactMap(\.power)
        return ProcessPowerSummary(measuredProcesses: values.count, totalProcesses: rows.count,
                                   measuredPower: values.isEmpty ? nil : values.reduce(0, +))
    }
}
