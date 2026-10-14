import CoreFoundation
import Darwin
import Foundation

enum OfficialRuntimeUpdateFailure: Error, LocalizedError, Equatable, Sendable {
    case transportMissing, networkUnavailable, sourceUnavailable, invalidResponse, integrityFailed
    case incompatible, downloadFailed, buildFailed, healthFailed, persistenceFailed, cleanupFailed
    case timeout, cancelled

    var code: String {
        switch self {
        case .transportMissing: "OFFICIAL_UPDATE_BRIDGE_MISSING"
        case .networkUnavailable: "OFFICIAL_UPDATE_NETWORK_FAILED"
        case .sourceUnavailable: "OFFICIAL_UPDATE_SOURCE_UNAVAILABLE"
        case .invalidResponse: "OFFICIAL_UPDATE_METADATA_INVALID"
        case .integrityFailed: "OFFICIAL_UPDATE_INTEGRITY_FAILED"
        case .incompatible: "OFFICIAL_UPDATE_INCOMPATIBLE"
        case .downloadFailed: "OFFICIAL_UPDATE_DOWNLOAD_FAILED"
        case .buildFailed: "OFFICIAL_UPDATE_BUILD_FAILED"
        case .healthFailed: "OFFICIAL_UPDATE_HEALTH_FAILED"
        case .persistenceFailed: "OFFICIAL_UPDATE_SAVE_FAILED"
        case .cleanupFailed: "OFFICIAL_UPDATE_CLEANUP_FAILED"
        case .timeout: "OFFICIAL_UPDATE_TIMEOUT"
        case .cancelled: "OFFICIAL_UPDATE_CANCELLED"
        }
    }

    var message: String {
        switch self {
        case .transportMissing: "App 的官方更新组件不可用，请重新安装完整的 App。"
        case .networkUnavailable: "无法通过已保存的统一代理检查或下载官方版本，请检查网络设置后重试。"
        case .sourceUnavailable: "尚未取得可验证的官方配套版本，请稍后重试。"
        case .invalidResponse: "官方版本信息未通过格式校验，尚未取得可用的新版本。"
        case .integrityFailed: "官方制品签名、摘要或候选文件不一致，已阻止使用该版本。"
        case .incompatible: "官方版本与当前 App 的 Node、处理器或协议不兼容，请使用兼容的 App。"
        case .downloadFailed: "官方配套制品下载未完成，请检查网络后重试。"
        case .buildFailed: "离线运行包构建未完成，当前版本保持不变。请检查本机环境和可用空间后重试。"
        case .healthFailed: "候选版本未通过隔离运行环境健康检查，未加入待启用版本。"
        case .persistenceFailed: "候选版本未能安全保存，请检查可用磁盘空间后重试。"
        case .cleanupFailed: "更新临时目录未能确认清理，请检查临时目录权限后重试。"
        case .timeout: "官方更新操作超时，请检查网络或本机运行环境后重试。"
        case .cancelled: "已取消官方更新，当前运行版本保持不变。"
        }
    }
    var errorDescription: String? { message }

    static func fromPackage(_ failure: RuntimePackageFailure) -> Self {
        switch failure {
        case .integrityFailed: .integrityFailed
        case .incompatible: .incompatible
        case .cancelled: .cancelled
        case .persistenceFailed, .busy: .persistenceFailed
        default: .invalidResponse
        }
    }
}

/// Contains metadata only. Official SDK modules are never imported on the host.
struct OfficialRuntimeRelease: Sendable {
    let sdkVersion: String
    let cliVersion: String
    let nodeMinimum: String
    let metadataBytes: Data
}

protocol OfficialRuntimeUpdating: Sendable {
    func check(current: RuntimePackageInfo, controller: OwnedProcessController) throws -> OfficialRuntimeRelease?
    func prepareAndImport(_ release: OfficialRuntimeRelease, store: any RuntimePackageManaging,
                          controller: OwnedProcessController,
                          progress: @Sendable (Double, String) -> Void) throws -> RuntimePackageInfo
}

enum OfficialRuntimeOperation: Equatable {
    case check, download, build, health
    var timeout: Double {
        switch self { case .check: 90; case .download: 30 * 60; case .build: 600; case .health: 120 }
    }
    var maximumLineBytes: Int { self == .health ? 4_096 : 256 * 1024 }
    var maximumOutputBytes: Int { self == .health ? 128 * 1024 : 2 * 1024 * 1024 }
    var scriptName: String {
        switch self { case .check, .download: "official-stdio.mjs"; case .build: "local-builder.mjs"; case .health: "health.mjs" }
    }
    var unsuccessful: OfficialRuntimeUpdateFailure {
        switch self { case .check: .sourceUnavailable; case .download: .downloadFailed; case .build: .buildFailed; case .health: .healthFailed }
    }
}

enum OfficialRuntimeWire {
    static let maximumMetadataBytes = 128 * 1024

