import Foundation
import SystemBridge

final class Collector {
    private let device = Hardware.device()
    private var previousTicks: [[UInt64]] = []
    private var previousProcesses: [Int32: MSProcess] = [:]
    private var previousNetworks: [String: (UInt64, UInt64)] = [:]
    private var previousDisk: (UInt64, UInt64)?
    private var previousTime: Double?
    private var slowMetrics: [Metric] = []
    private var cachedVolumes: [VolumeRow] = []
    private var slowTime: Double = -100
    private let gpuCounters = ProcessGPUCounters()
    private let gpuHardware = GPUHardwareSampler()
    private let processEnergy = ProcessEnergyLedger()
    private let totalPower = ProcessTotalPower()
    private var previousProcessTime: Double?

    func collect() -> Snapshot {
        let start = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime.map { start - $0 } ?? 0
        var issues: [String] = []
        var metrics: [Metric] = []
        var ticks = [UInt64](repeating: 0, count: 1024)
        let coreCount = Int(ms_cpu(&ticks, 256))
        var cores: [Double?] = []
        var newTicks: [[UInt64]] = []
        if coreCount > 0 {
            for i in 0..<coreCount {
                let current = Array(ticks[(i * 4)..<(i * 4 + 4)])
                cores.append(CounterMath.cpu(current, previous: previousTicks.indices.contains(i) ? previousTicks[i] : nil))
                newTicks.append(current)
            }
        } else { issues.append("CPU 计数器读取失败") }
        previousTicks = newTicks
        let validCores = cores.compactMap { $0 }
        metrics.append(Metric(id: "cpu", title: "CPU 总占用", value: validCores.isEmpty ? nil : validCores.reduce(0, +) / Double(validCores.count), unit: "%", source: "host_processor_info", detail: "所有逻辑核心平均负载"))
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 {
            for (i, minute) in [1, 5, 15].enumerated() {
                metrics.append(Metric(id: "load\(minute)", title: "\(minute) 分钟负载", value: load[i], unit: "", source: "getloadavg", detail: "正在运行和等待运行的任务数"))
            }
        }
        var memory = MSMemory()
        if ms_memory(&memory) != 0 {
            metrics.append(Metric(id: "memory", title: "内存占用", value: memory.total > 0 ? Double(memory.used) / Double(memory.total) * 100 : nil, unit: "%", source: "host_statistics64", detail: "应用 + wired + 压缩内存"))
            let memoryValues: [(String, String, UInt64)] = [
                ("memoryUsed", "已用内存", memory.used), ("memoryTotal", "物理内存", memory.total),
                ("memoryActive", "活跃内存", memory.active), ("memoryInactive", "非活跃内存", memory.inactive),
                ("memoryWired", "不可换出内存", memory.wired), ("memoryCompressed", "压缩内存", memory.compressed),
                ("memoryFree", "空闲内存", memory.free), ("memoryPurgeable", "可清除内存", memory.purgeable),
                ("swap", "交换空间", memory.swap)]
            for (id, title, value) in memoryValues { metrics.append(Metric(id: id, title: title, value: Double(value), unit: "B", source: "Mach VM / sysctl")) }
            metrics.append(Metric(id: "memoryPressure", title: "内存压力", value: memory.pressure == 0 ? nil : Double(memory.pressure), unit: "level", source: "sysctl", detail: "1 正常 / 2 升高 / 4 危急"))
            metrics.append(Metric(id: "pageins", title: "累计换入页", value: Double(memory.pageins), unit: "页", source: "Mach VM"))
            metrics.append(Metric(id: "pageouts", title: "累计换出页", value: Double(memory.pageouts), unit: "页", source: "Mach VM"))
        } else { issues.append("内存统计读取失败") }

        if start - slowTime >= 10 {
            slowMetrics = Hardware.battery()
            cachedVolumes = Hardware.volumes()
            slowTime = start
        }
        metrics += slowMetrics + Hardware.gpu()
        if let volume = cachedVolumes.first(where: { $0.path == "/" }) ?? cachedVolumes.first {
            metrics.append(Metric(id: "disk", title: "系统磁盘占用", value: Double(volume.total - min(volume.total, volume.available)) / Double(volume.total) * 100, unit: "%", source: "URL volume capacity", detail: volume.name))
            metrics.append(Metric(id: "diskAvailable", title: "磁盘可用空间", value: Double(volume.available), unit: "B", source: "URL volume capacity"))
        }
        if let disk = Hardware.diskBytes() {
            metrics.append(Metric(id: "diskRead", title: "磁盘读取", value: CounterMath.rate(disk.0, previous: previousDisk?.0, elapsed: elapsed), unit: "B/s", source: "IOBlockStorageDriver"))
            metrics.append(Metric(id: "diskWrite", title: "磁盘写入", value: CounterMath.rate(disk.1, previous: previousDisk?.1, elapsed: elapsed), unit: "B/s", source: "IOBlockStorageDriver"))
            previousDisk = disk
        } else {
            for (id, title) in [("diskRead", "磁盘读取"), ("diskWrite", "磁盘写入")] {
                metrics.append(Metric(id: id, title: title, value: nil, unit: "B/s", source: "IOBlockStorageDriver"))
            }
        }
        var networkBuffer = [MSNetwork](repeating: MSNetwork(), count: 128)
        let networkCount = Int(ms_network(&networkBuffer, 128))
        var networks: [NetworkRow] = []
        var nextNetworks: [String: (UInt64, UInt64)] = [:]
        if networkCount < 0 { issues.append("网络接口读取失败") }
        for raw in networkBuffer.prefix(max(0, networkCount)) {
            let name = cString(raw.name), old = previousNetworks[name]
            nextNetworks[name] = (raw.received, raw.sent)
            networks.append(NetworkRow(name: name, address: cString(raw.address), up: raw.up != 0, received: raw.received, sent: raw.sent,
                                       download: CounterMath.rate(raw.received, previous: old?.0, elapsed: elapsed),
                                       upload: CounterMath.rate(raw.sent, previous: old?.1, elapsed: elapsed)))
        }
        previousNetworks = nextNetworks
        // Physical en* interfaces exclude VPN/bridge counters to avoid double counting.
        let physical = networks.filter { $0.up && $0.name.hasPrefix("en") }
        for (id, title, rates) in [("download", "网络下载", physical.map(\.download)), ("upload", "网络上传", physical.map(\.upload))] {
            let valid = rates.compactMap { $0 }
            metrics.append(Metric(id: id, title: title, value: valid.isEmpty ? nil : valid.reduce(0, +), unit: "B/s", source: "getifaddrs", detail: "活动 en* 物理接口合计；VPN 流量在接口明细查看"))
        }
        var sensorBuffer = [MSSensor](repeating: MSSensor(), count: 2048)
        let sensorCount = Int(ms_sensors(&sensorBuffer, 2048))
        if sensorCount < 0 { issues.append("SMC 传感器不可访问；温度、风扇与部分功率不可用") }
        let sensors = sensorBuffer.prefix(max(0, sensorCount)).map { raw in
            let key = cString(raw.key)
            return SensorRow(key: key, type: cString(raw.type), value: raw.value, unit: key.hasPrefix("T") ? "°C" : key.hasPrefix("F") ? "RPM" : "W")
        }
        func hottest(_ prefixes: [String]) -> Double? {
            sensors.filter { row in prefixes.contains { row.key.hasPrefix($0) } && row.value > 0 }.map(\.value).max()
        }
        func sensor(_ keys: [String]) -> Double? { keys.compactMap { key in sensors.first { $0.key == key }?.value }.first }
        metrics += [
            Metric(id: "cpuTemp", title: "CPU 温度", value: hottest(["Tp", "TC"]), unit: "°C", source: "AppleSMC", detail: "CPU 前缀传感器最高值；映射随硬件变化"),
            Metric(id: "gpuTemp", title: "GPU 温度", value: hottest(["Tg", "TG"]), unit: "°C", source: "AppleSMC", detail: "GPU 前缀传感器最高值"),
            Metric(id: "cpuPower", title: "CPU 功耗", value: sensor(["PHPS", "PCPC", "PC0C"]), unit: "W", source: "AppleSMC", detail: "PHPS / PCPC / PC0C 功率键，机型映射可能不同"),
            Metric(id: "gpuPower", title: "GPU 功耗", value: sensor(["PG0R", "PG0C"]), unit: "W", source: "AppleSMC"),
            Metric(id: "systemPower", title: "系统功耗", value: sensor(["PSTR"]), unit: "W", source: "AppleSMC", detail: "PSTR 整机功率；不使用可能包含充电的适配器输入 PDTR"),
            Metric(id: "fan", title: "风扇转速", value: sensors.filter { $0.unit == "RPM" }.map(\.value).max(), unit: "RPM", source: "AppleSMC", detail: "多风扇最高转速；无风扇机型不可用"),
            Metric(id: "cpuFrequency", title: "CPU 标称频率", value: { let v = ms_sysctl("hw.cpufrequency"); return v > 0 ? Double(v) / 1e9 : nil }(), unit: "GHz", source: "sysctl", detail: "标称值，不是实时频率；Apple Silicon 通常不公开"),
            Metric(id: "uptime", title: "系统运行时间", value: start, unit: "s", source: "ProcessInfo"),
            Metric(id: "thermal", title: "系统热压力", value: Double(ProcessInfo.processInfo.thermalState.rawValue), unit: "thermal", source: "ProcessInfo", detail: "正常 / 轻度 / 严重 / 危急")
        ]
        // Keep GPU time/energy boundaries adjacent to the CPU counter capture.
        let gpuSample = GPUCounterSnapshot.capture()
        let gpuHardwareMetrics = gpuHardware.sample()
        metrics += gpuHardwareMetrics.filter { !["gpuResidencyFrequency"].contains($0.id) }
        if let i = metrics.firstIndex(where: { $0.id == "gpuPower" }), metrics[i].value == nil,
           let modeled = gpuHardwareMetrics.first(where: { $0.id == "gpuEnergyPower" }) {
            metrics[i] = Metric(id: "gpuPower", title: "GPU 功耗", value: modeled.value, unit: "W", source: modeled.source, detail: modeled.detail, kind: modeled.kind)
        }
        if let i = metrics.firstIndex(where: { $0.id == "gpuFrequency" }), metrics[i].value == nil,
           let residency = gpuHardwareMetrics.first(where: { $0.id == "gpuResidencyFrequency" }) {
            metrics[i] = Metric(id: "gpuFrequency", title: "GPU 频率", value: residency.value, unit: "MHz", source: residency.source, detail: residency.detail)
        }

        var pointer: UnsafeMutablePointer<MSProcess>?
        let processBegan = ProcessInfo.processInfo.systemUptime
        let processCount = Int(ms_processes(&pointer))
        let processTime = (processBegan + ProcessInfo.processInfo.systemUptime) / 2
        let processElapsed = previousProcessTime.map { processTime - $0 } ?? 0
        var processes: [ProcessRow] = []
        var nextProcesses: [Int32: MSProcess] = [:]
        if let pointer, processCount >= 0 {
            defer { ms_free(pointer) }
            for raw in UnsafeBufferPointer(start: pointer, count: processCount) {
                let prior = previousProcesses[raw.pid]
                let old = prior?.start == raw.start ? prior : nil
                nextProcesses[raw.pid] = raw
                let readable = raw.readable != 0
                let cpu = readable ? CounterMath.rate(raw.cpu_ns, previous: old?.cpu_ns, elapsed: elapsed).map { $0 / 1e9 * 100 } : nil
                let user = raw.uid >= 0 ? getpwuid(uid_t(raw.uid)).map { String(cString: $0.pointee.pw_name) } ?? String(raw.uid) : "未知"
                processes.append(ProcessRow(pid: raw.pid, parent: raw.parent, name: cString(raw.name), path: cString(raw.path), user: user, threads: raw.threads,
                                            cpu: cpu, memory: readable ? raw.memory : nil, resident: readable ? raw.resident : nil,
                                            readRate: readable ? CounterMath.rate(raw.read_bytes, previous: old?.read_bytes, elapsed: elapsed) : nil,
                                            writeRate: readable ? CounterMath.rate(raw.write_bytes, previous: old?.write_bytes, elapsed: elapsed) : nil,
                                            wakeups: readable ? CounterMath.rate(raw.wakeups, previous: old?.wakeups, elapsed: elapsed) : nil,
                                            power: nil, status: readable ? "可读取" : "权限受限或已退出"))
            }
        } else { issues.append("进程枚举失败") }
        previousProcesses = nextProcesses
        let gpuInterval = gpuCounters.interval(gpuSample, identities: nextProcesses.mapValues(\.start), elapsed: processElapsed)
        let gpuRates = gpuInterval.percentages
        let gpuNames = Dictionary(gpuSample.clients.compactMap { client in client.name.map { (client.pid, $0) } }, uniquingKeysWith: { first, _ in first })
        for i in processes.indices {
            processes[i].gpu = gpuRates[processes[i].pid]
            processes[i].responsible = nextProcesses[processes[i].pid].flatMap { $0.responsible > 0 ? $0.responsible : nil }
            processes[i].startAbstimeNS = nextProcesses[processes[i].pid].flatMap { $0.start_abstime_ns > 0 ? $0.start_abstime_ns : nil }
            processes[i].startIdentity = nextProcesses[processes[i].pid].flatMap { $0.start > 0 ? $0.start : nil }
            if processes[i].name == "受保护进程", let name = gpuNames[processes[i].pid], !name.isEmpty { processes[i].name = name }
        }
        let energyReadings = processEnergy.sample(nextProcesses.values.map {
            ProcessEnergyCounter(pid: $0.pid, start: $0.start_abstime_ns,
                                 energyNJ: $0.energy_available != 0 ? $0.energy_nj : nil)
        }, elapsed: processElapsed)
        let powerSummary = totalPower.apply(cpu: energyReadings, gpu: gpuInterval, energy: gpuHardware.energyInterval,
                                           start: previousProcessTime ?? processTime, end: processTime, to: &processes)
        previousProcessTime = processTime
        metrics.append(Metric(id: "gpuProcessCount", title: "GPU 计数器覆盖进程", value: gpuSample.available ? Double(gpuRates.count) : nil,
                              unit: "个", source: "IOGPU AppUsage", detail: gpuSample.available ? "逐进程累计 GPU 时间差；首采样、客户端变化或 PID 重用时等待基线。" : "此驱动未公开逐进程 AppUsage 计数器。"))
        previousTime = start
        metrics.append(Metric(id: "processCount", title: "进程总数", value: Double(processes.count), unit: "个", source: "libproc"))
        metrics.append(Metric(id: "threadCount", title: "线程总数", value: Double(processes.reduce(0) { $0 + Int($1.threads) }), unit: "个", source: "libproc", detail: "可读取进程线程合计"))
        return Snapshot(timestamp: Date().timeIntervalSince1970, device: device, metrics: metrics, cores: cores, processes: processes,
                        networks: networks, volumes: cachedVolumes, sensors: sensors,
                        collectionMS: (ProcessInfo.processInfo.systemUptime - start) * 1000, issues: issues,
                        processInterval: processElapsed > 0 && processElapsed <= 30 ? processElapsed : nil, processPower: powerSummary)
    }
}
