import Foundation

/// These mocks cover the model's admission, cancellation and idle-switch
/// orchestration. Payload verification and durable local trust are exercised by
/// the production service/store checks and standalone integration driver.
private final class OfficialVersionFixtureStore: RuntimePackageManaging, @unchecked Sendable {
    static let bundled = RuntimePackageInfo(id: "bundled", version: "0.12.3", cliVersion: "2.1.295",
                                           sdkVersion: "0.3.295", nodeVersion: "26.7.0")
    private let lock = NSLock()
    private var current = bundled
    private var previous: RuntimePackageInfo?
    private var pending: RuntimePackageInfo?
    private var activations = 0

    var activationCount: Int { lock.lock(); defer { lock.unlock() }; return activations }
    func snapshot() throws -> RuntimePackageSnapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(bundled: Self.bundled, current: current, previous: previous, pending: pending)
    }
    func importPackage(at: URL, shouldCancel: @Sendable () -> Bool,
                       progress: @Sendable (Double) -> Void) throws -> RuntimePackageInfo {
        throw RuntimePackageFailure.invalidPackage
    }
    func acceptValidatedFixture(_ release: OfficialRuntimeRelease,
                                shouldCancel: @Sendable () -> Bool) throws -> RuntimePackageInfo {
        lock.lock(); defer { lock.unlock() }
        guard !shouldCancel() else { throw OfficialRuntimeUpdateFailure.cancelled }
        guard pending == nil else { throw RuntimePackageFailure.busy }
        let info = RuntimePackageInfo(id: "local-fixture-" + release.sdkVersion,
                                     version: release.cliVersion, cliVersion: release.cliVersion,
                                     sdkVersion: release.sdkVersion, nodeVersion: "26.7.0")
        pending = info
        return info
    }
    func requestRollback() throws {
        lock.lock(); defer { lock.unlock() }
        guard pending == nil else { throw RuntimePackageFailure.busy }
        guard let previous else { throw RuntimePackageFailure.noPrevious }
        pending = previous
    }
    func activatePending() throws {
        lock.lock(); defer { lock.unlock() }
        guard let pending else { throw RuntimePackageFailure.noPending }
        previous = current; current = pending; self.pending = nil; activations += 1
    }
    func cancelPending() throws {
        lock.lock(); defer { lock.unlock() }
        guard pending != nil else { throw RuntimePackageFailure.noPending }
        pending = nil
    }
    func resolvedRuntimeRoot() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        return URL(fileURLWithPath: "/private/official-version-fixture/" + current.id + "/Contents", isDirectory: true)
    }
}

private final class OfficialVersionFixtureUpdater: OfficialRuntimeUpdating, @unchecked Sendable {
    static let release = OfficialRuntimeRelease(sdkVersion: "0.3.297", cliVersion: "2.1.296",
                                                nodeMinimum: "18.0.0", metadataBytes: Data("fixture-pair".utf8))
    private let condition = NSCondition()
    private var heldCheck = false
    private var heldInstall = false
    private var checks = 0
    private var installs = 0
    private var reachedCheck = false
    private var reachedInstall = false
    private var expired = false
    private var offered = true
    private var nextFailure: OfficialRuntimeUpdateFailure?

    var checkCount: Int { condition.lock(); defer { condition.unlock() }; return checks }
    var installCount: Int { condition.lock(); defer { condition.unlock() }; return installs }
    var checkStarted: Bool { condition.lock(); defer { condition.unlock() }; return reachedCheck }
    var installStarted: Bool { condition.lock(); defer { condition.unlock() }; return reachedInstall }
    var deadlineExpired: Bool { condition.lock(); defer { condition.unlock() }; return expired }
    func hold(check: Bool = false, install: Bool = false) {
        condition.lock(); heldCheck = check; heldInstall = install; condition.broadcast(); condition.unlock()
    }
    func offerUpdate(_ value: Bool) { condition.lock(); offered = value; condition.unlock() }
    func failNext(_ failure: OfficialRuntimeUpdateFailure) { condition.lock(); nextFailure = failure; condition.unlock() }

