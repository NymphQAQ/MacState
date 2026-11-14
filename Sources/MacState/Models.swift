import Foundation

struct Metric: Codable {
    let id: String
    let title: String
    var value: Double?
    let unit: String
    let source: String
    var detail: String = ""
    var kind: String = "measured"
}
struct ProcessRow: Codable {
    let pid: Int32
    let parent: Int32
    var name: String
    let path: String
    let user: String
    let threads: Int32
    let cpu: Double?
    let memory: UInt64?
    let resident: UInt64?
    let readRate: Double?
    let writeRate: Double?
    let wakeups: Double?
    var power: Double?
    var smoothedPower: Double? = nil
    var lifetimeEnergy: Double? = nil
    var gpu: Double? = nil
    var cpuPower: Double? = nil
    var gpuPower: Double? = nil
    var kernelPower: Double? = nil
    var responsible: Int32? = nil
    var startAbstimeNS: UInt64? = nil
    var startIdentity: UInt64? = nil
    var energyImpact: Double? = nil
    var powerStatus: String? = nil
    let status: String
}
struct NetworkRow: Codable {
    let name: String
    let address: String
    let up: Bool
    let received: UInt64
    let sent: UInt64
    let download: Double?
    let upload: Double?
}
struct VolumeRow: Codable {
    let name: String
    let path: String
    let total: UInt64
    let available: UInt64
    var availableForImportantUsage: UInt64? = nil
}
struct SensorRow: Codable {
    let key: String
    let type: String
    let value: Double
    let unit: String
}
struct Snapshot: Codable {
    let timestamp: Double
    let device: [String: String]
    let metrics: [Metric]
    let cores: [Double?]
    let processes: [ProcessRow]
    let networks: [NetworkRow]
    let volumes: [VolumeRow]
    let sensors: [SensorRow]
    let collectionMS: Double
    let issues: [String]
    var processInterval: Double? = nil
    var processPower: ProcessPowerSummary? = nil
}

struct HistorySample: Codable {
    let timestamp: Double
    let metrics: [Metric]
}

struct MenuTextStyle: Codable, Equatable {
    var font = "system"
    var size: Double = 10
    var color = "#FFFFFF"
    var automaticColor = true
    var opacity: Double = 1

    func validated() -> MenuTextStyle {
        var result = self
        result.size = size.isFinite ? min(18, max(6, size)) : 10
        result.opacity = opacity.isFinite ? min(1, max(0, opacity)) : 1
        result.color = color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil ? color.uppercased() : "#FFFFFF"
        result.font = font.isEmpty || font.count > 128 ? "system" : font
        return result
    }
}

struct MenuColumn: Codable, Equatable {
    var id: String
    var name: String
    var metrics: [String]
    var spacing: Double = 6
    var layout = "named"

    static func preset(_ id: String) -> MenuColumn {
        let labels = ["cpu":"CPU", "memory":"MEM", "gpu":"GPU", "cpuTemp":"CPU TEMP", "gpuTemp":"GPU TEMP", "systemPower":"PWR", "battery":"BAT", "disk":"SSD", "fan":"FAN"]
        return MenuColumn(id: id, name: labels[id] ?? "网络", metrics: id == "network" ? ["upload", "download"] : [id], layout: id == "network" ? "network" : "named")
    }
}

struct Settings: Codable, Equatable {
    var menuMetrics = ["cpu", "memory", "network"]
    var menuColumns: [MenuColumn]? = nil
    var menuColumnSpacing: Double = 4
    var hideFanUnit = false
    var resolvedMenuColumns: [MenuColumn] { menuColumns ?? menuMetrics.map(MenuColumn.preset) }
    var hiddenMetrics: [String] = []
    var interval: Double = 2
    var historySeconds: Double = 120
    var theme = "dark"
    // Persisted density: 1 means 0% user-facing transparency (frosted).
    var glassOpacity: Double = 1
    // Native enhancement only. The retired screen-capture setting is ignored.
    var nativeGlassEnabled = false
    var launchAtLogin = false
    var compact = false
    var commandTabOpensMissionControl = false
    var menuNameStyle = MenuTextStyle(size: 9, opacity: 0.8)
    var menuValueStyle = MenuTextStyle(font: "monospaced", size: 11)