    static func object(_ data: Data, limit: Int = maximumMetadataBytes) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= limit,
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OfficialRuntimeUpdateFailure.invalidResponse
        }
        return result
    }
    static func exact(_ object: [String: Any], _ keys: [String]) throws {
        guard Set(object.keys) == Set(keys) else { throw OfficialRuntimeUpdateFailure.invalidResponse }
    }
    static func bytes(_ object: [String: Any]) throws -> Data {
        do {
            let result = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard result.count <= maximumMetadataBytes else { throw OfficialRuntimeUpdateFailure.invalidResponse }
            return result
        } catch { throw OfficialRuntimeUpdateFailure.invalidResponse }
    }
    static func boolean(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw OfficialRuntimeUpdateFailure.invalidResponse
        }
        return number.boolValue
    }
    static func size(_ value: Any?, maximum: Int64) throws -> Int64 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 1, number.doubleValue <= Double(maximum) else {
            throw OfficialRuntimeUpdateFailure.invalidResponse
        }
        return number.int64Value
    }
    static func release(_ data: Data) throws -> OfficialRuntimeRelease {
        let value = try object(data)
        try exact(value, ["schema", "sdkVersion", "cliVersion", "nodeMinimum", "officialStableCLI", "stableChannelStatus",
                          "artifacts", "metadataSHA256", "signingKeyFingerprint"])
        guard value["schema"] as? String == "official-paired-release/v1",
              let sdk = value["sdkVersion"] as? String, let cli = value["cliVersion"] as? String,
              let node = value["nodeMinimum"] as? String,
              [sdk, cli, node].allSatisfy(RuntimePackageIO.isVersion),
              let status = value["stableChannelStatus"] as? String,
              let fingerprint = value["signingKeyFingerprint"] as? String,
              fingerprint == "31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE",
              let artifacts = value["artifacts"] as? [String: Any],
              let metadata = value["metadataSHA256"] as? [String: String] else {
            throw OfficialRuntimeUpdateFailure.invalidResponse
        }
        switch status {
        case "verified":
            guard let stable = value["officialStableCLI"] as? String, RuntimePackageIO.isVersion(stable) else {
                throw OfficialRuntimeUpdateFailure.invalidResponse
            }
        case "unavailable":
            guard value["officialStableCLI"] is NSNull else { throw OfficialRuntimeUpdateFailure.invalidResponse }
        default: throw OfficialRuntimeUpdateFailure.invalidResponse
        }
        try exact(artifacts, ["sdk", "nativeCLI", "cli"])
        guard Set(metadata.keys) == Set(["sdk", "nativeCLI", "manifest"]), metadata.values.allSatisfy(RuntimePackageIO.isDigest) else {
            throw OfficialRuntimeUpdateFailure.invalidResponse
        }
        var unpackedTotal: Int64 = 0
        for (kind, name) in [("sdk", "@anthropic-ai/claude-agent-sdk"), ("nativeCLI", "@anthropic-ai/claude-agent-sdk-linux-arm64")] {
            guard let artifact = artifacts[kind] as? [String: Any] else { throw OfficialRuntimeUpdateFailure.invalidResponse }
            try exact(artifact, ["name", "version", "integrity", "unpackedSize"])
            guard artifact["name"] as? String == name, artifact["version"] as? String == sdk,
                  let integrity = artifact["integrity"] as? String, integrity.hasPrefix("sha512-"), integrity.utf8.count == 95,
                  let decoded = Data(base64Encoded: String(integrity.dropFirst(7))), decoded.count == 64 else {
                throw OfficialRuntimeUpdateFailure.invalidResponse
            }
            unpackedTotal += try size(artifact["unpackedSize"], maximum: 320 * 1024 * 1024)
        }
        guard unpackedTotal <= 320 * 1024 * 1024 else { throw OfficialRuntimeUpdateFailure.invalidResponse }
        guard let artifact = artifacts["cli"] as? [String: Any] else { throw OfficialRuntimeUpdateFailure.invalidResponse }
        try exact(artifact, ["platform", "size", "sha256"])
        guard artifact["platform"] as? String == "linux-arm64", let digest = artifact["sha256"] as? String,
              RuntimePackageIO.isDigest(digest) else { throw OfficialRuntimeUpdateFailure.invalidResponse }
        _ = try size(artifact["size"], maximum: 320 * 1024 * 1024)
        return .init(sdkVersion: sdk, cliVersion: cli, nodeMinimum: node, metadataBytes: try bytes(value))
    }

    static func checked(_ data: Data, current: RuntimePackageInfo) throws -> OfficialRuntimeRelease? {
        let value = try object(data)
        try exact(value, ["type", "release", "updateAvailable"])
        guard value["type"] as? String == "checked", let metadata = value["release"] as? [String: Any],
              [current.cliVersion, current.sdkVersion, current.nodeVersion].allSatisfy(RuntimePackageIO.isVersion) else {
            throw OfficialRuntimeUpdateFailure.invalidResponse
        }
        let result = try release(bytes(metadata)), available = try boolean(value["updateAvailable"])
        let sdkChange = RuntimePackageIO.compareVersion(result.sdkVersion, current.sdkVersion)
        let cliChange = RuntimePackageIO.compareVersion(result.cliVersion, current.cliVersion)
        guard available == (sdkChange > 0 || cliChange > 0) else { throw OfficialRuntimeUpdateFailure.invalidResponse }
        if available {
            guard sdkChange >= 0, cliChange >= 0,
                  RuntimePackageIO.compareVersion(current.nodeVersion, result.nodeMinimum) >= 0 else {
                throw OfficialRuntimeUpdateFailure.incompatible
            }
        }
        return available ? result : nil
    }

    static func receipt(_ data: Data, release: OfficialRuntimeRelease) throws -> Data {
        let response = try object(data)
        try exact(response, ["type", "receipt"])
        guard response["type"] as? String == "downloaded", let value = response["receipt"] as? [String: Any] else {
            throw OfficialRuntimeUpdateFailure.invalidResponse
        }
        try exact(value, ["schema", "sdkVersion", "cliVersion", "nodeMinimum", "sdkArchiveSHA256", "nativeArchiveSHA256",
                          "cliSHA256", "cliManifestSHA256", "cliSigningKeySHA256", "cliSigningKeyFingerprint",
                          "sdkMetadataSHA256", "nativeMetadataSHA256", "sdkIntegrity", "nativeIntegrity", "cliBytes",
                          "sdkArchiveBytes", "nativeArchiveBytes", "installationScriptsExecuted", "cliExecuted",
                          "binaryMatchesSignedManifest", "provenance"])
        let metadata = try object(release.metadataBytes)
        guard let artifacts = metadata["artifacts"] as? [String: Any],
              let sdk = artifacts["sdk"] as? [String: Any], let native = artifacts["nativeCLI"] as? [String: Any],
              let cli = artifacts["cli"] as? [String: Any], let digests = metadata["metadataSHA256"] as? [String: String],
              value["schema"] as? String == "official-runtime-receipt/v1",
              value["sdkVersion"] as? String == release.sdkVersion, value["cliVersion"] as? String == release.cliVersion,
              value["nodeMinimum"] as? String == release.nodeMinimum,
              value["cliSHA256"] as? String == cli["sha256"] as? String,
              value["cliManifestSHA256"] as? String == digests["manifest"],
              value["sdkMetadataSHA256"] as? String == digests["sdk"], value["nativeMetadataSHA256"] as? String == digests["nativeCLI"],
              value["cliSigningKeySHA256"] as? String == "bd70a5e4a268002704024ceba7f8446024114e94f3f0bdd11c23a9e592be81c6",
              value["cliSigningKeyFingerprint"] as? String == metadata["signingKeyFingerprint"] as? String,
              value["sdkIntegrity"] as? String == sdk["integrity"] as? String,
              value["nativeIntegrity"] as? String == native["integrity"] as? String,
              value["provenance"] as? String == "official-npm-and-anthropic-signature" else {
            throw OfficialRuntimeUpdateFailure.integrityFailed
        }
        for key in ["sdkArchiveSHA256", "nativeArchiveSHA256", "cliSHA256", "cliManifestSHA256", "cliSigningKeySHA256",
                    "sdkMetadataSHA256", "nativeMetadataSHA256"] {
            guard let digest = value[key] as? String, RuntimePackageIO.isDigest(digest) else {
                throw OfficialRuntimeUpdateFailure.invalidResponse
            }
        }
        guard try size(value["cliBytes"], maximum: 320 * 1024 * 1024) == size(cli["size"], maximum: 320 * 1024 * 1024),
              try boolean(value["installationScriptsExecuted"]) == false,
              try boolean(value["cliExecuted"]) == false, try boolean(value["binaryMatchesSignedManifest"]) == true else {
            throw OfficialRuntimeUpdateFailure.integrityFailed
        }
        _ = try size(value["sdkArchiveBytes"], maximum: 160 * 1024 * 1024)
        _ = try size(value["nativeArchiveBytes"], maximum: 160 * 1024 * 1024)
        return try bytes(value)
    }

    static func wireFailure(_ code: String, operation: OfficialRuntimeOperation) throws -> OfficialRuntimeUpdateFailure {
        switch code {
        case "OFFICIAL_CANCELLED", "UPDATE_CANCELLED": return .cancelled
        case "OFFICIAL_TIMEOUT", "OFFICIAL_INPUT_TIMEOUT": return .timeout
        case "OFFICIAL_NETWORK_POLICY_INVALID", "OFFICIAL_NETWORK_FAILED": return .networkUnavailable
        case "OFFICIAL_SIGNATURE_INVALID", "OFFICIAL_ARTIFACT_INVALID", "OFFICIAL_DOWNLOAD_HASH", "OFFICIAL_DOWNLOAD_SIZE", "OFFICIAL_RELEASE_CHANGED": return .integrityFailed
        case "OFFICIAL_INCOMPATIBLE_RELEASE", "UPDATE_BUILD_NODE_UNSUPPORTED": return .incompatible
        case "UPDATE_BUILD_TEMPLATE_INVALID", "UPDATE_BUILD_ARCHIVE_INVALID": return .integrityFailed
        case "UPDATE_BUILD_PREPARE_FAILED", "UPDATE_BUILD_FAILED": return .buildFailed
        case "UPDATE_HEALTH_FAILED": return .healthFailed
        case "OFFICIAL_STAGING_INVALID", "OFFICIAL_SAVE_FAILED": return .persistenceFailed
        case "OFFICIAL_CLEANUP_FAILED": return .cleanupFailed
        case "OFFICIAL_HTTP_FAILED", "OFFICIAL_REDIRECT_REFUSED": return operation.unsuccessful
        case "OFFICIAL_MANIFEST_INVALID", "OFFICIAL_METADATA_INVALID", "OFFICIAL_INVALID_REQUEST",
             "OFFICIAL_METADATA_TOO_LARGE", "OFFICIAL_INPUT_TOO_LARGE", "UPDATE_BUILD_INVALID_REQUEST": return .invalidResponse
        default: throw OfficialRuntimeUpdateFailure.invalidResponse
        }
    }
}

