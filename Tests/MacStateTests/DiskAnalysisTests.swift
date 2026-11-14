import Foundation
import Darwin
import Testing
@testable import MacState

private func diskFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("macstate-disk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
private func diskMetadata(_ path: String) -> stat? {
    var value = stat()
    return lstat(path, &value) == 0 ? value : nil
}
private func diskAllocated(_ url: URL) -> UInt64 { UInt64(max(0, diskMetadata(url.path)?.st_blocks ?? 0)) * 512 }

@Test func diskScanCountsAllocatedSpaceDeduplicatesHardLinksAndDoesNotFollowSymlinks() throws {
    let root = try diskFixture(), outside = try diskFixture()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let folder = root.appendingPathComponent("folder"), a = root.appendingPathComponent("a.dat")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let b = folder.appendingPathComponent("b.dat"), link = root.appendingPathComponent("external")
    try Data(repeating: 1, count: 8192).write(to: a)
    try Data(repeating: 2, count: 32768).write(to: b)
    try Data(repeating: 3, count: 65536).write(to: outside.appendingPathComponent("not-in-scan.dat"))
    try FileManager.default.linkItem(at: a, to: folder.appendingPathComponent("hard-link.dat"))
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let result = DiskAnalysisScanner().scan(root: root, volumePath: root.path, name: "Fixture", requestID: "one", cancellation: DiskScanCancellation())
    #expect(result.progress.state == "completed")
    #expect(result.progress.files == 4)
    #expect(result.progress.directories == 2)
    #expect(result.progress.bytes == [root, folder, a, b, link].reduce(UInt64(0)) { $0 + diskAllocated($1) })
    #expect(!result.progress.largest.contains { $0.name == "not-in-scan.dat" })
    #expect(result.page(path: link.path) == nil)
    #expect(result.page(path: outside.path) == nil)
    let page = try #require(result.page(path: folder.path))
    #expect(page.breadcrumbs.map(\.name) == ["Fixture", "folder"])
    #expect(page.files == 2)
    #expect(result.contains(path: b.path))
    #expect(!result.contains(path: outside.path))
}

@Test func diskScanReportsDeniedDirectoriesAndSkipsOtherDevices() throws {
    let root = try diskFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["denied", "other-volume"] {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("child.dat"))
    }
    let scanner = DiskAnalysisScanner(metadata: { path in
        var value = diskMetadata(path)
        if path.hasSuffix("/other-volume") {
            let device = value?.st_dev ?? 0
            value?.st_dev = device + 1
        }
        return value
    }, listDirectory: { path in
        if path.hasSuffix("/denied") { throw CocoaError(.fileReadNoPermission) }
        return try FileManager.default.contentsOfDirectory(atPath: path)
    })
    let result = scanner.scan(root: root, volumePath: root.path, name: "Fixture", requestID: "two", cancellation: DiskScanCancellation())
    #expect(result.progress.skipped == 2)
    #expect(result.progress.files == 0)
    let entries = try #require(result.page(path: root.path)?.entries)
    #expect(entries.first { $0.name == "other-volume" }?.browsable == false)
    #expect(entries.first { $0.name == "denied" }?.skipped == 1)
    #expect(result.page(path: root.appendingPathComponent("denied").path)?.skipped == 1)
}

@Test func diskScanRetainsEveryFileDetailAndSupportsCancellation() throws {
    let root = try diskFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for i in 0..<8 { try Data(repeating: 1, count: (i + 1) * 4096).write(to: root.appendingPathComponent("\(i).dat")) }
    let result = DiskAnalysisScanner().scan(root: root, volumePath: root.path, name: "Fixture", requestID: "three", cancellation: DiskScanCancellation())
    #expect(result.progress.files == 8)
    #expect(result.page(path: root.path)?.entryCount == 8)
    #expect(result.progress.largest.count == 8)
    #expect(result.page(path: root.path)?.entries.map(\.name) == (0..<8).reversed().map { "\($0).dat" })
    let token = DiskScanCancellation()
    let cancelled = DiskAnalysisScanner().scan(root: root, volumePath: root.path, name: "Fixture", requestID: "four", cancellation: token) { _ in token.cancel() }
    #expect(cancelled.progress.state == "cancelled")
    #expect(cancelled.progress.files == 0)
    #expect(cancelled.page(path: root.path) != nil)
}

