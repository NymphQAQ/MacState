import Foundation
import Darwin

struct DiskAnalysisEntry: Codable {
    let path: String
    let name: String
    let directory: Bool
    var browsable = false
    var bytes: UInt64
    var files: Int = 0
    var skipped: Int = 0
    var pending = false
    var note = ""
    var logicalBytes: UInt64 = 0
    var allocatedBytes: UInt64 = 0
    var modified: Double = 0
    var created: Double = 0
    var fileExtension = ""
    var kind = "other"
    var device: Int64 = 0
    var inode: Int64 = 0
    var links: Int = 1
}

struct DiskAnalysisProgress: Codable {
    let requestID: String
    let volumePath: String
    let rootPath: String
    let state: String
    let files: Int
    let directories: Int
    let bytes: UInt64
    let skipped: Int
    let elapsed: Double
    let currentPath: String
    let message: String
    let largest: [DiskAnalysisEntry]
    var excluded: Int = 0
}

struct DiskDirectoryPage: Codable {
    struct Breadcrumb: Codable { let name: String; let path: String }
    let requestID: String
    let path: String
    let bytes: UInt64
    let files: Int
    let skipped: Int
    let entryCount: Int
    let offset: Int
    let entries: [DiskAnalysisEntry]
    let breadcrumbs: [Breadcrumb]
    var pending = false
    var filtered = false
    var countIsExact = true
    var searchText: String? = nil
    var searchKind: String? = nil
    var sortKey: String? = nil
    var sortDescending: Bool? = nil
}

final class DiskScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

struct DiskAnalysisResult {
    let progress: DiskAnalysisProgress
    let store: DiskAnalysisStore?

    func page(path: String, offset: Int = 0, sort: DiskFileSort = DiskFileSort()) -> DiskDirectoryPage? {
        guard let store else { return nil }
        do {
            return try store.withLock {
            guard let node = try store.directory(path: path) else { return nil }
            let start = min(max(0, offset / 100 * 100), max(0, (node.childCount - 1) / 100 * 100))
            var breadcrumbs: [DiskDirectoryPage.Breadcrumb] = []
            var current: DiskAnalysisStore.Directory? = node
            while let item = current {
                breadcrumbs.append(.init(name: item.entry.name, path: item.entry.path))
                current = try item.parent.flatMap { try store.directory(path: $0) }
            }
            return DiskDirectoryPage(requestID: progress.requestID, path: path, bytes: node.entry.bytes,
                                     files: node.entry.files, skipped: node.entry.skipped, entryCount: node.childCount,
                                     offset: start, entries: try store.children(path: path, offset: start, sort: sort), breadcrumbs: breadcrumbs.reversed(), pending: node.entry.pending, sortKey: sort.key, sortDescending: sort.descending)
            }
        } catch {
            return nil
        }
    }

    func contains(path: String) -> Bool {
        store?.contains(path: path) == true
    }
}

/// Metadata-only scan: no file contents, previews, subprocesses or cloud downloads.
final class DiskAnalysisScanner {
    let maximumDepth: Int
    let metadata: (String) -> stat?
    let listDirectory: (String) throws -> [String]
    let exclusion: (String) -> String?

    init(maximumDepth: Int = 256,
         metadata: @escaping (String) -> stat? = { path in
             var value = stat()
             return lstat(path, &value) == 0 ? value : nil
         }, listDirectory: @escaping (String) throws -> [String] = { try DiskAnalysisScanner.directoryNames($0) },
         exclusion: @escaping (String) -> String? = DiskLocalPolicy.exclusion) {
        self.maximumDepth = maximumDepth; self.metadata = metadata
        self.listDirectory = listDirectory; self.exclusion = exclusion
    }