struct StdioOfficialRuntimeUpdateService: OfficialRuntimeUpdating {
    let configuration: AppConfiguration
    let bundleContents: URL
    var networkPolicyProvider: any NetworkPolicyProviding = SavedNetworkPolicyProvider()

    func check(current: RuntimePackageInfo, controller: OwnedProcessController) throws -> OfficialRuntimeRelease? {
        try checkCancellation(controller)
        let context = try trustedContext(controller)
        guard RuntimePackageIO.isVersion(current.nodeVersion), current.nodeVersion == context.manifest.nodeVersion else {
            throw OfficialRuntimeUpdateFailure.incompatible
        }
        let network = try networkObject()
        return try withScratchDirectory { owned in
            let scratch = owned.url
            let response = try execute(operation: .check, request: ["schema": "official-runtime-request/v1", "operation": "check",
                "currentCLI": current.cliVersion, "currentSDK": current.sdkVersion, "network": network],
                scratch: scratch, controller: controller)
            try checkCancellation(controller)
            return try OfficialRuntimeWire.checked(response, current: current)
        }
    }

    func prepareAndImport(_ release: OfficialRuntimeRelease, store: any RuntimePackageManaging,
                          controller: OwnedProcessController,
                          progress: @Sendable (Double, String) -> Void) throws -> RuntimePackageInfo {
        try checkCancellation(controller)
        guard let localStore = store as? any LocalRuntimePackageManaging else { throw OfficialRuntimeUpdateFailure.persistenceFailed }
        let validRelease = try OfficialRuntimeWire.release(release.metadataBytes)
        guard validRelease.sdkVersion == release.sdkVersion, validRelease.cliVersion == release.cliVersion,
              validRelease.nodeMinimum == release.nodeMinimum else { throw OfficialRuntimeUpdateFailure.invalidResponse }
        let context = try trustedContext(controller)
        guard RuntimePackageIO.compareVersion(context.manifest.nodeVersion, release.nodeMinimum) >= 0 else {
            throw OfficialRuntimeUpdateFailure.incompatible
        }
        let network = try networkObject(), metadata = try OfficialRuntimeWire.object(release.metadataBytes)
        return try withoutActuallyEscaping(progress) { escapedProgress in
            let reporter = OfficialRuntimeProgressReporter(escapedProgress)
            return try withScratchDirectory { owned in
                let scratch = owned.url
                let artifacts = scratch.appendingPathComponent("artifacts", isDirectory: true)
                let candidate = scratch.appendingPathComponent("candidate", isDirectory: true)
                reporter.emit(0, phase: "download")
                // The downloader re-fetches the pinned metadata and re-verifies the official
                // signature before publishing any archive or receipt into this owned directory.
                let downloaded = try execute(operation: .download, request: ["schema": "official-runtime-request/v1",
                    "operation": "download", "release": metadata, "artifactDirectory": artifacts.path, "network": network],
                    scratch: scratch, controller: controller, progress: { fraction, phase in
                        reporter.emit(fraction * 0.25, phase: phase == "metadata" ? "download" : phase)
                    })
                let receiptBytes = try OfficialRuntimeWire.receipt(downloaded, release: release)
                let receipt = try OfficialRuntimeWire.object(receiptBytes)
                try verifyArchives(artifacts, receipt: receipt, controller: controller)
                try checkCancellation(controller)
                reporter.emit(0.25, phase: "build")
                let built = try execute(operation: .build, request: ["schema": "official-runtime-build/v1",
                    "templateContents": bundleContents.path, "artifactDirectory": artifacts.path,
                    "candidateDirectory": candidate.path, "release": metadata, "receipt": receipt],
                    scratch: scratch, controller: controller, progress: { fraction, phase in
                        reporter.emit(0.25 + fraction * 0.40, phase: ["validate", "built"].contains(phase) ? "build" : phase)
                    })
                try checkCancellation(controller)
                reporter.emit(0.65, phase: "verify")
                let (contents, manifest, recipe) = try verifyBuild(built, candidate: candidate, release: release,
                    receipt: receipt, context: context, controller: controller, progress: { fraction in
                        reporter.emit(0.65 + fraction * 0.15, phase: "verify")
                    })
                reporter.emit(0.80, phase: "health")
                _ = try execute(operation: .health, request: ["schema": "runtime-update-health/v1", "contentsRoot": contents.path],
                                scratch: scratch, controller: controller)
                try checkCancellation(controller)
                let authorization: LocalRuntimeBuildProvenance
                do {
                    authorization = try .init(validatedContents: contents, validatedManifest: manifest,
                        sdkArchiveSHA256: receipt["sdkArchiveSHA256"] as! String, cliSHA256: receipt["cliSHA256"] as! String,
                        cliManifestSHA256: receipt["cliManifestSHA256"] as! String,
                        cliSigningKeySHA256: receipt["cliSigningKeySHA256"] as! String, builderRecipeSHA256: recipe)
                } catch let failure as RuntimePackageFailure { throw OfficialRuntimeUpdateFailure.fromPackage(failure) }
                reporter.emit(0.85, phase: "install")
                let installed: RuntimePackageInfo
                do {
                    installed = try localStore.importLocalBuild(at: contents, provenance: authorization,
                        shouldCancel: { controller.isCancelled }, progress: { fraction in
                            reporter.emit(0.85 + fraction * 0.15, phase: "install")
                        }, beforeCommit: {
                            try checkCancellation(controller)
                            // The store has cached and verified its own immutable copy.
                            // Any cleanup failure occurs before its pending-state commit.
                            try owned.cleanup()
                        })
                } catch let failure as RuntimePackageFailure { throw OfficialRuntimeUpdateFailure.fromPackage(failure) }
                // The store returns info from the same verified manifest it committed.
                // No fallible work remains after the pending-state commit.
                reporter.emit(1, phase: "install")
                return installed
            }
        }
    }