    private func wait(check: Bool, controller: OwnedProcessController) throws {
        condition.lock(); defer { condition.unlock() }
        if check { checks += 1; reachedCheck = true }
        else { installs += 1; reachedInstall = true }
        let deadline = Date(timeIntervalSinceNow: 3)
        while check ? heldCheck : heldInstall {
            guard !controller.isCancelled else { throw OfficialRuntimeUpdateFailure.cancelled }
            guard Date() < deadline else { expired = true; throw OfficialRuntimeUpdateFailure.timeout }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
        }
        guard !controller.isCancelled else { throw OfficialRuntimeUpdateFailure.cancelled }
        if let failure = nextFailure { nextFailure = nil; throw failure }
    }
    func check(current: RuntimePackageInfo, controller: OwnedProcessController) throws -> OfficialRuntimeRelease? {
        try wait(check: true, controller: controller)
        condition.lock(); defer { condition.unlock() }
        return offered ? Self.release : nil
    }
    func prepareAndImport(_ release: OfficialRuntimeRelease, store: any RuntimePackageManaging,
                          controller: OwnedProcessController,
                          progress: @Sendable (Double, String) -> Void) throws -> RuntimePackageInfo {
        progress(0.2, "download")
        try wait(check: false, controller: controller)
        guard let fixture = store as? OfficialVersionFixtureStore else { throw RuntimePackageFailure.invalidState }
        progress(0.9, "health")
        return try fixture.acceptValidatedFixture(release, shouldCancel: { controller.isCancelled })
    }
}

private final class OfficialVersionForbiddenConfiguration: RuntimeUpdateConfigurationPersisting {
    private(set) var loads = 0
    func load() throws -> RuntimeUpdateConfiguration { loads += 1; throw RuntimeUpdateFailure.invalidSource }
    func save(_ configuration: RuntimeUpdateConfiguration) throws { throw RuntimeUpdateFailure.persistenceFailed }
}

@MainActor
private func officialVersionAwait(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<150 {
        if predicate() { return true }
        do { try await Task.sleep(for: .milliseconds(10)) }
        catch { return false }
    }
    return false
}

