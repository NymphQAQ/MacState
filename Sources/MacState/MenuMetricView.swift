import AppKit

enum MenuPresentation {
    // Decimal units, three significant digits. Promote the unit after rounding.
    static func bandwidth(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = bytesPerSecond, index = 0
        while amount >= 1000 && index < units.count - 1 { amount /= 1000; index += 1 }
        var decimals = index == 0 ? 0 : amount < 10 ? 2 : amount < 100 ? 1 : 0
        let factor = pow(10.0, Double(decimals))
        amount = (amount * factor).rounded() / factor
        if amount >= 1000 && index < units.count - 1 { amount /= 1000; index += 1 }
        decimals = index == 0 ? 0 : amount < 10 ? 2 : amount < 100 ? 1 : 0
        if amount >= 1000 { return "999TB+" }
        return String(format: "%.*f%@", decimals, amount, units[index])
    }
    static let bandwidthMetricIDs: Set<String> = ["upload", "download", "diskRead", "diskWrite"]
    static let bandwidthWidthSamples: [String] = (0...9).flatMap { digit in
        ["\(digit).\(digit)\(digit)", "\(digit)\(digit).\(digit)", "\(digit)\(digit)\(digit)"].flatMap { number in
            ["B", "KB", "MB", "GB", "TB"].map { number + $0 }
        }
    } + ["999TB+", "—"]

    static func value(_ metric: Metric?, hideFanUnit: Bool = false) -> String {
        guard let value = metric?.value, value.isFinite else { return "—" }
        if hideFanUnit && metric?.unit == "RPM" { return String(format: "%.0f", value) }
        if metric?.unit == "B" {
            if value >= 1_073_741_824 { return String(format: "%.1f GiB", value / 1_073_741_824) }
            if value >= 1_048_576 { return String(format: "%.0f MiB", value / 1_048_576) }
            if value >= 1024 { return String(format: "%.0f KiB", value / 1024) }
        }
        if metric?.unit == "s" { return String(format: "%.1fh", value / 3600) }
        if metric?.unit == "thermal" { return ["正常", "轻度", "严重", "危急"][min(3, max(0, Int(value)))] }
        if metric?.unit == "level" { return [1: "正常", 2: "升高", 4: "危急"][Int(value)] ?? "未知" }
        if metric?.unit == "powerState" { return [0: "电池", 1: "充电", 2: "外接电源"][Int(value)] ?? "未知" }
        if metric?.unit == "B/s" {
            return bandwidth(value)
        }
        return String(format: "%.0f", value) + (metric?.unit ?? "")
    }
    static func lines(id: String, metrics: [Metric]) -> (String, String) {
        if id == "network" {
            return ("↑ " + value(metrics.first { $0.id == "upload" }), "↓ " + value(metrics.first { $0.id == "download" }))
        }
        let label = ["cpu": "CPU", "memory": "MEM", "gpu": "GPU", "cpuTemp": "CPU TEMP", "gpuTemp": "GPU TEMP", "systemPower": "PWR", "battery": "BAT", "disk": "SSD", "fan": "FAN"][id] ?? id
        return (label, value(metrics.first { $0.id == id }))
    }
}

