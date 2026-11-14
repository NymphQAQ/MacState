import AppKit
import UniformTypeIdentifiers

struct DiskAppIcon: Encodable { let path: String; let icon: String }
struct DiskAppIconReport: Encodable { let requestID: String; let queryID: String; let icons: [DiskAppIcon] }

/// Icons are lazy presentation data, independent from index queries and scans.
final class DiskAppIcons {
    static let shared = DiskAppIcons()
    private let worker = DispatchQueue(label: "MacState.storage.icons", qos: .utility)
    private let cache = NSCache<NSString, NSString>()
    private init() { cache.countLimit = 384; cache.totalCostLimit = 4 * 1024 * 1024 }
    func load(_ apps: [DiskAppSpace], completion: @escaping ([DiskAppIcon]) -> Void) {
        worker.async { [self] in
            let icons = apps.compactMap { app -> DiskAppIcon? in
                autoreleasepool {
                    let key = (app.path + "|" + app.bundleID) as NSString
                    if let cached = cache.object(forKey:key) { return DiskAppIcon(path:app.path,icon:cached as String) }
                    let url: URL?
                    if app.path.lowercased().hasSuffix(".app") { url = URL(fileURLWithPath:app.path) }
                    else {
                        let id = app.bundleID.isEmpty ? app.name : app.bundleID
                        url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:id)
                    }
                    let image = url.map { NSWorkspace.shared.icon(forFile:$0.path) } ?? NSWorkspace.shared.icon(for:UTType.application)
                    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:128,pixelsHigh:128,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context = NSGraphicsContext(bitmapImageRep:bitmap) else { return nil }
                    bitmap.size = NSSize(width:128,height:128)
                    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                    image.draw(in:NSRect(x:0,y:0,width:128,height:128),from:.zero,operation:.sourceOver,fraction:1)
                    NSGraphicsContext.restoreGraphicsState()
                    guard let png = bitmap.representation(using:.png,properties:[:]) else { return nil }
                    let value = "data:image/png;base64," + png.base64EncodedString()
                    cache.setObject(value as NSString,forKey:key,cost:value.utf8.count)
                    return DiskAppIcon(path:app.path,icon:value)
                }
            }
            DispatchQueue.main.async { completion(icons) }
        }
    }
}