@Test func diskScanRetainsMoreThanOneHundredThousandFilesWithBoundedPages() throws {
    let root = URL(fileURLWithPath: "/macstate-synthetic-\(UUID().uuidString)")
    let names = (0..<100_205).map { String(format: "file-%06d.dat", $0) }
    let scanner = DiskAnalysisScanner(metadata: { path in
        var value = stat()
        value.st_dev = 1; value.st_nlink = 1; value.st_blocks = 8
        value.st_mode = mode_t(path == root.path ? S_IFDIR : S_IFREG)
        return value
    }, listDirectory: { _ in names })
    let result = scanner.scan(root: root, volumePath: root.path, name: "Large fixture", requestID: "unlimited", cancellation: DiskScanCancellation())
    #expect(result.progress.state == "completed")
    #expect(result.progress.files == names.count)
    #expect(result.progress.bytes == UInt64(names.count + 1) * 4096)
    #expect(result.progress.message.isEmpty)
    let first = try #require(result.page(path: root.path))
    #expect(first.entryCount == names.count)
    #expect(first.entries.count == 100)
    #expect(first.entries.first?.name == names.first)
    let beyondOldLimit = try #require(result.page(path: root.path, offset: 100_000))
    #expect(beyondOldLimit.entries.count == 100)
    #expect(beyondOldLimit.entries.first?.name == names[100_000])
    let last = try #require(result.page(path: root.path, offset: Int.max))
    #expect(last.offset == 100_200)
    #expect(last.entries.count == 5)
    #expect(last.entries.last?.name == names.last)
    #expect(result.contains(path: root.appendingPathComponent(names.last!).path))
    #expect(result.progress.largest.count == 50)
}

@Test func diskDetailStorePreservesNamesAndOnlyLivesWithItsScanResult() throws {
    weak var releasedStore: DiskAnalysisStore?
    do {
        let store = try DiskAnalysisStore()
        releasedStore = store
        let name = "文件 ' single \" double <tag>.txt"
        let root = DiskAnalysisEntry(path: "/fixture", name: "Fixture", directory: true, browsable: true, bytes: 4096, files: 1)
        let file = DiskAnalysisEntry(path: "/fixture/\(name)", name: name, directory: false, bytes: 4096, files: 1)
        try store.insert(file, parent: root.path)
        try store.insert(root, parent: nil, childCount: 1)
        try store.finish()
        #expect(try store.children(path: root.path, offset: 0).first?.name == name)
        #expect(store.contains(path: file.path))
        #expect(!store.contains(path: "/fixture/anything' OR 1=1 --"))
    }
    #expect(releasedStore == nil)
}

@Test func diskScanDoesNotDropFilesAfterOneHundredThousandDirectories() throws {
    let root = URL(fileURLWithPath: "/macstate-directory-fixture-\(UUID().uuidString)")
    let folders = (0..<100_001).map { String(format: "folder-%06d", $0) }
    let scanner = DiskAnalysisScanner(metadata: { path in
        var value = stat()
        value.st_dev = 1; value.st_nlink = 1; value.st_blocks = 8
        value.st_mode = mode_t(path.hasSuffix(".dat") ? S_IFREG : S_IFDIR)
        return value
    }, listDirectory: { $0 == root.path ? folders : ["child.dat"] })
    let result = scanner.scan(root: root, volumePath: root.path, name: "Directories", requestID: "directory-limit", cancellation: DiskScanCancellation())
    #expect(result.progress.state == "completed")
    #expect(result.progress.directories == folders.count + 1)
    #expect(result.progress.files == folders.count)
    #expect(result.progress.skipped == 0)
    let lastPath = root.appendingPathComponent(folders.last!).path
    let page = try #require(result.page(path: lastPath))
    #expect(page.files == 1)
    #expect(page.entries.first?.name == "child.dat")
    #expect(page.breadcrumbs.map(\.name) == ["Directories", folders.last!])
}