    private struct TrustedContext {
        let manifest: RuntimePackageManifest
        let appVersion: String
        let base: [String: Any]
    }

    private func trustedContext(_ controller: OwnedProcessController) throws -> TrustedContext {
        do {
            try RuntimePackageIO.validateAncestors(bundleContents)
            let manifest = try RuntimePackageIO.decodeManifest(RuntimePackageIO.readSmall(
                bundleContents.appendingPathComponent("Resources/BundledRuntimeManifest.json"), limit: RuntimePackageIO.maximumManifestBytes))
            let infoBytes = try RuntimePackageIO.readSmall(bundleContents.appendingPathComponent("Info.plist"), limit: 128 * 1024)
            guard let info = try PropertyListSerialization.propertyList(from: infoBytes, format: nil) as? [String: Any],
                  let version = info["CFBundleShortVersionString"] as? String, RuntimePackageIO.isVersion(version) else {
                throw OfficialRuntimeUpdateFailure.incompatible
            }
            try manifest.validateCompatibility(appVersion: version)
            try RuntimePackageIO.verifyPayload(bundleContents, manifest: manifest, full: false, shouldCancel: { controller.isCancelled })
            let base = try OfficialRuntimeWire.object(RuntimePackageIO.readSmall(
                bundleContents.appendingPathComponent("Resources/Runtime/host/text-runtime/images/base.json"), limit: 64 * 1024))
            guard let cliDigest = base["linux_cli_sha256"] as? String, RuntimePackageIO.isDigest(cliDigest) else {
                throw OfficialRuntimeUpdateFailure.integrityFailed
            }
            return .init(manifest: manifest, appVersion: version, base: base)
        } catch let failure as OfficialRuntimeUpdateFailure { throw failure }
        catch let failure as RuntimePackageFailure { throw OfficialRuntimeUpdateFailure.fromPackage(failure) }
        catch { throw OfficialRuntimeUpdateFailure.transportMissing }
    }

