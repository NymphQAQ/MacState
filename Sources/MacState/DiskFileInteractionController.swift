import AppKit
import Quartz
import UniformTypeIdentifiers

struct DiskOpenApplication: Codable {
    let id: String
    let name: String
    let path: String
    let custom: Bool
}

final class DiskFileInteractionController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var previewURLs: [URL] = []
    var onAction: ((String, String?) -> Void)?
    func applications() -> [DiskOpenApplication] {
        let defaults = [("com.microsoft.VSCode", "VS Code"), ("com.mitchellh.ghostty", "Ghostty"), ("com.apple.Terminal", "终端")]
        var apps = defaults.map { id, name in DiskOpenApplication(id:id, name:name, path:NSWorkspace.shared.urlForApplication(withBundleIdentifier:id)?.path ?? "", custom:false) }
        for path in UserDefaults.standard.stringArray(forKey:"storageOpenApplications") ?? [] {
            let url = URL(fileURLWithPath:path)
            if !apps.contains(where: { $0.path == path }) { apps.append(DiskOpenApplication(id:path, name:url.deletingPathExtension().lastPathComponent, path:path, custom:true)) }
        }
        return apps
    }
    func addApplication(window: NSWindow, completion: @escaping () -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = "选择要加入‘打开为’菜单的应用程序"
        panel.beginSheetModal(for:window) { response in
            if response == .OK {
                var paths = UserDefaults.standard.stringArray(forKey:"storageOpenApplications") ?? []
                for url in panel.urls where Bundle(url:url) != nil && !paths.contains(url.path) { paths.append(url.path) }
                UserDefaults.standard.set(paths,forKey:"storageOpenApplications")
            }
            completion()
        }
    }
    func removeApplication(_ path: String) {
        let paths = (UserDefaults.standard.stringArray(forKey:"storageOpenApplications") ?? []).filter { $0 != path }
        UserDefaults.standard.set(paths,forKey:"storageOpenApplications")
    }
    func preview(_ urls: [URL]) {
        previewURLs = urls
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil); return }
        panel.dataSource = self; panel.delegate = self; panel.reloadData(); panel.currentPreviewItemIndex = 0
        NSApp.activate(ignoringOtherApps:true); panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURLs.indices.contains(index) ? previewURLs[index] as NSURL : nil }
    func open(_ urls: [URL], application: String?, completion: @escaping (String?) -> Void) {
        if let application {
            guard let app = applications().first(where: { $0.id == application }), !app.path.isEmpty,
                  FileManager.default.fileExists(atPath:app.path) else { completion("应用未安装或已移动，请在设置中重新添加。"); return }
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            let targets = ["com.apple.Terminal","com.mitchellh.ghostty"].contains(app.id) ? urls.map { url in
                var directory: ObjCBool = false
                return FileManager.default.fileExists(atPath:url.path,isDirectory:&directory) && directory.boolValue ? url : url.deletingLastPathComponent()
            } : urls
            NSWorkspace.shared.open(Array(Set(targets)),withApplicationAt:URL(fileURLWithPath:app.path),configuration:configuration) { _, error in
                DispatchQueue.main.async { completion(error?.localizedDescription) }
            }
        } else {
            let failed = urls.filter { !NSWorkspace.shared.open($0) }
            completion(failed.isEmpty ? nil : "无法打开：" + failed.map(\.lastPathComponent).joined(separator:"、"))
        }
    }
    func menu(at point: NSPoint, in view: NSView) {
        let menu = NSMenu()
        func item(_ title: String, _ action: String, _ application: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title:title,action:#selector(choose(_:)),keyEquivalent:""); item.target = self
            item.representedObject = ["action":action,"application":application ?? ""]; return item
        }
        menu.addItem(item("打开", "open"))
        let openAs = NSMenuItem(title:"打开为",action:nil,keyEquivalent:""); let submenu = NSMenu()
        for app in applications() { let child = item(app.name,"open",app.id); child.isEnabled = !app.path.isEmpty; submenu.addItem(child) }
        openAs.submenu = submenu; menu.addItem(openAs); menu.addItem(.separator())
        menu.addItem(item("拷贝", "copy")); menu.addItem(item("拷贝名称", "names")); menu.addItem(item("拷贝路径", "paths"))
        menu.popUp(positioning:nil,at:point,in:view)
    }
    @objc private func choose(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String:String], let action = value["action"] else { return }
        onAction?(action, value["application"].flatMap { $0.isEmpty ? nil : $0 })
    }
}