    init() {}
    // Preserve existing preferences when adding fields or merging network items.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        menuMetrics = try values.decodeIfPresent([String].self, forKey: .menuMetrics) ?? menuMetrics
        menuColumns = try values.decodeIfPresent([MenuColumn].self, forKey: .menuColumns)
        menuColumnSpacing = try values.decodeIfPresent(Double.self, forKey: .menuColumnSpacing) ?? menuColumnSpacing
        hideFanUnit = try values.decodeIfPresent(Bool.self, forKey: .hideFanUnit) ?? hideFanUnit
        hiddenMetrics = try values.decodeIfPresent([String].self, forKey: .hiddenMetrics) ?? hiddenMetrics
        interval = try values.decodeIfPresent(Double.self, forKey: .interval) ?? interval
        historySeconds = try values.decodeIfPresent(Double.self, forKey: .historySeconds) ?? historySeconds
        theme = try values.decodeIfPresent(String.self, forKey: .theme) ?? theme
        glassOpacity = try values.decodeIfPresent(Double.self, forKey: .glassOpacity) ?? glassOpacity
        nativeGlassEnabled = try values.decodeIfPresent(Bool.self, forKey: .nativeGlassEnabled) ?? nativeGlassEnabled
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        compact = try values.decodeIfPresent(Bool.self, forKey: .compact) ?? compact
        commandTabOpensMissionControl = try values.decodeIfPresent(Bool.self, forKey: .commandTabOpensMissionControl) ?? commandTabOpensMissionControl
        menuNameStyle = try values.decodeIfPresent(MenuTextStyle.self, forKey: .menuNameStyle) ?? menuNameStyle
        menuValueStyle = try values.decodeIfPresent(MenuTextStyle.self, forKey: .menuValueStyle) ?? menuValueStyle
    }

    static let menuChoices = ["cpu", "memory", "gpu", "network", "cpuTemp", "gpuTemp", "systemPower", "battery", "disk", "fan"]
    func validated() -> Settings {
        var result = self
        var seen = Set<String>()
        result.menuMetrics = menuMetrics.map { ["download", "upload"].contains($0) ? "network" : $0 }
            .filter { Self.menuChoices.contains($0) && seen.insert($0).inserted }
        if result.menuMetrics.isEmpty { result.menuMetrics = ["cpu"] }
        var columnIDs = Set<String>()
        result.menuColumns = (menuColumns ?? result.menuMetrics.map(MenuColumn.preset)).prefix(20).compactMap { column in
            var column = column
            if column.id.isEmpty || column.id.count > 128 || !columnIDs.insert(column.id).inserted { column.id = UUID().uuidString }
            column.name = String(column.name.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").prefix(64))
            var metricIDs = Set<String>()
            column.metrics = Array(column.metrics.filter { !$0.isEmpty && $0.count <= 128 && metricIDs.insert($0).inserted }.prefix(8))
            guard !column.metrics.isEmpty else { return nil }
            column.spacing = column.spacing.isFinite ? min(40, max(0, column.spacing)) : 6
            column.layout = column.layout == "network" ? "network" : "named"
            if column.layout == "network" { column.metrics = ["upload", "download"] }
            return column
        }
        if result.menuColumns?.isEmpty != false { result.menuColumns = [.preset("cpu")] }
        result.menuColumnSpacing = menuColumnSpacing.isFinite ? min(40, max(0, menuColumnSpacing)) : 4
        result.interval = [1.0, 2, 3, 5, 10].contains(interval) ? interval : 2
        result.historySeconds = [60.0, 120, 300, 600].contains(historySeconds) ? historySeconds : 120
        result.theme = ["dark", "light", "system"].contains(theme) ? theme : "dark"
        result.glassOpacity = glassOpacity.isFinite ? min(1, max(0, glassOpacity)) : 1
        result.menuNameStyle = menuNameStyle.validated()
        result.menuValueStyle = menuValueStyle.validated()
        return result
    }
}

enum CounterMath {
    static func rate(_ current: UInt64, previous: UInt64?, elapsed: Double) -> Double? {
        guard let previous, current >= previous, elapsed > 0 else { return nil }
        return Double(current - previous) / elapsed
    }
    static func cpu(_ current: [UInt64], previous: [UInt64]?) -> Double? {
        guard let previous, current.count == 4, previous.count == 4 else { return nil }
        // Mach tick counters wrap at 32 bits.
        let delta = zip(current, previous).map { ($0 &- $1) & 0xffff_ffff }
        let total = delta.reduce(0, +)
        guard total > 0 else { return 0 }
        return 100 * Double(total - delta[2]) / Double(total)
    }
}