@Test func diskDirectoryPaginationIsBoundedAndCannotEscapeScannedTree() throws {
    let root = try diskFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for i in 0..<105 { try FileManager.default.createDirectory(at: root.appendingPathComponent("folder-\(i)"), withIntermediateDirectories: true) }
    let result = DiskAnalysisScanner().scan(root: root, volumePath: root.path, name: "Fixture", requestID: "five", cancellation: DiskScanCancellation())
    #expect(result.page(path: root.path)?.entries.count == 100)
    #expect(result.page(path: root.path, offset: 100)?.entries.count == 5)
    #expect(result.page(path: root.path, offset: Int.max)?.offset == 100)
    #expect(result.page(path: root.path, offset: -100)?.offset == 0)
    #expect(result.page(path: root.deletingLastPathComponent().path) == nil)
    #expect(DiskAnalysisScanner.scanRoot(volumePath: root.path).path == root.path)
}

@Test @MainActor func diskScanServiceDropsObsoleteJobsAndHonorsScopedCancellation() async throws {
    let root = try diskFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent("a.dat"))
    let service = DiskAnalysisService(accessCheck: { .granted })
    var updates: [DiskAnalysisProgress] = [], pages: [DiskDirectoryPage] = []
    service.onProgress = { updates.append($0) }; service.onDirectory = { pages.append($0) }
    let volume = VolumeRow(name: "Fixture", path: root.path, total: 100_000, available: 50_000)
    service.start(volume: volume, requestID: "obsolete")
    service.start(volume: volume, requestID: "current")
    service.cancel(requestID: "obsolete")
    for _ in 0..<100 {
        if pages.last?.requestID == "current", updates.last?.state == "completed" { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(!updates.isEmpty)
    #expect(updates.allSatisfy { $0.requestID == "current" })
    #expect(updates.last?.state == "completed")
    #expect(pages.last?.requestID == "current")
    #expect(service.revealURL(path: root.appendingPathComponent("a.dat").path, requestID: "current") != nil)
    #expect(service.revealURL(path: "/etc/passwd", requestID: "current") == nil)
    service.start(volume: volume, requestID: "cancelled")
    service.cancel(requestID: "cancelled")
    for _ in 0..<100 {
        if updates.last?.state == "cancelled" { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(updates.last?.requestID == "cancelled")
    #expect(updates.last?.state == "cancelled")
}

@Test @MainActor func diskScanStreamsBrowsableResultsAndTimerWhileDirectoryIOWaits() async throws {
    let root = try diskFixture(), gate = DispatchSemaphore(value: 0)
    defer { gate.signal(); try? FileManager.default.removeItem(at: root) }
    let scanner = DiskAnalysisScanner(metadata: { path in
        var value = stat(); value.st_dev = 1; value.st_nlink = 1; value.st_blocks = 8
        value.st_mode = mode_t(path.hasSuffix(".dat") ? S_IFREG : S_IFDIR)
        return value
    }, listDirectory: { path in
        if path == root.path { return ["blocked", "ready"] }
        if path.hasSuffix("/blocked") { _ = gate.wait(timeout: .now() + 5); return [] }
        return ["file.dat"]
    })
    let service = DiskAnalysisService(scannerFactory: { scanner }, accessCheck: { .granted })
    var updates: [DiskAnalysisProgress] = [], pages: [DiskDirectoryPage] = []
    service.onProgress = { updates.append($0) }; service.onDirectory = { pages.append($0) }
    service.start(volume: VolumeRow(name: "Fixture", path: root.path, total: 100_000, available: 50_000), requestID: "waiting")
    for _ in 0..<150 {
        if (updates.last?.elapsed ?? 0) >= 0.5 && pages.contains(where: { $0.entries.contains { $0.name == "ready" } }) { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(updates.last?.state == "scanning")
    #expect((updates.last?.elapsed ?? 0) >= 0.5)
    #expect(pages.contains { $0.path == root.path && $0.entries.contains { $0.name == "ready" } })
    service.browse(path: root.appendingPathComponent("ready").path, requestID: "waiting", offset: 0)
    for _ in 0..<100 {
        if pages.last?.entries.first?.name == "file.dat" { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(pages.last?.path == root.appendingPathComponent("ready").path)
    #expect(pages.last?.entries.first?.name == "file.dat")
    service.cancel(requestID: "waiting")
    for _ in 0..<100 {
        if updates.last?.state == "cancelled" { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(updates.last?.state == "cancelled")
}
