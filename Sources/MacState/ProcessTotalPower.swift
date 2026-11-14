import Foundation

struct GPUEnergyInterval {
    let joules: Double?
    let start: Double
    let end: Double
}

final class ProcessTotalPower {
    private var averages: [Int32: Double] = [:]

    func apply(cpu: [Int32: ProcessEnergyReading], gpu: GPUTimeInterval, energy: GPUEnergyInterval,
               start: Double, end: Double, to rows: inout [ProcessRow]) -> ProcessPowerSummary {
        let elapsed = end - start
        let validInterval = elapsed.isFinite && elapsed > 0 && elapsed <= 30
        // Compare boundaries, not just duration: equally long shifted windows
        // do not measure the same work.
        let tolerance = max(0.03, min(0.1, elapsed * 0.05))
        func aligned(_ a: Double?, _ b: Double?) -> Bool {
            guard validInterval, let a, let b, a.isFinite, b.isFinite, b > a else { return false }
            return abs(a - start) <= tolerance && abs(b - end) <= tolerance
        }
        let validEnergy = energy.joules.flatMap { $0.isFinite && $0 >= 0 && aligned(energy.start, energy.end) ? $0 : nil }
        let validTimes = gpu.nanoseconds.values.allSatisfy { $0.isFinite && $0 >= 0 }
        let totalTime = gpu.nanoseconds.values.reduce(0, +)
        let canAttribute = gpu.complete && validTimes && aligned(gpu.start, gpu.end) && validEnergy != nil && totalTime.isFinite && totalTime > 0
        let reason = canAttribute ? "GPU 能量按完整驱动客户端执行时间归属（估算）" : !gpu.complete ? "GPU 客户端变化、计数器缺失或多 GPU 设备未支持，等待完整区间" : validEnergy == nil || !aligned(gpu.start, gpu.end) ? "GPU 能量缺失或采样窗口未对齐" : "未观测到 GPU 执行时间；设备剩余能量保留为未归属"
        let alpha = validInterval ? 1 - exp(-elapsed / 30) : 1
        var nextAverages: [Int32: Double] = [:]
        var attributedGPU = 0.0
        for i in rows.indices {
            let pid = rows[i].pid, reading = cpu[pid]
            let cpuWatts = reading?.power.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let gpuRate = gpu.percentages[pid]
            var gpuWatts: Double?
            if validInterval, gpuRate == 0 {
                gpuWatts = 0 // stable counters confirm no observed work
            } else if validInterval, gpuRate != nil, canAttribute, let joules = validEnergy, let time = gpu.nanoseconds[pid] {
                // Divide by the CPU interval so combined W integrates back to
                // the CPU counter delta plus the attributed GPU joules.
                gpuWatts = joules * (time / totalTime) / elapsed
            }
            rows[i].cpuPower = cpuWatts; rows[i].gpuPower = gpuWatts
            rows[i].kernelPower = nil; rows[i].energyImpact = nil
            rows[i].lifetimeEnergy = reading?.lifetimeEnergy // CPU only
            rows[i].power = nil; rows[i].smoothedPower = nil
            rows[i].powerStatus = cpuWatts == nil ? "CPU 能量计数缺失，不能给出应用合计" : gpuWatts == nil ? reason : "CPU 内核能量 + GPU 执行时间归属；不含共享硬件静态及外设开销"
            if let cpuWatts, let gpuWatts, validInterval {
                let watts = cpuWatts + gpuWatts
                rows[i].power = watts
                let prior = averages[pid] ?? watts
                let smoothed = prior + alpha * (watts - prior)
                rows[i].smoothedPower = smoothed; nextAverages[pid] = smoothed
                attributedGPU += gpuWatts
            }
        }
        averages = nextAverages
        let values = rows.compactMap(\.power)
        var summary = ProcessPowerSummary(measuredProcesses: values.count, totalProcesses: rows.count,
                                          measuredPower: values.isEmpty ? nil : values.reduce(0, +))
        summary.source = "CPU 内核能量 + GPU 执行时间归属"
        summary.gpuDevicePower = validEnergy.map { $0 / elapsed }
        summary.gpuAttributedPower = validEnergy.map { _ in attributedGPU }
        summary.gpuUnattributedPower = validEnergy.map { max(0, $0 / elapsed - attributedGPU) }
        summary.gpuStatus = reason
        return summary
    }
}
