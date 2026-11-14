import Foundation
import Darwin
import SQLite3

struct DiskFileActionResult: Codable {
    let requestID: String
    let operationID: String
    let path: String
    let success: Bool
    let message: String
}

enum DiskFileSafety {
    static func validate(_ entry: DiskAnalysisEntry) throws {
        let url = URL(fileURLWithPath: entry.path)
        let canonical = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        let data = "/System/Volumes/Data"
        let systemPath = canonical.hasPrefix(data + "/") ? String(canonical.dropFirst(data.count)) : canonical
        let protected = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/etc", "/dev"]
        guard !protected.contains(where: { systemPath == $0 || systemPath.hasPrefix($0 + "/") }),
              !URL(fileURLWithPath: canonical).pathComponents.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }),
              !DiskLocalPolicy.isIndexStorage(canonical), DiskLocalPolicy.exclusion(entry.path) == nil,
              DiskLocalPolicy.isLocalVolume(entry.path) else {
            throw DiskAnalysisStore.Failure(message: "此文件位于系统保护区域、应用包内部或非本地目录，请在 Finder 中自行确认处理。")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sensitive = [".ssh", ".gnupg", ".aws", ".kube", "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Containers", "Library/Group Containers", "Library/Application Support", "Library/Application Support/MobileSync"]
        let packages = [".photoslibrary", ".photolibrary", ".pvm", ".vmwarevm", ".sparsebundle"]
        guard !sensitive.contains(where: { systemPath == home + "/" + $0 || systemPath.hasPrefix(home + "/" + $0 + "/") }),
              !URL(fileURLWithPath: systemPath).pathComponents.contains(where: { component in packages.contains(where: component.lowercased().hasSuffix) || component == ".git" }),
              ![".env", "credentials", "credentials.json", "id_rsa", "id_ed25519"].contains(url.lastPathComponent.lowercased()) else {
            throw DiskAnalysisStore.Failure(message: "此文件属于密钥、个人资料库、应用数据、设备备份或版本控制数据，已保护；请通过对应应用或 Finder 自行处理。")
        }
        if entry.directory {
            let important = sensitive.map { home + "/" + $0 } + [home, home + "/Desktop", home + "/Documents", home + "/Pictures", home + "/Movies", home + "/Music", home + "/Library"]
            guard !entry.pending, entry.skipped == 0, entry.note.isEmpty,
                  !important.contains(where: { $0 == systemPath || $0.hasPrefix(systemPath + "/") }) else {
                throw DiskAnalysisStore.Failure(message: "此目录包含重要用户数据或索引尚不完整，已保护；请在 Finder 中自行确认处理。")
            }
        }
        var value = stat()
        guard lstat(entry.path, &value) == 0 else { throw DiskAnalysisStore.Failure(message: "文件已移动、删除或无法访问，请刷新索引。") }
        let type = value.st_mode & S_IFMT
        let modified = Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1e9
        guard (entry.directory ? type == S_IFDIR : type == S_IFREG || type == S_IFLNK),
              value.st_flags & UInt32(SF_DATALESS) == 0,
              Int64(value.st_dev) == entry.device, Int64(clamping: value.st_ino) == entry.inode,
              (entry.directory || UInt64(max(0, value.st_size)) == entry.logicalBytes), abs(modified - entry.modified) < 0.000001 else {
            throw DiskAnalysisStore.Failure(message: "文件已发生变化或不属于可处理的本地文件，请刷新后重新选择。")
        }
    }
}


extension DiskAnalysisStore {
    func validateInteractionDirectory(_ path: String) throws {
        try withLock {
            let q = try prepare("SELECT 1 FROM entries WHERE instr(path,?)=1 AND (name IN ('.git','.ssh','.gnupg','.aws','.kube','.env','credentials','credentials.json','id_rsa','id_ed25519') OR lower(name) LIKE '%.photoslibrary' OR lower(name) LIKE '%.photolibrary' OR lower(name) LIKE '%.sparsebundle' OR lower(name) LIKE '%.pvm' OR lower(name) LIKE '%.vmwarevm') LIMIT 1")
            defer { sqlite3_finalize(q) }; try bind(path + "/", to:q, at:1)
            let step = sqlite3_step(q)
            if step == SQLITE_ROW { throw Failure(message: "此目录包含密钥、版本控制或重要资料库，已保护；请在 Finder 中确认。") }
            guard step == SQLITE_DONE else { throw failure() }
        }
    }
}
