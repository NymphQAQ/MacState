import Foundation
import Darwin

/// Directory I/O is isolated from scheduling, storage and UI callbacks. Three
/// background readers plus a reserved interactive slot keep clicked folders
/// responsive even when a reader waits inside the filesystem.
final class DiskScanSession {
    private struct Identity: Hashable { let device: Int32; let inode: UInt64 }
    private struct Item { var entry: DiskAnalysisEntry; let identity: Identity?; let excluded: Bool }
    var onProgress: ((DiskAnalysisProgress) -> Void)?
    var onCompletion: ((DiskAnalysisResult) -> Void)?
    private let backgroundReaders: Int
    private let storeURL: URL?
    private let scanner: DiskAnalysisScanner
    private let root: URL, volumePath: String, name: String, requestID: String
    private let cancellation: DiskScanCancellation
    private let coordinator = DispatchQueue(label: "app.macstate.disk-scheduler", qos: .utility)
    private let readers = DispatchQueue(label: "app.macstate.disk-readers", qos: .utility, attributes: .concurrent)
    private let storeLock = NSLock()
    private var store: DiskAnalysisStore?
    private var timer: DispatchSourceTimer?
    private var started = Date(), state = "scanning", message = ""
    private var files = 0, directories = 0, skipped = 0, excluded = 0
    private var bytes: UInt64 = 0
    private var currentPath: String, preferredPath: String?
    private var device: Int32 = 0
    private var active = Set<String>(), hardLinks = Set<Identity>()
    private var largest: [DiskAnalysisEntry] = []
    private var initialized = false
    private var lastPublished = Date.distantPast

    init(scanner: DiskAnalysisScanner, root: URL, volumePath: String, name: String,
         requestID: String, cancellation: DiskScanCancellation, storeURL: URL? = nil, backgroundReaders: Int = 3) {
        self.backgroundReaders = min(8, max(1, backgroundReaders))
        self.storeURL = storeURL
        self.scanner = scanner; self.root = root; self.volumePath = volumePath
        self.name = name; self.requestID = requestID; self.cancellation = cancellation; currentPath = root.path
    }

    func start() {
        coordinator.async { [self] in
            started = Date()
            do {
                let cache = try DiskAnalysisStore(url: storeURL, deferSizeIndexes: storeURL != nil)
                try cache.insert(DiskAnalysisEntry(path: root.path, name: name, directory: true,
                    browsable: true, bytes: 0, pending: true), parent: nil, pending: 1)
                storeLock.lock(); store = cache; storeLock.unlock()
            } catch { finish("failed", message: "无法创建本地明细缓存：\(error.localizedDescription)"); return }
            let clock = DispatchSource.makeTimerSource(queue: coordinator)
            clock.schedule(deadline: .now() + 0.1, repeating: 0.5)
            clock.setEventHandler { [weak self] in
                guard let self else { return }
                if cancellation.isCancelled { finish("cancelled") } else { publish() }
            }
            timer = clock; clock.resume()
            readers.async { [self] in
                let allowed = scanner.exclusion(root.path) == nil
                let local = allowed && DiskLocalPolicy.isLocalVolume(root.path)
                let info = local ? scanner.metadata(root.path) : nil
                coordinator.async { [self] in
                    guard state == "scanning" else { return }
                    guard local, scanner.exclusion(root.path) == nil else {
                        finish("failed", message: "仅扫描本地目录，不能扫描手机、云端映射或网络卷。"); return
                    }
                    guard let info, info.st_mode & S_IFMT == S_IFDIR else {
                        finish("failed", message: "存储卷已断开或目录无法读取。"); return
                    }
                    device = info.st_dev; bytes = UInt64(max(0, info.st_blocks)) * 512; directories = 1
                    do {
                        try store?.withLock {
                            try store?.addTotals(path: root.path, bytes: bytes)
                            try store?.enqueue(path: root.path, depth: 0, priority: false)
                        }
                        initialized = true; publish(force: true)
                        if cancellation.isCancelled { finish("cancelled") } else { schedule() }
                    } catch { fail(error) }
                }
            }
        }
    }

