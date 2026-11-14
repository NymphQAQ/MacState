import Foundation
import Darwin
import Testing
@testable import MacState

@Test func diskAccessDoesNotRequireAnExistingPrivacyDatabase() {
    var paths: [String] = []
    let status = DiskAccess.check(home: URL(fileURLWithPath: "/fixture")) { path in
        paths.append(path)
        return path.hasSuffix("/Mail") ? 0 : ENOENT
    }
    #expect(status == .granted)
    #expect(!paths.contains { $0.contains("TCC.db") })
}

@Test func diskAccessSeparatesPrivacyDenialFromMissingPathsAndUnixErrors() {
    let home = URL(fileURLWithPath: "/fixture")
    #expect(DiskAccess.check(home: home, probe: { _ in EPERM }) == .missing)
    #expect(DiskAccess.check(home: home, probe: { _ in ENOENT }) == .unknown)
    #expect(DiskAccess.check(home: home, probe: { _ in EACCES }) == .unknown)
    #expect(DiskAccess.check(home: home, probe: { _ in EIO }) == .unknown)
    #expect(DiskAccess.check(home: home, probe: { $0.hasSuffix("/Messages") ? 0 : EPERM }) == .granted)
}

@Test func diskAccessProbesActualDirectoryReadWithoutDependingOnDatabaseFiles() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("disk-access-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Mail"), withIntermediateDirectories: true)
    #expect(DiskAccess.check(home: home, probe: DiskAccess.directoryAccess) == .granted)
    #expect(DiskAccess.check(home: home.appendingPathComponent("absent"), probe: DiskAccess.directoryAccess) == .unknown)
}