    private static func directoryNames(_ path: String) throws -> [String] {
        // Foundation's URL enumerator requests bulk attributes, which can wait
        // on a File Provider even though we only need directory entry names.
        guard let directory = opendir(path) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let item = readdir(directory) else {
                if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return names
            }
            let name = withUnsafePointer(to: item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    static func scanRoot(volumePath: String) -> URL {
        // macOS exposes writable content through firmlinks on /. Scan the Data
        // volume once so Users/Applications are included without double counting.
        let data = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        if volumePath == "/", FileManager.default.fileExists(atPath: data.path) { return data }
        return URL(fileURLWithPath: volumePath, isDirectory: true).standardizedFileURL
    }

    static func larger(_ a: DiskAnalysisEntry, _ b: DiskAnalysisEntry) -> Bool {
        a.bytes == b.bytes ? a.path < b.path : a.bytes > b.bytes
    }

    // Synchronous adapter for fixtures/diagnostics. The application uses the
    // asynchronous session directly; no filesystem operation runs on main.
    func scan(root: URL, volumePath: String, name: String, requestID: String,
              cancellation: DiskScanCancellation, onProgress: @escaping (DiskAnalysisProgress) -> Void = { _ in }) -> DiskAnalysisResult {
        let done = DispatchSemaphore(value: 0)
        var result: DiskAnalysisResult!
        let session = DiskScanSession(scanner: self, root: root, volumePath: volumePath, name: name,
                                      requestID: requestID, cancellation: cancellation)
        session.onProgress = onProgress
        session.onCompletion = { result = $0; done.signal() }
        session.start(); done.wait()
        return result
    }
}

/// Main-thread facade. Permission probes, filesystem work and page queries use
/// separate queues, so a slow device cannot block browsing, elapsed time or Stop.
final class DiskAnalysisService {
    var onProgress: ((DiskAnalysisProgress) -> Void)?
    var onDirectory: ((DiskDirectoryPage) -> Void)?
    var onAccess: ((DiskAccessStatus) -> Void)?
    private let queryQueue = DispatchQueue(label: "app.macstate.disk-pages", qos: .userInitiated)
    private let accessQueue = DispatchQueue(label: "app.macstate.disk-access", qos: .utility)
    private var session: DiskScanSession?
    private var requestID: String?
    private var browseRevision = 0
    private var selectedPath: String?
    private var selectedOffset = 0
    private var pageInFlight = false
    private var pendingCancellation = false
    private let scannerFactory: () -> DiskAnalysisScanner
    private let accessCheck: () -> DiskAccessStatus

    init(scannerFactory: @escaping () -> DiskAnalysisScanner = { DiskAnalysisScanner() },
         accessCheck: @escaping () -> DiskAccessStatus = DiskAccess.check) {
        self.scannerFactory = scannerFactory; self.accessCheck = accessCheck
    }

    func checkAccess(_ completion: @escaping (DiskAccessStatus) -> Void) {
        accessQueue.async { [weak self, accessCheck = self.accessCheck] in
            let status = accessCheck()
            DispatchQueue.main.async { [weak self] in self?.onAccess?(status); completion(status) }
        }
    }

    func start(volume: VolumeRow, requestID: String) {
        cancel(); self.requestID = requestID; session = nil
        browseRevision += 1; selectedPath = nil; selectedOffset = 0; pageInFlight = false
        pendingCancellation = false
        checkAccess { [weak self] status in
            guard let self, self.requestID == requestID else { return }
            guard status == .granted else {
                self.onProgress?(DiskAnalysisProgress(requestID: requestID, volumePath: volume.path, rootPath: volume.path,
                    state: "failed", files: 0, directories: 0, bytes: 0, skipped: 0, elapsed: 0, currentPath: "",
                    message: "尚未确认完全磁盘访问权限，请先在存储页重新检查权限。", largest: []))
                return
            }
            let root = DiskAnalysisScanner.scanRoot(volumePath: volume.path)
            let token = DiskScanCancellation()
            if self.pendingCancellation { token.cancel() }
            let session = DiskScanSession(scanner: self.scannerFactory(), root: root, volumePath: volume.path,
                                          name: volume.name, requestID: requestID, cancellation: token)
            self.session = session; self.selectedPath = root.path
            session.onProgress = { [weak self] update in
                DispatchQueue.main.async {
                    guard let self, self.requestID == requestID else { return }
                    self.onProgress?(update); self.refreshPage()
                }
            }
            session.start()
        }
    }

    func cancel() { session?.cancel() }
    func cancel(requestID: String) {
        guard self.requestID == requestID else { return }
        if let session { session.cancel() } else { pendingCancellation = true }
    }

    func browse(path: String, requestID: String, offset: Int) {
        guard self.requestID == requestID, let session else { return }
        browseRevision += 1; selectedPath = path; selectedOffset = offset
        session.prioritize(path: path)
        refreshPage(force: true)
    }

    private func refreshPage(force: Bool = false) {
        guard let session, let path = selectedPath, let requestID, force || !pageInFlight else { return }
        let revision = browseRevision, offset = selectedOffset
        pageInFlight = true
        queryQueue.async { [weak self] in
            let page = session.page(path: path, offset: offset)
            DispatchQueue.main.async {
                guard let self, self.requestID == requestID, self.browseRevision == revision else { return }
                self.pageInFlight = false
                if let page { self.onDirectory?(page) }
            }
        }
    }

    func revealURL(path: String, requestID: String) -> URL? {
        guard self.requestID == requestID, session?.contains(path: path) == true else { return nil }
        return URL(fileURLWithPath: path)
    }

    func reveal(path: String, requestID: String, completion: @escaping (URL) -> Void) {
        guard self.requestID == requestID, let session else { return }
        queryQueue.async { [weak self] in
            guard session.contains(path: path) else { return }
            DispatchQueue.main.async {
                guard self?.requestID == requestID else { return }
                completion(URL(fileURLWithPath: path))
            }
        }
    }
}