@MainActor
func officialRuntimeVersionChecks() async -> [String: Bool] {
    var results: [String: Bool] = [:]
    func check(_ name: String, _ value: Bool) { results["official_runtime_model_" + name] = value }

    do {
        let store = OfficialVersionFixtureStore(), updater = OfficialVersionFixtureUpdater()
        let source = OfficialVersionForbiddenConfiguration(), registry = OwnedProcessRegistry()
        let model = RuntimeVersionViewModel(store: store, registry: registry, officialUpdater: updater,
                                           updateConfigurationStore: source)
        defer { model.beginTermination() }
        let baseline = try store.snapshot()
        check("check_available_without_custom_source", model.canCheckUpdates && model.updateSource.isEmpty && source.loads == 0)
        await model.checkForUpdates()
        check("offers_official_paired_versions", model.availableOfficialUpdate?.cliVersion == "2.1.296" &&
              model.availableOfficialUpdate?.sdkVersion == "0.3.297" && model.canInstallUpdate && model.availableUpdate == nil)
        check("check_retains_selected_runtime", try model.snapshot == baseline && store.snapshot() == baseline && registry.activeCount == 0)
        updater.offerUpdate(false); await model.checkForUpdates()
        check("current_official_version_disables_install", model.availableOfficialUpdate == nil && !model.canInstallUpdate && model.error == nil)
        model.beginTermination(); await model.checkForUpdates(); await model.installUpdate()
        check("termination_closes_update_admission", updater.checkCount == 2 && updater.installCount == 0 && !model.canCheckUpdates)
    } catch { check("source_free_fixture", false) }

    do {
        let store = OfficialVersionFixtureStore(), updater = OfficialVersionFixtureUpdater(), registry = OwnedProcessRegistry()
        let model = RuntimeVersionViewModel(store: store, registry: registry, officialUpdater: updater)
        defer { model.beginTermination() }
        let baseline = try store.snapshot()
        updater.hold(check: true)
        let task = Task { await model.checkForUpdates() }
        let reached = await officialVersionAwait { updater.checkStarted }
        check("checking_owns_cancellable_lifecycle", reached && model.isBusy && model.onlineOperation &&
              !model.isTerminationWorkSettled && registry.activeCount == 1)
        await model.checkForUpdates(); await model.installUpdate()
        check("busy_check_cannot_start_twice", updater.checkCount == 1 && updater.installCount == 0 && !model.canImport)
        model.cancelImport(); await task.value
        check("check_cancel_drains_and_retains_runtime", try model.error == OfficialRuntimeUpdateFailure.cancelled.message &&
              !model.isBusy && model.isTerminationWorkSettled && registry.activeCount == 0 &&
              model.snapshot == baseline && store.snapshot() == baseline && !updater.deadlineExpired)
        updater.hold(); await model.checkForUpdates()
        check("check_cancel_can_retry", model.canInstallUpdate && model.error == nil)
    } catch { check("check_cancellation_fixture", false) }

    do {
        let store = OfficialVersionFixtureStore(), updater = OfficialVersionFixtureUpdater(), registry = OwnedProcessRegistry()
        let model = RuntimeVersionViewModel(store: store, registry: registry, officialUpdater: updater)
        defer { model.beginTermination() }
        let baseline = try store.snapshot(), originalRoot = try store.resolvedRuntimeRoot()
        await model.checkForUpdates(); updater.hold(install: true)
        let task = Task { await model.installUpdate() }
        let reached = await officialVersionAwait { updater.installStarted && model.progress > 0 }
        check("install_owns_cancellable_lifecycle", reached && model.isBusy && model.onlineOperation && registry.activeCount == 1)
        await model.installUpdate()
        check("busy_install_cannot_start_twice", updater.installCount == 1)
        task.cancel(); await task.value
        check("task_cancellation_retains_release_for_retry", try model.error == OfficialRuntimeUpdateFailure.cancelled.message &&
              !model.isBusy && registry.activeCount == 0 && model.snapshot == baseline &&
              store.resolvedRuntimeRoot() == originalRoot && model.availableOfficialUpdate?.sdkVersion == "0.3.297" && !updater.deadlineExpired)
        updater.hold(install: true)
        let terminationTask = Task { await model.installUpdate() }
        _ = await officialVersionAwait { updater.installCount == 2 }
        model.beginTermination(); await terminationTask.value
        check("termination_cancels_install_before_settled", try !model.isBusy && model.isTerminationWorkSettled &&
              registry.activeCount == 0 && store.snapshot() == baseline && !model.canInstallUpdate)
    } catch { check("install_cancellation_fixture", false) }

    do {
        let store = OfficialVersionFixtureStore(), updater = OfficialVersionFixtureUpdater(), registry = OwnedProcessRegistry()
        var appIdle = true
        let model = RuntimeVersionViewModel(store: store, registry: registry, isApplicationIdle: { appIdle }, officialUpdater: updater)
        defer { model.beginTermination() }
        let baseline = try store.snapshot(), originalRoot = try store.resolvedRuntimeRoot()
        await model.checkForUpdates()
        for failure in [OfficialRuntimeUpdateFailure.networkUnavailable, .integrityFailed, .incompatible,
                        .buildFailed, .healthFailed, .persistenceFailed] {
            updater.failNext(failure); await model.installUpdate()
            check("failure_" + failure.code.lowercased() + "_retains_selection", try model.error == failure.message &&
                  model.snapshot == baseline && store.snapshot() == baseline && store.resolvedRuntimeRoot() == originalRoot &&
                  model.canInstallUpdate && registry.activeCount == 0)
        }
        let activeWorker = OwnedProcessController(); try activeWorker.registerWork(in: registry)
        defer { activeWorker.finish() }
        await model.installUpdate()
        let pending = model.snapshot?.pending
        check("validated_install_waits_for_active_worker", try model.error == nil && pending?.sdkVersion == "0.3.297" &&
              model.snapshot?.current == baseline.current && store.resolvedRuntimeRoot() == originalRoot && store.activationCount == 0)
        check("pending_blocks_further_update", !model.canCheckUpdates && !model.canInstallUpdate && !model.canRollback)
        appIdle = false; activeWorker.finish(); model.refresh()
        check("validated_install_also_waits_for_application_idle", model.snapshot?.pending == pending && store.activationCount == 0)
        appIdle = true; model.refresh()
        check("idle_enables_new_runtime_and_preserves_previous", try model.snapshot?.current == pending &&
              model.snapshot?.previous == baseline.current && model.snapshot?.pending == nil && store.activationCount == 1 &&
              store.resolvedRuntimeRoot() != originalRoot && model.canRollback && model.availableOfficialUpdate == nil)
        appIdle = false; model.requestRollback()
        check("rollback_waits_for_idle", model.snapshot?.current == pending && model.snapshot?.pending == baseline.current && store.activationCount == 1)
        appIdle = true; model.refresh()
        check("rollback_restores_old_selection", try model.snapshot?.current == baseline.current && model.snapshot?.previous == pending &&
              model.snapshot?.pending == nil && store.resolvedRuntimeRoot() == originalRoot && store.activationCount == 2)
    } catch { check("failure_and_idle_switch_fixture", false) }
    return results
}