    func cancel() {
        cancellation.cancel()
        coordinator.async { [self] in if state == "scanning" { finish("cancelled") } }
    }

    func prioritize(path: String) {
        coordinator.async { [self] in
            guard state == "scanning", store?.contains(path: path) == true else { return }
            preferredPath = path
            do { try store?.withLock { try store?.prioritize(path: path) }; schedule() }
            catch { fail(error) }
        }
    }

    func page(path: String, offset: Int) -> DiskDirectoryPage? {
        storeLock.lock(); let cache = store; storeLock.unlock()
        let identity = DiskAnalysisProgress(requestID: requestID, volumePath: volumePath, rootPath: root.path,
            state: "scanning", files: 0, directories: 0, bytes: 0, skipped: 0, elapsed: 0, currentPath: "", message: "", largest: [])
        return DiskAnalysisResult(progress: identity, store: cache).page(path: path, offset: offset)
    }

    func contains(path: String) -> Bool {
        storeLock.lock(); let cache = store; storeLock.unlock()
        return cache?.contains(path: path) == true
    }

    private func schedule() {
        guard state == "scanning", initialized else { return }
        if cancellation.isCancelled { finish("cancelled"); return }
        do {
            while active.count < backgroundReaders + 1 {
                // The fourth reader is reserved for a user-selected subtree.
                guard let job = try store?.withLock({ try store?.nextJob(priorityOnly: active.count >= backgroundReaders) }) else { break }
                active.insert(job.path); currentPath = job.path
                readers.async { [self] in read(path: job.path, depth: job.depth) }
            }
            if active.isEmpty { finish("completed") }
        } catch { fail(error) }
    }

    private func read(path: String, depth: Int) {
        // A bounded channel prevents directory readers from buffering millions
        // of file details while the database is busy. No main-thread waits.
        let capacity = DispatchSemaphore(value: 2)
        func deliver(_ batch: [Item]) {
            capacity.wait()
            coordinator.async { [self] in
                defer { capacity.signal() }
                guard state == "scanning", !cancellation.isCancelled else { return }
                do { try consume(batch, parent: path, childDepth: depth + 1); schedule() }
                catch { fail(error) }
            }
        }
        do {
            let names = try scanner.listDirectory(path)
            var batch: [Item] = []
            for child in names {
                if cancellation.isCancelled { break }
                let childPath = (path == "/" ? "" : path) + "/" + child
                if let reason = scanner.exclusion(childPath) {
                    batch.append(Item(entry: DiskAnalysisEntry(path: childPath, name: child, directory: true,
                        bytes: 0, skipped: 1, note: reason), identity: nil, excluded: true))
                } else if let info = scanner.metadata(childPath) {
                    let directory = info.st_mode & S_IFMT == S_IFDIR
                    let nonlocal = info.st_dev != device || info.st_flags & UInt32(SF_DATALESS) != 0
                    let tooDeep = directory && depth + 1 > scanner.maximumDepth
                    let omit = nonlocal || tooDeep
                    var entry = DiskAnalysisEntry(path: childPath, name: child, directory: directory,
                        browsable: directory && !omit, bytes: omit ? 0 : UInt64(max(0, info.st_blocks)) * 512,
                        files: !directory && !omit ? 1 : 0, skipped: omit ? 1 : 0, pending: directory && !omit,
                        note: nonlocal ? "其他挂载卷或未下载的占位文件，已跳过" : tooDeep ? "超出目录深度保护范围" : "")
                    entry.setMetadata(info)
                    let identity = !directory && info.st_nlink > 1 && info.st_mode & S_IFMT == S_IFREG
                        ? Identity(device: info.st_dev, inode: info.st_ino) : nil
                    batch.append(Item(entry: entry, identity: identity, excluded: nonlocal))
                } else {
                    batch.append(Item(entry: DiskAnalysisEntry(path: childPath, name: child, directory: false,
                        bytes: 0, skipped: 1, note: "无法读取文件属性"), identity: nil, excluded: false))
                }
                if batch.count == 1024 { deliver(batch); batch.removeAll(keepingCapacity: true) }
            }
            if !batch.isEmpty { deliver(batch) }
            coordinator.async { [self] in directoryFinished(path: path, error: nil) }
        } catch { coordinator.async { [self] in directoryFinished(path: path, error: error) } }
    }

