import Foundation
import Darwin

enum DiskAccessStatus: String, Codable { case granted, missing, unknown }

enum DiskAccess {
    // Test the directory capability actually needed by the scanner. The TCC
    // database's path/existence/permissions are private implementation details.
    // Validate one directory read, discard its buffer, and never read file
    // contents. No path/name from the probe is retained or sent to the UI.
    static func check() -> DiskAccessStatus {
        check(home: FileManager.default.homeDirectoryForCurrentUser, probe: directoryAccess)
    }

    static func check(home: URL, probe: (String) -> Int32) -> DiskAccessStatus {
        var privacyDenied = false
        for relative in ["Library/Mail", "Library/Messages", "Library/Safari"] {
            let error = probe(home.appendingPathComponent(relative).path)
            if error == 0 { return .granted }
            if error == EPERM { privacyDenied = true }
        }
        // EACCES may be an ordinary ACL/Unix denial; missing paths and I/O
        // errors also cannot establish whether FDA has been granted.
        return privacyDenied ? .missing : .unknown
    }

    static func directoryAccess(_ path: String) -> Int32 {
        guard let directory = opendir(path) else { return errno }
        errno = 0
        let readable = readdir(directory) != nil
        let error = readable ? 0 : errno
        closedir(directory)
        return error
    }
}

enum DiskLocalPolicy {
    static func isIndexStorage(_ path: String) -> Bool {
        let directory = "/Library/Application Support/MacState/DiskIndexes"
        return path.hasSuffix(directory) || path.contains(directory + "/")
    }

    static func exclusion(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        for index in parts.indices where parts[index] == "Library" && index + 1 < parts.endIndex {
            if ["CloudStorage", "Mobile Documents"].contains(String(parts[index + 1])) {
                return "手机或云端映射目录，已跳过（包含本地缓存）"
            }
        }
        return nil
    }

    static func isLocalVolume(_ path: String) -> Bool {
        var info = statfs()
        // Metadata handling reports inaccessible/missing roots separately.
        guard statfs(path, &info) == 0 else { return true }
        return info.f_flags & UInt32(MNT_LOCAL) != 0
    }
}
