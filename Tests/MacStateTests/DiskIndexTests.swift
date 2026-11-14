import Foundation
import Darwin
import CoreServices
import SQLite3
import Testing
@testable import MacState

private func fixtureEntry(_ url: URL) throws -> DiskAnalysisEntry {
    var info = stat()
    try #require(lstat(url.path, &info) == 0)
    let directory = info.st_mode & S_IFMT == S_IFDIR
    var result = DiskAnalysisEntry(path: url.path, name: url.lastPathComponent, directory: directory,
        browsable: directory, bytes: UInt64(max(0, info.st_blocks)) * 512, files: directory ? 0 : 1)
    result.setMetadata(info); return result
}

@Test func persistentDiskIndexPreservesMetadataAndUpdatesHardLinksAndAncestors() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("files"), folder = root.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let text = folder.appendingPathComponent("你好.TXT"), alias = root.appendingPathComponent("alias.txt")
    try Data(repeating: 65, count: 16000).write(to: text)
    try FileManager.default.linkItem(at: text, to: alias)
    let database = base.appendingPathComponent("index.sqlite")
    let session = DiskScanSession(scanner: DiskAnalysisScanner(), root: root, volumePath: root.path,
        name: "Fixture", requestID: "baseline", cancellation: DiskScanCancellation(), storeURL: database)
    let done = DispatchSemaphore(value: 0)
    var baseline: DiskAnalysisResult?
    session.onCompletion = { baseline = $0; done.signal() }; session.start()
    try #require(done.wait(timeout: .now() + 10) == .success)
    let result = try #require(baseline)
    #expect(result.progress.state == "completed")
    let store = try #require(result.store)
    let physical = try fixtureEntry(text).allocatedBytes
    try store.transaction { try store.setMetadata("directories", "2"); try store.setMetadata("cursor", "42") }
    let reopened = try DiskAnalysisStore(url: database, existing: true)
    #expect(try reopened.metadata("cursor") == "42")
    let indexed = try #require(reopened.withLock { try reopened.indexedEntry(text.path) })
    #expect(indexed.kind == "text" && indexed.fileExtension == "txt")
    #expect(indexed.logicalBytes == 16000 && indexed.modified > 0 && indexed.created > 0)
    let rootBefore = try #require(try reopened.directory(path: root.path)).entry.bytes
    try store.transaction { try store.removeIndexedTree(alias.path, root: root.path) }
    #expect(try store.directory(path: root.path)?.entry.bytes == rootBefore)
    #expect(try store.withLock { try store.indexedEntry(text.path)?.bytes } == physical)
    #expect(try store.directory(path: root.path)?.entry.files == 1)
    try FileManager.default.removeItem(at: alias)
    try Data(repeating: 66, count: 64000).write(to: text)
    let changed = try fixtureEntry(text)
    try store.transaction { _ = try store.upsertIndexedEntry(changed, root: root.path) }
    #expect(try store.directory(path: folder.path)?.entry.files == 1)
    #expect(try store.directory(path: root.path)?.entry.bytes == rootBefore - physical + changed.allocatedBytes)
    try store.transaction { try store.removeIndexedTree(folder.path, root: root.path) }
    #expect(try store.directory(path: root.path)?.entry.files == 0)
    #expect(try store.metadata("directories") == "1")
    #expect(!store.contains(path: text.path))
    #expect(try store.largestFiles().isEmpty)
    let literal = root.appendingPathComponent("report%_你好.txt")
    try Data("fixture".utf8).write(to: literal)
    try store.transaction { _ = try store.upsertIndexedEntry(fixtureEntry(literal), root: root.path) }
    let search = try #require(try store.searchPage(requestID: "search", root: root.path, query: DiskFileQuery(text: "%_", kind: "text"), offset: 0))
    #expect(search.filtered && search.entryCount == 1 && search.entries.first?.path == literal.path)
    #expect(try store.searchPage(requestID: "search", root: root.path, query: DiskFileQuery(text: "你好", kind: "image"), offset: 0)?.entryCount == 0)
    #expect(DiskFileQuery(text: "  hello  ", kind: "SQL injection").kind.isEmpty)
}

