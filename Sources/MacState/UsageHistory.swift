import Foundation

enum UsagePowerMode: String, Codable {
    case battery, charging, plugged, desktop, unknown
}

struct UsageApplication: Equatable {
    let id: String
    let name: String
    var icon: String? = nil
}

struct UsageReading {
    static let systemPowerSource = "AppleSMC · 整机功耗"
    static let batteryPowerSource = "电池电压 × 电流 · 放电功率估算"
    let timestamp: Double
    let uptime: Double
    let battery: Double?
    let mode: UsagePowerMode
    let power: Double?
    let powerSource: String
    let temperature: Double?
    let application: UsageApplication?
    let applicationPowers: [UsageApplicationPower]
    let powerInterval: Double?

    init(timestamp: Double, uptime: Double, battery: Double?, mode: UsagePowerMode, power: Double?, powerSource: String = "AppleSMC · 整机功耗", temperature: Double?, application: UsageApplication?, applicationPowers: [UsageApplicationPower] = [], powerInterval: Double? = nil) {
        self.timestamp = timestamp; self.uptime = uptime; self.mode = mode
        self.battery = battery.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        self.power = power.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.powerSource = powerSource
        self.temperature = temperature.flatMap { $0.isFinite && (0...150).contains($0) ? $0 : nil }
        self.application = application
        self.applicationPowers = applicationPowers
        self.powerInterval = powerInterval
    }

    init(snapshot: Snapshot, application: UsageApplication?, preferredPowerSource: String? = nil, applicationPowers: [UsageApplicationPower] = []) {
        func value(_ id: String) -> Double? { snapshot.metrics.first { $0.id == id }?.value }
        let battery = value("battery")
        let mode: UsagePowerMode
        switch value("batteryState") {
        case 0: mode = .battery
        case 1: mode = .charging
        case 2: mode = .plugged
        default: mode = battery == nil && snapshot.device["model"]?.hasPrefix("MacBook") != true ? .desktop : .unknown
        }
        let systemPower = value("systemPower")
        let batteryPower = mode == .battery ? value("batteryPower") : nil
        let useBatteryPower = mode == .battery && (preferredPowerSource == Self.batteryPowerSource ||
            (preferredPowerSource != Self.systemPowerSource && systemPower == nil))
        self.init(timestamp: snapshot.timestamp, uptime: value("uptime") ?? ProcessInfo.processInfo.systemUptime,
                  battery: battery, mode: mode, power: useBatteryPower ? batteryPower : systemPower,
                  powerSource: useBatteryPower ? Self.batteryPowerSource : Self.systemPowerSource,
                  temperature: value("cpuTemp"), application: application, applicationPowers: applicationPowers, powerInterval: snapshot.processInterval)
    }
}

struct UsagePoint: Codable {
    let timestamp: Double
    let battery: Double?
    let power: Double?
    let temperature: Double?
    let appID: String?
    let gap: Bool
}

struct UsageSegment: Codable {
    let appID: String
    let start: Double
    var end: Double
}

struct UsageApplicationStats: Codable {
    let id: String
    var name: String
    var duration: Double = 0
    var energy: Double = 0
    var powerDuration: Double = 0
    var temperatureTotal: Double = 0
    var temperatureDuration: Double = 0
    var maximumTemperature: Double?
    // Legacy foreground whole-machine energy is retained only for export.
    var attributed: UsageAttributedPower?
    // Optional so pre-detail history remains readable without invented rows.
    var processes: [String: UsageProcessStats]? = nil
}

struct UsageProcessStats: Codable {
    let id: String
    let pid: Int32
    var parent: Int32
    var parentID: String?
    var name: String
    var path: String
    var isMain: Bool
    let firstSeen: Double
    var lastSeen: Double
    var observedDuration: Double = 0
    var energy: Double = 0
    var powerDuration: Double = 0
    var lastPower: Double?
    var status: String
}

struct UsageAttributedPower: Codable {
    var observedDuration: Double = 0
    // Schema-2 CPU/GPU fields are retained to decode and export old records.
    // Schema-3 fields retain score allocation; schema 4 integrates raw process
    // energy deltas. Neither CPU/GPU split nor device residual is added to it.
    var cpuEnergy: Double = 0
    var cpuDuration: Double = 0
    var gpuEnergy: Double = 0
    var gpuDuration: Double = 0
    var combinedEnergy: Double = 0
    var combinedDuration: Double = 0
    var processCount: Int = 0
    var scoredProcessCount: Int? = nil
    var measuredProcessCount: Int? = nil
}