    private func consume(_ batch: [Item], parent: String, childDepth: Int) throws {
        guard let store else { return }
        try store.withLock {
            var addedBytes: UInt64 = 0, addedFiles = 0, addedSkipped = 0, addedPending = 0
            for item in batch {
                var entry = item.entry
                if let identity = item.identity, !hardLinks.insert(identity).inserted { entry.bytes = 0 }
                try store.insert(entry, parent: parent, pending: entry.pending ? 1 : 0)
                if entry.pending {
                    let priority = preferredPath.map { entry.path == $0 || entry.path.hasPrefix($0 + "/") } ?? false
                    try store.enqueue(path: entry.path, depth: childDepth, priority: priority); addedPending += 1
                }
                if entry.directory { directories += 1 } else { files += entry.files }
                addedBytes += entry.bytes; addedFiles += entry.files; addedSkipped += entry.skipped
                if item.excluded { excluded += 1 }
                if !entry.directory, entry.files > 0, entry.bytes > 0 {
                    if largest.count < 50 || DiskAnalysisScanner.larger(entry, largest.last!) {
                        largest.append(entry); largest.sort(by: DiskAnalysisScanner.larger)
                        if largest.count > 50 { largest.removeLast() }
                    }
                }
            }
            bytes += addedBytes; skipped += addedSkipped
            for ancestor in ancestors(of: parent) {
                try store.addTotals(path: ancestor, bytes: addedBytes, files: addedFiles, skipped: addedSkipped,
                    children: ancestor == parent ? batch.count : 0, pending: addedPending)
            }
        }
    }

    private func directoryFinished(path: String, error: Error?) {
        guard state == "scanning" else { return }
        do {
            try store?.withLock {
                if let error { skipped += 1; try store?.directoryReadNote(path:path,note:"无法读取目录："+error.localizedDescription) }
                for ancestor in ancestors(of: path) {
                    try store?.addTotals(path: ancestor, skipped: error == nil ? 0 : 1, pending: -1)
                }
            }
            active.remove(path); publish(); schedule()
        } catch { fail(error) }
    }

    private func ancestors(of path: String) -> [String] {
        var values: [String] = [], current = path
        while current == root.path || current.hasPrefix(root.path == "/" ? "/" : root.path + "/") {
            values.append(current)
            if current == root.path { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return values
    }

    private func progress() -> DiskAnalysisProgress {
        DiskAnalysisProgress(requestID: requestID, volumePath: volumePath, rootPath: root.path, state: state,
            files: files, directories: directories, bytes: bytes, skipped: skipped,
            elapsed: Date().timeIntervalSince(started), currentPath: currentPath, message: message,
            largest: largest, excluded: excluded)
    }
    private func publish(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublished) >= 0.4 else { return }
        if storeURL != nil, state == "scanning", initialized {
            do { try store?.checkpointBuild() } catch { fail(error); return }
        }
        lastPublished = now; onProgress?(progress())
    }
    private func fail(_ error: Error) { finish("failed", message: "本地明细缓存写入失败：\(error.localizedDescription)") }
    private func finish(_ finalState: String, message: String = "") {
        guard state == "scanning" else { return }
        state = finalState; self.message = message; timer?.cancel(); timer = nil
        if finalState != "completed" { cancellation.cancel() }
        do { try store?.finish(buildIndexes: finalState == "completed") }
        catch { state = "failed"; self.message = "本地明细缓存保存失败：\(error.localizedDescription)" }
        let result = DiskAnalysisResult(progress: progress(), store: store)
        onProgress?(result.progress); onCompletion?(result)
    }
}
