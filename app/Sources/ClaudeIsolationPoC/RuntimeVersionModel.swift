import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum RuntimePackageEnvironment {
    static let store = RuntimePackageStore(
        bundleContents: Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true),
        storageRoot: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeIsolationPoC/RuntimePackages", isDirectory: true))
}

@MainActor
final class RuntimeVersionViewModel: ObservableObject {
    @Published private(set) var snapshot: RuntimePackageSnapshot?
    @Published private(set) var status = "正在读取运行版本…"
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var progress = 0.0
    @Published var updateSource = ""
    @Published private(set) var updateStatus = "官方更新组件尚未就绪，可先导入本地运行包。"
    @Published private(set) var availableUpdate: RuntimeUpdateRelease?
    @Published private(set) var availableOfficialUpdate: OfficialRuntimeRelease?
    @Published private(set) var onlineOperation = false
    private let store: any RuntimePackageManaging
    private let updater: (any RuntimeUpdating)?
    private let officialUpdater: (any OfficialRuntimeUpdating)?
    private let updateConfigurationStore: (any RuntimeUpdateConfigurationPersisting)?
    private var savedUpdateConfiguration = RuntimeUpdateConfiguration(channelURL: "")
    private let registry: OwnedProcessRegistry
    private let isApplicationIdle: @MainActor () -> Bool
    private var pendingTask: Task<Void, Never>?
    private var importController: OwnedProcessController?
    private var terminating = false

    init(store: any RuntimePackageManaging, registry: OwnedProcessRegistry = .shared,
         isApplicationIdle: @escaping @MainActor () -> Bool = { true },
         updater: (any RuntimeUpdating)? = nil,
         officialUpdater: (any OfficialRuntimeUpdating)? = nil,
         updateConfigurationStore: (any RuntimeUpdateConfigurationPersisting)? = nil) {
        self.store = store; self.registry = registry; self.isApplicationIdle = isApplicationIdle
        self.updater = updater; self.updateConfigurationStore = updateConfigurationStore
        self.officialUpdater = officialUpdater
        refresh()
        if officialUpdater != nil {
            updateStatus = "从 Anthropic 官方获取配套 CLI / SDK，在本机生成隔离运行包，无需配置更新源。"
            return
        }
        do {
            if let updateConfigurationStore {
                savedUpdateConfiguration = try updateConfigurationStore.load()
                updateSource = savedUpdateConfiguration.channelURL
                if savedUpdateConfiguration.feedURL != nil { updateStatus = "更新源已配置，点击检查更新。" }
            }
        } catch { report(error); updateStatus = "更新源读取失败，请重新配置并保存。" }
    }

    var isTerminationWorkSettled: Bool { !isBusy }
    var canImport: Bool { !terminating && !isBusy && snapshot?.pending == nil }
    var canRollback: Bool { !terminating && !isBusy && snapshot?.previous != nil && snapshot?.pending == nil }
    var canCheckUpdates: Bool {
        canImport && (officialUpdater != nil || (updater != nil && savedUpdateConfiguration.feedURL != nil))
    }
    var canInstallUpdate: Bool {
        if officialUpdater != nil {
            guard canCheckUpdates, let release = availableOfficialUpdate, let current = snapshot?.current,
                  RuntimePackageIO.isVersion(current.cliVersion), RuntimePackageIO.isVersion(current.sdkVersion) else { return false }
            return RuntimePackageIO.compareVersion(release.cliVersion, current.cliVersion) > 0 ||
                (release.cliVersion == current.cliVersion && RuntimePackageIO.compareVersion(release.sdkVersion, current.sdkVersion) > 0)
        }
        guard canCheckUpdates, let release = availableUpdate, let current = snapshot?.current,
              RuntimePackageIO.isVersion(current.version) else { return false }
        return RuntimePackageIO.compareVersion(release.info.version, current.version) > 0
    }

    func saveUpdateSource() {
        guard !isBusy, !terminating, let updateConfigurationStore else { return }
        do {
            let configuration = RuntimeUpdateConfiguration(channelURL: updateSource)
            try configuration.validate()
            try updateConfigurationStore.save(configuration)
            savedUpdateConfiguration = configuration; availableUpdate = nil; error = nil
            updateStatus = configuration.feedURL == nil ? "当前未提供默认更新服务，可先导入本地运行包。" : "更新源已保存，点击检查更新。"
        } catch { report(error) }
    }