struct UsageSession: Codable {
    let id: String
    let startedAt: Double
    var updatedAt: Double
    var endedAt: Double?
    let mode: UsagePowerMode
    let hasBattery: Bool
    var startBattery: Double?
    var endBattery: Double?
    var activeDuration: Double = 0
    var energy: Double = 0
    var powerDuration: Double = 0
    var trackedBatteryDrop: Double = 0
    var powerSource: String = ""
    var points: [UsagePoint] = []
    var segments: [UsageSegment] = []
    var applications: [String: UsageApplicationStats] = [:]
    var applicationPowerVersion: Int? = 5

    var averagePower: Double? { powerDuration > 0 ? energy / powerDuration : nil }
    // Count only battery changes during observed awake intervals. Sleep/restart
    // gaps cannot contribute battery drain without contributing elapsed time.
    var theoreticalRuntime: Double? {
        guard mode == .battery, activeDuration >= 300, trackedBatteryDrop >= 2 else { return nil }
        let seconds = activeDuration * 100 / trackedBatteryDrop
        return seconds.isFinite && seconds <= 604_800 ? seconds : nil
    }
}

struct UsageArchive: Codable {
    var version = 5
    var activeSessionID: String?
    var sessions: [UsageSession] = []
    var icons: [String: String] = [:]
}

struct UsageSessionSummary: Encodable {
    let id: String
    let startedAt: Double
    let updatedAt: Double
    let mode: UsagePowerMode
    let active: Bool
    let startBattery: Double?
    let endBattery: Double?
    let activeDuration: Double
}

struct UsagePayload: Encodable {
    let sessions: [UsageSessionSummary]
    let selected: UsageSession?
    let averagePower: Double?
    let theoreticalRuntime: Double?
    let icons: [String: String]
}

final class UsageRecorder {
    static let maximumSessions = 30
    static let maximumPoints = 2048
    static let maximumSegments = 2048
    private(set) var archive: UsageArchive
    private var previous: UsageReading?
    private var pendingGap = false
    // Unreadable start counters must not merge PID generations across a gap
    // or a recorder restart. Normal processes use their kernel start identity.
    private let observationID = UUID().uuidString
    private var previousUnknownProcesses: [String: String] = [:]
    var currentPowerSource: String? {
        archive.sessions.first { $0.id == archive.activeSessionID }.flatMap { $0.powerSource.isEmpty ? nil : $0.powerSource }
    }

    init(archive: UsageArchive = UsageArchive()) {
        self.archive = archive
        self.archive.version = 5
        if self.archive.sessions.count > Self.maximumSessions {
            self.archive.sessions.removeFirst(self.archive.sessions.count - Self.maximumSessions)
        }
        // A restored session may continue, but never count time while the app
        // was stopped. The first new point explicitly breaks the chart.
        pendingGap = archive.activeSessionID != nil
    }

    func interrupt() { previous = nil; pendingGap = true; previousUnknownProcesses = [:] }

