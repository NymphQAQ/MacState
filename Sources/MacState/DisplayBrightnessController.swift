import AppKit
import CoreGraphics
import Foundation
import IOKit
import Darwin

/// User-facing per-display brightness state. Hardware backlight and software
/// dimming are deliberately labelled differently; software 100% is not the
/// monitor's measured backlight brightness.
struct DisplayBrightnessRow: Codable, Equatable {
    let id: String
    let name: String
    let percent: Int
    let mode: String
    let detail: String
    /// False means the slider position is only a starting reference, not a
    /// measurement. A write-only DDC display can still be hardware-controlled.
    var valueKnown: Bool = true
}

enum DisplayBrightnessMath {
    /// DDC Get VCP (0x10) often fails even when Set VCP works. Do not confuse
    /// read capability with hardware write capability (Crisp DDC notes).
    static func controlMode(hasNative: Bool, hasChannel: Bool,
                            hasValidDDCRead: Bool, failedWrites: Int) -> String {
        if hasNative {return "system"}
        if hasChannel && failedWrites < 3 {
            return hasValidDDCRead ? "ddc" : "ddcUnverified"
        }
        return "software"
    }

    static func clamp(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return min(100, max(0, Int(value.rounded())))
    }

    /// DDC is much slower than mouse input. Pace command starts, not UI
    /// movement; the background worker can absorb intermediate slider values.
    static func ddcWaitNanos(now: UInt64, last: UInt64?, minimum: UInt64 = 85_000_000) -> UInt64 {
        guard let last, now >= last else {return 0}
        let elapsed=now-last
        return elapsed >= minimum ? 0 : minimum-elapsed
    }

    static func ddcValue(percent: Int, maximum: UInt16) -> UInt16 {
        UInt16((Double(min(100, max(0, percent))) * Double(maximum) / 100).rounded())
    }