    private func networkObject() throws -> Any {
        do {
            let policy = try networkPolicyProvider.snapshot(); try policy.validate()
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy))
        } catch { throw OfficialRuntimeUpdateFailure.networkUnavailable }
    }

    private func verifyArchives(_ artifacts: URL, receipt: [String: Any], controller: OwnedProcessController) throws {
        do {
            try RuntimePackageIO.validateAncestors(artifacts)
            guard Set(try FileManager.default.contentsOfDirectory(atPath: artifacts.path)) == Set(["root-sdk.tgz", "native-cli.tgz",
                "sdk-metadata.json", "native-metadata.json", "cli-manifest.json", "cli-manifest.sig", "receipt.json"]) else {
                throw OfficialRuntimeUpdateFailure.integrityFailed
            }
            let persisted = try OfficialRuntimeWire.object(RuntimePackageIO.readSmall(artifacts.appendingPathComponent("receipt.json"), limit: 128 * 1024))
            guard try OfficialRuntimeWire.bytes(persisted) == OfficialRuntimeWire.bytes(receipt) else { throw OfficialRuntimeUpdateFailure.integrityFailed }
            for (name, sizeKey, digestKey) in [("root-sdk.tgz", "sdkArchiveBytes", "sdkArchiveSHA256"), ("native-cli.tgz", "nativeArchiveBytes", "nativeArchiveSHA256")] {
                let file = artifacts.appendingPathComponent(name), stat = try RuntimePackageIO.statFile(file)
                guard stat.st_size == (receipt[sizeKey] as? NSNumber)?.int64Value,
                      try RuntimePackageIO.streamDigest(file, shouldCancel: { controller.isCancelled }) == receipt[digestKey] as? String else {
                    throw OfficialRuntimeUpdateFailure.integrityFailed
                }
            }
            for (name, digestKey) in [("sdk-metadata.json", "sdkMetadataSHA256"), ("native-metadata.json", "nativeMetadataSHA256"), ("cli-manifest.json", "cliManifestSHA256")] {
                let bytes = try RuntimePackageIO.readSmall(artifacts.appendingPathComponent(name), limit: 64 * 1024)
                guard RuntimePackageIO.digest(bytes) == receipt[digestKey] as? String else { throw OfficialRuntimeUpdateFailure.integrityFailed }
            }
            let signature = try RuntimePackageIO.readSmall(artifacts.appendingPathComponent("cli-manifest.sig"), limit: 4_096)
            guard !signature.isEmpty else { throw OfficialRuntimeUpdateFailure.integrityFailed }
        } catch let failure as RuntimePackageFailure { throw OfficialRuntimeUpdateFailure.fromPackage(failure) }
    }

    private func recipeDigest() throws -> String {
        var recipe = Data()
        for path in ["Resources/Runtime/updates/local-builder.mjs", "Resources/Runtime/host/text-runtime/local_build.py"] {
            let bytes = try RuntimePackageIO.readSmall(bundleContents.appendingPathComponent(path), limit: 4 * 1024 * 1024)
            recipe.append(Data("\(bytes.count)\n".utf8)); recipe.append(bytes)
        }
        return RuntimePackageIO.digest(recipe)
    }

    private func verifyBuild(_ data: Data, candidate: URL, release: OfficialRuntimeRelease, receipt: [String: Any],
                             context: TrustedContext, controller: OwnedProcessController,
                             progress: @Sendable (Double) -> Void) throws -> (URL, RuntimePackageManifest, String) {
        let response = try OfficialRuntimeWire.object(data)
        try OfficialRuntimeWire.exact(response, ["type", "result"])
        guard response["type"] as? String == "built", let result = response["result"] as? [String: Any] else { throw OfficialRuntimeUpdateFailure.invalidResponse }
        try OfficialRuntimeWire.exact(result, ["schema", "contentsRoot", "versions", "digests", "baseMetadata", "provenance"])
        let contents = candidate.appendingPathComponent("Contents", isDirectory: true)
        guard result["schema"] as? String == "official-runtime-build-result/v1", result["contentsRoot"] as? String == contents.path,
              let versions = result["versions"] as? [String: String], let digests = result["digests"] as? [String: String],
              let base = result["baseMetadata"] as? [String: Any], let provenance = result["provenance"] as? [String: Any],
              Set(versions.keys) == Set(["sdkVersion", "cliVersion", "nodeVersion"]),
              versions["sdkVersion"] == release.sdkVersion, versions["cliVersion"] == release.cliVersion,
              versions["nodeVersion"] == context.manifest.nodeVersion,
              Set(digests.keys) == Set(["linuxCLI", "disk", "kernel", "initrd"]), digests.values.allSatisfy(RuntimePackageIO.isDigest),
              digests["linuxCLI"] == receipt["cliSHA256"] as? String else { throw OfficialRuntimeUpdateFailure.integrityFailed }
        try OfficialRuntimeWire.exact(provenance, ["release", "receipt", "builderRecipeSHA256"])
        let recipe = try recipeDigest()
        guard let recordedRelease = provenance["release"] as? [String: Any], let recordedReceipt = provenance["receipt"] as? [String: Any],
              try OfficialRuntimeWire.bytes(recordedRelease) == release.metadataBytes,
              try OfficialRuntimeWire.bytes(recordedReceipt) == OfficialRuntimeWire.bytes(receipt),
              provenance["builderRecipeSHA256"] as? String == recipe else { throw OfficialRuntimeUpdateFailure.integrityFailed }
        do {
            try RuntimePackageIO.validateAncestors(contents)
            guard Set(try FileManager.default.contentsOfDirectory(atPath: candidate.path)) == Set(["Contents"]),
                  Set(try FileManager.default.contentsOfDirectory(atPath: contents.path)) == Set(["Helpers", "Resources"]),
                  Set(try FileManager.default.contentsOfDirectory(atPath: contents.appendingPathComponent("Resources").path)) == Set(["Runtime"]) else {
                throw OfficialRuntimeUpdateFailure.integrityFailed
            }
            let basePath = "Resources/Runtime/host/text-runtime/images/base.json"
            let actualBase = try OfficialRuntimeWire.object(RuntimePackageIO.readSmall(contents.appendingPathComponent(basePath), limit: 64 * 1024))
            guard try OfficialRuntimeWire.bytes(actualBase) == OfficialRuntimeWire.bytes(base),
                  let seconds = base["preparation_seconds"] as? NSNumber, CFGetTypeID(seconds) != CFBooleanGetTypeID(),
                  seconds.doubleValue.isFinite, (0...600).contains(seconds.doubleValue) else { throw OfficialRuntimeUpdateFailure.integrityFailed }
            var expectedBase = context.base
            expectedBase["sdk_version"] = release.sdkVersion; expectedBase["cli_version"] = release.cliVersion
            expectedBase["linux_cli_sha256"] = receipt["cliSHA256"]; expectedBase["cli_sha256"] = receipt["cliSHA256"]
            expectedBase["disk_sha256"] = digests["disk"]
            expectedBase["preparation_seconds"] = seconds; expectedBase["socket_devices"] = 0
            guard try OfficialRuntimeWire.bytes(base) == OfficialRuntimeWire.bytes(expectedBase) else { throw OfficialRuntimeUpdateFailure.integrityFailed }
            var files: [RuntimePackageFile] = []
            let mutable: Set<String> = [RuntimePackageManifest.diskPath, basePath, "Resources/Runtime/sdk/package.json",
                "Resources/Runtime/guest/text-runtime/runtime.mjs", "Resources/Runtime/host/text-runtime/common.py",
                "Resources/Runtime/sdk/deepseek-text-chat.mjs", "Resources/Runtime/sdk/deepseek-text-smoke.mjs"]
            let total = max(Int64(1), context.manifest.files.reduce(Int64(0)) { $0 + $1.size })
            var completed: Int64 = 0
            for entry in context.manifest.files {
                try checkCancellation(controller)
                let file = contents.appendingPathComponent(entry.path), metadata = try RuntimePackageIO.statFile(file)
                guard ((metadata.st_mode & 0o111) != 0) == entry.executable else { throw OfficialRuntimeUpdateFailure.integrityFailed }
                let digest = try RuntimePackageIO.streamDigest(file, shouldCancel: { controller.isCancelled }, onBytes: { count in
                    completed += count; progress(min(1, Double(completed) / Double(total)))
                })
                guard mutable.contains(entry.path) || (digest == entry.sha256 && metadata.st_size == entry.size) else {
                    throw OfficialRuntimeUpdateFailure.integrityFailed
                }
                if entry.path == RuntimePackageManifest.diskPath {
                    guard digest == digests["disk"], metadata.st_size == entry.size else { throw OfficialRuntimeUpdateFailure.integrityFailed }
                } else if entry.path == "Resources/Runtime/sdk/package.json" {
                    var expected = try OfficialRuntimeWire.object(RuntimePackageIO.readSmall(bundleContents.appendingPathComponent(entry.path), limit: 64 * 1024))
                    guard var dependencies = expected["dependencies"] as? [String: Any] else { throw OfficialRuntimeUpdateFailure.integrityFailed }
                    dependencies["@anthropic-ai/claude-agent-sdk"] = release.sdkVersion; expected["dependencies"] = dependencies
                    let actual = try OfficialRuntimeWire.object(RuntimePackageIO.readSmall(file, limit: 64 * 1024))
                    guard try OfficialRuntimeWire.bytes(actual) == OfficialRuntimeWire.bytes(expected) else { throw OfficialRuntimeUpdateFailure.integrityFailed }
                } else if mutable.contains(entry.path), entry.path != basePath {
                    let source = try RuntimePackageIO.readSmall(bundleContents.appendingPathComponent(entry.path), limit: 4 * 1024 * 1024)
                    let expected = try rewrittenTemplate(source, path: entry.path, old: context.manifest,
                        oldCLIHash: context.base["linux_cli_sha256"] as! String, release: release, nextCLIHash: digests["linuxCLI"]!)
                    guard digest == RuntimePackageIO.digest(expected), metadata.st_size == expected.count else { throw OfficialRuntimeUpdateFailure.integrityFailed }
                }
                files.append(.init(path: entry.path, size: metadata.st_size, sha256: digest, executable: entry.executable))
            }
            let template = context.manifest
            let manifest = RuntimePackageManifest(schema: RuntimePackageManifest.schemaValue, version: release.cliVersion,
                cliVersion: release.cliVersion, sdkVersion: release.sdkVersion, nodeVersion: template.nodeVersion,
                hostProtocol: template.hostProtocol, platform: template.platform, minimumOSVersion: template.minimumOSVersion,
                minimumAppVersion: template.minimumAppVersion, maximumAppVersionExclusive: template.maximumAppVersionExclusive, files: files)
            try manifest.validate(); try manifest.validateCompatibility(appVersion: context.appVersion)
            for (name, key) in [("kernel", "kernel"), ("initrd", "initrd")] {
                guard files.first(where: { $0.path == "Resources/Runtime/host/text-runtime/images/" + name })?.sha256 == digests[key] else {
                    throw OfficialRuntimeUpdateFailure.integrityFailed
                }
            }
            try RuntimePackageIO.verifyPayload(contents, manifest: manifest, full: true, shouldCancel: { controller.isCancelled })
            progress(1)
            return (contents, manifest, recipe)
        } catch let failure as RuntimePackageFailure { throw OfficialRuntimeUpdateFailure.fromPackage(failure) }
    }

    private func rewrittenTemplate(_ data: Data, path: String, old: RuntimePackageManifest,
                                   oldCLIHash: String, release: OfficialRuntimeRelease, nextCLIHash: String) throws -> Data {
        guard var source = String(data: data, encoding: .utf8) else { throw OfficialRuntimeUpdateFailure.integrityFailed }
        func replace(_ before: String, _ after: String, count: Int = 1) throws {
            guard source.components(separatedBy: before).count - 1 == count else { throw OfficialRuntimeUpdateFailure.integrityFailed }
            source = source.replacingOccurrences(of: before, with: after)
        }
        switch path {
        case "Resources/Runtime/guest/text-runtime/runtime.mjs":
            for (name, before, after) in [("SDK_VERSION", old.sdkVersion, release.sdkVersion), ("CLI_VERSION", old.cliVersion, release.cliVersion), ("CLI_SHA256", oldCLIHash, nextCLIHash)] {
                try replace("const \(name) = '\(before)';", "const \(name) = '\(after)';")
            }
            try replace("cc_version=\(old.cliVersion.replacingOccurrences(of: ".", with: "\\."))\\.", "cc_version=\(release.cliVersion.replacingOccurrences(of: ".", with: "\\."))\\.")
        case "Resources/Runtime/host/text-runtime/common.py": try replace("CLI_SHA256 = '\(oldCLIHash)'", "CLI_SHA256 = '\(nextCLIHash)'")
        case "Resources/Runtime/sdk/deepseek-text-chat.mjs":
            try replace("claude-cli/\(old.cliVersion) (external, sdk-ts, agent-sdk/\(old.sdkVersion))", "claude-cli/\(release.cliVersion) (external, sdk-ts, agent-sdk/\(release.sdkVersion))")
            try replace("CLAUDE_AGENT_SDK_VERSION: '\(old.sdkVersion)'", "CLAUDE_AGENT_SDK_VERSION: '\(release.sdkVersion)'")
            try replace("event.claude_code_version === '\(old.cliVersion)'", "event.claude_code_version === '\(release.cliVersion)'")
            try replace("cc_version=\(old.cliVersion.replacingOccurrences(of: ".", with: "\\."))\\.", "cc_version=\(release.cliVersion.replacingOccurrences(of: ".", with: "\\."))\\.")
            try replace("// Pinned CLI \(old.cliVersion) OAuth", "// Pinned CLI \(release.cliVersion) OAuth")
        case "Resources/Runtime/sdk/deepseek-text-smoke.mjs":
            try replace("packageInfo.version !== '\(old.sdkVersion)' || sdkPackageInfo.version !== '\(old.sdkVersion)'", "packageInfo.version !== '\(release.sdkVersion)' || sdkPackageInfo.version !== '\(release.sdkVersion)'")
            try replace("sdkVersion: '\(old.sdkVersion)', expectedCliVersion: '\(old.cliVersion)'", "sdkVersion: '\(release.sdkVersion)', expectedCliVersion: '\(release.cliVersion)'")
            try replace("CLAUDE_AGENT_SDK_VERSION: '\(old.sdkVersion)'", "CLAUDE_AGENT_SDK_VERSION: '\(release.sdkVersion)'")
            try replace("event.claude_code_version === '\(old.cliVersion)'", "event.claude_code_version === '\(release.cliVersion)'", count: 2)
            try replace("// CLI \(old.cliVersion) appends", "// CLI \(release.cliVersion) appends")
        default: throw OfficialRuntimeUpdateFailure.integrityFailed
        }
        return Data(source.utf8)
    }

    private func checkCancellation(_ controller: OwnedProcessController) throws {
        if controller.isTimedOut { throw OfficialRuntimeUpdateFailure.timeout }
        if controller.isCancelled { throw OfficialRuntimeUpdateFailure.cancelled }
    }

    private func execute(operation: OfficialRuntimeOperation, request: [String: Any], scratch: URL,
                         controller: OwnedProcessController, progress: (Double, String) -> Void = { _, _ in }) throws -> Data {
        try checkCancellation(controller)
        // Updates always use immutable App-owned scripts, including after a local version is activated.
        let script = bundleContents.appendingPathComponent("Resources/Runtime/updates/" + operation.scriptName)
        guard configuration.nodeExecutable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: configuration.nodeExecutable) else {
            throw OfficialRuntimeUpdateFailure.transportMissing
        }
        do { try RuntimePackageIO.validateAncestors(script.deletingLastPathComponent()); _ = try RuntimePackageIO.statFile(script) }
        catch { throw OfficialRuntimeUpdateFailure.transportMissing }
        let payload = try OfficialRuntimeWire.bytes(request) + Data([10])
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: configuration.nodeExecutable); process.arguments = [script.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        var environment = AppRuntimeProfile.japan.processEnvironment
        environment["HOME"] = scratch.path; environment["TMPDIR"] = scratch.path
        process.environment = environment; process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let timeout = DispatchWorkItem { if process.isRunning { controller.cancel(timedOut: true) } }
        var started = false, inputClosed = false
        var outcome: Result<Data, Error>
        do {
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw OfficialRuntimeUpdateFailure.transportMissing }
            try controller.install(process); try process.run(); started = true; controller.didStart()
            DispatchQueue.global().asyncAfter(deadline: .now() + operation.timeout, execute: timeout)
            try checkCancellation(controller); try input.fileHandleForWriting.write(contentsOf: payload)
            try input.fileHandleForWriting.close(); inputClosed = true
            var parser = OfficialRuntimeResponseParser(operation: operation), pending = Data(), outputBytes = 0
            var buffer = [UInt8](repeating: 0, count: 32_768)
            while true {
                try checkCancellation(controller)
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count < 0 { if errno == EINTR { continue }; throw OfficialRuntimeUpdateFailure.invalidResponse }
                if count == 0 { break }
                outputBytes += count
                guard outputBytes <= operation.maximumOutputBytes else { throw OfficialRuntimeUpdateFailure.invalidResponse }
                pending.append(contentsOf: buffer.prefix(count))
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                    guard !line.isEmpty, line.count <= operation.maximumLineBytes else { throw OfficialRuntimeUpdateFailure.invalidResponse }
                    if let (fraction, phase) = try parser.consume(line) { progress(fraction, phase) }
                }
                guard pending.count <= operation.maximumLineBytes else { throw OfficialRuntimeUpdateFailure.invalidResponse }
            }
            guard pending.isEmpty else { throw OfficialRuntimeUpdateFailure.invalidResponse }
            process.waitUntilExit(); try checkCancellation(controller)
            outcome = .success(try parser.finish(processSucceeded: process.terminationReason == .exit && process.terminationStatus == 0))
        } catch { outcome = .failure(error) }
        timeout.cancel()
        if started && process.isRunning { controller.terminateForCleanup(); process.waitUntilExit() }
        do {
            if !inputClosed { try input.fileHandleForWriting.close() }
            try output.fileHandleForReading.close(); try controller.clearFinishedProcess(process)
        } catch { if case .success = outcome { outcome = .failure(OfficialRuntimeUpdateFailure.transportMissing) } }
        try checkCancellation(controller)
        do { return try outcome.get() }
        catch let failure as OfficialRuntimeUpdateFailure { throw failure }
        catch let failure as RuntimePackageFailure { throw OfficialRuntimeUpdateFailure.fromPackage(failure) }
        catch { throw operation.unsuccessful }
    }

    private func withScratchDirectory<T>(_ operation: (OfficialRuntimeOwnedScratch) throws -> T) throws -> T {
        let owned = try OfficialRuntimeOwnedScratch()
        let outcome: Result<T, Error>
        do { outcome = .success(try operation(owned)) } catch { outcome = .failure(error) }
        // Successful imports have already deleted and read back the scratch
        // directory inside beforeCommit. This call performs no further I/O then.
        try owned.cleanup()
        return try outcome.get()
    }
}