    func record(_ reading: UsageReading) {
        guard reading.timestamp.isFinite, reading.uptime.isFinite else { return }
        if let previous, reading.timestamp <= previous.timestamp { return }
        let current = archive.sessions.first { $0.id == archive.activeSessionID }
        let dayBoundary = current.map { $0.mode != .battery && reading.timestamp - $0.startedAt >= 86400 } ?? false
        let sourceChanged = current.map { !$0.powerSource.isEmpty && reading.power != nil && $0.powerSource != reading.powerSource } ?? false
        if current == nil || current?.applicationPowerVersion != 5 || current?.mode != reading.mode || current?.hasBattery != (reading.battery != nil) || dayBoundary || sourceChanged {
            closeCurrent()
            let session = UsageSession(id: UUID().uuidString, startedAt: reading.timestamp, updatedAt: reading.timestamp,
                                       mode: reading.mode, hasBattery: reading.battery != nil,
                                       startBattery: reading.battery, endBattery: reading.battery)
            archive.sessions.append(session); archive.activeSessionID = session.id
            previous = nil; pendingGap = false
        }
        guard let index = archive.sessions.firstIndex(where: { $0.id == archive.activeSessionID }) else { return }
        var session = archive.sessions[index]
        let elapsed = previous.map { reading.timestamp - $0.timestamp } ?? 0
        let awake = previous.map { reading.uptime - $0.uptime } ?? 0
        let observed = previous != nil && elapsed > 0 && elapsed <= 30 && awake > 0 && abs(awake - elapsed) <= 2
        let gap = pendingGap || (previous != nil && !observed)
        if session.powerSource.isEmpty, reading.power != nil { session.powerSource = reading.powerSource }
        if let old = previous, observed {
            session.activeDuration += elapsed
            // Process deltas cover the interval just ended. Device power is
            // independently sampled and is never forced into application totals.
            let intervalReading = reading.applicationPowers.isEmpty ? old : reading
            let intervalPower = intervalReading.powerSource == session.powerSource ? intervalReading.power : nil
            if let watts = intervalPower {
                session.energy += watts * elapsed; session.powerDuration += elapsed
            }
            if session.mode == .battery, let before = old.battery, let after = reading.battery {
                session.trackedBatteryDrop += before - after
            }
            if let app = old.application {
                var stats = session.applications[app.id] ?? UsageApplicationStats(id: app.id, name: app.name)
                stats.name = app.name; stats.duration += elapsed
                if let temperature = old.temperature {
                    stats.temperatureTotal += temperature * elapsed; stats.temperatureDuration += elapsed
                    stats.maximumTemperature = max(stats.maximumTemperature ?? temperature, temperature)
                }
                session.applications[app.id] = stats
                if let last = session.segments.last, last.appID == app.id, abs(last.end - old.timestamp) < 0.1 {
                    session.segments[session.segments.count - 1].end = reading.timestamp
                } else {
                    session.segments.append(UsageSegment(appID: app.id, start: old.timestamp, end: reading.timestamp))
                }
            }
            // Process counters describe the interval that just ended, unlike
            // the foreground/system reading held from the previous sample.
            let measuredElapsed = reading.powerInterval ?? elapsed
            if measuredElapsed.isFinite, measuredElapsed > 0, measuredElapsed <= 30,
               abs(measuredElapsed - elapsed) <= max(0.5, elapsed * 0.1) {
                for sample in reading.applicationPowers {
                    let app = sample.application
                    var stats = session.applications[app.id] ?? UsageApplicationStats(id: app.id, name: app.name)
                    stats.name = app.name
                    var attributed = stats.attributed ?? UsageAttributedPower()
                    attributed.observedDuration += elapsed; attributed.processCount = sample.processCount
                    attributed.measuredProcessCount = sample.measuredProcessCount
                    if let watts = sample.power, watts.isFinite, watts >= 0 {
                        attributed.combinedEnergy += watts * measuredElapsed
                        attributed.combinedDuration += measuredElapsed
                    }
                    stats.attributed = attributed; session.applications[app.id] = stats
                }
            }
        }
        let processInterval = reading.powerInterval ?? elapsed
        let validProcessInterval = observed && processInterval.isFinite && processInterval > 0 && processInterval <= 30 && abs(processInterval - elapsed) <= max(0.5, elapsed * 0.1)
        recordProcesses(in: &session, reading: reading, observed: observed ? elapsed : 0,
                        measured: validProcessInterval ? processInterval : nil)
        for app in reading.applicationPowers.map(\.application) + (reading.application.map { [$0] } ?? []) {
            if let icon = app.icon, icon.hasPrefix("data:image/png;base64,"), icon.count < 65_536 { archive.icons[app.id] = icon }
        }
        let point = UsagePoint(timestamp: reading.timestamp, battery: reading.battery,
                               power: reading.powerSource == session.powerSource ? reading.power : nil,
                               temperature: reading.temperature, appID: reading.application?.id, gap: gap)
        if let last = session.points.last, session.points.count > 1,
           reading.timestamp - session.points[session.points.count - 2].timestamp <= 10, !gap, !last.gap,
           previous?.application?.id == reading.application?.id {
            session.points[session.points.count - 1] = point
        } else { session.points.append(point) }
        session.updatedAt = reading.timestamp; session.endBattery = reading.battery
        if session.points.count > Self.maximumPoints {
            // Keep all interval boundaries until the final hard bound. Missing
            // spans remain breaks instead of being drawn as measured discharge.
            let original = session.points
            session.points = original.enumerated().compactMap { i, point in
                i == 0 || i == original.count - 1 || i % 2 == 0 || point.gap || (i + 1 < original.count && original[i + 1].gap) ? point : nil
            }
            if session.points.count > Self.maximumPoints { session.points.removeFirst(session.points.count - Self.maximumPoints) }
        }
        if session.segments.count > Self.maximumSegments { session.segments.removeFirst(session.segments.count - Self.maximumSegments) }
        archive.sessions[index] = session
        if archive.sessions.count > Self.maximumSessions { archive.sessions.removeFirst(archive.sessions.count - Self.maximumSessions) }
        let usedIDs = Set(archive.sessions.flatMap { $0.applications.keys })
        archive.icons = archive.icons.filter { usedIDs.contains($0.key) || $0.key == reading.application?.id }
        previous = reading; pendingGap = false
    }

