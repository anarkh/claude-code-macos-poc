import Darwin
import Foundation

enum ProjectDirectoryFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidPath, nonCanonicalPath, rootNotAllowed, homeNotAllowed, protectedDirectory
    case missing, notDirectory, notReadable, notWritable, resolutionFailed, protectionUnavailable

    var errorDescription: String? { message }

    var message: String {
        switch self {
        case .invalidPath:
            "执行目录必须是有效的本机绝对路径，且不超过 4096 字节。请重新选择文件夹。"
        case .nonCanonicalPath:
            "保存的执行目录路径格式无效。请重新选择文件夹；原会话数据已保留。"
        case .rootNotAllowed:
            "不能将文件系统根目录作为执行目录。请选择具体的项目文件夹。"
        case .homeNotAllowed:
            "不能将整个用户主目录作为执行目录。请选择具体的项目文件夹。"
        case .protectedDirectory:
            "应用数据目录及包含它的文件夹不能作为执行目录。请选择其他具体项目文件夹。"
        case .missing:
            "执行目录已不存在或当前无法访问。请检查磁盘是否已连接，或重新选择文件夹。"
        case .notDirectory:
            "执行路径指向文件而非文件夹。请重新选择项目文件夹。"
        case .notReadable:
            "应用无法读取执行目录。请检查文件夹权限，或重新选择可读取的文件夹。"
        case .notWritable:
            "应用无法写入执行目录。请检查文件夹权限，或重新选择可写入的文件夹。"
        case .resolutionFailed:
            "执行目录的真实路径无法解析。请检查文件夹或符号链接是否有效，或重新选择文件夹。"
        case .protectionUnavailable:
            "无法确认应用数据目录的保护范围。请检查用户目录和应用数据目录的权限及符号链接后重试。"
        }
    }
}

enum ProjectDirectory {
    static var defaultProtectedRoots: [URL] {
        [FileCredentialStore.defaultDirectoryURL.deletingLastPathComponent()]
    }

    /// Resolve the user's selection before granting the VM access to that directory.
    static func normalized(_ path: String, protectedRoots: [URL] = defaultProtectedRoots) throws -> String {
        try validateAbsolutePath(path)
        let resolved = try existingRealPath(path)
        try validateStoredPath(resolved)

        let manager = FileManager.default
        let home = try protectedRealPath(manager.homeDirectoryForCurrentUser.path)
        guard resolved != home else { throw ProjectDirectoryFailure.homeNotAllowed }
        for root in protectedRoots {
            guard root.isFileURL else { throw ProjectDirectoryFailure.protectionUnavailable }
            let protected = try protectedRealPath(root.path)
            if protected == "/" || resolved == protected || resolved.hasPrefix(protected + "/") || protected.hasPrefix(resolved + "/") {
                throw ProjectDirectoryFailure.protectedDirectory
            }
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            throw ProjectDirectoryFailure.missing
        }
        guard isDirectory.boolValue else { throw ProjectDirectoryFailure.notDirectory }
        guard manager.isReadableFile(atPath: resolved) else { throw ProjectDirectoryFailure.notReadable }
        guard manager.isWritableFile(atPath: resolved) else { throw ProjectDirectoryFailure.notWritable }
        return resolved
    }

    /// Persisted paths are checked without touching the filesystem. A disconnected drive or
    /// removed directory must not prevent the rest of the conversation store from loading.
    static func validateStoredPath(_ path: String) throws {
        try validateAbsolutePath(path)
        guard path != "/" else { throw ProjectDirectoryFailure.rootNotAllowed }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ProjectDirectoryFailure.nonCanonicalPath
        }
    }

    private static func validateAbsolutePath(_ path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096, !path.utf8.contains(0) else {
            throw ProjectDirectoryFailure.invalidPath
        }
    }

    private static func existingRealPath(_ path: String) throws -> String {
        guard let pointer = Darwin.realpath(path, nil) else {
            switch errno {
            case ENOENT: throw ProjectDirectoryFailure.missing
            case ENOTDIR: throw ProjectDirectoryFailure.notDirectory
            case EACCES: throw ProjectDirectoryFailure.notReadable
            default: throw ProjectDirectoryFailure.resolutionFailed
            }
        }
        defer { Darwin.free(pointer) }
        guard let resolved = String(validatingUTF8: pointer) else { throw ProjectDirectoryFailure.invalidPath }
        return resolved
    }

    /// An app data directory may not exist yet. Resolve its nearest existing ancestor
    /// using POSIX semantics, retaining its remaining components without Foundation's
    /// /private/tmp -> /tmp or /private/var -> /var presentation aliases.
    private static func protectedRealPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              path == "/" || path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ProjectDirectoryFailure.protectionUnavailable
        }
        var candidate = path
        var suffix: [String] = []
        while true {
            if let pointer = Darwin.realpath(candidate, nil) {
                defer { Darwin.free(pointer) }
                guard let resolved = String(validatingUTF8: pointer) else {
                    throw ProjectDirectoryFailure.protectionUnavailable
                }
                return suffix.reversed().reduce(resolved) { prefix, component in
                    (prefix == "/" ? "" : prefix) + "/" + component
                }
            }
            guard errno == ENOENT else { throw ProjectDirectoryFailure.protectionUnavailable }
            // A dangling symlink is an existing object with an unknown target boundary.
            // Reject it rather than treating its name as an ordinary missing component.
            var metadata = stat()
            guard Darwin.lstat(candidate, &metadata) != 0, errno == ENOENT,
                  candidate != "/", let separator = candidate.lastIndex(of: "/") else {
                throw ProjectDirectoryFailure.protectionUnavailable
            }
            suffix.append(String(candidate[candidate.index(after: separator)...]))
            candidate = separator == candidate.startIndex ? "/" : String(candidate[..<separator])
        }
    }
}