    static func writeFrame(vcp: UInt8, value: UInt16) -> [UInt8] {
        let payload: [UInt8] = [0x84, 0x03, vcp, UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        return payload + [payload.reduce(UInt8(0x6e ^ 0x51), ^)]
    }

    static func readFrame(vcp: UInt8) -> [UInt8] {
        let payload: [UInt8] = [0x82, 0x01, vcp]
        return payload + [payload.reduce(UInt8(0x6e ^ 0x51), ^)]
    }

    /// Rejects stale EDID bytes, echoed requests and corrupt DDC responses.
    static func parseReply(_ data: [UInt8], vcp: UInt8) -> (current: UInt16, maximum: UInt16)? {
        guard data.count >= 11, data[0] == 0x6e, data[2] == 0x02,
              data[3] == 0, data[4] == vcp,
              data[0...9].reduce(UInt8(0x50), ^) == data[10] else { return nil }
        let maximum = UInt16(data[6]) << 8 | UInt16(data[7])
        let current = UInt16(data[8]) << 8 | UInt16(data[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (current, maximum)
    }

    /// Never guess between indistinguishable monitor identities. A wrong
    /// guess could drive a different screen, not just display an old value.
    struct Identity: Equatable {
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
    }

    static func match(externals: [(UInt32, Identity)],
                      channels: [Identity?]) -> [UInt32: Int] {
        if externals.count == 1 && channels.count == 1 {
            // One external and one channel: the identity may be absent.
            return [externals[0].0: 0]
        }
        var map: [UInt32: Int] = [:]
        var assigned = Set<Int>()
        for (display, identity) in externals {
            let matches = channels.enumerated().filter { index, candidate in
                guard !assigned.contains(index), let candidate else { return false }
                return candidate.vendor == identity.vendor &&
                       candidate.product == identity.product &&
                       identity.serial != 0 && candidate.serial == identity.serial
            }
            guard matches.count == 1 else { continue }
            map[display] = matches[0].offset
            assigned.insert(matches[0].offset)
        }
        return map
    }

    /// Gamma never goes to zero: a completely black display would make the
    /// restore slider impossible to find.
    static func softwareFactor(_ percent: Int) -> Float {
        Float(max(0.12, Double(min(100, max(0, percent))) / 100))
    }
}

/// Hardware brightness inspired by didriksg/Crisp (MIT), without importing
/// its more invasive display reconfiguration, keyboard hooks or HDR paths.
/// DDC commands follow VESA MCCS VCP 0x10. All I2C work is off the UI thread.
final class DisplayBrightnessController: @unchecked Sendable {
    var onUpdate: (([DisplayBrightnessRow]) -> Void)?

    private let queue = DispatchQueue(label: "app.macstate.display-brightness", qos: .userInitiated)
    private var rows: [DisplayBrightnessRow] = []
    private let pendingLock=NSLock()
    private var pending: [String: Int] = [:]
    private var working = Set<String>()
    private var ddcMaximums: [UInt32: UInt16] = [:]
    private var ddcFailures: [UInt32: Int] = [:]
    // Only accessed from the serial background worker, never the WebView.
    private var lastDDCWriteAt: [UInt32: UInt64] = [:]
    private let ddc = DisplayBrightnessDDC()
    private let gamma = DisplayBrightnessGamma()
    private var generation = 0

    /// Explicit retry clears a previous three-write-failure latch. Simple
    /// page reads do not silently re-enable hardware after a real failure.
    func retryHardware() {
        queue.async {
            self.ddcFailures.removeAll()
            DispatchQueue.main.async {self.refresh()}
        }
    }

    func refresh() {
        // Read AppKit screen names before entering the background DDC queue.
        let names=Dictionary(uniqueKeysWithValues:NSScreen.screens.compactMap { screen -> (CGDirectDisplayID,String)? in
            guard let id=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {return nil}
            return (id,screen.localizedName)
        })
        queue.async {
            self.generation &+= 1
            let version = self.generation
            let displays = Self.onlineDisplays()
            self.ddc.rebuild(for: displays.filter { CGDisplayIsBuiltin($0) == 0 })
            var newRows: [DisplayBrightnessRow] = []
            for id in displays {
                let identity = Self.key(id)
                let name = names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "内建显示器" : "显示器 \(id)")
                let builtin = CGDisplayIsBuiltin(id) != 0
                let native = Self.nativeBrightness(id)
                let hasChannel = !builtin && self.ddc.hasChannel(for:id)
                // No repeated probe on an absent channel. A failed read is
                // inconclusive: many displays accept writes but never reply.
                let read = hasChannel ? self.ddc.read(display:id,code:0x10) : nil
                let mode = builtin && native == nil ? "unavailable" :
                    DisplayBrightnessMath.controlMode(hasNative:native != nil,
                      hasChannel:hasChannel,hasValidDDCRead:read != nil,
                      failedWrites:self.ddcFailures[id,default:0])
                switch mode {
                case "system":
                    self.gamma.restore(display:id)
                    newRows.append(DisplayBrightnessRow(id:identity,name:name,
                       percent:Int((Double(native ?? 1)*100).rounded()),mode:mode,
                       detail:"系统背光 · 直接调节硬件亮度"))
                case "ddc":
                    self.gamma.restore(display:id)
                    if let read {
                        self.ddcMaximums[id] = read.maximum
                        let level = Int((Double(read.current) / Double(read.maximum) * 100).rounded())
                        newRows.append(DisplayBrightnessRow(id:identity,name:name,
                            percent:level,mode:mode,
                            detail:"DDC/CI · 已读取显示器真实硬件亮度"))
                    }
                case "ddcUnverified":
                    self.ddcMaximums.removeValue(forKey:id)
                    self.gamma.restore(display:id)
                    let previous = self.rows.first(where:{$0.id == identity &&
                        ["ddc","ddcUnverified"].contains($0.mode)})
                    // 50 is only an initial thumb location. Do not present
                    // it as an actual brightness measurement.
                    let hasPreviousValue = previous?.mode == "ddc" && previous?.valueKnown == true
                    newRows.append(DisplayBrightnessRow(id:identity,name:name,
                        percent:previous?.percent ?? 50,
                        mode:hasPreviousValue ? "ddc" : mode,
                        detail:hasPreviousValue
                            ? "DDC/CI · 最近记录 \(previous?.percent ?? 50)%；目前未能读回实时值"
                            : "DDC/CI 通道存在，但未读到亮度；首次拖动会尝试硬件调节",
                        valueKnown:hasPreviousValue))
                case "software":
                    self.ddcMaximums.removeValue(forKey:id)
                    newRows.append(DisplayBrightnessRow(id:identity,name:name,
                        percent:self.gamma.percent(for:id) ?? 100,mode:mode,
                        detail:hasChannel
                          ? "DDC/CI 连续写入失败，已降级软件调暗 · 不改变物理背光"
                          : "没有可配对的 DDC/CI 通道 · 软件调暗，不改变物理背光"))
                default:
                    newRows.append(DisplayBrightnessRow(id:identity,name:name,
                        percent:100,mode:"unavailable",
                        detail:"此显示器不提供可用的亮度控制接口"))
                }
            }
            guard version == self.generation else { return }
            self.rows = newRows
            self.publish()
        }
    }

    func set(id: String, percent: Double) {
        guard let value = DisplayBrightnessMath.clamp(percent) else { return }
        // Latest requested value wins even while the serial I2C queue is
        // blocked in a slow monitor write. Avoid accumulating stale writes.
        pendingLock.lock()
        pending[id]=value
        let shouldStart=working.insert(id).inserted
        pendingLock.unlock()
        if shouldStart {queue.async {self.processWrites(for:id)}}
    }

    private func processWrites(for id: String) {
        while true {
            pendingLock.lock()
            let value=pending.removeValue(forKey:id)
            if value == nil {working.remove(id)}
            pendingLock.unlock()
            guard var value else {break}
            guard let display = Self.onlineDisplays().first(where: { Self.key($0) == id }),
                  let index = rows.firstIndex(where: { $0.id == id }) else {
                pendingLock.lock()
                pending.removeValue(forKey:id)
                working.remove(id)
                pendingLock.unlock()
                break
            }
            let old = rows[index]
            var success = false
            var mode = old.mode
            var detail = old.detail
            switch old.mode {
            case "system":
                success = Self.setNativeBrightness(display,percent:value)
                if !success { detail = "系统背光写入失败，请使用系统显示器设置" }
            case "ddc", "ddcUnverified":
                let maximum = ddcMaximums[display] ?? 100
                // The UI streams the first value instantly and coalesces
                // subsequent input every ~85ms. Enforce the same DDC pacing
                // here for other clients and slow/reconnecting monitors.
                let now=DispatchTime.now().uptimeNanoseconds
                let wait=DisplayBrightnessMath.ddcWaitNanos(
                    now:now,last:lastDDCWriteAt[display])
                if wait>0 {Thread.sleep(forTimeInterval:Double(wait)/1_000_000_000)}
                // If the user moved the thumb during the wait, skip the stale
                // target and send the newest one instead.
                pendingLock.lock()
                if let newer=pending.removeValue(forKey:id) {value=newer}
                pendingLock.unlock()
                lastDDCWriteAt[display]=DispatchTime.now().uptimeNanoseconds
                // VCP read failure must never disable hardware writes. Even
                // Crisp sees no valid reply on DM73u pro while its writes work.
                let wrote = ddc.write(display:display,code:0x10,
                    value:DisplayBrightnessMath.ddcValue(percent:value,maximum:maximum))
                if wrote {
                    ddcFailures[display] = 0
                    gamma.restore(display:display)
                    mode = "ddc"
                    detail = "DDC/CI 硬件命令已发送 · 未可靠读回时显示上次设定值"
                    success = true
                } else {
                    let failures = ddcFailures[display,default:0] + 1
                    ddcFailures[display] = failures
                    if failures >= 3 {
                        success = gamma.set(display:display,percent:value)
                        if success {
                            mode = "software"
                            detail = "连续 3 次 DDC/CI 写入失败，已降级为软件调暗"
                        } else {
                            detail = "DDC 写入失败，软件调暗也不可用；请重新检测或检查连接"
                        }
                    } else {
                        detail = "DDC/CI 写入失败（连续 \(failures)/3 次），暂不切换软件调暗"
                    }
                }
            case "software":
                success = gamma.set(display:display,percent:value)
                if !success { detail = "无法应用软件调暗，显示器可能不允许修改色彩表" }
            default: break
            }
            rows[index] = DisplayBrightnessRow(id:id,name:old.name,
                percent:success ? value : old.percent,
                mode:mode,detail:detail,
                valueKnown:success ? true : old.valueKnown)
            publish()
        }
    }

    /// Restore just the LUTs we replaced, not all of macOS's ColorSync state.
    func restoreSoftwareBrightness() {
        gamma.restoreAll()
    }

    private func publish() {
        let snapshot=rows
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snapshot) }
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count:UInt32=0
        guard CGGetOnlineDisplayList(0,nil,&count) == .success, count>0 else{return []}
        var ids=[CGDirectDisplayID](repeating:0,count:Int(count))
        guard CGGetOnlineDisplayList(count,&ids,&count) == .success else{return []}
        return Array(ids.prefix(Int(count))).filter { CGDisplayIsActive($0) != 0 }
    }

