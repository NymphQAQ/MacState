import Foundation
import Darwin

/// Directory readers never write SQLite or block the event coordinator. At most
/// two 64-entry batches per worker can wait to be consumed.
enum DiskIndexDirectoryReader {
    struct Item { let path: String; let entry: DiskAnalysisEntry? }
    enum Outcome { case finished, missing, skipped, unreadable }
    typealias Read = (String, String, dev_t, DiskScanCancellation, ([Item]) -> Void) -> Outcome
    static func read(path: String, root: String, device: dev_t, cancellation: DiskScanCancellation,
                     batch: ([Item]) -> Void) -> Outcome {
        guard !cancellation.isCancelled, DiskLocalPolicy.exclusion(path) == nil else { return .skipped }
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable }
        guard info.st_dev == device, info.st_flags & UInt32(SF_DATALESS) == 0 else { return .skipped }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .missing }
        let depth = path.dropFirst(root.count).split(separator: "/").count
        guard depth <= 256 else { return .skipped }
        guard let directory = opendir(path) else { return errno == ENOENT ? .missing : .unreadable }
        defer { closedir(directory) }
        var items: [Item] = []
        while !cancellation.isCancelled {
            errno = 0
            guard let record = readdir(directory) else {
                let result: Outcome = errno == 0 ? .finished : .unreadable
                if !items.isEmpty { batch(items) }
                return result
            }
            let name = withUnsafePointer(to: record.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(record.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let child = (path == "/" ? "" : path) + "/" + name
            var entry: DiskAnalysisEntry?
            if let reason = DiskLocalPolicy.exclusion(child) {
                entry = DiskAnalysisEntry(path: child, name: name, directory: true, bytes: 0, skipped: 1, note: reason)
            } else {
                var value = stat()
                if lstat(child, &value) == 0 {
                    let isDirectory = value.st_mode & S_IFMT == S_IFDIR
                    let omitted = value.st_dev != device || value.st_flags & UInt32(SF_DATALESS) != 0 || (isDirectory && depth + 1 > 256)
                    var item = DiskAnalysisEntry(path: child, name: name, directory: isDirectory, browsable: isDirectory && !omitted,
                        bytes: omitted ? 0 : UInt64(max(0, value.st_blocks)) * 512, files: !isDirectory && !omitted ? 1 : 0,
                        skipped: omitted ? 1 : 0, note: omitted ? "非本地文件、其他挂载卷或超出目录深度，已跳过" : "")
                    item.setMetadata(value); entry = item
                }
            }
            // An attribute-read race must not masquerade as removal.
            items.append(Item(path: child, entry: entry))
            if items.count == 64 { batch(items); items.removeAll(keepingCapacity: true) }
        }
        return .skipped
    }
}