/// Captures directory identity once and remembers a verified deletion. The store's
/// synchronous beforeCommit hook may own the successful cleanup; other paths clean here.
private final class OfficialRuntimeOwnedScratch: @unchecked Sendable {
    let url: URL
    private let identity: stat
    private let lock = NSLock()
    private var removed = false

    init() throws {
        guard let physicalPath = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw OfficialRuntimeUpdateFailure.persistenceFailed }
        let parent = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true); free(physicalPath)
        url = parent.appendingPathComponent("ClaudeOfficialRuntimeUpdate-" + UUID().uuidString, isDirectory: true)
        do {
            try RuntimePackageIO.validateAncestors(parent); try RuntimePackageIO.createPrivateDirectory(url)
            identity = try RuntimePackageIO.statFile(url, directory: true)
            guard identity.st_uid == getuid(), identity.st_mode & 0o777 == 0o700 else { throw OfficialRuntimeUpdateFailure.persistenceFailed }
        } catch { throw OfficialRuntimeUpdateFailure.persistenceFailed }
    }

    func cleanup() throws {
        lock.lock(); defer { lock.unlock() }
        if removed { return }
        do {
            try RuntimePackageIO.validateAncestors(url)
            let current = try RuntimePackageIO.statFile(url, directory: true)
            guard current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
                  current.st_uid == identity.st_uid, current.st_mode & 0o777 == 0o700 else { throw OfficialRuntimeUpdateFailure.cleanupFailed }
            try FileManager.default.removeItem(at: url)
            var remaining = stat()
            guard lstat(url.path, &remaining) != 0, errno == ENOENT else { throw OfficialRuntimeUpdateFailure.cleanupFailed }
            removed = true
        } catch { throw OfficialRuntimeUpdateFailure.cleanupFailed }
    }
}

