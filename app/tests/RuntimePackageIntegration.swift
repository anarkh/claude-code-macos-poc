import Foundation

/// Standalone catalog driver for a task-owned integration directory. Compile
/// with RuntimePackageCore.swift and RuntimePackageStore.swift only. It never
/// launches package artifacts, reads credentials or uses the default catalog.
@main
struct RuntimePackageIntegration {
    private struct Arguments {
        let bundleContents: URL
        let storageRoot: URL
        let step: String
        let package: URL?

        init(_ values: [String]) throws {
            let allowed = Set(["--bundle-contents", "--storage-root", "--step", "--package"])
            var options: [String: String] = [:]
            var index = 0
            while index < values.count {
                let name = values[index]
                guard allowed.contains(name), index + 1 < values.count, options[name] == nil else {
                    throw ArgumentsFailure.invalid
                }
                options[name] = values[index + 1]
                index += 2
            }
            guard let bundle = options["--bundle-contents"], bundle.hasPrefix("/"),
                  let storage = options["--storage-root"], storage.hasPrefix("/"),
                  let step = options["--step"],
                  Set(["import", "activate", "status", "rollback-request", "rollback", "cancel"]).contains(step),
                  step == "import" ? options["--package"]?.hasPrefix("/") == true : options["--package"] == nil else {
                throw ArgumentsFailure.invalid
            }
            bundleContents = URL(fileURLWithPath: bundle, isDirectory: true)
            storageRoot = URL(fileURLWithPath: storage, isDirectory: true)
            self.step = step
            package = options["--package"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
    }

    private enum ArgumentsFailure: Error {
        case invalid
    }

    static func main() {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            let store = RuntimePackageStore(bundleContents: arguments.bundleContents, storageRoot: arguments.storageRoot)
            let before = try store.snapshot()
            switch arguments.step {
            case "import":
                guard let package = arguments.package else { throw ArgumentsFailure.invalid }
                _ = try store.importPackage(at: package, shouldCancel: { false }, progress: { _ in })
            case "activate": try store.activatePending()
            case "rollback-request": try store.requestRollback()
            case "rollback": try store.requestRollback(); try store.activatePending()
            case "cancel": try store.cancelPending()
            case "status": break
            default: throw ArgumentsFailure.invalid
            }
            let snapshot = try store.snapshot()
            // A newly constructed store proves each invocation reads durable
            // state. Runtime execution is deliberately left to the VM runner.
            let restarted = RuntimePackageStore(bundleContents: arguments.bundleContents, storageRoot: arguments.storageRoot)
            let restored = try restarted.snapshot()
            guard restored == snapshot else { throw RuntimePackageFailure.persistenceFailed }
            let root = try restarted.resolvedRuntimeRoot()
            let result: [String: Any] = ["schema": "runtime-package-integration/v1", "ok": true,
                                         "step": arguments.step, "before": try snapshotObject(before),
                                         "after": try snapshotObject(snapshot), "restartEqual": true,
                                         "selectedContents": root.path,
                                         "packageArtifactsExecuted": false,
                                         "imageHashedByImporter": arguments.step == "import"]
            try emit(result)
        } catch let failure as RuntimePackageFailure {
            fail(code: failure.code, message: failure.message)
        } catch is ArgumentsFailure {
            fail(code: "INTEGRATION_ARGUMENTS_INVALID",
                 message: "Use --bundle-contents ABSOLUTE_PHYSICAL_PATH --storage-root TASK_OWNED_ABSOLUTE_PHYSICAL_PATH --step import|activate|status|rollback-request|rollback|cancel, with --package ABSOLUTE_PHYSICAL_PATH for import only.")
        } catch {
            fail(code: "INTEGRATION_OPERATION_FAILED", message: error.localizedDescription)
        }
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

    private static func emit(_ value: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: bytes, as: UTF8.self))
    }

    private static func fail(code: String, message: String) -> Never {
        do { try emit(["schema": "runtime-package-integration/v1", "ok": false, "code": code, "message": message]) }
        catch { print("{\"schema\":\"runtime-package-integration/v1\",\"ok\":false,\"code\":\"INTEGRATION_OUTPUT_FAILED\"}") }
        exit(1)
    }
}
