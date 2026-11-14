import Foundation
import IOKit
import SystemBridge

struct GPUResidency {
    let name: String
    let time: Double
}

enum GPUFrequencyMath {
    static func average(states: [GPUResidency], frequencies: [Double]) -> (frequency: Double?, active: Double?) {
        guard !states.isEmpty, states.allSatisfy({ $0.time.isFinite && $0.time >= 0 }),
              !frequencies.isEmpty, frequencies.allSatisfy({ $0.isFinite && $0 > 0 }) else { return (nil, nil) }
        let active = states.filter { !["OFF", "IDLE", "DOWN"].contains($0.name.uppercased()) }
        // Drivers reserve unused trailing states (e.g. P7–P15 on M1 Pro).
        // They can be ignored only while their observed residency is zero.
        guard active.count >= frequencies.count, active.dropFirst(frequencies.count).allSatisfy({ $0.time == 0 }),
              let firstIndex = active.first.flatMap({ Int($0.name.dropFirst()) }), [0, 1].contains(firstIndex),
              active.enumerated().allSatisfy({ i, state in
                  ["P", "V"].contains(String(state.name.prefix(1)).uppercased()) && Int(state.name.dropFirst()) == i + firstIndex
              }) else { return (nil, nil) }
        let total = states.map(\.time).reduce(0, +), busy = active.map(\.time).reduce(0, +)
        guard total > 0 else { return (nil, nil) }
        let frequency = busy > 0 ? zip(active, frequencies).reduce(0) { $0 + $1.0.time * $1.1 } / busy : nil
        return (frequency, busy / total * 100)
    }
}

final class GPUHardwareSampler {
    private let context = ms_ioreport_create()
    private let frequencies = GPUHardwareSampler.frequencyTable()
    private(set) var energyInterval: GPUEnergyInterval = .init(joules: nil, start: 0, end: 0)
    private var previousTime: Double?
    deinit { ms_ioreport_destroy(context) }

    func sample() -> [Metric] {
        let began = ProcessInfo.processInfo.systemUptime
        var energy = MSIOEnergy(), raw = [MSGPUState](repeating: MSGPUState(), count: 64)
        let count = Int(ms_ioreport_sample(context, &energy, &raw, 64))
        let now = (began + ProcessInfo.processInfo.systemUptime) / 2
        energyInterval = GPUEnergyInterval(joules: energy.gpu_valid != 0 ? energy.gpu_watts * energy.elapsed : nil,
                                          start: previousTime ?? now, end: now)
        previousTime = now
        let states = raw.prefix(max(0, count)).map { GPUResidency(name: cString($0.name), time: Double($0.residency)) }
        let frequency = GPUFrequencyMath.average(states: states, frequencies: frequencies)
        return [
            Metric(id: "gpuEnergyPower", title: "GPU 能量模型功耗", value: energy.gpu_valid != 0 ? energy.gpu_watts : nil, unit: "W", source: "IOReport Energy Model", detail: "GPU Energy 能量差 / 采样秒数；驱动硬件模型，非插座测量。", kind: "estimated"),
            Metric(id: "anePower", title: "ANE 功耗", value: energy.ane_valid != 0 ? energy.ane_watts : nil, unit: "W", source: "IOReport Energy Model", detail: "ANE Energy 能量差 / 采样秒数；不计入应用 CPU+GPU 功耗。", kind: "estimated"),
            Metric(id: "gpuActive", title: "GPU 活跃驻留", value: frequency.active, unit: "%", source: "IOReport GPU Stats", detail: "采样期间 GPU 活跃档位驻留比例，区别于设备忙碌率。"),
            Metric(id: "gpuResidencyFrequency", title: "GPU 活跃平均频率", value: frequency.frequency, unit: "MHz", source: "IOReport GPU Stats", detail: "根据 DVFS 频率表按活跃档位驻留时间加权；空闲或档位映射不明确时不提供。")
        ]
    }

    static func frequencyTable() -> [Double] {
        for values in Hardware.registry("AppleARMIODevice") {
            guard let data = values["voltage-states9"] as? Data, !data.isEmpty, data.count % 8 == 0, data.count <= 512 else { continue }
            let bytes = [UInt8](data)
            let freqs: [Double] = stride(from: 0, to: bytes.count, by: 8).map { i -> Double in
                let low = UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
                let high = (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
                return Double(low | high) / 1e6
            }.filter { $0 > 0 }
            if !freqs.isEmpty, freqs.allSatisfy({ $0 <= 10_000 }), zip(freqs.dropFirst(), freqs).allSatisfy({ $0 >= $1 }) { return freqs }
        }
        return []
    }
}