private final class OfficialRuntimeProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: @Sendable (Double, String) -> Void
    private var fraction = -1.0, lastTime: TimeInterval = 0
    private var phase = ""
    init(_ sink: @escaping @Sendable (Double, String) -> Void) { self.sink = sink }
    func emit(_ value: Double, phase nextPhase: String) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let nextFraction = min(1, max(fraction, value)), shouldEmit = phase != nextPhase || nextFraction == 1 || now - lastTime >= 0.20
        if shouldEmit { fraction = nextFraction; phase = nextPhase; lastTime = now }
        lock.unlock()
        if shouldEmit { sink(nextFraction, nextPhase) }
    }
}

struct OfficialRuntimeResponseParser {
    let operation: OfficialRuntimeOperation
    private var terminal: Data?
    private var failure: OfficialRuntimeUpdateFailure?
    private var fraction = -1.0
    private var progressCount = 0

    init(operation: OfficialRuntimeOperation) { self.operation = operation }

    mutating func consume(_ line: Data) throws -> (Double, String)? {
        guard terminal == nil, failure == nil else { throw OfficialRuntimeUpdateFailure.invalidResponse }
        let value = try OfficialRuntimeWire.object(line, limit: operation.maximumLineBytes)
        guard let type = value["type"] as? String else { throw OfficialRuntimeUpdateFailure.invalidResponse }
        switch type {
        case "checked":
            guard operation == .check else { throw OfficialRuntimeUpdateFailure.invalidResponse }
            try OfficialRuntimeWire.exact(value, ["type", "release", "updateAvailable"])
            guard let metadata = value["release"] as? [String: Any] else { throw OfficialRuntimeUpdateFailure.invalidResponse }
            _ = try OfficialRuntimeWire.release(OfficialRuntimeWire.bytes(metadata))
            _ = try OfficialRuntimeWire.boolean(value["updateAvailable"])
            terminal = line
        case "downloaded", "built", "healthy":
            let expected: OfficialRuntimeOperation = type == "downloaded" ? .download : type == "built" ? .build : .health
            guard operation == expected else { throw OfficialRuntimeUpdateFailure.invalidResponse }
            try OfficialRuntimeWire.exact(value, type == "healthy" ? ["type"] : ["type", type == "built" ? "result" : "receipt"])
            guard type == "healthy" || value[type == "built" ? "result" : "receipt"] is [String: Any] else {
                throw OfficialRuntimeUpdateFailure.invalidResponse
            }
            terminal = line
        case "error":
            try OfficialRuntimeWire.exact(value, ["type", "code"])
            guard let code = value["code"] as? String else { throw OfficialRuntimeUpdateFailure.invalidResponse }
            failure = try OfficialRuntimeWire.wireFailure(code, operation: operation)
        case "progress":
            try OfficialRuntimeWire.exact(value, ["type", "fraction", "phase"])
            let allowed: Set<String> = operation == .build ? ["validate", "clone", "extract", "prepare", "hash", "built"] : ["metadata", "download", "verify"]
            guard operation != .health, let phase = value["phase"] as? String, allowed.contains(phase),
                  let number = value["fraction"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...1).contains(number.doubleValue), number.doubleValue >= fraction,
                  progressCount < 4096 else { throw OfficialRuntimeUpdateFailure.invalidResponse }
            fraction = number.doubleValue; progressCount += 1
            return (fraction, phase)
        default: throw OfficialRuntimeUpdateFailure.invalidResponse
        }
        return nil
    }

    func finish(processSucceeded: Bool) throws -> Data {
        if let failure {
            guard !processSucceeded else { throw OfficialRuntimeUpdateFailure.invalidResponse }
            throw failure
        }
        guard let terminal else { throw OfficialRuntimeUpdateFailure.invalidResponse }
        guard processSucceeded else { throw operation.unsuccessful }
        return terminal
    }
}