// Draw inside the native status button so its click, hover, and right-click remain intact.
final class MenuMetricView: NSView {
    var top = "", bottom = ""
    var parameters: [String] = []
    var spacing: CGFloat = 6
    var horizontalPadding: CGFloat = 6
    var bandwidthParameters = Set<Int>()
    var nameStyle = MenuTextStyle(), valueStyle = MenuTextStyle()
    var network = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func font(_ style: MenuTextStyle, scale: CGFloat = 1) -> NSFont {
        let size = CGFloat(style.size) * scale
        if style.font == "monospaced" { return .monospacedDigitSystemFont(ofSize: size, weight: .medium) }
        if style.font == "system" { return .systemFont(ofSize: size, weight: .medium) }
        return NSFontManager.shared.font(withFamily: style.font, traits: [], weight: 5, size: size)
            ?? NSFont(name: style.font, size: size) ?? .systemFont(ofSize: size, weight: .medium)
    }
    private func color(_ style: MenuTextStyle) -> NSColor {
        let color: NSColor
        if style.automaticColor { color = .labelColor }
        else {
            let value = UInt32(style.color.dropFirst(), radix: 16) ?? 0xFFFFFF
            color = NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                            blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        return color.withAlphaComponent(CGFloat(style.opacity))
    }
    private func scaledFonts(height: CGFloat) -> (NSFont, NSFont) {
        let topStyle = network ? valueStyle : nameStyle
        let first = font(topStyle), second = font(valueStyle)
        let required = max(first.ascender - first.descender, second.ascender - second.descender)
        let scale = min(1, max(1, (height - 2) / 2) / max(1, required))
        return (font(topStyle, scale: scale), font(valueStyle, scale: scale))
    }
    private func bandwidthWidth(font: NSFont) -> CGFloat {
        MenuPresentation.bandwidthWidthSamples.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }
    private func parameterWidths(font: NSFont) -> [CGFloat] {
        parameters.enumerated().map { index, text in
            bandwidthParameters.contains(index) ? bandwidthWidth(font: font) : (text as NSString).size(withAttributes: [.font: font]).width
        }
    }
    func preferredWidth(height: CGFloat) -> CGFloat {
        let (first, second) = scaledFonts(height: height)
        if network {
            let arrowWidth = ["↑ ", "↓ "].map { ($0 as NSString).size(withAttributes: [.font: second]).width }.max() ?? 0
            return ceil(max(24, arrowWidth + bandwidthWidth(font: second))) + horizontalPadding * 2
        }
        let reserve = !network && parameters.isEmpty && bottom.contains("%") ? "100%" : ""
        let widths = [(top, first), (parameters.isEmpty ? bottom : "", second), (reserve, second)].map { text, font in
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        let parameterWidth = parameterWidths(font: second).reduce(0, +) + CGFloat(max(0, parameters.count - 1)) * spacing
        return ceil(max(24, widths.max() ?? 24, parameterWidth)) + horizontalPadding * 2
    }
    override func draw(_ dirtyRect: NSRect) {
        let (first, second) = scaledFonts(height: bounds.height)
        let rowHeight = (bounds.height - 2) / 2
        if network {
            let attributes: [NSAttributedString.Key: Any] = [.font: second, .foregroundColor: color(valueStyle)]
            let arrowWidth = ["↑ ", "↓ "].map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
            let numberWidth = bandwidthWidth(font: second)
            let x = (bounds.width - arrowWidth - numberWidth) / 2
            for (text, row) in [(top, 0), (bottom, 1)] {
                let arrow = String(text.prefix(2)), number = String(text.dropFirst(2))
                let size = (number as NSString).size(withAttributes: attributes)
                let y = 1 + CGFloat(row) * rowHeight + (rowHeight - size.height) / 2
                (arrow as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
                (number as NSString).draw(at: NSPoint(x: x + arrowWidth + numberWidth - size.width, y: y), withAttributes: attributes)
            }
            return
        }
        for (text, font, style, row) in [(top, first, network ? valueStyle : nameStyle, 0), (parameters.isEmpty ? bottom : "", second, valueStyle, 1)] {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(style)]
            let size = (text as NSString).size(withAttributes: attributes)
            let origin = NSPoint(x: (bounds.width - size.width) / 2, y: 1 + CGFloat(row) * rowHeight + (rowHeight - size.height) / 2)
            (text as NSString).draw(at: origin, withAttributes: attributes)
        }
        if !parameters.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: second, .foregroundColor: color(valueStyle)]
            let sizes = parameters.map { ($0 as NSString).size(withAttributes: attributes) }
            let widths = parameterWidths(font: second)
            let width = widths.reduce(0, +) + CGFloat(max(0, parameters.count - 1)) * spacing
            var x = (bounds.width - width) / 2
            for (index, text) in parameters.enumerated() {
                let size = sizes[index]
                (text as NSString).draw(at: NSPoint(x: x + (widths[index] - size.width) / 2, y: 1 + rowHeight + (rowHeight - size.height) / 2), withAttributes: attributes)
                x += widths[index] + spacing
            }
        }
    }
}

// The actual menu and its preview use this same view, including AppKit fonts and colors.
final class MenuBarView: NSView {
    private var columnViews: [MenuMetricView] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(settings: Settings, metrics: [Metric], height: CGFloat) -> CGFloat {
        while columnViews.count > settings.resolvedMenuColumns.count { columnViews.removeLast().removeFromSuperview() }
        while columnViews.count < settings.resolvedMenuColumns.count {
            let view = MenuMetricView(frame: .zero)
            view.horizontalPadding = 0
            addSubview(view); columnViews.append(view)
        }
        var x: CGFloat = 4
        for (column, view) in zip(settings.resolvedMenuColumns, columnViews) {
            view.network = column.layout == "network"
            let values = column.metrics.map { id in MenuPresentation.value(metrics.first { $0.id == id }, hideFanUnit: settings.hideFanUnit) }
            let lines = view.network ? MenuPresentation.lines(id: "network", metrics: metrics) : (column.name, values.joined(separator: " "))
            view.top = lines.0; view.bottom = lines.1
            view.parameters = view.network ? [] : values
            view.bandwidthParameters = Set(column.metrics.enumerated().filter { _, id in
                MenuPresentation.bandwidthMetricIDs.contains(id) || metrics.first { $0.id == id }?.unit == "B/s"
            }.map(\.offset))
            view.spacing = CGFloat(column.spacing)
            view.nameStyle = settings.menuNameStyle; view.valueStyle = settings.menuValueStyle
            let width = view.preferredWidth(height: height)
            view.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width + CGFloat(settings.menuColumnSpacing)
            view.needsDisplay = true
        }
        let width = x - CGFloat(settings.menuColumnSpacing) + 4
        frame.size = NSSize(width: width, height: height)
        needsDisplay = true
        return width
    }

    func previewPNG() -> Data? {
        guard bounds.width > 0, bounds.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(bounds.width * 2)), pixelsHigh: Int(ceil(bounds.height * 2)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = bounds.size
        cacheDisplay(in: bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
