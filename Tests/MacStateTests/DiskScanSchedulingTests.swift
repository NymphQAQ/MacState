import Foundation
import Darwin
import Testing
@testable import MacState

private final class DiskPathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ path: String) { lock.lock(); values.append(path); lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

@Test func diskLocalPolicySkipsPhoneAndCloudRootsBeforeReadingTheirMetadata() throws {
    let root = URL(fileURLWithPath: "/disk-policy-fixture/Users/test/Library"), calls = DiskPathLog()
    let scanner = DiskAnalysisScanner(metadata: { path in
        calls.add(path)
        var info = stat(); info.st_dev = 1; info.st_blocks = 8; info.st_nlink = 1
        info.st_mode = mode_t(path.hasSuffix(".dat") ? S_IFREG : S_IFDIR)
        if path.hasSuffix("placeholder.dat") { info.st_flags = UInt32(SF_DATALESS) }
        return info
    }, listDirectory: { path in
        calls.add(path)
        return path == root.path ? ["CloudStorage", "Mobile Documents", "ordinary", "placeholder.dat"] : ["local.dat"]
    })
    let result = scanner.scan(root: root, volumePath: root.path, name: "Local", requestID: "local", cancellation: DiskScanCancellation())
    #expect(result.progress.state == "completed")
    #expect(result.progress.excluded == 3)
    #expect(result.progress.skipped == 3)
    #expect(result.progress.files == 1)
    #expect(result.progress.bytes == 3 * 4096)
    #expect(!calls.paths.contains { $0.contains("CloudStorage") || $0.contains("Mobile Documents") })
    let cloud = try #require(result.page(path: root.path)?.entries.first { $0.name == "CloudStorage" })
    #expect(!cloud.browsable && cloud.bytes == 0 && cloud.note.contains("本地缓存"))
    #expect(DiskLocalPolicy.exclusion("/System/Volumes/Data/Users/a/Library/CloudStorage/OPPO互联-DeviceSpace/storage") != nil)
    #expect(DiskLocalPolicy.exclusion("/Users/a/Documents/CloudStorage-not-provider") == nil)
}

@Test @MainActor func diskScanReservesReaderForClickedDirectoryWhenBackgroundReadersWait() async throws {
    let root = URL(fileURLWithPath: "/disk-priority-fixture"), gate = DispatchSemaphore(value: 0), calls = DiskPathLog()
    defer { for _ in 0..<3 { gate.signal() } }
    let scanner = DiskAnalysisScanner(metadata: { path in
        var info = stat(); info.st_dev = 1; info.st_blocks = 8; info.st_nlink = 1
        info.st_mode = mode_t(path.hasSuffix(".dat") ? S_IFREG : S_IFDIR)
        return info
    }, listDirectory: { path in
        calls.add(path)
        if path == root.path { return ["a-blocked", "b-blocked", "c-blocked", "z-selected"] }
        if path.hasSuffix("blocked") { _ = gate.wait(timeout: .now() + 15); return [] }
        return ["priority.dat"]
    })
    let service = DiskAnalysisService(scannerFactory: { scanner }, accessCheck: { .granted })
    var updates: [DiskAnalysisProgress] = [], pages: [DiskDirectoryPage] = []
    service.onProgress = { updates.append($0) }; service.onDirectory = { pages.append($0) }
    let volume = VolumeRow(name: "Fixture", path: root.path, total: 100_000, available: 50_000)
    service.start(volume: volume, requestID: "priority")
    for _ in 0..<500 {
        if calls.paths.filter({ $0.hasSuffix("blocked") }).count == 3 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(calls.paths.filter { $0.hasSuffix("blocked") }.count == 3)
    #expect(!calls.paths.contains(root.path + "/z-selected"))
    service.browse(path: root.path + "/z-selected", requestID: "priority", offset: 0)
    for _ in 0..<300 {
        if pages.last?.entries.first?.name == "priority.dat" { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(calls.paths.contains(root.path + "/z-selected"))
    #expect(pages.last?.entries.first?.name == "priority.dat")
    #expect(updates.last?.state == "scanning")
    service.cancel(requestID: "priority")
    for _ in 0..<50 {
        if updates.last?.state == "cancelled" { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(updates.last?.state == "cancelled")
    #expect(service.revealURL(path: root.path + "/z-selected/priority.dat", requestID: "priority") != nil)
    #expect(service.revealURL(path: "/outside", requestID: "priority") == nil)
}

@Test @MainActor func diskScanCannotStartWithoutConfirmedFullDiskAccess() async throws {
    for status in [DiskAccessStatus.missing, .unknown] {
        var readersCreated = 0
        let service = DiskAnalysisService(scannerFactory: { readersCreated += 1; return DiskAnalysisScanner() }, accessCheck: { status })
        var updates: [DiskAnalysisProgress] = []
        service.onProgress = { updates.append($0) }
        service.start(volume: VolumeRow(name: "Fixture", path: "/", total: 10, available: 5), requestID: status.rawValue)
        for _ in 0..<50 {
            if !updates.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(readersCreated == 0)
        #expect(updates.last?.state == "failed")
        #expect(updates.last?.message.contains("完全磁盘访问权限") == true)
    }
}