    private static func key(_ display: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
           let value = CFUUIDCreateString(kCFAllocatorDefault, uuid) {
            return value as String
        }
        // Never use a bare display ID if there is a better identity available.
        return "v\(CGDisplayVendorNumber(display))-m\(CGDisplayModelNumber(display))-s\(CGDisplaySerialNumber(display))-\(display)"
    }

    private typealias NativeGet=@convention(c)(CGDirectDisplayID,UnsafeMutablePointer<Float>)->Int32
    private typealias NativeSet=@convention(c)(CGDirectDisplayID,Float)->Int32
    private typealias NativeCan=@convention(c)(CGDirectDisplayID)->Bool
    private static let nativeLibrary=dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let nativeGet:NativeGet? = {
        guard let p=dlsym(nativeLibrary,"DisplayServicesGetBrightness") else {return nil}
        return unsafeBitCast(p,to:NativeGet.self)
    }()
    private static let nativeSet:NativeSet? = {
        guard let p=dlsym(nativeLibrary,"DisplayServicesSetBrightness") else {return nil}
        return unsafeBitCast(p,to:NativeSet.self)
    }()
    private static let nativeCan:NativeCan? = {
        guard let p=dlsym(nativeLibrary,"DisplayServicesCanChangeBrightness") else {return nil}
        return unsafeBitCast(p,to:NativeCan.self)
    }()
    private static func nativeBrightness(_ display: CGDirectDisplayID) -> Float? {
        guard nativeCan?(display) == true, let get=nativeGet else{return nil}
        var value:Float=0
        guard get(display,&value) == 0, value.isFinite, (0...1).contains(value) else{return nil}
        return value
    }
    private static func setNativeBrightness(_ display:CGDirectDisplayID,percent:Int)->Bool {
        guard nativeCan?(display) == true, let set=nativeSet else{return false}
        return set(display,Float(percent)/100)==0
    }
}

