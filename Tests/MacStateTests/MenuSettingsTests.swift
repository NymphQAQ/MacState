import Testing
import Foundation
import AppKit
@testable import MacState

@Test func legacySettingsMergeNetworkAndPreservePreferences() throws {
    let data = Data(#"{"menuMetrics":["cpu","upload","gpu","download"],"hiddenMetrics":["swap"],"interval":5,"theme":"light","compact":true}"#.utf8)
    let settings = try JSONDecoder().decode(Settings.self, from: data).validated()
    #expect(settings.menuMetrics == ["cpu", "network", "gpu"])
    #expect(settings.hiddenMetrics == ["swap"])
    #expect(settings.interval == 5)
    #expect(settings.theme == "light")
    #expect(settings.compact)
    #expect(settings.menuNameStyle.size == 9)
    #expect(settings.menuValueStyle.size == 11)
    #expect(settings.resolvedMenuColumns.map(\.id) == ["cpu", "network", "gpu"])
    #expect(settings.resolvedMenuColumns[1].metrics == ["upload", "download"])
}

@Test func customColumnsPersistAndValidate() throws {
    var settings = Settings()
    settings.menuColumns = [MenuColumn(id: "custom", name: "处理器", metrics: ["cpu", "cpuTemp", "cpu"], spacing: 13), MenuColumn(id: "custom", name: "GPU", metrics: ["gpu"], spacing: 100)]
    let saved = settings.validated()
    #expect(saved.resolvedMenuColumns[0].metrics == ["cpu", "cpuTemp"])
    #expect(saved.resolvedMenuColumns[0].name == "处理器")
    #expect(saved.resolvedMenuColumns[0].spacing == 13)
    #expect(saved.resolvedMenuColumns[1].spacing == 40)
    #expect(saved.resolvedMenuColumns[1].id != "custom")
    #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(saved)) == saved)
    settings.menuColumns = []
    #expect(settings.validated().resolvedMenuColumns.count == 1)
}

@Test @MainActor func parameterSpacingChangesNativeWidth() {
    let view = MenuMetricView(frame: NSRect(x: 0, y: 0, width: 160, height: 22))
    view.top = "CPU"; view.parameters = ["30%", "60°C", "12W"]
    view.spacing = 0
    let compact = view.preferredWidth(height: 22)
    view.spacing = 20
    #expect(view.preferredWidth(height: 22) == compact + 40)
}

@Test func gpuZeroIsValidAndMissingAggregateStaysUnavailable() {
    let idle = Hardware.gpuMetrics([["Device Utilization %": NSNumber(value: 0)]])
    #expect(idle.first { $0.id == "gpu" }?.value == 0)
    let alternative = Hardware.gpuMetrics([["GPU Activity(%)": NSNumber(value: 42)]])
    #expect(alternative.first { $0.id == "gpu" }?.value == 42)
    let partial = Hardware.gpuMetrics([["Renderer Utilization %": NSNumber(value: 60)]])
    #expect(partial.first { $0.id == "gpu" }?.value == nil)
    #expect(partial.first { $0.id == "gpuRenderer" }?.value == 60)
}

@Test func fanUnitAndColumnSpacingPersistWithLegacyDefaults() throws {
    let legacy = try JSONDecoder().decode(Settings.self, from: Data(#"{"menuMetrics":["fan"]}"#.utf8)).validated()
    #expect(legacy.menuColumnSpacing == 4)
    #expect(!legacy.hideFanUnit)
    var settings = legacy
    settings.hideFanUnit = true
    settings.menuColumnSpacing = 0
    let saved = settings.validated()
    #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(saved)) == saved)
    let fan = Metric(id: "fan", title: "风扇", value: 1640, unit: "RPM", source: "test")
    #expect(MenuPresentation.value(fan) == "1640RPM")
    #expect(MenuPresentation.value(fan, hideFanUnit: true) == "1640")
    #expect(MenuPresentation.value(nil, hideFanUnit: true) == "—")
    settings.menuColumnSpacing = -8
    #expect(settings.validated().menuColumnSpacing == 0)
    settings.menuColumnSpacing = 100
    #expect(settings.validated().menuColumnSpacing == 40)
}

@Test func menuStylesValidateAndPersistIndependently() throws {
    var settings = Settings()
    settings.menuNameStyle = MenuTextStyle(font: "Menlo", size: 8, color: "#33aa99", automaticColor: false, opacity: 0.4)
    settings.menuValueStyle = MenuTextStyle(font: "Helvetica", size: 12, color: "#FFAA22", automaticColor: false, opacity: 0.9)
    let saved = settings.validated()
    let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(saved))
    #expect(decoded == saved)
    #expect(decoded.menuNameStyle.color == "#33AA99")
    #expect(decoded.menuValueStyle.font == "Helvetica")
    #expect(MenuTextStyle(size: 100, color: "invalid", opacity: -2).validated().size == 18)
    #expect(MenuTextStyle(size: 100, color: "invalid", opacity: -2).validated().opacity == 0)
    #expect(MenuTextStyle(color: "invalid").validated().color == "#FFFFFF")
}

@Test func menuLinesPlaceNameAboveValueAndUploadAboveDownload() {
    let metrics = [Metric(id: "cpu", title: "CPU", value: 30, unit: "%", source: "test"),
                   Metric(id: "download", title: "download", value: 2000, unit: "B/s", source: "test"),
                   Metric(id: "upload", title: "upload", value: 138, unit: "B/s", source: "test")]
    let cpu = MenuPresentation.lines(id: "cpu", metrics: metrics)
    #expect(cpu.0 == "CPU")
    #expect(cpu.1 == "30%")
    let network = MenuPresentation.lines(id: "network", metrics: metrics)
    #expect(network.0 == "↑ 138B")
    #expect(network.1 == "↓ 2.00KB")
    #expect(MenuPresentation.lines(id: "network", metrics: []).1 == "↓ —")
}

@Test func bandwidthUsesThreeSignificantDigitsAndDecimalUnits() {
    for (rate, expected) in [(5000.0,"5.00KB"),(50_000,"50.0KB"),(500_000,"500KB"),(1_000_000,"1.00MB"),(10_300_000,"10.3MB"),(999_999,"1.00MB"),(9999,"10.0KB"),(0,"0B")] {
        #expect(MenuPresentation.bandwidth(rate) == expected)
    }
    #expect(MenuPresentation.bandwidth(.nan) == "—")
    #expect(MenuPresentation.bandwidth(-1) == "—")
}

@Test @MainActor func bandwidthChangesKeepMenuWidthAndFollowingColumnsFixed() throws {
    var settings = Settings()
    settings.menuColumns = [.preset("network"), .preset("fan")]
    settings.menuValueStyle = MenuTextStyle(font: "Helvetica", size: 18)
    let view = MenuBarView(frame: .zero)
    var initialWidth: CGFloat?
    var initialFanX: CGFloat?
    for rate: Double? in [nil, 0, 5000, 50_000, 500_000, 1_000_000, 10_300_000, 1_000_000_000] {
        let metrics = [Metric(id:"upload", title:"上传", value:rate, unit:"B/s", source:"test"), Metric(id:"download",title:"下载",value:rate,unit:"B/s",source:"test"),Metric(id:"fan",title:"风扇",value:1640,unit:"RPM",source:"test")]
        let width = view.configure(settings: settings, metrics: metrics, height: 24)
        let fanX = view.subviews[1].frame.minX
        if let initialWidth, let initialFanX { #expect(width == initialWidth); #expect(fanX == initialFanX) }
        else { initialWidth = width; initialFanX = fanX }
    }
    let png = try #require(view.previewPNG())
    let bitmap = try #require(NSBitmapImageRep(data: png))
    #expect(bitmap.pixelsWide == Int(ceil(view.bounds.width * 2)))
    #expect(bitmap.pixelsHigh == 48)
    // A named column with a network parameter also reserves space independently.
    settings.menuColumns = [MenuColumn(id:"custom",name:"流量",metrics:["download","cpuTemp"]),.preset("fan")]
    let widths = [5000.0,50_000,500_000,1_000_000].map { rate in
        view.configure(settings: settings, metrics: [Metric(id:"download",title:"下载",value:rate,unit:"B/s",source:"test")], height:24)
    }
    #expect(Set(widths).count == 1)
}

@Test @MainActor func nativeMenuFitsLargeAndMissingFonts() {
    let view = MenuMetricView(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
    view.top = "CPU"; view.bottom = "100%"
    view.nameStyle = MenuTextStyle(font: "nonexistent font", size: 18)
    view.valueStyle = MenuTextStyle(size: 18)
    #expect(view.preferredWidth(height: 22) >= 36)
    #expect(view.preferredWidth(height: 22) < 160)
    #expect(view.hitTest(NSPoint(x: 5, y: 5)) == nil)
}
