import Darwin
import Foundation

/// Exercises the production official downloader, offline builder, health gate
/// and local store using only explicit task-owned filesystem inputs. It never
/// reads saved configuration, credentials, history or the production catalog.
@main
struct OfficialRuntimeIntegration {
    private enum Step: String, Sendable {
        case check, install, activate, rollback, cancel, status
        case invalidProxyCheck = "invalid-proxy-check"
    }
    private enum ArgumentsFailure: Error { case invalid }
    private struct Arguments: Sendable {
        let bundleContents: URL
        let storageRoot: URL
        let projectRoot: URL
        let node: URL
        let policy: AppNetworkPolicy
        let step: Step

        init(_ values: [String]) throws {
            let allowed = Set(["--bundle-contents", "--storage-root", "--project-root", "--node", "--proxy-url", "--step"])
            var options: [String: String] = [:]
            var index = 0
            while index < values.count {
                let name = values[index]
                guard allowed.contains(name), index + 1 < values.count, options[name] == nil else { throw ArgumentsFailure.invalid }
                options[name] = values[index + 1]; index += 2
            }
            func path(_ name: String, directory: Bool) throws -> URL {
                guard let value = options[name], value.hasPrefix("/"), value.utf8.count <= 4_096,
                      !value.contains("\0"), !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                    throw ArgumentsFailure.invalid
                }
                return URL(fileURLWithPath: value, isDirectory: directory)
            }
            bundleContents = try path("--bundle-contents", directory: true)
            storageRoot = try path("--storage-root", directory: true)
            projectRoot = try path("--project-root", directory: true)
            node = try path("--node", directory: false)
            guard let rawStep = options["--step"], let selected = Step(rawValue: rawStep),
                  let proxy = options["--proxy-url"], proxy.utf8.count <= 128 else { throw ArgumentsFailure.invalid }
            step = selected; policy = AppNetworkPolicy(proxyURL: proxy)
            if step != .invalidProxyCheck { try policy.validate() }
            else {
                do { try policy.validate() }
                catch is NetworkPolicyFailure { return }
                throw ArgumentsFailure.invalid
            }
        }
    }
    private struct Output: Sendable { let bytes: Data; let ok: Bool }

    /// Keep numeric progress and fixed phase tokens only. Raw bridge diagnostics
    /// are deliberately excluded from the integration receipt.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [[String: Any]] = []
        private var previousPhase: String?
        private var previousBucket = -1
        private var previousFraction = -1.0
        private var valid = true
        func record(_ fraction: Double, _ phase: String) {
            lock.lock(); defer { lock.unlock() }
            let allowed = Set(["metadata", "download", "verify", "validate", "clone", "extract", "prepare",
                               "hash", "built", "build", "health", "install"])
            guard fraction.isFinite, (0...1).contains(fraction), fraction >= previousFraction,
                  allowed.contains(phase) else { valid = false; return }
            previousFraction = fraction
            let bucket = Int(fraction * 20)
            if samples.count < 64, phase != previousPhase || bucket != previousBucket {
                samples.append(["fraction": fraction, "phase": phase]); previousPhase = phase; previousBucket = bucket
            }
        }
        func object() -> [String: Any] {
            lock.lock(); defer { lock.unlock() }
            return ["valid": valid, "samples": samples]
        }
        var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    }

    static func main() async {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            let output = await Task.detached(priority: .userInitiated) { execute(arguments) }.value
            print(String(decoding: output.bytes, as: UTF8.self))
            if !output.ok { exit(1) }
        } catch {
            let output = failureOutput(error)
            print(String(decoding: output.bytes, as: UTF8.self)); exit(1)
        }
    }

    private static func execute(_ arguments: Arguments) -> Output {
        let store = RuntimePackageStore(bundleContents: arguments.bundleContents, storageRoot: arguments.storageRoot)
        let recorder = ProgressRecorder()
        var before: RuntimePackageSnapshot?
        var after: RuntimePackageSnapshot?
        var restartedSnapshot: RuntimePackageSnapshot?
        var beforeStateHash: String?
        var afterStateHash: String?
        var selectedRuntimeHash: String?
        var release: OfficialRuntimeRelease?
        var imported: RuntimePackageInfo?
        var attempted: [String] = []
        var completed: [String] = []
        var expectedProxyRejection = false
        var operationFailure: Error?
        var readbackFailure: Error?
        do {
            before = try store.snapshot(); beforeStateHash = try persistedStateHash(arguments.storageRoot)
            guard before?.diagnostic == nil else { throw RuntimePackageFailure.integrityFailed }
            switch arguments.step {
            case .check, .install, .invalidProxyCheck:
                let controller = OwnedProcessController(); try controller.registerWork()
                defer { controller.finish() }
                let configuration = AppConfiguration(projectRoot: arguments.projectRoot.path, nodeExecutable: arguments.node.path)
                let service = StdioOfficialRuntimeUpdateService(configuration: configuration, bundleContents: arguments.bundleContents,
                    networkPolicyProvider: FixedNetworkPolicyProvider(policy: arguments.policy))
                attempted.append("official.check")
                do {
                    release = try service.check(current: before!.current, controller: controller)
                    guard arguments.step != .invalidProxyCheck else { throw ArgumentsFailure.invalid }
                } catch let failure as NetworkPolicyFailure where arguments.step == .invalidProxyCheck && failure == .invalid {
                    expectedProxyRejection = true
                } catch let failure as OfficialRuntimeUpdateFailure where arguments.step == .invalidProxyCheck && failure == .networkUnavailable {
                    expectedProxyRejection = true
                }
                completed.append(expectedProxyRejection ? "official.invalidProxyRejected" : "official.check")
                if arguments.step == .install, let release {
                    attempted.append("official.prepareAndImport")
                    imported = try service.prepareAndImport(release, store: store, controller: controller, progress: { recorder.record($0, $1) })
                    guard recorder.isValid else { throw OfficialRuntimeUpdateFailure.invalidResponse }
                    completed.append("official.prepareAndImport")
                }
            case .activate:
                attempted.append("store.activatePending"); try store.activatePending(); completed.append("store.activatePending")
            case .rollback:
                attempted.append("store.requestRollback"); try store.requestRollback(); completed.append("store.requestRollback")
                attempted.append("store.activatePending"); try store.activatePending(); completed.append("store.activatePending")
            case .cancel:
                attempted.append("store.cancelPending"); try store.cancelPending(); completed.append("store.cancelPending")
            case .status: break
            }
        } catch { operationFailure = error }

        // Read back on failure too. Separate fresh-store readback demonstrates
        // persisted selection and local trust without reopening the app catalog.
        do {
            after = try store.snapshot(); afterStateHash = try persistedStateHash(arguments.storageRoot)
            let restarted = RuntimePackageStore(bundleContents: arguments.bundleContents, storageRoot: arguments.storageRoot)
            restartedSnapshot = try restarted.snapshot()
            guard after == restartedSnapshot else { throw RuntimePackageFailure.persistenceFailed }
            guard after?.diagnostic == nil else { throw RuntimePackageFailure.integrityFailed }
            selectedRuntimeHash = RuntimePackageIO.digest(Data(try restarted.resolvedRuntimeRoot().path.utf8))
        } catch { readbackFailure = error; if operationFailure == nil { operationFailure = error } }
        do {
            var object: [String: Any] = [
                "schema": "official-runtime-integration/v1", "ok": operationFailure == nil,
                "step": arguments.step.rawValue, "real_provider": false,
                "before": try before.map(snapshotObject) ?? NSNull(), "after": try after.map(snapshotObject) ?? NSNull(),
                "beforeStateSHA256": beforeStateHash as Any? ?? NSNull(), "afterStateSHA256": afterStateHash as Any? ?? NSNull(),
                "restartEqual": after != nil && restartedSnapshot != nil && after == restartedSnapshot,
                "selectedRuntimePathSHA256": selectedRuntimeHash as Any? ?? NSNull(),
                "updateAvailable": release != nil, "release": release.map(releaseObject) ?? NSNull(),
                "imported": try imported.map(infoObject) ?? NSNull(), "expectedProxyRejection": expectedProxyRejection,
                "attemptedOperations": attempted, "completedOperations": completed, "progress": recorder.object()
            ]
            if let operationFailure { let failure = sanitizedFailure(operationFailure); object["code"] = failure.code; object["message"] = failure.message }
            if let readbackFailure { let failure = sanitizedFailure(readbackFailure); object["readbackFailure"] = ["code": failure.code, "message": failure.message] }
            return try encode(object, ok: operationFailure == nil)
        } catch { return failureOutput(error) }
    }
    private static func persistedStateHash(_ root: URL) throws -> String? {
        let file = root.appendingPathComponent("state.json")
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0 else {
            guard errno == ENOENT else { throw RuntimePackageFailure.persistenceFailed }
            return nil
        }
        return RuntimePackageIO.digest(try RuntimePackageIO.readSmall(file, limit: 16 * 1024))
    }
    private static func infoObject(_ info: RuntimePackageInfo) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(info))
    }
    private static func snapshotObject(_ snapshot: RuntimePackageSnapshot) throws -> [String: Any] {
        ["bundled": try infoObject(snapshot.bundled), "current": try infoObject(snapshot.current),
         "previous": try snapshot.previous.map(infoObject) ?? NSNull(), "pending": try snapshot.pending.map(infoObject) ?? NSNull(),
         "hasDiagnostic": snapshot.diagnostic != nil]
    }
    private static func releaseObject(_ release: OfficialRuntimeRelease) -> [String: Any] {
        ["cliVersion": release.cliVersion, "sdkVersion": release.sdkVersion, "nodeMinimum": release.nodeMinimum,
         "metadataBytes": release.metadataBytes.count, "metadataSHA256": RuntimePackageIO.digest(release.metadataBytes)]
    }
    private static func encode(_ object: [String: Any], ok: Bool) throws -> Output {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard bytes.count <= 64 * 1024 else { throw OfficialRuntimeUpdateFailure.invalidResponse }
        return Output(bytes: bytes, ok: ok)
    }
    private static func sanitizedFailure(_ error: Error) -> (code: String, message: String) {
        switch error {
        case let failure as OfficialRuntimeUpdateFailure: return (failure.code, failure.message)
        case let failure as RuntimePackageFailure: return (failure.code, failure.message)
        case let failure as NetworkPolicyFailure: return (failure.code, failure.message)
        case is CancellationError: return ("OFFICIAL_UPDATE_CANCELLED", "Official runtime update was cancelled.")
        case is ArgumentsFailure:
            return ("INTEGRATION_ARGUMENTS_INVALID", "Use explicit --bundle-contents ABS --storage-root ABS --project-root ABS --node ABS --proxy-url http://127.0.0.1:PORT --step check|install|activate|rollback|cancel|status|invalid-proxy-check.")
        default: return ("INTEGRATION_OPERATION_FAILED", "Official runtime integration failed.")
        }
    }
    private static func failureOutput(_ error: Error) -> Output {
        let failure = sanitizedFailure(error)
        do {
            return try encode(["schema": "official-runtime-integration/v1", "ok": false, "real_provider": false,
                               "code": failure.code, "message": failure.message], ok: false)
        } catch {
            return Output(bytes: Data("{\"schema\":\"official-runtime-integration/v1\",\"ok\":false,\"real_provider\":false,\"code\":\"INTEGRATION_OUTPUT_FAILED\"}".utf8), ok: false)
        }
    }
}