/// Minimal, conservative Apple Silicon IOAVService DDC/CI transport.
/// When multiple displays are present we only pair unambiguous serial numbers;
/// no guessed channel may dim the wrong physical monitor.
private final class DisplayBrightnessDDC {
    private typealias Create=@convention(c)(CFAllocator?,io_service_t)->UnsafeMutableRawPointer?
    private typealias IO=@convention(c)(UnsafeMutableRawPointer,UInt32,UInt32,UnsafeMutableRawPointer,UInt32)->kern_return_t
    private let handle=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY)
    private lazy var create:Create? = {
        guard let p=dlsym(handle,"IOAVServiceCreateWithService") else{return nil}
        return unsafeBitCast(p,to:Create.self)
    }()
    private lazy var writeIO:IO? = {
        guard let p=dlsym(handle,"IOAVServiceWriteI2C") else{return nil}
        return unsafeBitCast(p,to:IO.self)
    }()
    private lazy var readIO:IO? = {
        guard let p=dlsym(handle,"IOAVServiceReadI2C") else{return nil}
        return unsafeBitCast(p,to:IO.self)
    }()
    private var channels:[CGDirectDisplayID:UnsafeMutableRawPointer]=[:]

    func hasChannel(for display:CGDirectDisplayID) -> Bool {
        channels[display] != nil && writeIO != nil
    }

    func rebuild(for displays:[CGDirectDisplayID]) {
        // Old IOAVService references may point to a different display after
        // a hot-plug. Drop the entire mapping on every explicit refresh.
        channels.values.forEach { Unmanaged<AnyObject>.fromOpaque($0).release() }
        channels.removeAll()
        guard !displays.isEmpty,let create else{return}
        let root=IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else{return}
        defer {IOObjectRelease(root)}
        var iterator:io_iterator_t=0
        guard IORegistryEntryCreateIterator(root,kIOServicePlane,
                 IOOptionBits(kIORegistryIterateRecursively),&iterator)==KERN_SUCCESS else{return}
        defer {IOObjectRelease(iterator)}
        var services:[UnsafeMutableRawPointer]=[]
        var identities:[DisplayBrightnessMath.Identity?]=[]
        var preceding:DisplayBrightnessMath.Identity?
        var entry=IOIteratorNext(iterator)
        while entry != 0 {
            if let attrs=IORegistryEntryCreateCFProperty(
                entry,"DisplayAttributes" as CFString,kCFAllocatorDefault,0)?
                .takeRetainedValue() as? [String:Any],
               let values=attrs["ProductAttributes"] as? [String:Any],
               let vendor=Self.uint32(values["LegacyManufacturerID"]),
               let product=Self.uint32(values["ProductID"]) {
                preceding = .init(vendor:vendor,product:product,
                                serial:Self.uint32(values["SerialNumber"]) ?? 0)
            }
            let name=UnsafeMutablePointer<CChar>.allocate(capacity:128)
            defer {name.deallocate()}
            let isProxy=IOObjectGetClass(entry,name)==KERN_SUCCESS &&
                String(cString:name)=="DCPAVServiceProxy"
            if isProxy {
                let location=IORegistryEntryCreateCFProperty(
                    entry,"Location" as CFString,kCFAllocatorDefault,0)?
                    .takeRetainedValue() as? String
                if (location == nil || location == "External"),
                   let service=create(kCFAllocatorDefault,entry) {
                    services.append(service)
                    identities.append(preceding)
                }
            }
            IOObjectRelease(entry)
            entry=IOIteratorNext(iterator)
        }
        let match=DisplayBrightnessMath.match(
            externals:displays.map{($0,.init(vendor:CGDisplayVendorNumber($0),
                                            product:CGDisplayModelNumber($0),
                                            serial:CGDisplaySerialNumber($0)))},
            channels:identities)
        for (id,index) in match {channels[id]=services[index]}
        for (index,service) in services.enumerated() where !match.values.contains(index) {
            Unmanaged<AnyObject>.fromOpaque(service).release()
        }
    }

    private static func uint32(_ value:Any?)->UInt32? {
        if let number=value as? NSNumber{return number.uint32Value}
        if let value=value as? UInt32{return value}
        return nil
    }

    func read(display:CGDirectDisplayID,code:UInt8)->(current:UInt16,maximum:UInt16)? {
        guard let channel=channels[display],let readIO,let writeIO else{return nil}
        var request=DisplayBrightnessMath.readFrame(vcp:code)
        let requestCount=UInt32(request.count)
        let written=request.withUnsafeMutableBytes { ptr in
            writeIO(channel,0x37,0x51,ptr.baseAddress!,requestCount)
        }
        guard written==KERN_SUCCESS else{return nil}
        Thread.sleep(forTimeInterval:0.04)
        var result=[UInt8](repeating:0,count:12)
        let resultCount=UInt32(result.count)
        let status=result.withUnsafeMutableBytes { ptr in
            readIO(channel,0x37,0x51,ptr.baseAddress!,resultCount)
        }
        guard status==KERN_SUCCESS else{return nil}
        return DisplayBrightnessMath.parseReply(result,vcp:code)
    }

    func write(display:CGDirectDisplayID,code:UInt8,value:UInt16)->Bool {
        guard let channel=channels[display],let writeIO else{return false}
        var data=DisplayBrightnessMath.writeFrame(vcp:code,value:value)
        let dataCount=UInt32(data.count)
        let status=data.withUnsafeMutableBytes { ptr in
            writeIO(channel,0x37,0x51,ptr.baseAddress!,dataCount)
        }
        if status == KERN_SUCCESS {return true}
        // Some monitors intermittently ignore writes. Small bounded retries
        // keep hardware control viable without blocking the WebView thread.
        for _ in 0..<2 {
            Thread.sleep(forTimeInterval:0.05)
            let retry=data.withUnsafeMutableBytes { ptr in
                writeIO(channel,0x37,0x51,ptr.baseAddress!,dataCount)
            }
            if retry == KERN_SUCCESS {return true}
        }
        return false
    }
}