    private func recordProcesses(in session: inout UsageSession, reading: UsageReading, observed: Double, measured: Double?) {
        var nextUnknown: [String: String] = [:]
        for sample in reading.applicationPowers {
            guard let rows = sample.processes else { continue }
            let app = sample.application
            var stats = session.applications[app.id] ?? UsageApplicationStats(id: app.id, name: app.name)
            var records = stats.processes ?? [:]
            var ids: [Int32: String] = [:]
            for row in rows {
                let key = "\(app.id):\(row.pid):\(row.path)"
                if let identity = row.identity {
                    ids[row.pid] = "\(row.pid):\(identity)"
                } else {
                    let id = previousUnknownProcesses[key] ?? "\(row.pid):unknown:\(observationID):\(reading.timestamp)"
                    ids[row.pid] = id; nextUnknown[key] = id
                }
            }
            for row in rows {
                guard let id = ids[row.pid] else { continue }
                var record = records[id] ?? UsageProcessStats(id: id, pid: row.pid, parent: row.parent,
                    name: row.name, path: row.path, isMain: row.isMain, firstSeen: reading.timestamp,
                    lastSeen: reading.timestamp, status: row.status)
                record.name = row.name; record.path = row.path; record.parent = row.parent
                record.isMain = row.isMain; record.lastSeen = reading.timestamp
                let parentID = ids[row.parent]
                record.parentID = parentID == id ? nil : parentID
                record.status = row.status
                record.observedDuration += observed
                record.lastPower = nil
                if let measured, let power = row.power, power.isFinite, power >= 0 {
                    record.energy += power * measured; record.powerDuration += measured
                    record.lastPower = power
                }
                records[id] = record
            }
            stats.processes = records; session.applications[app.id] = stats
        }
        previousUnknownProcesses = nextUnknown
    }

    func closeCurrent() {
        if let index = archive.sessions.firstIndex(where: { $0.id == archive.activeSessionID }) {
            archive.sessions[index].endedAt = archive.sessions[index].updatedAt
        }
        archive.activeSessionID = nil; previous = nil; previousUnknownProcesses = [:]
    }

    @discardableResult func deleteSession(id: String) -> Bool {
        guard archive.sessions.contains(where: { $0.id == id }) else { return false }
        archive.sessions.removeAll { $0.id == id }
        if archive.activeSessionID == id { archive.activeSessionID = nil; previous = nil }
        let usedIDs = Set(archive.sessions.flatMap { $0.applications.keys })
        archive.icons = archive.icons.filter { usedIDs.contains($0.key) }
        return true
    }

    func payload(selectedID: String? = nil) -> UsagePayload {
        let selected = archive.sessions.first { $0.id == (selectedID ?? archive.activeSessionID) } ?? archive.sessions.last
        let ids = Set(selected?.applications.keys.map { $0 } ?? [])
        return UsagePayload(sessions: archive.sessions.reversed().map {
            UsageSessionSummary(id: $0.id, startedAt: $0.startedAt, updatedAt: $0.updatedAt, mode: $0.mode,
                                active: $0.id == archive.activeSessionID, startBattery: $0.startBattery,
                                endBattery: $0.endBattery, activeDuration: $0.activeDuration)
        }, selected: selected, averagePower: selected?.averagePower, theoreticalRuntime: selected?.theoreticalRuntime,
           icons: archive.icons.filter { ids.contains($0.key) })
    }
}

enum UsagePersistence {
    static let maximumArchiveBytes = 128_000_000
    static let maximumProcessRowsPerShard = 2_000
    private static let storeFormat = "MacStateUsageSessionsV1"

