import Foundation
import AppKit
import Security
import SQLite3
import Darwin

struct DiskInsightItem: Codable {
    let entry: DiskAnalysisEntry
    let section: String
    let owner: String
    let ownerID: String
    let category: String
    let risk: String
    let reason: String
    let removable: Bool
    var orphan = false
    var shared = false
    var ruleID = ""
}
struct DiskAppSpace: Codable {
    let name: String
    let bundleID: String
    let path: String
    var parts: [DiskInsightItem]
    var bytes: UInt64 {
        let sorted = parts.filter { !$0.shared }.sorted { $0.entry.path.count < $1.entry.path.count }
        var roots: [String] = []; var total: UInt64 = 0
        for item in sorted where !roots.contains(where: { item.entry.path == $0 || item.entry.path.hasPrefix($0 + "/") }) { roots.append(item.entry.path); total += item.entry.bytes }
        return total
    }
    var sharedBytes: UInt64 { parts.filter(\.shared).reduce(0) { $0 + $1.entry.bytes } }
    enum CodingKeys: String, CodingKey { case name, bundleID, path, parts, bytes, sharedBytes }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(bundleID, forKey: .bundleID); try c.encode(path, forKey: .path)
        try c.encode(parts, forKey: .parts); try c.encode(bytes, forKey: .bytes); try c.encode(sharedBytes, forKey: .sharedBytes)
    }
    init(name: String, bundleID: String, path: String, parts: [DiskInsightItem]) { self.name = name; self.bundleID = bundleID; self.path = path; self.parts = parts }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name); bundleID = try c.decode(String.self, forKey: .bundleID)
        path = try c.decode(String.self, forKey: .path); parts = try c.decode([DiskInsightItem].self, forKey: .parts)
    }
}
struct DiskInsightReport: Codable {
    let requestID: String
    let queryID: String
    var apps: [DiskAppSpace] = []
    var items: [DiskInsightItem] = []
    var updated = Date().timeIntervalSince1970
    var scope = ""
    var error = ""
}

enum DiskInsightRules {
    static let data = "/System/Volumes/Data"
    static func logical(_ path: String) -> String { path.hasPrefix(data + "/") ? String(path.dropFirst(data.count)) : path }
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static func key(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
    static func cacheCategory(_ path: String) -> String {
        let p = path.lowercased()
        if ["safari", "chrome", "chromium", "firefox", "mozilla", "microsoft.edge", "company.thebrowser", "/arc"].contains(where: p.contains) { return "browser" }
        if ["xcode", "deriveddata", "npm", "pnpm", "yarn", "pip", "gradle", "jetbrains", "rust", "cargo", "homebrew", "cocoapods", "swiftpm"].contains(where: p.contains) { return "developer" }
        return p.hasPrefix("/library/") || p.contains("/com.apple.") ? "system" : "application"
    }
    static func groups(_ url: URL) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any], let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
    /// Only immediate children of known expendable/data roots are eligible.
    /// Shared groups, Apple data, system directories and app bundles stay protected.
    static func allowed(_ item: DiskInsightItem) -> Bool {
        let path = logical(item.entry.path), parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let library = home + "/Library"
        let base = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if base.hasPrefix("com.apple.") || base.hasPrefix("group.com.apple.") || base == "macstate" || base.hasPrefix("app.macstate") || item.shared { return false }
        if item.section == "cache" {
            return parent == library + "/Caches" || ["Google", "Microsoft", "Mozilla", "JetBrains"].contains { parent == library + "/Caches/" + $0 }
        }
        if item.section == "developer" { return path == library + "/Developer/Xcode/DerivedData" }
        if item.section == "logs" { return parent == library + "/Logs" }
        if item.orphan && item.risk == "high" {
            return ["Application Support", "Containers", "Preferences"].contains { parent == library + "/" + $0 }
        }
        return false
    }
}

