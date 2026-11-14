import Foundation
import AppKit
import SQLite3

enum DiskIndexMaintenance {
    /// Explicit offline maintenance for an existing index. Only saved metadata
    /// is read: no collector, permission request or filesystem scan is started.
    static func runIfRequested(_ arguments: [String]) -> Bool {
        guard let option = arguments.firstIndex(of: "--optimize-disk-index") else { return false }
        guard arguments.indices.contains(option + 1), arguments.count == option + 2 else {
            fputs("用法：MacState --optimize-disk-index <已有索引.sqlite>\n", stderr); exit(2)
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "app.macstate.monitor").allSatisfy({ $0.processIdentifier == ProcessInfo.processInfo.processIdentifier }) else {
            fputs("请先退出 MacState，再优化索引。\n", stderr); exit(2)
        }
        do {
            let url = URL(fileURLWithPath: arguments[option + 1])
            let started = Date()
            let before = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            let store = try DiskAnalysisStore(url: url, existing: true)
            let count = try store.prepare("SELECT COUNT(*) FROM file_records")
            defer { sqlite3_finalize(count) }
            guard sqlite3_step(count) == SQLITE_ROW else { throw store.failure() }
            let records = sqlite3_column_int64(count, 0)
            let after = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            let output: [String: Any] = ["beforeBytes": before, "afterBytes": after, "records": records,
                "elapsedSeconds": Date().timeIntervalSince(started), "root": try store.metadata("root") ?? ""]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        } catch { fputs("索引优化失败：\(error.localizedDescription)\n", stderr); exit(1) }
        return true
    }
}