    func checkForUpdates() async {
        if let officialUpdater { await checkOfficialUpdates(using: officialUpdater); return }
        guard canCheckUpdates, let updater, let url = savedUpdateConfiguration.feedURL,
              let current = snapshot?.current else { return }
        guard RuntimePackageIO.isVersion(current.version) else { report(RuntimePackageFailure.integrityFailed); return }
        let controller = OwnedProcessController()
        do { try controller.registerWork(in: registry) }
        catch { report(error); return }
        importController = controller; isBusy = true; onlineOperation = true; error = nil; progress = 0
        availableUpdate = nil; updateStatus = "正在检查更新…"
        defer { controller.finish(); importController = nil; isBusy = false; onlineOperation = false }
        await withTaskCancellationHandler {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try updater.check(feedURL: url, current: current, controller: controller) }
            }.value
            switch result {
            case .success(let release):
                availableUpdate = release
                updateStatus = release == nil ? "此更新源没有比当前版本更新的兼容运行包。" : "发现新版本，签名与兼容性校验已通过。"
            case .failure(let failure): report(failure); updateStatus = "检查更新未完成，当前版本保持不变。"
            }
        } onCancel: { controller.cancel() }
    }

    func installUpdate() async {
        if let officialUpdater { await installOfficialUpdate(using: officialUpdater); return }
        guard canInstallUpdate, let updater, let release = availableUpdate else { return }
        let controller = OwnedProcessController()
        do { try controller.registerWork(in: registry) }
        catch { report(error); return }
        importController = controller; isBusy = true; onlineOperation = true; error = nil; progress = 0
        updateStatus = "正在下载更新…"
        let store = self.store
        defer {
            controller.finish(); importController = nil; isBusy = false; onlineOperation = false
            if !terminating { refreshPreservingError() }
        }
        await withTaskCancellationHandler {
            let result = await Task.detached(priority: .userInitiated) { [self] in
                Result {
                    try updater.prepareAndImport(release, store: store, controller: controller, progress: { value, phase in
                        Task { @MainActor [self] in
                            guard self.importController === controller, self.isBusy else { return }
                            self.progress = min(1, max(0, value))
                            switch phase {
                            case "download": self.updateStatus = "正在下载更新…"
                            case "verify": self.updateStatus = "正在验证运行包完整性…"
                            case "health": self.updateStatus = "正在检查 VM 与 Claude Code 启动，首次可能需要约一分钟…"
                            case "install": self.updateStatus = "正在保存已验证的更新…"
                            default: self.updateStatus = "正在准备更新…"
                            }
                        }
                    })
                }
            }.value
            switch result {
            case .success: progress = 1; availableUpdate = nil; updateStatus = "下载与启动检查通过。"
            case .failure(let failure): report(failure); updateStatus = "更新未完成，已保留当前版本，可重试。"
            }
        } onCancel: { controller.cancel() }
    }

    private func checkOfficialUpdates(using updater: any OfficialRuntimeUpdating) async {
        guard canCheckUpdates, let current = snapshot?.current else { return }
        guard RuntimePackageIO.isVersion(current.cliVersion), RuntimePackageIO.isVersion(current.sdkVersion) else {
            report(RuntimePackageFailure.integrityFailed); return
        }
        let controller = OwnedProcessController()
        do { try controller.registerWork(in: registry) }
        catch { report(error); return }
        importController = controller; isBusy = true; onlineOperation = true; error = nil; progress = 0
        availableOfficialUpdate = nil; updateStatus = "正在检查官方配套版本…"
        defer { controller.finish(); importController = nil; isBusy = false; onlineOperation = false }
        await withTaskCancellationHandler {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try updater.check(current: current, controller: controller) }
            }.value
            switch result {
            case .success(let release):
                availableOfficialUpdate = release
                updateStatus = release == nil ? "当前官方配套版本已是最新版本。" : "发现官方配套版本，下载后将进行本机封装与兼容性检查。"
            case .failure(let failure): report(failure); updateStatus = "官方更新检查未完成，当前版本保持不变。"
            }
        } onCancel: { controller.cancel() }
    }

    private func installOfficialUpdate(using updater: any OfficialRuntimeUpdating) async {
        guard canInstallUpdate, let release = availableOfficialUpdate else { return }
        let controller = OwnedProcessController()
        do { try controller.registerWork(in: registry) }
        catch { report(error); return }
        importController = controller; isBusy = true; onlineOperation = true; error = nil; progress = 0
        updateStatus = "正在下载官方 CLI / SDK…"
        let store = self.store
        defer {
            controller.finish(); importController = nil; isBusy = false; onlineOperation = false
            if !terminating { refreshPreservingError() }
        }
        await withTaskCancellationHandler {
            let result = await Task.detached(priority: .userInitiated) { [self] in
                Result {
                    try updater.prepareAndImport(release, store: store, controller: controller, progress: { value, phase in
                        Task { @MainActor [self] in
                            guard self.importController === controller, self.isBusy else { return }
                            self.progress = min(1, max(0, value))
                            switch phase {
                            case "download": self.updateStatus = "正在下载官方 CLI / SDK…"
                            case "verify", "validate": self.updateStatus = "正在验证官方签名与文件完整性…"
                            case "clone", "extract", "prepare", "build", "built": self.updateStatus = "正在本机离线生成隔离运行包…"
                            case "hash": self.updateStatus = "正在验证生成的隔离运行包…"
                            case "health": self.updateStatus = "正在检查 DeepSeek、Sonnet、Opus、Haiku 与 VM 启动兼容性…"
                            case "install": self.updateStatus = "正在保存已验证的运行包…"
                            default: self.updateStatus = "正在准备官方更新…"
                            }
                        }
                    })
                }
            }.value
            switch result {
            case .success: progress = 1; availableOfficialUpdate = nil; updateStatus = "官方运行包已在本机生成，兼容性检查通过。"
            case .failure(let failure): report(failure); updateStatus = "官方更新未完成，已保留当前版本，可重试。"
            }
        } onCancel: { controller.cancel() }
    }

    private func refreshPreservingError() {
        let previousError = error
        if previousError == nil { refresh() }
        else {
            do { snapshot = try store.snapshot() }
            catch { report(error) }
        }
    }

    func refresh() {
        guard !isBusy else { return }
        error = nil
        do {
            snapshot = try store.snapshot()
            status = snapshot?.pending == nil ? "当前运行版本已就绪" : "运行包已验证，等待当前任务结束后启用"
            if snapshot?.diagnostic != nil { status = "部分版本信息未通过校验，可重新导入或回退" }
            applyPendingIfIdle()
        } catch { report(error) }
    }

    func choosePackage() {
        guard canImport else { return }
        let panel = NSOpenPanel()
        panel.title = "导入 Claude Code 运行包"
        panel.message = "选择由本 App 信任的发布密钥签名的 .clauderuntime 运行包。"
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.init(importedAs: "com.claude-isolation.runtime-package")]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.importPackage(at: url) }
        }
    }

    func importPackage(at url: URL) async {
        guard canImport else { return }
        let controller = OwnedProcessController()
        do { try controller.registerWork(in: registry) }
        catch { report(error); return }
        importController = controller; isBusy = true; progress = 0; error = nil
        status = "正在校验并复制运行包…"
        let store = self.store
        let securityScope = url.startAccessingSecurityScopedResource()
        defer {
            if securityScope { url.stopAccessingSecurityScopedResource() }
            importController = nil; isBusy = false
            if !terminating && error == nil { refresh() }
        }
        await withTaskCancellationHandler {
            let result = await Task.detached(priority: .userInitiated) { [self] in
                defer { controller.finish() }
                return Result {
                    try store.importPackage(at: url, shouldCancel: { controller.isCancelled }, progress: { value in
                        Task { @MainActor [self] in
                            guard self.importController === controller, self.isBusy else { return }
                            self.progress = min(1, max(0, value))
                        }
                    })
                }
            }.value
            switch result {
            case .success: progress = 1; status = "运行包已验证，等待启用"
            case .failure(let failure): report(failure)
            }
        } onCancel: { controller.cancel() }
    }

    func requestRollback() {
        guard canRollback else { return }
        do { try store.requestRollback(); refresh() }
        catch { report(error) }
    }

    func cancelPending() {
        guard !isBusy, !terminating else { return }
        do { try store.cancelPending(); pendingTask?.cancel(); pendingTask = nil; refresh() }
        catch { report(error) }
    }

    func cancelImport() { importController?.cancel() }

    func beginTermination() {
        terminating = true; pendingTask?.cancel(); pendingTask = nil; importController?.cancel()
    }

    func endTermination() { terminating = false; refresh() }

    private func applyPendingIfIdle() {
        guard !terminating, !isBusy, snapshot?.pending != nil else { return }
        do {
            if isApplicationIdle(), try registry.performRuntimeSwitchWhenIdle({ try store.activatePending() }) {
                snapshot = try store.snapshot(); status = "已切换运行版本，下一次任务使用新版本"
                pendingTask?.cancel(); pendingTask = nil
            } else { schedulePendingCheck() }
        } catch { pendingTask?.cancel(); pendingTask = nil; report(error) }
    }

    private func schedulePendingCheck() {
        guard pendingTask == nil else { return }
        pendingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
                guard let self, !self.terminating else { return }
                self.applyPendingIfIdle()
                if self.snapshot?.pending == nil || self.error != nil { return }
            }
        }
    }

    private func report(_ failure: Error) {
        if let failure = failure as? RuntimePackageFailure { error = failure.localizedDescription }
        else if let failure = failure as? RuntimeUpdateFailure { error = failure.localizedDescription; return }
        else if let failure = failure as? OfficialRuntimeUpdateFailure { error = failure.localizedDescription; status = "官方更新未完成"; return }
        else if let failure = failure as? ApplicationTerminationFailure { error = failure.localizedDescription }
        else if let failure = failure as? LoginResetLifecycleFailure { error = failure.localizedDescription }
        else if failure is CancellationError { error = "已取消运行包导入，当前版本保持不变。" }
        else { error = "运行包操作未完成，请检查文件完整性和本机可用空间后重试。" }
        status = "运行包操作未完成"
    }
}

