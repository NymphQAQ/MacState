import Foundation
import Testing
@testable import MacState

@Test func diskStorageGrowthComparesActualSamplesAndRanksSpecificPaths() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let catalog = try DiskStorageCatalog(url: temporary.appendingPathComponent("storage.sqlite"))
    let baseline = Date().timeIntervalSince1970.rounded(.down) - 6 * 3600
    try catalog.execute("""
        INSERT INTO storage_samples VALUES (1,'fixture',\(baseline),600,800,10,6,0);
        INSERT INTO storage_sample_items VALUES
            (1,'/data','Data','directory',600),
            (1,'/data/project','Project','directory',100),
            (1,'/data/project/pack','Pack','directory',50),
            (1,'/data/cache','Cache','directory',100),
            (1,'/data/old-only','Old','directory',200),
            (1,'/data/app','App','application',40);
        """)
    let token = DiskScanCancellation()
    var filter = DiskWorkbenchFilter(category: "directory", growthHours: 24)
    func report() throws -> DiskWorkbenchReport {
        try catalog.growth(requestID: "fixture", queryID: "growth", volume: "fixture", root: "/data",
            filter: filter, cancellation: token)
    }
    #expect(try report().growth?.baseline == nil)
    #expect(try report().growth?.latest == baseline)
    let status = DiskIndexStatus(volumePath: "/data", state: "ready", files: 11, directories: 6, bytes: 650,
        elapsed: 0, currentPath: "", message: "", updated: 0, ready: true)
    try catalog.record(volume: "fixture", status: status, used: 870, items: [
        DiskWorkbenchRow(title: "Data", path: "/data", category: "directory", bytes: 650),
        DiskWorkbenchRow(title: "Project", path: "/data/project", category: "directory", bytes: 180),
        DiskWorkbenchRow(title: "Pack", path: "/data/project/pack", category: "directory", bytes: 130),
        DiskWorkbenchRow(title: "Cache", path: "/data/cache", category: "directory", bytes: 70),
        DiskWorkbenchRow(title: "New", path: "/data/new-only", category: "directory", bytes: 500),
        DiskWorkbenchRow(title: "App", path: "/data/app", category: "application", bytes: 60),
        DiskWorkbenchRow(title: "App folder", path: "/data/app", category: "directory", bytes: 62)
    ])

    let growth = try report()
    #expect(growth.growth?.baseline == baseline)
    #expect(growth.growth?.latest ?? 0 > baseline)
    #expect(growth.growth?.volumeDelta == 70)
    #expect(growth.growth?.indexedDelta == 50)
    #expect(growth.growth?.trend.map(\.indexedDelta) == [0, 50])
    #expect(growth.growth?.trend.map(\.volumeDelta) == [0, 70])
    #expect(growth.growth?.largestChange == 80)
    #expect(growth.growth?.unmatchedCount == 3)
    #expect(growth.rows.map(\.path) == ["/data/project/pack"])
    #expect(growth.rows.first?.delta == 80 && growth.rows.first?.previousBytes == 50)

    filter.text = "Project"
    #expect(try report().rows.map(\.path) == ["/data/project", "/data/project/pack"])
    filter.text = ""
    filter.growthDecreasing = true
    #expect(try report().rows.map(\.path) == ["/data/cache"])
    #expect(try report().rows.first?.delta == -30)
    filter.category = "application"
    filter.growthDecreasing = false
    #expect(try report().rows.first?.delta == 20)

    let previous = baseline + 5.5 * 3600
    try catalog.execute("UPDATE storage_samples SET time=\(previous),used=0 WHERE id=2;")
    try catalog.record(volume: "fixture", status: status, used: 880, items: [
        DiskWorkbenchRow(title: "App", path: "/data/app", category: "application", bytes: 65)
    ])
    filter.growthHours = 0
    #expect(try report().growth?.baseline == previous)
    #expect(try report().rows.first?.delta == 5)
    filter.growthHours = 1
    #expect(try report().growth?.baseline == previous)
    filter.growthHours = 24
    let full = try report()
    #expect(full.growth?.baseline == baseline)
    #expect(full.growth?.trend.map(\.timestamp).prefix(2).elementsEqual([baseline, previous]) == true)
    #expect(full.growth?.trend.map(\.volumeDelta) == [0, nil, 80])
}