    private struct Manifest: Codable {
        let format: String
        let version: Int
        let activeSessionID: String?
        let sessions: [SessionReference]
        let icons: [String: String]
    }

    private struct SessionReference: Codable {
        let id: String
        let updatedAt: Double
        let endedAt: Double?
        let storageToken: String
    }

    private struct StoredSession: Codable {
        let session: UsageSession
        let processGroups: [ProcessGroup]
    }

    private struct ProcessGroup: Codable {
        let applicationID: String
        let applicationIndex: Int
        let shardCount: Int
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacState", isDirectory: true).appendingPathComponent("usage-history.json")
    }

    static func partsDirectory(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("parts")
    }

    static func load(from url: URL) throws -> UsageArchive {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if FileManager.default.fileExists(atPath: partsDirectory(for: url).path) { throw CocoaError(.fileReadCorruptFile) }
            return UsageArchive()
        }
        let data = try Data(contentsOf: url)
        guard data.count < maximumArchiveBytes else { throw CocoaError(.fileReadTooLarge) }
        if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["format"] as? String == storeFormat {
            return try loadSharded(from: url, manifestData: data)
        }
        let archive = try JSONDecoder().decode(UsageArchive.self, from: data)
        try validate(archive)
        return archive
    }

    static func save(_ archive: UsageArchive, to url: URL) throws {
        try validate(archive)
        let fileManager = FileManager.default
        let parts = partsDirectory(for: url)
        try fileManager.createDirectory(at: parts, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let priorManifest = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        let priorReferences = Dictionary(uniqueKeysWithValues: ((priorManifest?.format == storeFormat ? priorManifest?.sessions : nil) ?? []).map { ($0.id, $0) })
        var filesToKeep = Set<String>()
        var references: [SessionReference] = []

        for session in archive.sessions {
            let oldReference = priorReferences[session.id]
            if let oldReference, oldReference.updatedAt == session.updatedAt, oldReference.endedAt == session.endedAt {
                let oldToken = oldReference.storageToken
                let oldSessionURL = parts.appendingPathComponent("session-\(oldToken).json")
                let oldStored: StoredSession? = try? decodeFile(at: oldSessionURL, with: JSONDecoder())
                if let oldStored, oldStored.session.id == session.id,
                   oldStored.processGroups.allSatisfy({ group in
                       group.shardCount > 0 && group.shardCount <= 100_000 &&
                       (0..<group.shardCount).allSatisfy { fileManager.fileExists(atPath: parts.appendingPathComponent(processFilename(sessionToken: oldToken, applicationIndex: group.applicationIndex, shardIndex: $0)).path) }
                   }) {
                    references.append(oldReference)
                    filesToKeep.insert(oldSessionURL.lastPathComponent)
                    for group in oldStored.processGroups {
                        for shardIndex in 0..<group.shardCount {
                            filesToKeep.insert(processFilename(sessionToken: oldToken, applicationIndex: group.applicationIndex, shardIndex: shardIndex))
                        }
                    }
                    continue
                }
            }

            let token = UUID().uuidString
            references.append(SessionReference(id: session.id, updatedAt: session.updatedAt, endedAt: session.endedAt, storageToken: token))
            let sessionURL = parts.appendingPathComponent("session-\(token).json")
            filesToKeep.insert(sessionURL.lastPathComponent)

            var core = session
            var groups: [ProcessGroup] = []
            for (applicationIndex, applicationID) in session.applications.keys.sorted().enumerated() {
                guard let stats = session.applications[applicationID], let processMap = stats.processes, !processMap.isEmpty else { continue }
                let rows = processMap.values.sorted { $0.id < $1.id }
                let shardCount = (rows.count + maximumProcessRowsPerShard - 1) / maximumProcessRowsPerShard
                groups.append(ProcessGroup(applicationID: applicationID, applicationIndex: applicationIndex, shardCount: shardCount))
                for shardIndex in 0..<shardCount {
                    let start = shardIndex * maximumProcessRowsPerShard
                    let end = min(start + maximumProcessRowsPerShard, rows.count)
                    let filename = processFilename(sessionToken: token, applicationIndex: applicationIndex, shardIndex: shardIndex)
                    filesToKeep.insert(filename)
                    try write(encoder.encode(Array(rows[start..<end])), to: parts.appendingPathComponent(filename))
                }
                core.applications[applicationID]?.processes = nil
            }
            let stored = StoredSession(session: core, processGroups: groups)
            try write(encoder.encode(stored), to: sessionURL)
        }

        let manifest = Manifest(format: storeFormat, version: archive.version, activeSessionID: archive.activeSessionID,
                                sessions: references, icons: archive.icons)
        try write(encoder.encode(manifest), to: url)
        for filename in try fileManager.contentsOfDirectory(atPath: parts.path) where !filesToKeep.contains(filename) {
            try fileManager.removeItem(at: parts.appendingPathComponent(filename))
        }
    }

    static func preserveForRecovery(from url: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: url, to: destination)
        let parts = partsDirectory(for: url)
        if fileManager.fileExists(atPath: parts.path) {
            try fileManager.copyItem(at: parts, to: partsDirectory(for: destination))
        }
    }

    private static func loadSharded(from url: URL, manifestData: Data) throws -> UsageArchive {
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.format == storeFormat, [1, 2, 3, 4, 5].contains(manifest.version),
              Set(manifest.sessions.map(\.id)).count == manifest.sessions.count,
              Set(manifest.sessions.map(\.storageToken)).count == manifest.sessions.count,
              manifest.sessions.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 }),
              manifest.activeSessionID.map({ id in manifest.sessions.contains(where: { $0.id == id }) }) ?? true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let parts = partsDirectory(for: url)
        let decoder = JSONDecoder()
        var sessions: [UsageSession] = []
        for reference in manifest.sessions {
            guard !reference.storageToken.isEmpty, reference.storageToken.count <= 64,
                  reference.storageToken.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let token = reference.storageToken
            let sessionURL = parts.appendingPathComponent("session-\(token).json")
            let stored: StoredSession = try decodeFile(at: sessionURL, with: decoder)
            guard stored.session.id == reference.id, stored.session.updatedAt == reference.updatedAt,
                  stored.session.endedAt == reference.endedAt else { throw CocoaError(.fileReadCorruptFile) }
            var session = stored.session
            let applicationIDs = session.applications.keys.sorted()
            var groupedApplications = Set<String>()
            for group in stored.processGroups {
                guard group.shardCount > 0, group.shardCount <= 100_000,
                      applicationIDs.indices.contains(group.applicationIndex),
                      applicationIDs[group.applicationIndex] == group.applicationID,
                      groupedApplications.insert(group.applicationID).inserted else { throw CocoaError(.fileReadCorruptFile) }
                var processes: [String: UsageProcessStats] = [:]
                for shardIndex in 0..<group.shardCount {
                    let filename = processFilename(sessionToken: token, applicationIndex: group.applicationIndex, shardIndex: shardIndex)
                    let rows: [UsageProcessStats] = try decodeFile(at: parts.appendingPathComponent(filename), with: decoder)
                    guard rows.count <= maximumProcessRowsPerShard else { throw CocoaError(.fileReadCorruptFile) }
                    for row in rows {
                        guard processes[row.id] == nil else { throw CocoaError(.fileReadCorruptFile) }
                        processes[row.id] = row
                    }
                }
                session.applications[group.applicationID]?.processes = processes
            }
            sessions.append(session)
        }
        let archive = UsageArchive(version: manifest.version, activeSessionID: manifest.activeSessionID, sessions: sessions, icons: manifest.icons)
        try validate(archive)
        return archive
    }

    private static func validate(_ archive: UsageArchive) throws {
        guard [1, 2, 3, 4, 5].contains(archive.version),
              Set(archive.sessions.map(\.id)).count == archive.sessions.count,
              archive.activeSessionID.map({ id in archive.sessions.contains(where: { $0.id == id }) }) ?? true,
              archive.sessions.allSatisfy({ $0.id.utf8.count <= 128 && $0.startedAt.isFinite && $0.updatedAt >= $0.startedAt && $0.activeDuration >= 0 && $0.energy >= 0 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        guard data.count < maximumArchiveBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }

    private static func decodeFile<T: Decodable>(at url: URL, with decoder: JSONDecoder) throws -> T {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) < maximumArchiveBytes else { throw CocoaError(.fileReadTooLarge) }
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private static func processFilename(sessionToken: String, applicationIndex: Int, shardIndex: Int) -> String {
        "process-\(sessionToken)-\(applicationIndex)-\(shardIndex).json"
    }
}
