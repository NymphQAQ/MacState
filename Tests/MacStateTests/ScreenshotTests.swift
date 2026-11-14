import AppKit
import Testing
import WebKit
@testable import MacState

private func screenshotFixture() throws -> (NSBitmapImageRep,Data) {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:400,pixelsHigh:240,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    NSColor.white.setFill(); NSRect(x:0,y:0,width:400,height:240).fill()
    ("MACSTATE 2026" as NSString).draw(at:NSPoint(x:30,y:140),withAttributes:[.font:NSFont.systemFont(ofSize:34),.foregroundColor:NSColor.black])
    ("截图文字识别" as NSString).draw(at:NSPoint(x:30,y:65),withAttributes:[.font:NSFont.systemFont(ofSize:32),.foregroundColor:NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    return (bitmap,try #require(bitmap.representation(using:.png,properties:[:])))
}

@Test @MainActor func screenshotRetinaColorAndCropUseOriginalPixels() throws {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
    let bytes = try #require(bitmap.bitmapData)
    for y in 0..<8 { for x in 0..<8 { let i = y*bitmap.bytesPerRow+x*4; bytes[i] = UInt8(x*255/7); bytes[i+1] = UInt8(y*255/7); bytes[i+2] = 0; bytes[i+3] = 255 } }
    let raster = ScreenshotRaster(try #require(bitmap.cgImage)), size = NSSize(width:4,height:4)
    let topRight = try #require(raster.color(at:NSPoint(x:3.9,y:0),viewSize:size))
    let bottomLeft = try #require(raster.color(at:NSPoint(x:-100,y:100),viewSize:size))
    #expect(ScreenshotRaster.hex(topRight) == "#FF0000")
    #expect(ScreenshotRaster.hex(bottomLeft) == "#00FF00")
    #expect(ScreenshotRaster.colorName(topRight) == "红色")
    #expect(ScreenshotRaster.colorName(NSColor(srgbRed:0.35,green:0.01,blue:0.04,alpha:1)) == "深酒红色")
    #expect(ScreenshotRaster.colorName(NSColor(srgbRed:0.5,green:0.5,blue:0.5,alpha:1)) == "灰色")
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    raster.drawMagnifier(center:NSPoint(x:0,y:0),in:NSRect(x:0,y:0,width:220,height:220))
    NSGraphicsContext.restoreGraphicsState()
    let crop = try #require(raster.crop(NSRect(x:1,y:2,width:2,height:1),viewSize:size))
    #expect(crop.width == 4 && crop.height == 2)
    let color = try #require(ScreenshotRaster(crop).color(at:.zero,viewSize:NSSize(width:4,height:2)))
    let original = try #require(raster.color(at:NSPoint(x:1,y:2),viewSize:size))
    #expect(ScreenshotRaster.hex(color) == ScreenshotRaster.hex(original))
    #expect(raster.crop(NSRect(x:10,y:10,width:1,height:1),viewSize:size) == nil)
    #expect(raster.crop(.zero,viewSize:size) == nil)
}

@Test @MainActor func screenshotRegionSelectionPreservesExistingWindowsAndCancels() throws {
    let (bitmap,_) = try screenshotFixture(), image = try #require(bitmap.cgImage)
    let previous = NSWindow(contentRect:NSRect(x:30,y:30,width:200,height:120),styleMask:.borderless,backing:.buffered,defer:false)
    previous.isReleasedWhenClosed = false; previous.orderFront(nil)
    defer { previous.close() }
    let picker = ScreenshotRegionPicker(); var called = false
    picker.start(frames:[(NSRect(x:20,y:20,width:400,height:240),image)]) { result in called = true; #expect(result == nil) }
    #expect(picker.active && previous.isVisible)
    picker.cancel(); #expect(called && !picker.active && previous.isVisible)
    picker.cancel(); #expect(!picker.active)
}

@Test @MainActor func screenshotSettingsPermissionAndPersistenceAreIsolated() throws {
    let suite = "MacState.ScreenshotTests."+UUID().uuidString, defaults = try #require(UserDefaults(suiteName:suite))
    defer { defaults.removePersistentDomain(forName:suite) }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let controller = ScreenshotController(base:base,defaults:defaults,permissionCheck:{false})
    var state: ScreenshotState?; controller.onState = {state = $0}
    controller.capture(mode:"region",display:1)
    #expect(state?.permission == false && state?.busy == false && state?.records.isEmpty == true)
    #expect(state?.message.contains("手动") == true)
    var config = ScreenshotSettings(); config.delay = 99; config.prefix = "/\n:"; config.destination = "invalid"
    for key in ScreenshotHotkeys.modes { config.shortcuts[key]?.enabled = false }
    controller.saveSettings(config)
    let restored = ScreenshotController(base:base,defaults:defaults,permissionCheck:{false})
    #expect(restored.settings.delay == 30 && restored.settings.prefix == "MacState" && restored.settings.destination == "both")
    #expect(restored.settings.shortcuts.values.allSatisfy {!$0.enabled})
}

@Test @MainActor func screenshotPageEditorLoadsOriginalAndNativeOCR() async throws {
    let (_,data) = try screenshotFixture(), base = FileManager.default.temporaryDirectory.appendingPathComponent("MacState-Shot-Test-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:base) }
    let path = base.appendingPathComponent("fixture.png"); try data.write(to:path)
    let record = ScreenshotRecord(id:"fixture",date:0,mode:"region",path:path.path,outputPath:"",thumbnail:"",width:400,height:240)
    try JSONEncoder().encode([record]).write(to:base.appendingPathComponent("history.json"))
    let suite = "MacState.ScreenshotTests."+UUID().uuidString, defaults = try #require(UserDefaults(suiteName:suite))
    defer { defaults.removePersistentDomain(forName:suite) }
    let controller = ScreenshotController(base:base,defaults:defaults,permissionCheck:{false})
    var editor: CGImage?, state: ScreenshotState?
    controller.onState = { state = $0 }; controller.onEditorImage = { _,image in editor=image }
    controller.openEditor("fixture")
    for _ in 0..<200 { if editor != nil { break }; try await Task.sleep(nanoseconds:10_000_000) }
    let image=try #require(editor)
    #expect(image.width == 400 && image.height == 240 && state?.busy == false)
    let text=try ScreenshotEditDocument.recognize(image).map(\.text).joined(separator:"\n")
    #expect(text.contains("MACSTATE") && text.contains("2026") && text.contains("截图文字识别"))
    controller.finishEditor(image,id:"fixture",action:"copy",window:NSWindow())
    for _ in 0..<300 {
        if state?.records.count == 2 && state?.busy == false {break}
        try await Task.sleep(nanoseconds:10_000_000)
    }
    let updated=try #require(state)
    #expect(updated.records.count==2)
    #expect(updated.records[0].id != "fixture" && updated.records[0].mode=="edited")
    #expect(updated.records[0].width==400 && updated.records[0].height==240)
    #expect(updated.records[0].outputPath.isEmpty)
    #expect(updated.records[0].thumbnail.hasPrefix("data:image/png;base64,"))
    #expect(FileManager.default.fileExists(atPath:updated.records[0].path))
    #expect(updated.records[1].id=="fixture")
    #expect(try Data(contentsOf:path)==data)
    #expect(NSPasteboard.general.canReadObject(forClasses:[NSImage.self],options:nil))
}

@Test @MainActor func screenshotEditorSaveAndCopyCreateDistinctPersistentHistoryEntries() async throws {
    let (_,data)=try screenshotFixture()
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("MacState-Edited-History-"+UUID().uuidString)
    let base=root.appendingPathComponent("cache",isDirectory:true)
    try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:root)}
    let source=base.appendingPathComponent("original.png");try data.write(to:source)
    let original=ScreenshotRecord(id:"original",date:1,mode:"region",path:source.path,outputPath:"",thumbnail:"",width:400,height:240)
    try JSONEncoder().encode([original]).write(to:base.appendingPathComponent("history.json"))
    let suite="MacState.Edited-History."+UUID().uuidString
    let defaults=try #require(UserDefaults(suiteName:suite))
    defer {defaults.removePersistentDomain(forName:suite)}
    let controller=ScreenshotController(base:base,defaults:defaults,permissionCheck:{false})
    var latest:ScreenshotState?
    controller.onState={latest=$0}
    let bitmap=try #require(screenshotFixture().0.cgImage)
    let saved=root.appendingPathComponent("marked.png")
    controller.saveEditedOutput(bitmap,id:"original",action:"save",output:saved)
    for _ in 0..<300 {
        if latest?.records.count==2 && latest?.busy==false {break}
        try await Task.sleep(nanoseconds:10_000_000)
    }
    let first=try #require(latest)
    #expect(first.records.count==2 && first.records[0].mode=="edited")
    #expect(first.records[0].outputPath==saved.path)
    #expect(FileManager.default.fileExists(atPath:saved.path))
    #expect(first.records[0].thumbnail.hasPrefix("data:image/png;base64,"))
    #expect(first.records[1].id=="original")
    #expect(try Data(contentsOf:source)==data)

    controller.finishEditor(bitmap,id:first.records[0].id,action:"copy",window:NSWindow())
    for _ in 0..<300 {
        if latest?.records.count==3 && latest?.busy==false {break}
        try await Task.sleep(nanoseconds:10_000_000)
    }
    let second=try #require(latest)
    #expect(second.records.count==3)
    #expect(Set(second.records.map(\.id)).count==3)
    #expect(second.records.map(\.mode)==["edited","edited","region"])
    #expect(second.records[0].outputPath.isEmpty)
    #expect(second.records[0].thumbnail.hasPrefix("data:image/png;base64,"))
    #expect(NSPasteboard.general.canReadObject(forClasses:[NSImage.self],options:nil))
    #expect(try Data(contentsOf:source)==data)
    for _ in 0..<300 {
        let file=base.appendingPathComponent("history.json")
        if let stored=try? JSONDecoder().decode([ScreenshotRecord].self,from:Data(contentsOf:file)),
           stored.count==3 {break}
        try await Task.sleep(nanoseconds:10_000_000)
    }
    let reopened=ScreenshotController(base:base,defaults:defaults,permissionCheck:{false})
    var persisted:ScreenshotState?
    reopened.onState={persisted=$0};reopened.state()
    #expect(persisted?.records.map(\.id)==second.records.map(\.id))
    #expect(persisted?.records.allSatisfy{FileManager.default.fileExists(atPath:$0.path)}==true)
}

private final class ScreenshotBridgeCapture: NSObject, WKScriptMessageHandler {
    var messages: [[String:Any]] = []
    func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) {
        if let body = message.body as? [String:Any] { messages.append(body) }
    }
}

@Test @MainActor func screenshotPageUsesNativeEditorInsteadOfWebCanvas() async throws {
    let root = try #require(Bundle.module.url(forResource:"Web",withExtension:nil)), capture = ScreenshotBridgeCapture(), config = WKWebViewConfiguration()
    config.userContentController.add(capture,name:"macstate")
    let web = WKWebView(frame:NSRect(x:0,y:0,width:1100,height:800),configuration:config)
    let window = NSWindow(contentRect:web.frame,styleMask:.borderless,backing:.buffered,defer:false)
    window.contentView=web;window.orderFront(nil)
    defer { window.orderOut(nil);window.contentView=nil;config.userContentController.removeScriptMessageHandler(forName:"macstate") }
    web.loadFileURL(root.appendingPathComponent("index.html"),allowingReadAccessTo:root)
    for _ in 0..<300 { if capture.messages.contains(where:{$0["action"] as? String == "ready"}) { break }; try await Task.sleep(nanoseconds:20_000_000) }
    try #require(capture.messages.contains {$0["action"] as? String == "ready"})
    let (_,data) = try screenshotFixture(), state = ScreenshotState(settings:ScreenshotSettings(),permission:true,busy:false,canCancel:false,message:"",hotkeyError:"",records:[ScreenshotRecord(id:"fixture",date:0,mode:"region",path:"/fixture.png",outputPath:"",thumbnail:"data:image/png;base64,"+data.base64EncodedString(),width:400,height:240)],displays:["测试显示器"])
    let json = String(decoding:try JSONEncoder().encode(state),as:UTF8.self)
    _ = try await web.evaluateJavaScript("receiveScreenshotState(\(json));navigate('screenshot');")
    #expect(try await web.evaluateJavaScript("!$('screenshot').hidden && $('shot-permission').hidden && !$('shot-canvas') && !$('shot-tools') && document.querySelector('.shot-card-actions [data-shot-edit]').getAttribute('aria-label')==='编辑' && [...document.querySelectorAll('.shot-card-action')].every(button=>button.title && button.getAttribute('aria-label') && button.textContent.trim()==='')") as? Bool == true)
    _ = try await web.evaluateJavaScript("document.querySelector('.shot-thumbnail').click();document.querySelector('[data-shot-capture=region]').click();document.querySelectorAll('.shot-card-actions .glyph').forEach(icon=>icon.click());")
    for _ in 0..<100 { if capture.messages.contains(where:{$0["action"] as? String == "trashScreenshot"}) {break}; try await Task.sleep(nanoseconds:10_000_000) }
    #expect(capture.messages.contains {$0["action"] as? String == "editScreenshotRecord" && $0["id"] as? String == "fixture"})
    #expect(capture.messages.contains {$0["action"] as? String == "captureScreenshot" && $0["mode"] as? String == "region"})
    #expect(capture.messages.contains {$0["action"] as? String == "copyScreenshotRecord"})
    #expect(capture.messages.contains {$0["action"] as? String == "revealScreenshot" && $0["id"] as? String == "fixture"})
    #expect(capture.messages.contains {$0["action"] as? String == "trashScreenshot" && $0["id"] as? String == "fixture"})
    _ = try await web.evaluateJavaScript("receiveScreenshotState({...screenshotState,busy:true,canCancel:true,permission:false});")
    #expect(try await web.evaluateJavaScript("!$('shot-permission').hidden && document.querySelector('[data-shot-edit]').disabled && !$('shot-cancel').disabled") as? Bool == true)
    _ = try await web.evaluateJavaScript("receiveScreenshotState({...screenshotState,busy:false,canCancel:false});$('shot-settings-toggle').click()")
    #expect(try await web.evaluateJavaScript("view==='settings' && settingsCategory==='screenshot' && !$('settings-screenshot').hidden && $('shot-settings').closest('.settings-category')===$('settings-screenshot') && !$('screenshot').contains($('shot-settings')) && $('save-status').hidden && getComputedStyle($('shot-settings-feedback')).display!=='none'") as? Bool == true)
    _ = try await web.evaluateJavaScript("""
    $('shot-destination').value='clipboard';$('shot-format').value='jpg';$('shot-prefix').value='旅行截图';$('shot-delay').value='99';$('shot-pointer').checked=true;
    $('shot-prefix').dispatchEvent(new Event('change',{bubbles:true}));
    """)
    for _ in 0..<100 { if capture.messages.contains(where:{$0["action"] as? String == "saveScreenshotSettings"}) { break };try await Task.sleep(nanoseconds:10_000_000) }
    let saved = try #require(capture.messages.last {$0["action"] as? String == "saveScreenshotSettings"}?["settings"] as? [String:Any])
    #expect(saved["destination"] as? String == "clipboard")
    #expect(saved["format"] as? String == "jpg")
    #expect(saved["prefix"] as? String == "旅行截图")
    #expect(saved["delay"] as? Int == 30)
    #expect(saved["pointer"] as? Bool == true)
    let savedJSON = String(decoding:try JSONSerialization.data(withJSONObject:saved),as:UTF8.self)
    _ = try await web.evaluateJavaScript("""
    receiveScreenshotState({...screenshotState,settings:\(savedJSON),message:'截屏设置已保存。'});
    $('shot-choose-directory').click();$('shot-shortcuts-reset').click();
    const shortcut=document.querySelector('[data-shot-shortcut=region]');shortcut.focus();
    shortcut.dispatchEvent(new KeyboardEvent('keydown',{key:'x',code:'KeyX',bubbles:true}));
    """)
    #expect(try await web.evaluateJavaScript("$('shot-settings-feedback').textContent.includes('已保存') && $('shot-shortcut-error').textContent.includes('包含') && shotRecording==='region'") as? Bool == true)
    _ = try await web.evaluateJavaScript("document.querySelector('[data-shot-shortcut=region]').dispatchEvent(new KeyboardEvent('keydown',{key:'6',code:'Digit6',ctrlKey:true,altKey:true,bubbles:true}))")
    for _ in 0..<100 {
        let shortcut = (capture.messages.last {$0["action"] as? String == "saveScreenshotSettings"}?["settings"] as? [String:Any])?["shortcuts"] as? [String:[String:Any]]
        if shortcut?["region"]?["keyCode"] as? Int == 22 { break }
        try await Task.sleep(nanoseconds:10_000_000)
    }
    let shortcuts = try #require((capture.messages.last {$0["action"] as? String == "saveScreenshotSettings"}?["settings"] as? [String:Any])?["shortcuts"] as? [String:[String:Any]])
    #expect(shortcuts["region"]?["keyCode"] as? Int == 22)
    #expect(shortcuts["region"]?["modifiers"] as? Int == 6144)
    #expect(shortcuts["region"]?["label"] as? String == "⌃⌥6")
    _ = try await web.evaluateJavaScript("document.querySelector('[data-shot-shortcut=window]').focus();selectSettingsCategory('general')")
    #expect(try await web.evaluateJavaScript("shotRecording===null && !$('save-status').hidden") as? Bool == true)
    for _ in 0..<100 { if capture.messages.last(where:{$0["action"] as? String == "suspendScreenshotShortcuts"})?["suspended"] as? Bool == false {break};try await Task.sleep(nanoseconds:10_000_000) }
    #expect(capture.messages.last(where:{$0["action"] as? String == "suspendScreenshotShortcuts"})?["suspended"] as? Bool == false)
    _ = try await web.evaluateJavaScript("selectSettingsCategory('screenshot');document.querySelector('[data-shot-shortcut=screen]').focus();navigate('screenshot')")
    #expect(try await web.evaluateJavaScript("shotRecording===null && !$('screenshot').hidden") as? Bool == true)
    for _ in 0..<100 { if capture.messages.last(where:{$0["action"] as? String == "suspendScreenshotShortcuts"})?["suspended"] as? Bool == false {break};try await Task.sleep(nanoseconds:10_000_000) }
    #expect(capture.messages.last(where:{$0["action"] as? String == "suspendScreenshotShortcuts"})?["suspended"] as? Bool == false)
    #expect(capture.messages.contains {$0["action"] as? String == "screenshotDirectory"})
    #expect(capture.messages.contains {$0["action"] as? String == "resetScreenshotShortcuts"})
    #expect(!capture.messages.contains {$0["action"] as? String == "openScreenshotPermission"})
}

@Test @MainActor func screenshotHotkeyConflictAndRegistrationRecovery() throws {
    let first = ScreenshotHotkeys(), second = ScreenshotHotkeys()
    defer { first.stop(); second.stop() }
    var shortcuts = ScreenshotHotkeys.defaults
    for mode in ScreenshotHotkeys.modes { shortcuts[mode]?.enabled = false }
    shortcuts["region"] = ScreenshotShortcut(keyCode:111,modifiers:6656,label:"⌃⌥⇧F12")
    #expect(first.install(shortcuts).isEmpty)
    #expect(!second.install(shortcuts).isEmpty)
    first.stop(); #expect(second.install(shortcuts).isEmpty)
    second.stop()
    shortcuts["region"]?.modifiers = 0
    #expect(second.install(shortcuts).contains("无效"))
}

@Test @MainActor func screenshotDelayedCaptureCancellationDoesNotCreateFiles() async throws {
    let suite = "MacState.ScreenshotTests."+UUID().uuidString, defaults = try #require(UserDefaults(suiteName:suite))
    defer { defaults.removePersistentDomain(forName:suite) }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let controller = ScreenshotController(base:base,defaults:defaults,permissionCheck:{true})
    var config = ScreenshotSettings(); config.delay = 1
    for mode in ScreenshotHotkeys.modes { config.shortcuts[mode]?.enabled = false }
    controller.saveSettings(config)
    var state: ScreenshotState?; controller.onState = {state = $0}
    controller.capture(mode:"region",display:1)
    #expect(state?.busy == true && state?.canCancel == true)
    controller.cancel()
    try await Task.sleep(nanoseconds:1_100_000_000)
    #expect(state?.busy == false && state?.canCancel == false && state?.records.isEmpty == true)
    #expect(!FileManager.default.fileExists(atPath:base.path))
}
