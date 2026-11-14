import AppKit

final class UsageAppCapture {
    private var cache: [String: UsageApplication] = [:]

    func current() -> UsageApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return capture(app)
    }

    func powers(in snapshot: Snapshot) -> [UsageApplicationPower] {
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.pathExtension.lowercased() == "app"
        }
        let roots = candidates.filter { candidate in
            !candidates.contains { other in
                other.processIdentifier != candidate.processIdentifier &&
                candidate.bundleURL!.path.hasPrefix(other.bundleURL!.path + "/")
            }
        }.map { UsageAppRoot(pid: $0.processIdentifier, bundlePath: $0.bundleURL!.path, application: capture($0)) }
        return ApplicationPowerGrouping.group(snapshot.processes, roots: roots)
    }

    private func capture(_ app: NSRunningApplication) -> UsageApplication {
        let id = app.bundleIdentifier ?? app.bundleURL?.path ?? "pid:\(app.processIdentifier)"
        if let cached = cache[id] { return cached }
        let captured = UsageApplication(id: id, name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "未知应用", icon: pngIcon(app.icon))
        if cache.count >= 256 { cache.removeAll() }
        cache[id] = captured
        return captured
    }

    private func pngIcon(_ image: NSImage?) -> String? {
        guard let image, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]).map { "data:image/png;base64," + $0.base64EncodedString() }
    }
}

struct UsageAppRoot {
    let pid: Int32
    let bundlePath: String
    let application: UsageApplication
}

struct UsageApplicationPower {
    let application: UsageApplication
    let power: Double?
    let processCount: Int
    var measuredProcessCount: Int? = nil
    var processes: [UsageProcessPower]? = nil
}

struct UsageProcessPower {
    let pid: Int32
    let parent: Int32
    let identity: String?
    let name: String
    let path: String
    let isMain: Bool
    let power: Double?
    let status: String

    init(_ row: ProcessRow, mainPID: Int32?) {
        pid = row.pid; parent = row.parent; name = row.name; path = row.path
        identity = row.startIdentity.map { "bsd:\($0)" } ?? row.startAbstimeNS.map { "mach:\($0)" }
        isMain = row.pid == mainPID; power = row.power
        status = row.powerStatus ?? row.status
    }
}

enum ApplicationPowerGrouping {
    static func group(_ processes: [ProcessRow], roots: [UsageAppRoot]) -> [UsageApplicationPower] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let rootByPID = Dictionary(roots.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let paths = roots.sorted { $0.bundlePath.count > $1.bundlePath.count }
        var groups: [String: (UsageApplication, [ProcessRow])] = [:]
        for root in roots { groups[root.application.id] = (root.application, []) }
        func owner(_ process: ProcessRow) -> UsageAppRoot? {
            if let root = rootByPID[process.pid] { return root }
            // An executable inside the app bundle also covers helpers reparented
            // to launchd. Boundary matching avoids Foo.app / Foo.app-copy overlap.
            if let root = paths.first(where: { process.path.hasPrefix($0.bundlePath + "/") }) { return root }
            if let responsible = process.responsible, responsible != process.pid, let root = rootByPID[responsible] { return root }
            var parent = process.parent, visited: Set<Int32> = [process.pid]
            while parent > 1, visited.insert(parent).inserted {
                if let root = rootByPID[parent] { return root }
                guard let ancestor = byPID[parent] else { break }
                if let root = paths.first(where: { ancestor.path.hasPrefix($0.bundlePath + "/") }) { return root }
                parent = ancestor.parent
            }
            return nil
        }
        var other: [ProcessRow] = []
        for process in processes {
            guard let root = owner(process) else { other.append(process); continue }
            if groups[root.application.id] == nil { groups[root.application.id] = (root.application, []) }
            groups[root.application.id]!.1.append(process)
        }
        func sum(_ rows: [ProcessRow]) -> Double? {
            let values = rows.compactMap(\.power)
            // A subset must not be presented as the application's total.
            guard !values.isEmpty, values.count == rows.count,
                  values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
            return values.reduce(0, +)
        }
        var result = groups.values.map { app, rows in
            let mainPIDs = Set(roots.filter { $0.application.id == app.id }.map(\.pid))
            return UsageApplicationPower(application: app, power: sum(rows), processCount: rows.count,
                                  measuredProcessCount: rows.filter { $0.power != nil }.count,
                                  processes: rows.map { UsageProcessPower($0, mainPID: mainPIDs.contains($0.pid) ? $0.pid : nil) })
        }.sorted { $0.application.id < $1.application.id }
        if !other.isEmpty {
            result.append(UsageApplicationPower(application: UsageApplication(id: "macstate:other-processes", name: "其他进程（已读取部分）"),
                                                power: sum(other.filter { $0.power != nil }), processCount: other.count,
                                                measuredProcessCount: other.filter { $0.power != nil }.count,
                                                processes: other.map { UsageProcessPower($0, mainPID: nil) }))
        }
        return result
    }
}