@Test func backgroundDiskIndexTracksRealFileEventsAndCatchesUpAfterRestart() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let source = temp.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    // Canonical Data-volume path matches per-device FSEvents names.
    let resolved = try #require(realpath(source.path, nil))
    let canonical = String(cString: resolved); free(resolved)
    let root = URL(fileURLWithPath: "/System/Volumes/Data" + canonical)
    let cache = temp.appendingPathComponent("cache")
    let row = VolumeRow(name: "Fixture", path: root.path, total: 100000, available: 50000)
    let queue = DispatchQueue(label: "test.disk-index")
    let index = IndexedVolume(volume: row, baseURL: cache, queue: queue, rootOverride: root)
    queue.sync { index.start() }
    defer { queue.sync { index.stop() } }
    for _ in 0..<300 {
        if queue.sync(execute: { index.status.state == "ready" }) { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    try #require(queue.sync { index.status.state == "ready" }, "Status: \(queue.sync { index.status })")
    let nested = source.appendingPathComponent("new/nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = nested.appendingPathComponent("picture.png")
    try Data(repeating: 70, count: 16384).write(to: file)
    let indexedPath = root.appendingPathComponent("new/nested/picture.png").path
    for _ in 0..<400 {
        if queue.sync(execute: { index.store?.contains(path: indexedPath) == true && index.status.state == "ready" }) { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    try #require(queue.sync { index.store?.contains(path: indexedPath) == true })
    #expect(queue.sync { index.status.files } == 1)
    let renamed = nested.appendingPathComponent("renamed.jpg")
    try FileManager.default.moveItem(at: file, to: renamed)
    let renamedPath = root.appendingPathComponent("new/nested/renamed.jpg").path
    for _ in 0..<400 {
        if queue.sync(execute: { index.store?.contains(path: renamedPath) == true && index.store?.contains(path: indexedPath) == false && index.status.state == "ready" }) { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(queue.sync { index.store?.contains(path: indexedPath) } == false)
    try #require(queue.sync { index.store?.contains(path: renamedPath) == true })
    try Data(repeating: 75, count: 65536).write(to: renamed)
    for _ in 0..<400 {
        if queue.sync(execute: { (try? index.store?.indexedEntry(renamedPath)?.logicalBytes) == 65536 && index.status.state == "ready" }) { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(queue.sync { try? index.store?.indexedEntry(renamedPath)?.logicalBytes } == 65536)
    queue.sync { index.stop() }
    try FileManager.default.removeItem(at: source.appendingPathComponent("new"))
    try Data(repeating: 90, count: 32768).write(to: source.appendingPathComponent("offline.txt"))
    let restored = IndexedVolume(volume: row, baseURL: cache, queue: queue, rootOverride: root)
    queue.sync { restored.start() }
    defer { queue.sync { restored.stop() } }
    #expect(queue.sync { restored.status.state } != "indexing")
    let offline = root.appendingPathComponent("offline.txt").path
    for _ in 0..<400 {
        if queue.sync(execute: { restored.store?.contains(path: offline) == true && restored.store?.contains(path: renamedPath) == false && restored.status.state == "ready" }) { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(queue.sync { restored.status.state } == "ready")
    #expect(queue.sync { restored.store?.contains(path: offline) } == true)
    #expect(queue.sync { restored.store?.contains(path: renamedPath) } == false)
    #expect(queue.sync { restored.status.files } == 1)

    // A coalesced event must recursively verify the same database, never call
    // beginBuild or reset completion time. Excluded events must remain idle.
    let completed = queue.sync { restored.status.completedAt }
    let sameStore = queue.sync { restored.store }
    var restarted = false
    queue.sync {
        restored.onChange = { if restored.status.state == "indexing" { restarted = true } }
        restored.receive([.init(path: canonical, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), id: 0)])
    }
    #expect(queue.sync { restored.status.state } == "verifying")
    #expect(queue.sync { restored.status.ready })
    for _ in 0..<200 {
        if queue.sync(execute: { restored.status.state == "ready" }) { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(queue.sync { restored.store === sameStore && restored.status.completedAt == completed && !restarted })
    #expect(completed > 0)
    let updatedBefore = queue.sync { restored.status.updated }
    queue.sync {
        restored.receive([.init(path: canonical + "/Library/CloudStorage/provider/file",
                                flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), id: 0)])
    }
    #expect(queue.sync { restored.status.state } == "ready")
    #expect(queue.sync { restored.status.updated } == updatedBefore)
}

@Test func diskIndexDistinguishesLocalCoalescingFromStreamWideHistoryLoss() {
    #expect(DiskIndexEvents.recovery(UInt32(kFSEventStreamEventFlagMustScanSubDirs)) == .verifySubtree)
    for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped] {
        #expect(DiskIndexEvents.recovery(UInt32(flag)) == .verifyVolume)
    }
    #expect(DiskIndexEvents.recovery(UInt32(kFSEventStreamEventFlagRootChanged)) == .rootChanged)
    #expect(DiskIndexEvents.recovery(UInt32(kFSEventStreamEventFlagEventIdsWrapped)) == .eventsWrapped)
    #expect(DiskIndexEvents.recovery(UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)) == .none)
}

@Test func diskIndexCountsHiddenFilesAndItsOwnDatabaseAndUpgradesOldIndexes() async throws {
    let manager = FileManager.default
    let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: temporary) }
    let resolved = try #require(realpath(temporary.path, nil))
    let canonical = String(cString: resolved); free(resolved)
    let root = URL(fileURLWithPath: "/System/Volumes/Data" + canonical)
    let storage = root.appendingPathComponent("Library/Application Support/MacState/DiskIndexes")
    let cache = storage.appendingPathComponent("v1")
    let hidden = root.appendingPathComponent(".hidden")
    try manager.createDirectory(at: cache, withIntermediateDirectories: true)
    try manager.createDirectory(at: hidden, withIntermediateDirectories: true)
    let hiddenFile = hidden.appendingPathComponent(".config")
    let archive = cache.appendingPathComponent("archived.sqlite-wal")
    try Data(repeating: 65, count: 8192).write(to: hiddenFile)
    try Data(repeating: 66, count: 32768).write(to: archive)
    let archiveBytes = try fixtureEntry(archive).allocatedBytes
    let queue = DispatchQueue(label: "test.index-with-hidden-and-internal-files")
    let volume = VolumeRow(name: "Fixture", path: root.path, total: 100_000, available: 50_000)
    let index = IndexedVolume(volume: volume, baseURL: cache, queue: queue, rootOverride: root)
    queue.sync { index.start() }
    defer { queue.sync { index.stop(); index.store = nil } }

    for _ in 0..<300 {
        if queue.sync(execute: { index.status.state == "ready" }) { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let completedAt = queue.sync { index.status.completedAt }
    try queue.sync {
        try #require(index.status.state == "ready")
        let store = try #require(index.store)
        let database = try #require(store.storeURL)
        #expect(try store.indexedEntry(database.path)?.bytes ?? 0 > 0)
        #expect(try store.indexedEntry(database.path + "-wal")?.bytes ?? 0 > 0)
        #expect(try store.indexedEntry(database.path + "-shm")?.bytes ?? 0 > 0)
        #expect(try store.indexedEntry(archive.path)?.bytes == archiveBytes)
        #expect(try store.searchPage(requestID: "hidden", root: root.path, query: DiskFileQuery(text: ".config"), offset: 0)?
            .entries.contains { $0.path == hiddenFile.path } == true)
        index.stop()
        // Re-create the row written by the previous scan policy in the same index.
        try store.transaction {
            _ = try store.upsertIndexedEntry(DiskAnalysisEntry(path: storage.path, name: "DiskIndexes", directory: true,
                bytes: 0, skipped: 1, note: "MacState 文件索引缓存，已跳过"), root: root.path)
        }
        #expect(!store.contains(path: archive.path))
        index.store = nil
    }
    let restored = IndexedVolume(volume: volume, baseURL: URL(fileURLWithPath: DiskInsightRules.logical(cache.path)),
        queue: queue, rootOverride: root)
    queue.sync { restored.start() }
    defer { queue.sync { restored.stop(); restored.store = nil } }
    for _ in 0..<300 {
        if queue.sync(execute: { restored.status.state == "ready" && restored.store?.contains(path: archive.path) == true }) { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    try queue.sync {
        try #require(restored.status.state == "ready")
        let store = try #require(restored.store)
        #expect(restored.status.completedAt == completedAt)
        #expect(try store.indexedEntry(archive.path)?.bytes == archiveBytes)
        let directory = try #require(try store.indexedEntry(storage.path))
        #expect(directory.browsable && directory.skipped == 0 && directory.bytes >= archiveBytes)
        let activeDatabase = try #require(store.storeURL)
        let indexedDatabase = try #require(try store.indexedEntry(cache.appendingPathComponent(activeDatabase.lastPathComponent).path))
        #expect(indexedDatabase.bytes > 0)
        #expect(throws: DiskAnalysisStore.Failure.self) { try DiskFileSafety.validate(indexedDatabase) }
        let walPath = DiskInsightRules.logical(indexedDatabase.path) + "-wal"
        restored.receive([.init(path: walPath, flags: UInt32(kFSEventStreamEventFlagItemModified), id: 0)])
        #expect(restored.status.state == "ready" && restored.status.pendingChanges == 0)
    }
    let added = cache.appendingPathComponent(".new-hidden-file")
    try Data(repeating: 67, count: 4096).write(to: added)
    for _ in 0..<300 {
        if queue.sync(execute: { restored.status.state == "ready" && restored.store?.contains(path: added.path) == true }) { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    try #require(queue.sync { restored.store?.contains(path: added.path) == true })
    let lastUpdate = queue.sync { restored.status.updated }
    try await Task.sleep(nanoseconds: 4_500_000_000)
    #expect(queue.sync { restored.status.state == "ready" && restored.status.updated == lastUpdate })
}

@Test func persistentIndexOpensAndSearchesOneHundredThousandMetadataRowsWithoutTraversal() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let url = base.appendingPathComponent("benchmark.sqlite"), root = "/fixture"
    let started = Date()
    var store: DiskAnalysisStore? = try DiskAnalysisStore(url: url)
    try store?.insert(DiskAnalysisEntry(path: root, name: "Fixture", directory: true, browsable: true,
        bytes: 409_600_000, files: 100000), parent: nil, childCount: 100000)
    for i in 0..<100000 {
        try store?.insert(DiskAnalysisEntry(path: root + "/file-\(i).txt", name: "file-\(i).txt", directory: false,
            bytes: 4096, files: 1, logicalBytes: 1234, allocatedBytes: 4096, modified: 100, created: 50,
            fileExtension: "txt", kind: "text"), parent: root)
    }
    try store?.finish(); store = nil
    let build = Date().timeIntervalSince(started), openTime = Date()
    let reopened = try DiskAnalysisStore(url: url, existing: true)
    let firstPage = try reopened.children(path: root, offset: 0)
    let open = Date().timeIntervalSince(openTime)
    try reopened.prepareFastSearch()
    let searchTime = Date()
    let page = try #require(try reopened.searchPage(requestID: "search", root: root, query: DiskFileQuery(text: "file-99999", kind: "text"), offset: 0))
    let search = Date().timeIntervalSince(searchTime)
    #expect(firstPage.count == 100 && page.entryCount == 1)
    #expect(page.entries.first?.logicalBytes == 1234)
    print(String(format: "DISK_INDEX_BENCH rows=100000 metadata_insert_s=%.3f reopen_and_first_page_ms=%.3f filename_search_ms=%.3f", build, open * 1000, search * 1000))
}

@Test func diskEventStartingCursorUsesUnixEpochInsteadOfReplayingAllHistory() throws {
    var info = stat()
    try #require(lstat("/System/Volumes/Data", &info) == 0)
    let expected = FSEventsGetLastEventIdForDeviceBeforeTime(info.st_dev, Date().timeIntervalSince1970)
    try #require(expected > 0)
    #expect(DiskIndexEvents.currentID(device: info.st_dev) > 0)
}

@Test func coalescedDirectoryEventsDoNotRequireDeletingTheWholeIndex() {
    #expect(DiskIndexEvents.recovery(UInt32(kFSEventStreamEventFlagMustScanSubDirs)) == .verifySubtree)
}

private final class IndexReaderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0, peak = 0
    func enter() { lock.lock(); active += 1; peak = max(peak, active); lock.unlock() }
    func leave() { lock.lock(); active -= 1; lock.unlock() }
    var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
}

@Test func initialIndexActuallyRunsSixDirectoryReadersConcurrently() async throws {
    let root = URL(fileURLWithPath: "/index-parallel-fixture"), gate = DispatchSemaphore(value: 0), counter = IndexReaderCounter()
    defer { for _ in 0..<6 { gate.signal() } }
    let scanner = DiskAnalysisScanner(metadata: { _ in
        var value = stat(); value.st_dev = 1; value.st_mode = mode_t(S_IFDIR); value.st_nlink = 1; return value
    }, listDirectory: { path in
        if path == root.path { return (0..<6).map { "dir-\($0)" } }
        counter.enter(); defer { counter.leave() }
        _ = gate.wait(timeout: .now() + 15); return []
    })
    let session = DiskScanSession(scanner: scanner, root: root, volumePath: root.path, name: "Fixture",
        requestID: "parallel", cancellation: DiskScanCancellation(), backgroundReaders: 6)
    session.start(); defer { session.cancel() }
    for _ in 0..<200 {
        if counter.maximum == 6 { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(counter.maximum == 6)
    // The configured concurrency is a bound, not an unbounded task per directory.
    #expect(counter.maximum <= 6)
}

private final class IndexVerificationGate {
    private let lock = NSLock()
    private var enabled = false
    private var paths = Set<String>()
    func arm() { lock.lock(); enabled = true; lock.unlock() }
    func firstRead(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && paths.insert(path).inserted
    }
}

@Test func diskIndexPauseKeepsSearchAvailableAndManualSyncReplaysChanges() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = base.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let resolved = try #require(realpath(source.path, nil))
    let canonical = String(cString: resolved)
    free(resolved)
    let root = URL(fileURLWithPath: "/System/Volumes/Data" + canonical)
    let cache = base.appendingPathComponent("cache")
    let volume = VolumeRow(name: "Fixture", path: root.path, total: 100000, available: 50000)
    let queue = DispatchQueue(label: "test.index-pause")
    let gate = IndexVerificationGate(), releaseReader = DispatchSemaphore(value: 0), entered = IndexReaderCounter()
    let index = IndexedVolume(volume: volume, baseURL: cache, queue: queue, rootOverride: root,
        directoryReader: { path, root, device, token, batch in
            if gate.firstRead(path) {
                entered.enter()
                defer { entered.leave() }
                _ = releaseReader.wait(timeout: .now() + 10)
            }
            return DiskIndexDirectoryReader.read(path: path, root: root, device: device, cancellation: token, batch: batch)
        })
    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if queue.sync(execute: condition) { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        Issue.record("Timed out waiting for index synchronization.")
    }
    queue.sync { index.start() }
    defer { releaseReader.signal(); queue.sync { index.stop() } }
    try await waitUntil { index.status.state == "ready" }
    let store = try #require(queue.sync { index.store })
    let completedAt = queue.sync { index.status.completedAt }
    let cursor = try store.metadata("cursor")
    gate.arm()
    queue.sync {
        index.receive([.init(path: canonical, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), id: 0)])
        index.requestSynchronization()
    }
    try await waitUntil { entered.maximum > 0 }
    queue.sync { index.setSynchronizationPaused(true) }
    releaseReader.signal()
    let manualFile = root.appendingPathComponent("manual.txt").path
    try Data("manual".utf8).write(to: source.appendingPathComponent("manual.txt"))
    queue.sync { index.receive([.init(path: canonical + "/manual.txt", flags: 0, id: 0)]) }
    try await Task.sleep(nanoseconds: 2_200_000_000)
    #expect(queue.sync { index.status.ready && index.status.synchronizationPaused && !store.contains(path: manualFile) })
    #expect(try store.metadata("cursor") == cursor)
    queue.sync { index.requestSynchronization() }
    try await waitUntil { !index.status.manualSynchronization && store.contains(path: manualFile) }
    #expect(queue.sync { index.status.synchronizationPaused && index.status.ready })
    #expect(try store.metadata("cursor") != cursor)
    queue.sync { index.stop(); index.store = nil }

    let restored = IndexedVolume(volume: volume, baseURL: cache, queue: queue, rootOverride: root)
    queue.sync { restored.setSynchronizationPaused(true); restored.start() }
    defer { queue.sync { restored.stop() } }
    #expect(queue.sync { restored.status.ready && restored.status.completedAt == completedAt })
    let automaticFile = root.appendingPathComponent("automatic.txt").path
    try Data("automatic".utf8).write(to: source.appendingPathComponent("automatic.txt"))
    #expect(queue.sync { restored.store?.contains(path: automaticFile) == false })
    queue.sync { restored.setSynchronizationPaused(false) }
    try await waitUntil { restored.status.state == "ready" && restored.store?.contains(path: automaticFile) == true }
    #expect(queue.sync { !restored.status.synchronizationPaused && restored.status.completedAt == completedAt })
}

@Test(arguments: [false, true])
func incrementalIndexRetriesLockedWritesWithoutLosingChanges(duringRead: Bool) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = base.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let resolved = try #require(realpath(source.path, nil))
    let canonical = String(cString: resolved); free(resolved)
    let root = URL(fileURLWithPath: "/System/Volumes/Data" + canonical)
    let queue = DispatchQueue(label: "test.index-write-retry")
    let entered = IndexReaderCounter(), releaseReader = DispatchSemaphore(value: 0)
    let gate = IndexVerificationGate()
    let volume = VolumeRow(name: "Fixture", path: root.path, total: 100000, available: 50000)
    let index = IndexedVolume(volume: volume, baseURL: base.appendingPathComponent("cache"), queue: queue, rootOverride: root,
        directoryReader: { path, root, device, token, batch in
            if gate.firstRead(path) {
                entered.enter(); defer { entered.leave() }
                _ = releaseReader.wait(timeout: .now() + 10)
            }
            return DiskIndexDirectoryReader.read(path: path, root: root, device: device, cancellation: token, batch: batch)
        })
    queue.sync { index.start() }
    defer { releaseReader.signal(); queue.sync { index.stop() } }
    for _ in 0..<200 {
        if queue.sync(execute: { index.status.state == "ready" }) { break }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    try #require(queue.sync { index.status.state == "ready" })
    let store = try #require(queue.sync { index.store })
    let url = try #require(store.storeURL)
    try queue.sync { try store.execute("PRAGMA busy_timeout=0") }
    let cursor = try store.metadata("cursor")
    var blocker: OpaquePointer?
    defer { sqlite3_close(blocker) }
    try #require(sqlite3_open_v2(url.path, &blocker, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    if duringRead { gate.arm() }
    else { try #require(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK) }
    try Data("fixture".utf8).write(to: source.appendingPathComponent("new.txt"))
    queue.sync {
        let path = duringRead ? canonical + "/new.txt" : canonical
        let flags = duringRead ? 0 : UInt32(kFSEventStreamEventFlagMustScanSubDirs)
        index.receive([.init(path: path, flags: flags, id: 0)])
        index.requestSynchronization()
    }
    if duringRead {
        for _ in 0..<200 {
            if entered.maximum > 0 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try #require(entered.maximum > 0)
        try #require(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        releaseReader.signal()
    }
    for _ in 0..<100 {
        if queue.sync(execute: { !index.status.message.isEmpty }) { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    let interrupted = queue.sync { index.status }
    #expect(!interrupted.message.isEmpty)
    #expect(interrupted.ready)
    #expect(try store.metadata("cursor") == cursor)
    try #require(sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
    let path = root.appendingPathComponent("new.txt").path
    for _ in 0..<200 {
        if queue.sync(execute: { index.status.state == "ready" && store.contains(path: path) }) { break }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    #expect(queue.sync { index.status.state == "ready" && index.status.message.isEmpty })
    #expect(queue.sync { index.store === store && index.status.completedAt == interrupted.completedAt && store.contains(path: path) })
}

@Test func incrementalVerificationReadsFourIndependentDirectoriesWithoutBlockingCoordinator() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("files")
    for i in 0..<4 { try FileManager.default.createDirectory(at: source.appendingPathComponent("dir-\(i)"), withIntermediateDirectories: true) }
    let resolved = try #require(realpath(source.path, nil))
    let canonical = String(cString: resolved); free(resolved)
    let root = URL(fileURLWithPath: "/System/Volumes/Data" + canonical)
    let queue = DispatchQueue(label: "test.parallel-index"), counter = IndexReaderCounter(), gate = DispatchSemaphore(value: 0)
    let row = VolumeRow(name: "Fixture", path: root.path, total: 100000, available: 100000)
    let verificationGate = IndexVerificationGate()
    let index = IndexedVolume(volume: row, baseURL: base.appendingPathComponent("cache"), queue: queue, rootOverride: root, readConcurrency: 4,
        directoryReader: { path, root, device, token, batch in
            let firstRead = verificationGate.firstRead(path)
            if firstRead && (path as NSString).lastPathComponent.hasPrefix("dir-") {
                counter.enter(); defer { counter.leave() }
                _ = gate.wait(timeout: .now() + 15)
            }
            return DiskIndexDirectoryReader.read(path: path, root: root, device: device, cancellation: token, batch: batch)
        })
    queue.sync { index.start() }
    defer { for _ in 0..<4 { gate.signal() }; queue.sync { index.stop() } }
    for _ in 0..<200 {
        if queue.sync(execute: { index.status.state == "ready" }) { break }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    try #require(queue.sync { index.status.state == "ready" })
    let completed = queue.sync { index.status.completedAt }
    verificationGate.arm()
    queue.sync { index.receive([.init(path: canonical, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), id: 0)]) }
    for _ in 0..<300 {
        if counter.maximum == 4 { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(counter.maximum == 4)
    // All four readers are waiting, but event/status work and indexed browsing
    // still execute immediately on the separate coordinator/query path.
    #expect(queue.sync { index.status.ready && index.status.state == "verifying" })
    #expect(queue.sync { (try? index.store?.directory(path: root.path)?.childCount) == 4 })
    for _ in 0..<4 { gate.signal() }
    for _ in 0..<200 {
        if queue.sync(execute: { index.status.state == "ready" }) { break }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    #expect(queue.sync { index.status.state } == "ready")
    #expect(queue.sync { index.status.completedAt } == completed)
}
