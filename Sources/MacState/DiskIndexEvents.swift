import Foundation
import CoreServices

/// Per-device cursors survive restarts without collisions from other disks.
final class DiskIndexEvents {
    struct Event { let path: String; let flags: FSEventStreamEventFlags; let id: UInt64 }
    private var stream: FSEventStreamRef?
    private let handler: ([Event]) -> Void
    init(device: dev_t, since: UInt64, queue: DispatchQueue, relativePath: String = "/", handler: @escaping ([Event]) -> Void) throws {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let owner = Unmanaged<DiskIndexEvents>.fromOpaque(info).takeUnretainedValue()
            let strings = unsafeBitCast(paths, to: NSArray.self) as! [String]
            owner.handler((0..<count).map { Event(path: strings[$0], flags: flags[$0], id: ids[$0]) })
        }
        stream = FSEventStreamCreateRelativeToDevice(nil, callback, &context, device, [relativePath] as CFArray,
            since, 2, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { throw DiskAnalysisStore.Failure(message: "无法创建文件变化监听") }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { stop(); throw DiskAnalysisStore.Failure(message: "无法启动文件变化监听") }
    }
    func flush() { if let stream { FSEventStreamFlushAsync(stream) } }
    func stop() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
    }
    deinit { stop() }
    enum Recovery: Equatable { case none, verifySubtree, verifyVolume, eventsWrapped, rootChanged }
    static func recovery(_ flags: FSEventStreamEventFlags) -> Recovery {
        if flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 { return .rootChanged }
        if flags & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0 { return .eventsWrapped }
        if flags & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 { return .verifyVolume }
        if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 { return .verifySubtree }
        return .none
    }
    static func identity(device: dev_t) -> String? {
        guard let uuid = FSEventsCopyUUIDForDevice(device) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
    static func currentID(device: dev_t) -> UInt64 {
        // Despite its CFAbsoluteTime parameter, this API explicitly requires
        // POSIX seconds since 1970 (see FSEvents.h), not CF's 2001 epoch.
        FSEventsGetLastEventIdForDeviceBeforeTime(device, Date().timeIntervalSince1970)
    }
}