extension DiskAnalysisStore {
    /// Independent extension table: metadata indexing never depends on cleanup
    /// rules. Disabling a rule removes its action eligibility without a rescan.
    func ensureStorageInsightRules() throws {
        try withLock {
            try transaction {
                try execute("""
                    CREATE TABLE IF NOT EXISTS storage_cleanup_rules (
                        id TEXT PRIMARY KEY,version INTEGER NOT NULL,risk TEXT NOT NULL,
                        scope TEXT NOT NULL,enabled INTEGER NOT NULL DEFAULT 1);
                    INSERT OR IGNORE INTO storage_cleanup_rules(id,version,risk,scope) VALUES
                        ('user-cache',1,'safe','current-user/Library/Caches'),
                        ('user-logs',1,'review','current-user/Library/Logs'),
                        ('orphan-support',1,'high','current-user/Library/Application Support'),
                        ('orphan-containers',1,'high','current-user/Library/Containers'),
                        ('orphan-preferences',1,'high','current-user/Library/Preferences'),
                        ('xcode-derived',1,'review','current-user/Library/Developer/Xcode/DerivedData');
                    """)
            }
        }
    }
    func insightEnabledRules() throws -> Set<String> {
        let q = try prepare("SELECT id FROM storage_cleanup_rules WHERE enabled=1 AND version=1")
        defer { sqlite3_finalize(q) }; var result: Set<String> = []
        while true {
            let step = sqlite3_step(q)
            if step == SQLITE_DONE { break }; guard step == SQLITE_ROW else { throw failure() }
            result.insert(string(q,0))
        }
        return result
    }
    func insightChildren(_ path: String) throws -> [DiskAnalysisEntry] {
        let q = try prepare("SELECT \(Self.columns) FROM entries WHERE id IN (SELECT id FROM file_records WHERE root=0 AND dir_id=(SELECT id FROM directory_paths WHERE path=?)) ORDER BY bytes DESC,name")
        defer { sqlite3_finalize(q) }; try bind(path, to: q, at: 1)
        var result: [DiskAnalysisEntry] = []
        while true {
            let step = sqlite3_step(q)
            if step == SQLITE_DONE { break }; guard step == SQLITE_ROW else { throw failure() }
            result.append(entry(q))
        }
        return result
    }
    func insights(requestID: String, queryID: String, root: String, cancellation: DiskScanCancellation) throws -> DiskInsightReport {
        // Short indexed reads; bundle/signing metadata is read after the SQLite
        // snapshot ends, avoiding a long-running reader during code inspection.
        var bundles: [DiskAnalysisEntry] = [], folders: [(String, DiskAnalysisEntry)] = []
        var ownerHints: [String: String] = [:]
        var enabledRules: Set<String> = []
        let home = DiskInsightRules.home
        func mapped(_ path: String) -> String { root == DiskInsightRules.data ? root + path : path }
        try storageSnapshot(cancellation: cancellation) {
            enabledRules = try insightEnabledRules()
            let q = try prepare("SELECT \(Self.columns) FROM entries WHERE id IN (SELECT id FROM file_records WHERE root=0 AND directory=1 AND lower(name) LIKE '%.app') ORDER BY path")
            defer { sqlite3_finalize(q) }
            while true {
                let step = sqlite3_step(q)
                if step == SQLITE_DONE { break }; guard step == SQLITE_ROW else { throw failure() }
                let e = entry(q)
                if !URL(fileURLWithPath: e.path).pathComponents.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) { bundles.append(e) }
            }
            for (section, suffix) in [("cache","Caches"),("support","Application Support"),("containers","Containers"),("groups","Group Containers"),("logs","Logs"),("preferences","Preferences")] {
                for e in try insightChildren(mapped(home + "/Library/" + suffix)) {
                    if section == "cache" && ["Google", "Microsoft", "Mozilla", "JetBrains"].contains(e.name) {
                        let children = try insightChildren(e.path)
                        if children.isEmpty { folders.append((section,e)) }
                        else { for child in children { folders.append((section,child)) } }
                    } else { folders.append((section,e)) }
                    if section == "support" && ["Google", "Microsoft", "Mozilla", "Adobe", "JetBrains"].contains(e.name) {
                        for child in try insightChildren(e.path) { folders.append((section,child)) }
                    }
                    if section == "containers", let cache = try indexedEntry(e.path + "/Data/Library/Caches") {
                        folders.append(("cache",cache)); ownerHints[cache.path] = e.name
                    }
                }
            }
            for e in try insightChildren(mapped("/Library/Caches")) { folders.append(("cache",e)) }
            // DerivedData is a cache, not the whole Developer folder.
            if let e = try indexedEntry(mapped(home + "/Library/Developer/Xcode/DerivedData")) { folders.append(("developer",e)) }
        }
        var report = DiskInsightReport(requestID: requestID, queryID: queryID)
        report.scope = "所选卷的 App 包与当前用户 \(home) 的 Library；仅分析已索引本地目录"
        var ids: [String: [Int]] = [:], names: [String: [Int]] = [:], groups: [String: [Int]] = [:]
        for e in bundles {
            if cancellation.isCancelled { throw Failure(message: "已取消。") }
            let url = URL(fileURLWithPath: e.path)
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
            let identifier = info["CFBundleIdentifier"] as? String ?? ""
            let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
            let index = report.apps.count
            let body = DiskInsightItem(entry: e, section: "body", owner: name, ownerID: identifier, category: "application", risk: "high", reason: "App 本体；请通过 Finder 或系统卸载流程处理。", removable: false)
            report.apps.append(DiskAppSpace(name: name, bundleID: identifier, path: e.path, parts: [body]))
            if !identifier.isEmpty { ids[identifier.lowercased(), default: []].append(index) }
            for key in Set([DiskInsightRules.key(name), DiskInsightRules.key(url.deletingPathExtension().lastPathComponent)]) where key.count >= 4 { names[key, default: []].append(index) }
            let aliases = ["com.google.chrome": "Chrome", "com.microsoft.edgemac": "Edge", "org.mozilla.firefox": "Firefox", "company.thebrowser.browser": "Arc"]
            if let alias = aliases[identifier.lowercased()] { names[DiskInsightRules.key(alias), default: []].append(index) }
            for group in DiskInsightRules.groups(url) { groups[group.lowercased(), default: []].append(index) }
        }
        var installed: [String: Bool] = [:]
        for (section,e) in folders {
            if cancellation.isCancelled { throw Failure(message: "已取消。") }
            let logical = DiskInsightRules.logical(e.path)
            let rawName = ownerHints[e.path] ?? e.name
            let stem = rawName.hasSuffix(".plist") ? String(rawName.dropLast(6)) : rawName
            let lower = stem.lowercased()
            let matches = Array(Set(section == "groups" ? groups[lower] ?? [] : ids[lower] ?? names[DiskInsightRules.key(stem)] ?? [])).sorted()
            let identifierLike = stem.split(separator: ".").count >= 3 && !stem.contains(" ")
            var missing = false
            if matches.isEmpty && identifierLike && section != "groups" && !lower.hasPrefix("com.apple.") {
                if installed[stem] == nil { installed[stem] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: stem) != nil }
                missing = installed[stem] == false
            }
            let orphan = ownerHints[e.path] == nil && missing && ["cache","preferences","support","containers","logs"].contains(section)
            let system = !logical.hasPrefix(home + "/Library/") || lower.hasPrefix("com.apple.")
            let risk = section == "cache" && !system ? "safe" : ["logs","developer"].contains(section) ? "review" : "high"
            let shared = section == "groups" || matches.count > 1
            let owner = matches.map { report.apps[$0].name }.joined(separator: "、")
            let reason: String
            if shared { reason = "共享目录，可能被多个 App 使用；仅分析，不纳入可清理项目。" }
            else if orphan { reason = "未在索引应用及系统注册信息中找到此标识；仅疑似残留，可能含设置或个人数据，须自行确认。" }
            else if risk == "safe" { reason = "可再生成缓存；仍可能含离线资源，清理后 App 可能重新下载。" }
            else if section == "developer" { reason = "Xcode 派生构建缓存，可重新生成；清理后首次构建更慢，请先退出 Xcode。" }
            else if section == "logs" { reason = "日志可用于排查问题，确认不再需要后处理。" }
            else { reason = "可能含应用数据、工程或设置；系统目录及未知归属目录仅供分析。" }
            var item = DiskInsightItem(entry: e, section: section, owner: owner.isEmpty ? "归属未确定" : owner,
                ownerID: section == "developer" ? "com.apple.dt.Xcode" : matches.count == 1 ? report.apps[matches[0]].bundleID : stem,
                category: section == "developer" ? "developer" : DiskInsightRules.cacheCategory(logical + "/" + stem), risk: risk,
                reason: reason, removable: false, orphan: orphan, shared: shared)
            let ruleID: String
            switch section {
            case "cache": ruleID = "user-cache"
            case "logs": ruleID = "user-logs"
            case "developer": ruleID = "xcode-derived"
            case "support", "containers", "preferences": ruleID = orphan ? "orphan-" + section : ""
            default: ruleID = ""
            }
            let allowed = enabledRules.contains(ruleID) && DiskInsightRules.allowed(item) && !e.pending && e.skipped == 0 && e.note.isEmpty && (["cache","logs","developer"].contains(section) || orphan)
            item = DiskInsightItem(entry: e, section: section, owner: item.owner, ownerID: item.ownerID, category: item.category,
                risk: risk, reason: reason, removable: allowed, orphan: orphan, shared: shared)
            item.ruleID = ruleID
            report.items.append(item)
            for index in matches { report.apps[index].parts.append(item) }
        }
        report.apps.sort { $0.bytes > $1.bytes }
        report.items.sort { $0.entry.bytes > $1.entry.bytes }
        return report
    }
}