/// Software fallback for external screens without supported hardware control.
/// Only modifies a display after the user moves its slider. The captured
/// display-specific ColorSync table is restored when MacState quits.
private final class DisplayBrightnessGamma {
    private struct LUT {
        let red:[CGGammaValue]
        let green:[CGGammaValue]
        let blue:[CGGammaValue]
    }
    private let lock=NSLock()
    private var original:[CGDirectDisplayID:LUT]=[:]
    private var percentages:[CGDirectDisplayID:Int]=[:]
    func percent(for id:CGDirectDisplayID)->Int? {
        lock.lock();defer{lock.unlock()}
        return percentages[id]
    }
    func set(display:CGDirectDisplayID,percent:Int)->Bool {
        lock.lock();defer{lock.unlock()}
        if original[display] == nil {
            var red=[CGGammaValue](repeating:0,count:256)
            var green=red,blue=red
            var count:UInt32=0
            let status=red.withUnsafeMutableBufferPointer { r in
                green.withUnsafeMutableBufferPointer { g in
                    blue.withUnsafeMutableBufferPointer { b in
                        CGGetDisplayTransferByTable(display,256,r.baseAddress,g.baseAddress,b.baseAddress,&count)
                    }
                }
            }
            guard status == .success, count > 0, count <= 256 else{return false}
            original[display]=LUT(red:Array(red.prefix(Int(count))),
                                  green:Array(green.prefix(Int(count))),
                                  blue:Array(blue.prefix(Int(count))))
        }
        guard let original=original[display] else{return false}
        let factor=DisplayBrightnessMath.softwareFactor(percent)
        var r=original.red.map { $0 * factor }
        var g=original.green.map { $0 * factor }
        var b=original.blue.map { $0 * factor }
        let tableCount=UInt32(r.count)
        let status=r.withUnsafeMutableBufferPointer { rv in
            g.withUnsafeMutableBufferPointer { gv in
                b.withUnsafeMutableBufferPointer { bv in
                    CGSetDisplayTransferByTable(display,tableCount,
                                                rv.baseAddress,gv.baseAddress,bv.baseAddress)
                }
            }
        }
        if status == .success {percentages[display]=percent}
        return status == .success
    }
    func restore(display:CGDirectDisplayID) {
        lock.lock();defer{lock.unlock()}
        guard let lut=original.removeValue(forKey:display) else{return}
        percentages.removeValue(forKey:display)
        Self.restoreLUT(lut,to:display)
    }
    private static func restoreLUT(_ lut:LUT,to id:CGDirectDisplayID) {
        var r=lut.red,g=lut.green,b=lut.blue
        let tableCount=UInt32(r.count)
        _=r.withUnsafeMutableBufferPointer { rv in
            g.withUnsafeMutableBufferPointer { gv in
                b.withUnsafeMutableBufferPointer { bv in
                    CGSetDisplayTransferByTable(id,tableCount,
                                                rv.baseAddress,gv.baseAddress,bv.baseAddress)
                }
            }
        }
    }
    func restoreAll() {
        lock.lock();defer{lock.unlock()}
        for (id,lut) in original {Self.restoreLUT(lut,to:id)}
        original.removeAll()
        percentages.removeAll()
    }
}
