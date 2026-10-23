import Foundation
import CryptoKit
import Darwin

private enum RuntimeToolFailure: Error {
    case usage, keyInvalid, outputExists, bundleVersionInvalid
    var message: String {
        switch self {
        case .usage: "Usage: runtime-package-tool prepare-key --key-file ABS --trust-output ABS | bundled-manifest --contents-root ABS --output ABS --version X.Y.Z | pack --contents-root ABS --output ABS.clauderuntime --key-file ABS --version X.Y.Z | publish-layout --package ABS.clauderuntime --trust-file ABS --output ABS_NEW_DIRECTORY"
        case .keyInvalid: "Publisher key is invalid. Use a current-user, private 0600 Ed25519 key file in a 0700 directory outside the repository."
        case .outputExists: "Output already exists; preserve it or select a new output location."
        case .bundleVersionInvalid: "Bundled runtime requires a valid CFBundleShortVersionString in Contents/Info.plist."
        }
    }
}

@main
enum RuntimePackageTool {
    static func main() {
        do { try run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            let message: String
            if let failure = error as? RuntimePackageFailure { message = failure.code + ": " + failure.message }
            else if let failure = error as? RuntimeToolFailure { message = failure.message }
            else { message = "Runtime package operation failed; no payload was executed. Check the input metadata and available storage." }
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(2)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw RuntimeToolFailure.usage }
        var options: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count, arguments[index].hasPrefix("--"),
                  options[arguments[index]] == nil else { throw RuntimeToolFailure.usage }
            options[arguments[index]] = arguments[index + 1]
            index += 2
        }
        let allowed: Set<String>
        switch command {
        case "prepare-key": allowed = ["--key-file", "--trust-output"]
        case "bundled-manifest": allowed = ["--contents-root", "--output", "--version"]
        case "pack": allowed = ["--contents-root", "--output", "--key-file", "--version"]
        case "publish-layout": allowed = ["--package", "--trust-file", "--output"]
        default: throw RuntimeToolFailure.usage
        }
        guard Set(options.keys) == allowed else { throw RuntimeToolFailure.usage }
        func url(_ key: String) throws -> URL {
            guard let path = options[key], path.hasPrefix("/"), !path.contains("\0") else { throw RuntimeToolFailure.usage }
            return URL(fileURLWithPath: path)
        }
        switch command {
        case "prepare-key":
            let keyURL = try url("--key-file")
            let output = try url("--trust-output")
            guard keyURL.path != output.path else { throw RuntimeToolFailure.usage }
            let key = try prepareKey(at: keyURL)
            let raw = key.publicKey.rawRepresentation
            let trust = RuntimePackageTrust(schema: RuntimePackageTrust.schemaValue,
                                            publicKeys: [RuntimePackageIO.digest(raw): raw.base64EncodedString()])
            try RuntimePackageIO.atomicWrite(encode(trust), to: output)
            print("{\"status\":\"publisher_ready\",\"keyID\":\"\(RuntimePackageIO.digest(raw))\"}")
        case "bundled-manifest":
            let contents = try url("--contents-root")
            let manifest = try makeManifest(contents: contents, version: options["--version"]!)
            try validateBundledCompatibility(manifest, contents: contents)
            let output = try url("--output")
            try RuntimePackageIO.atomicWrite(encode(manifest), to: output)
            printSummary(manifest, status: "bundled_manifest_written")
        case "pack":
            let contents = try url("--contents-root")
            let output = try url("--output")
            guard output.pathExtension.lowercased() == "clauderuntime",
                  !output.path.hasPrefix(contents.path + "/") else { throw RuntimeToolFailure.usage }
            var existing = stat()
            guard lstat(output.path, &existing) != 0, errno == ENOENT else { throw RuntimeToolFailure.outputExists }
            let key = try loadKey(at: url("--key-file"))
            let manifest = try makeManifest(contents: contents, version: options["--version"]!)
            let bytes = try encode(manifest)
            let signature = RuntimePackageSignature(schema: RuntimePackageSignature.schemaValue,
                                                    keyID: RuntimePackageIO.digest(key.publicKey.rawRepresentation),
                                                    signature: try key.signature(for: bytes).base64EncodedString())
            let staging = output.deletingLastPathComponent().appendingPathComponent(".runtime-package-" + UUID().uuidString)
            try RuntimePackageIO.createPrivateDirectory(staging)
            do {
                try RuntimePackageIO.copyPayload(from: contents, to: staging.appendingPathComponent("Contents"),
                                                 manifest: manifest, shouldCancel: { false }, progress: { _ in })
                try RuntimePackageIO.atomicWrite(bytes, to: staging.appendingPathComponent("manifest.json"), mode: 0o400)
                try RuntimePackageIO.atomicWrite(encode(signature), to: staging.appendingPathComponent("signature.json"), mode: 0o400)
                try RuntimePackageIO.verifyPayload(staging.appendingPathComponent("Contents"), manifest: manifest,
                                                   full: true, packageRoot: staging)
                try RuntimePackageIO.sealDirectories(staging, manifest: manifest, sealRoot: false)
                guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, output.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw RuntimePackageFailure.persistenceFailed
                }
                guard chmod(output.path, 0o500) == 0 else { throw RuntimePackageFailure.persistenceFailed }
                try RuntimePackageIO.syncDirectory(output)
                try RuntimePackageIO.syncDirectory(output.deletingLastPathComponent())
                printSummary(manifest, status: "signed_package_written")
            } catch {
                do { try RuntimePackageIO.removeOwnedStaging(staging) }
                catch { throw RuntimePackageFailure.persistenceFailed }
                throw error
            }
        case "publish-layout":
            try publishLayout(package: url("--package"), trustFile: url("--trust-file"), output: url("--output"))
        default: throw RuntimeToolFailure.usage
        }
    }

    private struct PublishChannel: Encodable {
        let schema = "claude-runtime-channel/v1"
        let manifestBase64: String
        let signatureBase64: String
    }

    /// Builds a local static directory from an already signed package. It neither
    /// loads the private signing key nor opens a network connection.
    private static func publishLayout(package: URL, trustFile: URL, output: URL) throws {
        guard package.pathExtension.lowercased() == "clauderuntime",
              output.path != package.path, !output.path.hasPrefix(package.path + "/") else {
            throw RuntimeToolFailure.usage
        }
        try RuntimePackageIO.validateAncestors(output.deletingLastPathComponent())
        var existing = stat()
        guard lstat(output.path, &existing) != 0, errno == ENOENT else { throw RuntimeToolFailure.outputExists }
        try RuntimePackageIO.validateAncestors(trustFile.deletingLastPathComponent())
        let trust = try RuntimePackageIO.loadTrust(trustFile)
        let verified = try RuntimePackageIO.signedManifest(at: package, trust: trust)
        guard let signatureBytes = verified.signatureBytes else { throw RuntimePackageFailure.invalidPackage }
        let source = package.appendingPathComponent("Contents", isDirectory: true)
        try RuntimePackageIO.verifyPayload(source, manifest: verified.manifest, full: true, packageRoot: package)

        let staging = output.deletingLastPathComponent().appendingPathComponent(".runtime-publish-" + UUID().uuidString)
        try RuntimePackageIO.createPrivateDirectory(staging)
        do {
            let packages = staging.appendingPathComponent("packages", isDirectory: true)
            let published = packages.appendingPathComponent(verified.id, isDirectory: true)
            try RuntimePackageIO.createPrivateDirectory(packages)
            try RuntimePackageIO.createPrivateDirectory(published)
            try RuntimePackageIO.copyPayload(from: source, to: published.appendingPathComponent("Contents"),
                                             manifest: verified.manifest, shouldCancel: { false }, progress: { _ in })
            // Keep the original signed bytes, including their whitespace, so the
            // channel, downloadable metadata and package ID refer to one release.
            try RuntimePackageIO.atomicWrite(verified.bytes, to: published.appendingPathComponent("manifest.json"), mode: 0o400)
            try RuntimePackageIO.atomicWrite(signatureBytes, to: published.appendingPathComponent("signature.json"), mode: 0o400)
            try RuntimePackageIO.verifyPayload(published.appendingPathComponent("Contents"), manifest: verified.manifest,
                                               full: true, packageRoot: published)
            try RuntimePackageIO.sealDirectories(published, manifest: verified.manifest)
            let channel = PublishChannel(manifestBase64: verified.bytes.base64EncodedString(),
                                         signatureBase64: signatureBytes.base64EncodedString())
            try RuntimePackageIO.atomicWrite(encode(channel), to: staging.appendingPathComponent("channel.json"), mode: 0o400)
            guard chmod(packages.path, 0o500) == 0 else { throw RuntimePackageFailure.persistenceFailed }
            try RuntimePackageIO.syncDirectory(packages)
            try RuntimePackageIO.syncDirectory(staging)
            guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, output.path, UInt32(RENAME_EXCL)) == 0 else {
                throw RuntimePackageFailure.persistenceFailed
            }
            guard chmod(output.path, 0o500) == 0 else { throw RuntimePackageFailure.persistenceFailed }
            try RuntimePackageIO.syncDirectory(output)
            try RuntimePackageIO.syncDirectory(output.deletingLastPathComponent())
            printSummary(verified.manifest, status: "publish_layout_written")
        } catch {
            do { try RuntimePackageIO.removeOwnedStaging(staging) }
            catch { throw RuntimePackageFailure.persistenceFailed }
            throw error
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var bytes = try encoder.encode(value)
        bytes.append(10)
        return bytes
    }

    private static func printSummary(_ manifest: RuntimePackageManifest, status: String) {
        // All fields have already passed bounded numeric-version validation.
        print("{\"status\":\"\(status)\",\"version\":\"\(manifest.version)\",\"cliVersion\":\"\(manifest.cliVersion)\",\"sdkVersion\":\"\(manifest.sdkVersion)\",\"nodeVersion\":\"\(manifest.nodeVersion)\",\"files\":\(manifest.files.count)}")
    }

    private static func privateParent(_ directory: URL) throws {
        var metadata = stat()
        if lstat(directory.path, &metadata) == 0 {
            try RuntimePackageIO.validateAncestors(directory)
            guard metadata.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else { throw RuntimeToolFailure.keyInvalid }
            return
        }
        guard errno == ENOENT, directory.path != "/" else { throw RuntimeToolFailure.keyInvalid }
        // Existing higher ancestors are checked without changing their permissions.
        let parent = directory.deletingLastPathComponent()
        var parentMetadata = stat()
        if lstat(parent.path, &parentMetadata) != 0 {
            guard errno == ENOENT else { throw RuntimeToolFailure.keyInvalid }
            try privateParent(parent)
        } else { try RuntimePackageIO.validateAncestors(parent) }
        try RuntimePackageIO.createPrivateDirectory(directory)
    }

    private static func prepareKey(at url: URL) throws -> Curve25519.Signing.PrivateKey {
        try validateKeyLocation(url)
        try privateParent(url.deletingLastPathComponent())
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 { return try loadKey(at: url) }
        guard errno == ENOENT else { throw RuntimeToolFailure.keyInvalid }
        let key = Curve25519.Signing.PrivateKey()
        // No replacement: concurrent publisher setup cannot overwrite a key already created.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RuntimeToolFailure.keyInvalid }
        var complete = false
        defer { close(fd); if !complete { unlink(url.path) } }
        let raw = key.rawRepresentation
        let written = raw.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == raw.count, fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { throw RuntimeToolFailure.keyInvalid }
        complete = true
        return key
    }

    private static func loadKey(at url: URL) throws -> Curve25519.Signing.PrivateKey {
        try validateKeyLocation(url)
        try RuntimePackageIO.validateAncestors(url.deletingLastPathComponent())
        let parent = try RuntimePackageIO.statFile(url.deletingLastPathComponent(), directory: true)
        let metadata = try RuntimePackageIO.statFile(url)
        guard parent.st_uid == getuid(), parent.st_mode & 0o777 == 0o700,
              metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o600, metadata.st_size == 32 else {
            throw RuntimeToolFailure.keyInvalid
        }
        do { return try Curve25519.Signing.PrivateKey(rawRepresentation: RuntimePackageIO.readSmall(url, limit: 32)) }
        catch { throw RuntimeToolFailure.keyInvalid }
    }

    private static func validateKeyLocation(_ url: URL) throws {
        var path = (url.path as NSString).deletingLastPathComponent
        while path != "/" {
            let directory = URL(fileURLWithPath: path)
            var metadata = stat()
            guard !["app", "clauderuntime"].contains(directory.pathExtension.lowercased()),
                  lstat(directory.appendingPathComponent(".git").path, &metadata) != 0 else {
                throw RuntimeToolFailure.keyInvalid
            }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    private static func validateBundledCompatibility(_ manifest: RuntimePackageManifest, contents: URL) throws {
        let bytes = try RuntimePackageIO.readSmall(contents.appendingPathComponent("Info.plist"), limit: 64 * 1024)
        guard let info = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let appVersion = info["CFBundleShortVersionString"] as? String,
              RuntimePackageIO.isVersion(appVersion) else { throw RuntimeToolFailure.bundleVersionInvalid }
        // Validate the actual App version, independently of the runtime release
        // version, so a new App cannot ship a bundle that rejects itself.
        try manifest.validateCompatibility(appVersion: appVersion)
    }

    private static func makeManifest(contents: URL, version: String) throws -> RuntimePackageManifest {
        guard RuntimePackageIO.isVersion(version) else { throw RuntimeToolFailure.usage }
        try RuntimePackageIO.validateAncestors(contents)
        var files: [RuntimePackageFile] = []
        func visit(_ directory: URL, relative: String) throws {
            try RuntimePackageIO.validateAncestors(directory)
            for name in try RuntimePackageIO.fileManager.contentsOfDirectory(atPath: directory.path).sorted() {
                let child = directory.appendingPathComponent(name)
                let path = relative + "/" + name
                var metadata = stat()
                guard lstat(child.path, &metadata) == 0 else { throw RuntimePackageFailure.invalidPackage }
                if (metadata.st_mode & S_IFMT) == S_IFDIR { try visit(child, relative: path) }
                else {
                    guard RuntimePackageIO.isPayloadPath(path), (metadata.st_mode & S_IFMT) == S_IFREG,
                          metadata.st_nlink == 1 else { throw RuntimePackageFailure.invalidPackage }
                    let lowercase = name.lowercased()
                    guard !["runtimetrust.json", "bundledruntimemanifest.json", "projectconfiguration.json", "state.json"].contains(lowercase),
                          !["key", "pem", "p12", "pfx"].contains(child.pathExtension.lowercased()) else {
                        throw RuntimePackageFailure.invalidPackage
                    }
                    let size = Int64(metadata.st_size)
                    guard size >= 0, size <= 10 * 1024 * 1024 * 1024,
                          path == RuntimePackageManifest.diskPath || size <= 128 * 1024 * 1024 else {
                        throw RuntimePackageFailure.invalidPackage
                    }
                    files.append(.init(path: path, size: size, sha256: try RuntimePackageIO.streamDigest(child),
                                       executable: metadata.st_mode & 0o111 != 0))
                    guard files.count <= 4096 else { throw RuntimePackageFailure.invalidPackage }
                }
            }
        }
        for root in ["Resources/Runtime", "Helpers"] { try visit(contents.appendingPathComponent(root), relative: root) }
        let bytes = try RuntimePackageIO.readSmall(contents.appendingPathComponent("Resources/Runtime/host/text-runtime/images/base.json"), limit: 64 * 1024)
        guard let base = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let cli = base["cli_version"] as? String, let sdk = base["sdk_version"] as? String,
              let node = base["node_version"] as? String else { throw RuntimePackageFailure.invalidPackage }
        let manifest = RuntimePackageManifest(schema: RuntimePackageManifest.schemaValue,
                                              version: version, cliVersion: cli, sdkVersion: sdk, nodeVersion: node,
                                              hostProtocol: 1, platform: "macOS-arm64", minimumOSVersion: "14.0.0",
                                              minimumAppVersion: "0.12.0", maximumAppVersionExclusive: "0.14.0",
                                              files: files.sorted { $0.path < $1.path })
        try manifest.validate()
        try RuntimePackageIO.inventory(contents, manifest: manifest)
        try RuntimePackageIO.validateBase(contents, manifest: manifest)
        return manifest
    }
}
