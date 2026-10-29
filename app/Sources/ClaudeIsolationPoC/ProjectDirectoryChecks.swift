import Foundation

/// All filesystem fixtures live in a disposable directory; no real project is modified.
func projectDirectoryChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) {
        results.append(("project_directory_" + name, passed))
    }
    func expectFailure(_ name: String, _ expected: ProjectDirectoryFailure,
                       operation: () throws -> Void) {
        do { try operation(); check(name, false) }
        catch let failure as ProjectDirectoryFailure {
            check(name, failure == expected && !failure.message.isEmpty)
        } catch { check(name, false) }
    }
    func pythonRealPath(_ path: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import os, sys; sys.stdout.write(os.path.realpath(sys.argv[1]))", path]
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let resolved = String(data: bytes, encoding: .utf8),
              resolved.hasPrefix("/") else {
            throw NSError(domain: "ProjectDirectoryChecks", code: 1)
        }
        return resolved
    }

    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
        "project-directory-checks-\(UUID().uuidString)", isDirectory: true)
    let aliasRoots = ["/private/tmp", "/private/var/tmp"].map {
        URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(
            "project-directory-checks-\(UUID().uuidString)-项目 with spaces", isDirectory: true)
    }
    do {
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let project = root.appendingPathComponent("项目 with spaces", isDirectory: true)
        try manager.createDirectory(at: project, withIntermediateDirectories: false)
        let canonical = try pythonRealPath(project.path)
        check("unicode_and_spaces_supported", try ProjectDirectory.normalized(project.path) == canonical)
        check("temporary_directory_matches_python_realpath", try ProjectDirectory.normalized(root.path) == pythonRealPath(root.path))
        check("selection_is_standardized", try ProjectDirectory.normalized(project.path + "/./") == canonical)
        try ProjectDirectory.validateStoredPath(canonical)
        check("canonical_stored_path_accepted", true)

        let link = root.appendingPathComponent("linked-project", isDirectory: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: project)
        check("selection_resolves_symlinks", try ProjectDirectory.normalized(link.path) == canonical)
        check("symlink_matches_python_realpath", try ProjectDirectory.normalized(link.path) == pythonRealPath(link.path))
        for (index, aliasRoot) in aliasRoots.enumerated() {
            try manager.createDirectory(at: aliasRoot, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            let expected = try pythonRealPath(aliasRoot.path)
            let alias = String(aliasRoot.path.dropFirst("/private".count))
            check("private_alias_\(index)_matches_python_realpath",
                  try ProjectDirectory.normalized(aliasRoot.path) == expected)
            check("public_alias_\(index)_matches_python_realpath",
                  try ProjectDirectory.normalized(alias) == expected && pythonRealPath(alias) == expected)
        }
        let rootLink = root.appendingPathComponent("linked-root", isDirectory: true)
        try manager.createSymbolicLink(at: rootLink, withDestinationURL: URL(fileURLWithPath: "/"))
        expectFailure("symlink_to_root_rejected", .rootNotAllowed) {
            _ = try ProjectDirectory.normalized(rootLink.path)
        }
        expectFailure("relative_path_rejected", .invalidPath) {
            _ = try ProjectDirectory.normalized("relative/project")
        }
        expectFailure("empty_path_rejected", .invalidPath) {
            _ = try ProjectDirectory.normalized("")
        }
        expectFailure("root_rejected", .rootNotAllowed) {
            _ = try ProjectDirectory.normalized("/")
        }
        expectFailure("normalized_root_rejected", .rootNotAllowed) {
            _ = try ProjectDirectory.normalized("/.")
        }
        expectFailure("entire_home_directory_rejected", .homeNotAllowed) {
            _ = try ProjectDirectory.normalized(manager.homeDirectoryForCurrentUser.path)
        }
        let privateRoot = root.appendingPathComponent("AppData", isDirectory: true)
        let privateChild = privateRoot.appendingPathComponent("Credentials", isDirectory: true)
        try manager.createDirectory(at: privateChild, withIntermediateDirectories: true)
        for (name, path) in [
            ("root", privateRoot.path),
            ("ancestor", root.path),
            ("descendant", privateChild.path)
        ] {
            expectFailure("protected_" + name + "_rejected", .protectedDirectory) {
                _ = try ProjectDirectory.normalized(path, protectedRoots: [privateRoot])
            }
        }
        let privateLink = root.appendingPathComponent("linked-app-data", isDirectory: true)
        try manager.createSymbolicLink(at: privateLink, withDestinationURL: privateRoot)
        expectFailure("symlink_to_protected_directory_rejected", .protectedDirectory) {
            _ = try ProjectDirectory.normalized(privateLink.path, protectedRoots: [privateRoot])
        }
        check("project_outside_protected_directory_allowed",
              try ProjectDirectory.normalized(project.path, protectedRoots: [privateRoot]) == canonical)
        let sibling = root.appendingPathComponent("AppData-other", isDirectory: true)
        try manager.createDirectory(at: sibling, withIntermediateDirectories: false)
        check("protected_path_prefix_sibling_allowed",
              try ProjectDirectory.normalized(sibling.path, protectedRoots: [privateRoot])
                == pythonRealPath(sibling.path))
        let futurePrivateRoot = root.appendingPathComponent("not-created/AppData", isDirectory: true)
        expectFailure("missing_protected_root_still_protects_ancestor", .protectedDirectory) {
            _ = try ProjectDirectory.normalized(root.path, protectedRoots: [futurePrivateRoot])
        }
        check("missing_protected_root_allows_unrelated_project",
              try ProjectDirectory.normalized(project.path, protectedRoots: [futurePrivateRoot]) == canonical)
        let danglingLink = root.appendingPathComponent("dangling-app-link", isDirectory: true)
        try manager.createSymbolicLink(at: danglingLink, withDestinationURL: futurePrivateRoot)
        expectFailure("dangling_protected_root_fails_closed", .protectionUnavailable) {
            _ = try ProjectDirectory.normalized(project.path, protectedRoots: [danglingLink.appendingPathComponent("Credentials")])
        }
        expectFailure("nul_rejected", .invalidPath) {
            _ = try ProjectDirectory.normalized(project.path + "\0ignored")
        }
        let missing = root.appendingPathComponent("missing-project", isDirectory: true)
        expectFailure("missing_directory_rejected_at_use", .missing) {
            _ = try ProjectDirectory.normalized(missing.path)
        }
        try ProjectDirectory.validateStoredPath(missing.path)
        check("missing_stored_directory_remains_loadable", true)
        let file = root.appendingPathComponent("plain-file")
        try Data("fixture".utf8).write(to: file)
        expectFailure("file_selection_rejected", .notDirectory) {
            _ = try ProjectDirectory.normalized(file.path)
        }
        try ProjectDirectory.validateStoredPath(file.path)
        check("stored_validation_does_not_read_filesystem", true)
        for (name, path) in [
            ("repeated_separator", canonical + "//child"),
            ("trailing_separator", canonical + "/"),
            ("dot_component", canonical + "/./child"),
            ("parent_component", canonical + "/../child")
        ] {
            expectFailure("stored_" + name + "_rejected", .nonCanonicalPath) {
                try ProjectDirectory.validateStoredPath(path)
            }
        }
        expectFailure("stored_relative_path_rejected", .invalidPath) {
            try ProjectDirectory.validateStoredPath("relative/project")
        }
        expectFailure("stored_root_rejected", .rootNotAllowed) {
            try ProjectDirectory.validateStoredPath("/")
        }
        expectFailure("stored_nul_rejected", .invalidPath) {
            try ProjectDirectory.validateStoredPath(canonical + "\0ignored")
        }
        let maximumASCIIPath = "/" + String(repeating: "a", count: 4_095)
        try ProjectDirectory.validateStoredPath(maximumASCIIPath)
        check("stored_exact_4096_ascii_bytes_accepted", maximumASCIIPath.utf8.count == 4_096)
        let maximumUnicodePath = "/" + String(repeating: "界", count: 1_365)
        try ProjectDirectory.validateStoredPath(maximumUnicodePath)
        check("stored_exact_4096_unicode_bytes_accepted", maximumUnicodePath.utf8.count == 4_096)
        for (name, path) in [
            ("ascii", maximumASCIIPath + "a"),
            ("unicode", maximumUnicodePath + "a")
        ] {
            expectFailure("stored_4097_" + name + "_bytes_rejected", .invalidPath) {
                try ProjectDirectory.validateStoredPath(path)
            }
            expectFailure("selected_4097_" + name + "_bytes_rejected", .invalidPath) {
                _ = try ProjectDirectory.normalized(path)
            }
        }
    } catch {
        check("fixture_setup_or_execution", false)
    }
    var cleaned = true
    for fixture in [root] + aliasRoots {
        do {
            if manager.fileExists(atPath: fixture.path) { try manager.removeItem(at: fixture) }
            if manager.fileExists(atPath: fixture.path) { cleaned = false }
        } catch { cleaned = false }
    }
    check("temporary_fixtures_cleaned", cleaned)
    return results
}
