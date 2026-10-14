import Darwin
import Foundation

/// Standalone driver for a task-owned online-update fixture. All filesystem
/// inputs are explicit; no saved configuration, credentials or default catalog
/// is read. The check and install steps call the production update service.
@main
struct RuntimeUpdateIntegration {
    private enum Step: String, Sendable {
        case check, install, activate, rollback, cancel, status
    }

    private struct Arguments: Sendable {
        let bundleContents: URL
        let storageRoot: URL
        let projectRoot: URL
        let node: URL
        let channelURL: URL
        let policy: AppNetworkPolicy
        let step: Step

        init(_ values: [String]) throws {
            let allowed = Set(["--bundle-contents", "--storage-root", "--project-root", "--node",
                               "--channel-url", "--proxy-url", "--step"])
            var options: [String: String] = [:]
            var index = 0
            while index < values.count {
                let name = values[index]
                guard allowed.contains(name), index + 1 < values.count,
                      options[name] == nil else { throw ArgumentsFailure.invalid }
                options[name] = values[index + 1]
                index += 2
            }
            func path(_ name: String, directory: Bool) throws -> URL {
                guard let value = options[name], value.hasPrefix("/"), value.utf8.count <= 4_096,
                      !value.contains("\0"),
                      !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                    throw ArgumentsFailure.invalid
                }
                return URL(fileURLWithPath: value, isDirectory: directory)
            }
            bundleContents = try path("--bundle-contents", directory: true)
            storageRoot = try path("--storage-root", directory: true)
            projectRoot = try path("--project-root", directory: true)
            node = try path("--node", directory: false)
            guard let rawChannel = options["--channel-url"], rawChannel.utf8.count <= 8_192,
                  let channel = URL(string: rawChannel), channel.scheme == "https",
                  channel.host?.isEmpty == false, channel.user == nil, channel.password == nil,
                  channel.query == nil, channel.fragment == nil,
                  let rawStep = options["--step"], let step = Step(rawValue: rawStep) else {
                throw ArgumentsFailure.invalid
            }
            channelURL = channel
            self.step = step
            policy = AppNetworkPolicy(proxyURL: options["--proxy-url"] ?? AppNetworkPolicy.defaultPolicy.proxyURL)
            try policy.validate()
        }
    }

    private enum ArgumentsFailure: Error { case invalid }

    private struct Output: Sendable {
        let bytes: Data
        let ok: Bool
    }

    /// Production progress callbacks may run on an importer worker. Store only
    /// bounded numeric progress and known phase tokens, never bridge output.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [[String: Any]] = []
        private var previousPhase: String?
        private var previousBucket = -1
        private var valid = true

        func record(_ fraction: Double, _ phase: String) {
            lock.lock()
            defer { lock.unlock() }
            let allowed = Set(["download", "verify", "health", "install"])
            guard fraction.isFinite, (0...1).contains(fraction), allowed.contains(phase) else {
                valid = false
                return
            }
            let bucket = Int(fraction * 20)
            if samples.count < 64, phase != previousPhase || bucket != previousBucket {
                samples.append(["fraction": fraction, "phase": phase])
                previousPhase = phase
                previousBucket = bucket
            }
        }

        func object() -> [String: Any] {
            lock.lock()
            defer { lock.unlock() }
            return ["valid": valid, "samples": samples]
        }
    }

    static func main() async {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            let output = await Task.detached(priority: .userInitiated) { execute(arguments) }.value
            print(String(decoding: output.bytes, as: UTF8.self))
            if !output.ok { exit(1) }
        } catch {
            let output = failureOutput(error)
            print(String(decoding: output.bytes, as: UTF8.self))
            exit(1)
        }
    }

    private static func execute(_ arguments: Arguments) -> Output {
        let store = RuntimePackageStore(bundleContents: arguments.bundleContents,
                                        storageRoot: arguments.storageRoot)
        let recorder = ProgressRecorder()
        var before: RuntimePackageSnapshot?
        var after: RuntimePackageSnapshot?
        var restored: RuntimePackageSnapshot?
        var selectedContents: URL?
        var release: RuntimeUpdateRelease?
        var imported: RuntimePackageInfo?
        var attempted: [String] = []
        var completed: [String] = []
        var operationFailure: Error?
        var readbackFailure: Error?

        do {
            before = try store.snapshot()
            switch arguments.step {
            case .check, .install:
                let controller = OwnedProcessController()
                try controller.registerWork()
                defer { controller.finish() }
                let configuration = AppConfiguration(projectRoot: arguments.projectRoot.path,
                                                     nodeExecutable: arguments.node.path)
                let service = StdioRuntimeUpdateService(configuration: configuration,
                                                        bundleContents: arguments.bundleContents,
                                                        networkPolicyProvider: FixedNetworkPolicyProvider(policy: arguments.policy))
                attempted.append("service.check")
                release = try service.check(feedURL: arguments.channelURL,
                                            current: before!.current, controller: controller)
                completed.append("service.check")
                if arguments.step == .install, let release {
                    attempted.append("service.prepareAndImport")
                    imported = try service.prepareAndImport(release, store: store, controller: controller,
                                                             progress: { recorder.record($0, $1) })
                    completed.append("service.prepareAndImport")
                }
            case .activate:
                attempted.append("store.activatePending")
                try store.activatePending()
                completed.append("store.activatePending")
            case .rollback:
                attempted.append("store.requestRollback")
                try store.requestRollback()
                completed.append("store.requestRollback")
                attempted.append("store.activatePending")
                try store.activatePending()
                completed.append("store.activatePending")
            case .cancel:
                attempted.append("store.cancelPending")
                try store.cancelPending()
                completed.append("store.cancelPending")
            case .status: break
            }
        } catch { operationFailure = error }

        // Read back after failures as well, so fixture tests can demonstrate
        // that rejected downloads left the durable selection unchanged.
        do {
            after = try store.snapshot()
            let restarted = RuntimePackageStore(bundleContents: arguments.bundleContents,
                                                storageRoot: arguments.storageRoot)
            restored = try restarted.snapshot()
            guard after == restored else { throw RuntimePackageFailure.persistenceFailed }
            selectedContents = try restarted.resolvedRuntimeRoot()
        } catch {
            readbackFailure = error
            if operationFailure == nil { operationFailure = error }
        }

        do {
            var object: [String: Any] = [
                "schema": "runtime-update-integration/v1", "ok": operationFailure == nil,
                "step": arguments.step.rawValue,
                "before": try before.map(snapshotObject) ?? NSNull(),
                "after": try after.map(snapshotObject) ?? NSNull(),
                "restartEqual": after != nil && restored != nil && after == restored,
                "selectedContents": selectedContents?.path as Any? ?? NSNull(),
                "updateAvailable": release != nil,
                "release": try release.map(releaseObject) ?? NSNull(),
                "imported": try imported.map(infoObject) ?? NSNull(),
                "attemptedOperations": attempted, "completedOperations": completed,
                "progress": recorder.object()
            ]
            if let operationFailure {
                let failure = sanitizedFailure(operationFailure)
                object["code"] = failure.code
                object["message"] = failure.message
            }
            if let readbackFailure {
                let failure = sanitizedFailure(readbackFailure)
                object["readbackFailure"] = ["code": failure.code, "message": failure.message]
            }
            return try encode(object, ok: operationFailure == nil)
        } catch { return failureOutput(error) }
    }

    private static func infoObject(_ info: RuntimePackageInfo) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(info))
    }

    private static func snapshotObject(_ snapshot: RuntimePackageSnapshot) throws -> [String: Any] {
        ["bundled": try infoObject(snapshot.bundled), "current": try infoObject(snapshot.current),
         "previous": try snapshot.previous.map(infoObject) ?? NSNull(),
         "pending": try snapshot.pending.map(infoObject) ?? NSNull(),
         "diagnostic": snapshot.diagnostic as Any? ?? NSNull()]
    }

    private static func releaseObject(_ release: RuntimeUpdateRelease) throws -> [String: Any] {
        ["id": release.id, "info": try infoObject(release.info),
         "totalBytes": release.totalBytes, "fileCount": release.manifest.files.count,
         "manifestBytes": release.manifestBytes.count, "signatureBytes": release.signatureBytes.count]
    }

    private static func encode(_ object: [String: Any], ok: Bool) throws -> Output {
        Output(bytes: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), ok: ok)
    }

    private static func sanitizedFailure(_ error: Error) -> (code: String, message: String) {
        switch error {
        case let failure as RuntimeUpdateFailure: return (failure.code, failure.message)
        case let failure as RuntimePackageFailure: return (failure.code, failure.message)
        case let failure as NetworkPolicyFailure: return (failure.code, failure.message)
        case is CancellationError: return ("RUNTIME_UPDATE_CANCELLED", "Local runtime update was cancelled.")
        case is ArgumentsFailure:
            return ("INTEGRATION_ARGUMENTS_INVALID",
                    "Use --bundle-contents ABS --storage-root ABS --project-root ABS --node ABS --channel-url HTTPS --step check|install|activate|rollback|cancel|status, optionally --proxy-url http://127.0.0.1:PORT.")
        default: return ("INTEGRATION_OPERATION_FAILED", "Local runtime update integration failed.")
        }
    }

    private static func failureOutput(_ error: Error) -> Output {
        let failure = sanitizedFailure(error)
        do {
            return try encode(["schema": "runtime-update-integration/v1", "ok": false,
                               "code": failure.code, "message": failure.message], ok: false)
        } catch {
            return Output(bytes: Data("{\"schema\":\"runtime-update-integration/v1\",\"ok\":false,\"code\":\"INTEGRATION_OUTPUT_FAILED\"}".utf8), ok: false)
        }
    }
}
