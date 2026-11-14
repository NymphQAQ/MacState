import Foundation
import SQLite3

/// Maintenance never shares the query or metadata-writer connection. PASSIVE
/// copies only eligible WAL pages and does not wait for readers to finish.
final class DiskIndexCheckpoint {
    private let queue = DispatchQueue(label: "app.macstate.index-checkpoint", qos: .utility)
    private var database: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let walURL: URL
    private let didTruncate: () -> Void

    init(url: URL, didTruncate: @escaping () -> Void = {}) throws {
        walURL = URL(fileURLWithPath: url.path + "-wal")
        self.didTruncate = didTruncate
        queue.setSpecific(key: queueKey, value: 1)
        // SQLite opens lazily; attach the WAL before disabling writer auto-checkpoint.
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              sqlite3_exec(database, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开索引维护连接"
            sqlite3_close(database); database = nil
            throw DiskAnalysisStore.Failure(message: message)
        }
        sqlite3_busy_timeout(database, 0)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.checkpoint() }
        self.timer = timer; timer.resume()
    }

    func request() { queue.async { [weak self] in self?.checkpoint() } }

    private func checkpoint() {
        guard let database else { return }
        // BUSY is expected while another connection is writing/checkpointing.
        // Keep the WAL intact and retry on the next maintenance tick.
        var frames: Int32 = -1, written: Int32 = -1
        let result = sqlite3_wal_checkpoint_v2(database, "main", SQLITE_CHECKPOINT_PASSIVE, &frames, &written)
        guard result == SQLITE_OK, frames >= 0 else {
            if result != SQLITE_BUSY { NSLog("索引回写未完成：status=%d, frames=%d", result, frames) }
            return
        }
        guard written == frames,
              let attributes = try? FileManager.default.attributesOfItem(atPath: walURL.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 64 * 1024 * 1024 else { return }
        // Reclaim oversized files only after every page is safe; busy readers retry later.
        let truncation = sqlite3_wal_checkpoint_v2(database, "main", SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        if truncation == SQLITE_OK {
            didTruncate()
        } else if truncation != SQLITE_BUSY {
            NSLog("索引日志回收未完成：status=%d", truncation)
        }
    }

    func stop() {
        timer?.cancel(); timer = nil
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            sqlite3_close(database); database = nil
        } else {
            queue.sync { sqlite3_close(database); database = nil }
        }
    }

    deinit { stop() }
}
