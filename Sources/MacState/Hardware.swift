import Foundation
import IOKit
import IOKit.ps
import Metal
import SystemBridge

func cString<T>(_ value: T) -> String {
    var copy = value
    return withUnsafePointer(to: &copy) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
    }
}

enum Hardware {
    static func sysString(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "未知" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return "未知" }
        return String(cString: buffer)
    }
    static func device() -> [String: String] {
        ["model": sysString("hw.model"), "chip": sysString("machdep.cpu.brand_string"),
         "os": ProcessInfo.processInfo.operatingSystemVersionString,
         "cores": String(ProcessInfo.processInfo.processorCount),
         "performanceCores": String(ms_sysctl("hw.perflevel0.physicalcpu")),
         "efficiencyCores": String(ms_sysctl("hw.perflevel1.physicalcpu")),
         "gpu": MTLCreateSystemDefaultDevice()?.name ?? "不可用",
         "hostname": ProcessInfo.processInfo.hostName]
    }
    static func registry(_ serviceClass: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let values = properties?.takeRetainedValue() as? [String: Any] { result.append(values) }
        }
        return result
    }
    static func gpu() -> [Metric] {
        let stats = registry("IOAccelerator").compactMap { $0["PerformanceStatistics"] as? [String: Any] }
        return gpuMetrics(stats)
    }
    static func gpuMetrics(_ stats: [[String: Any]]) -> [Metric] {
        func number(_ keys: [String]) -> Double? {
            stats.compactMap { dict in keys.compactMap { (dict[$0] as? NSNumber)?.doubleValue }.filter { $0.isFinite && $0 >= 0 }.first }.max()
        }
        let usageKeys = ["Device Utilization %", "GPU Activity(%)"]
        let sourceKey = usageKeys.first { key in stats.contains { ($0[key] as? NSNumber)?.doubleValue.isFinite == true } }
        let usage = number(usageKeys)
        let explanation = usage != nil ? "整机 GPU 忙碌率，字段 \(sourceKey ?? "未知")；多 GPU 取最高值，0% 表示空闲。可在状态栏栏目中添加此参数。" : stats.isEmpty ? "未发现 IOAccelerator 性能统计；此系统的驱动未开放整机 GPU 数据。" : "驱动未提供设备忙碌率；渲染器和平铺器数据可单独查看，但不等同于总 GPU 占用。"
        return [
            Metric(id: "gpu", title: "GPU 占用", value: usage, unit: "%", source: "IOAccelerator", detail: explanation),
            Metric(id: "gpuRenderer", title: "GPU 渲染器", value: number(["Renderer Utilization %"]), unit: "%", source: "IOAccelerator"),
            Metric(id: "gpuTiler", title: "GPU 平铺器", value: number(["Tiler Utilization %"]), unit: "%", source: "IOAccelerator"),
            Metric(id: "gpuMemory", title: "GPU 分配内存", value: number(["Alloc system memory", "In use system memory"]), unit: "B", source: "IOAccelerator", detail: "统一内存架构下与系统内存共享"),
            Metric(id: "gpuFrequency", title: "GPU 频率", value: number(["Core Clock(MHz)", "GPU Core Clock(MHz)"]), unit: "MHz", source: "IOAccelerator", detail: "仅在驱动公开时可用")
        ]
    }
    static func battery() -> [Metric] {
        var percent: Double?
        var state: Double?
        var detail = "设备无电池或未提供电源信息"
        var remaining: Double?
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                let current = (d[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
                let maximum = (d[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 0
                if maximum > 0 { percent = current / maximum * 100 }
                let charging = d[kIOPSIsChargingKey] as? Bool ?? false
                let ac = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                state = charging ? 1 : ac ? 2 : 0
                detail = charging ? "正在充电" : ac ? "已连接电源" : "使用电池"
                let minutes = (d[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? NSNumber)?.doubleValue
                if let minutes, minutes > 0 { remaining = minutes }
            }
        }
        let d = registry("AppleSmartBattery").first ?? [:]
        func value(_ key: String) -> Double? { (d[key] as? NSNumber)?.doubleValue }
        let voltage = value("Voltage").map { $0 / 1000 }
        let current = value("Amperage").map { $0 / 1000 }
        let max = value("AppleRawMaxCapacity") ?? value("MaxCapacity")
        let design = value("DesignCapacity")
        return [
            Metric(id: "battery", title: "电池电量", value: percent, unit: "%", source: "IOPowerSources", detail: detail),
            Metric(id: "batteryState", title: "电源状态", value: state, unit: "powerState", source: "IOPowerSources", detail: detail),
            Metric(id: "batteryRemaining", title: "电池剩余时间", value: remaining, unit: "min", source: "IOPowerSources", detail: detail, kind: "estimated"),
            Metric(id: "batteryHealth", title: "电池健康", value: max.flatMap { m in design.flatMap { $0 > 0 ? m / $0 * 100 : nil } }, unit: "%", source: "AppleSmartBattery", kind: "estimated"),
            Metric(id: "batteryCycles", title: "电池循环次数", value: value("CycleCount"), unit: "次", source: "AppleSmartBattery"),
            Metric(id: "batteryVoltage", title: "电池电压", value: voltage, unit: "V", source: "AppleSmartBattery"),
            Metric(id: "batteryCurrent", title: "电池电流", value: current, unit: "A", source: "AppleSmartBattery", detail: "正值充电，负值放电"),
            Metric(id: "batteryPower", title: "电池充放电功率", value: voltage.flatMap { v in current.map { abs(v * $0) } }, unit: "W", source: "电压 × 电流", detail: "电池侧功率，不等于整机功耗", kind: "estimated")
        ]
    }
    static func volumes() -> [VolumeRow] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsLocal == true,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let importantCapacity = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
            return VolumeRow(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: UInt64(total),
                available: UInt64(max(0, values.volumeAvailableCapacity ?? 0)),
                availableForImportantUsage: importantCapacity.map { UInt64(min(Int64(total), max(0, $0))) }
            )
        }
    }
    static func diskBytes() -> (UInt64, UInt64)? {
        let statistics = registry("IOBlockStorageDriver").compactMap { $0["Statistics"] as? [String: Any] }
        guard !statistics.isEmpty else { return nil }
        return statistics.reduce((0, 0)) { result, d in
            (result.0 + ((d["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0),
             result.1 + ((d["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0))
        }
    }
}