enum DiskCleanupSafety {
    static func validate(_ item: DiskInsightItem, running: Set<String>) throws {
        let e = item.entry
        guard item.removable, !item.ruleID.isEmpty, DiskInsightRules.allowed(item), !running.contains(item.ownerID.lowercased()),
              !running.contains(where: { id in
                  let name = item.entry.name.lowercased()
                  return id.hasPrefix(name + ".") || name.hasPrefix(id + ".") ||
                      (["google", "microsoft", "mozilla", "adobe", "jetbrains"].contains(name) && id.split(separator: ".").contains(Substring(name))) ||
                      (["com.google.chrome", "com.microsoft.edgemac", "org.mozilla.firefox", "company.thebrowser.browser"].contains(id) && item.category == "browser" && item.owner == "归属未确定")
              }),
              !DiskLocalPolicy.isIndexStorage(e.path), DiskLocalPolicy.exclusion(e.path) == nil,
              DiskLocalPolicy.isLocalVolume(e.path) else {
            throw DiskAnalysisStore.Failure(message: "此项目受保护，或关联 App 正在运行。请先退出相关 App；共享和系统目录需在 Finder 自行处理。")
        }
        let url = URL(fileURLWithPath: e.path)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard DiskInsightRules.logical(parent) == DiskInsightRules.logical(url.deletingLastPathComponent().path) else {
            throw DiskAnalysisStore.Failure(message: "目录经过链接重定向，已阻止清理。")
        }
        var value = stat()
        guard lstat(e.path, &value) == 0 else { throw DiskAnalysisStore.Failure(message: "项目已移动或无法访问，请刷新分析。") }
        let type = value.st_mode & S_IFMT
        let modified = Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1e9
        guard type == (e.directory ? S_IFDIR : S_IFREG), value.st_flags & UInt32(SF_DATALESS) == 0,
              Int64(value.st_dev) == e.device, Int64(clamping: value.st_ino) == e.inode, abs(modified - e.modified) < 0.000001,
              e.directory || UInt64(max(0,value.st_size)) == e.logicalBytes else {
            throw DiskAnalysisStore.Failure(message: "项目类型或内容状态已变化，请刷新分析并重新预览。")
        }
        if item.orphan && NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.ownerID) != nil {
            throw DiskAnalysisStore.Failure(message: "此标识已有已安装应用，已阻止按残留清理，请刷新分析。")
        }
    }
}
