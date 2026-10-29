import Foundation
import SwiftUI

struct SubscriptionAccountSelection: Equatable, Sendable {
    let id: UUID
    let label: String
    let credentialVersion: UUID
    let token: String
}

enum SubscriptionAccountSelectionFailure: Error, LocalizedError, Sendable {
    case unavailable, missingAccount, missingCredential

    var message: String {
        switch self {
        case .unavailable: "账号记录尚未载入或读取失败，请在设置中重新读取账号。"
        case .missingAccount: "请在设置中添加并选择一个 Claude 订阅账号。"
        case .missingCredential: "当前账号尚未保存订阅 Token，请在账号设置中更新授权。"
        }
    }
    var errorDescription: String? { message }
}

struct SubscriptionAccountQuotaState: Equatable, Sendable {
    var snapshot: SubscriptionQuotaSnapshot?
    var isRefreshing = false
    var lastError: String?
    var isStale = false
}

/// The selected account is read once at the request boundary. Quota results are
/// bound to their account and credential version, never to the current UI row.
@MainActor
final class SubscriptionAccountsModel: ObservableObject {
    @Published private(set) var catalog: SubscriptionAccountCatalog?
    @Published private(set) var quotaStates: [UUID: SubscriptionAccountQuotaState] = [:]
    @Published private(set) var error: String?
    @Published private(set) var status: String?
    @Published private(set) var activeRefreshCount = 0

    var canMutate: () -> Bool = { true }
    var canRefresh: () -> Bool = { true }

    private let store: any SubscriptionAccountStoring
    private let quotaService: (any SubscriptionQuotaFetching)?
    private struct Refresh {
        let accountID: UUID
        let credentialVersion: UUID
        let task: Task<SubscriptionQuotaSnapshot, Error>
    }
    private var refreshes: [UUID: Refresh] = [:]
    private var activeGenerations: [UUID: UUID] = [:]
    private var batchGeneration = UUID()

    init(store: any SubscriptionAccountStoring, quotaService: (any SubscriptionQuotaFetching)? = nil) {
        self.store = store
        self.quotaService = quotaService
    }

    var accounts: [SubscriptionAccount] { catalog?.accounts ?? [] }
    var currentAccountID: UUID? { catalog?.currentAccountID }
    var currentAccount: SubscriptionAccount? { accounts.first { $0.id == currentAccountID } }
    var hasLoaded: Bool { catalog != nil }
    var isRefreshSettled: Bool { refreshes.isEmpty }

    @discardableResult
    func load() -> Bool {
        do {
            let loaded = try store.load()
            accept(loaded)
            error = nil
            return true
        } catch {
            invalidateCatalog()
            self.error = safeStoreError(error)
            return false
        }
    }

    func currentSelection() throws -> SubscriptionAccountSelection {
        guard catalog != nil else { throw SubscriptionAccountSelectionFailure.unavailable }
        guard let account = currentAccount else { throw SubscriptionAccountSelectionFailure.missingAccount }
        guard let token = account.token else { throw SubscriptionAccountSelectionFailure.missingCredential }
        return .init(id: account.id, label: account.label, credentialVersion: account.credentialVersion, token: token)
    }

    @discardableResult
    func add(label: String, token: String) -> Bool {
        mutate(status: "账号已添加。") { catalog in
            let account = SubscriptionAccount(label: label.trimmingCharacters(in: .whitespacesAndNewlines), token: token)
            let firstAccount = catalog.accounts.isEmpty
            catalog.accounts.append(account)
            if firstAccount { catalog.currentAccountID = account.id }
        }
    }

    @discardableResult
    func rename(id: UUID, label: String) -> Bool {
        mutate(status: "账号名称已保存。") { catalog in
            guard let index = catalog.accounts.firstIndex(where: { $0.id == id }) else {
                throw SubscriptionAccountSelectionFailure.missingAccount
            }
            catalog.accounts[index].label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @discardableResult
    func updateToken(id: UUID, token: String) -> Bool {
        mutate(status: "此账号的订阅 Token 已更新。") { catalog in
            guard let index = catalog.accounts.firstIndex(where: { $0.id == id }) else {
                throw SubscriptionAccountSelectionFailure.missingAccount
            }
            catalog.accounts[index].token = token
            catalog.accounts[index].credentialVersion = UUID()
        }
    }

    @discardableResult
    func select(id: UUID) -> Bool {
        mutate(status: "当前账号已切换；下一次发送使用此账号。") { catalog in
            guard catalog.accounts.contains(where: { $0.id == id }) else {
                throw SubscriptionAccountSelectionFailure.missingAccount
            }
            catalog.currentAccountID = id
        }
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        mutate(status: "此账号已从本机移除。") { catalog in
            guard catalog.accounts.contains(where: { $0.id == id }) else {
                throw SubscriptionAccountSelectionFailure.missingAccount
            }
            catalog.accounts.removeAll { $0.id == id }
            if catalog.currentAccountID == id { catalog.currentAccountID = nil }
        }
    }

    @discardableResult
    func clearCredential(id: UUID) -> Bool {
        mutate(status: "此账号的本机授权已清除。") { catalog in
            try Self.clearCredential(id: id, catalog: &catalog)
        }
    }

    /// The caller has already stopped requests and entered the login-reset
    /// lifecycle. This operation intentionally bypasses the regular UI gate.
    func clearCurrentCredentialForReset() throws {
        guard var candidate = catalog else { throw SubscriptionAccountSelectionFailure.unavailable }
        guard isRefreshSettled else { throw LoginResetLifecycleFailure.workStillRunning }
        guard let id = candidate.currentAccountID else { return }
        try Self.clearCredential(id: id, catalog: &candidate)
        do {
            try commit(candidate)
            status = "当前账号的本机授权已清除，其他账号已保留。"
            error = nil
        } catch {
            invalidateCatalog()
            self.error = safeStoreError(error)
            throw error
        }
    }

    func refreshAll() async {
        let generation = batchGeneration
        let ids = accounts.filter { $0.token != nil }.map(\.id)
        // A page can contain many accounts. Bound concurrent requests rather
        // than issuing the entire catalog to the service at once.
        for start in stride(from: 0, to: ids.count, by: 2) {
            guard !Task.isCancelled, generation == batchGeneration, canRefresh() else { break }
            await withTaskGroup(of: Void.self) { group in
                for id in ids[start..<min(start + 2, ids.count)] {
                    group.addTask { await self.performRefresh(id: id, batch: generation) }
                }
            }
        }
    }

    func refresh(id: UUID) async {
        await performRefresh(id: id, batch: nil)
    }

    private func performRefresh(id: UUID, batch: UUID?) async {
        // A queued child may not begin until after the page cancels its batch.
        guard batch == nil || batch == batchGeneration else { return }
        guard canRefresh() else {
            setQuotaError(id: id, message: "正在退出或清理登录，请等待完成后刷新额度。")
            return
        }
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        guard let token = account.token else {
            setQuotaError(id: id, message: SubscriptionAccountSelectionFailure.missingCredential.message)
            return
        }
        guard let quotaService else {
            setQuotaError(id: id, message: "额度查询服务不可用，请检查 App 安装后重试。")
            return
        }
        if let generation = activeGenerations[id], let refresh = refreshes[generation],
           refresh.credentialVersion == account.credentialVersion {
            _ = await refresh.task.result
            return
        }
        guard !Task.isCancelled else { return }
        let generation = UUID()
        let task = Task {
            try Task.checkCancellation()
            let snapshot = try await quotaService.fetch(token: token)
            try Task.checkCancellation()
            return snapshot
        }
        refreshes[generation] = Refresh(accountID: id, credentialVersion: account.credentialVersion, task: task)
        activeGenerations[id] = generation
        activeRefreshCount = refreshes.count
        var state = quotaStates[id] ?? .init()
        state.isRefreshing = true
        quotaStates[id] = state

        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        refreshes.removeValue(forKey: generation)
        activeRefreshCount = refreshes.count
        guard activeGenerations[id] == generation else { return }
        activeGenerations.removeValue(forKey: id)
        guard let current = accounts.first(where: { $0.id == id }),
              current.credentialVersion == account.credentialVersion else { return }
        var updated = quotaStates[id] ?? .init()
        updated.isRefreshing = false
        switch result {
        case .success(let snapshot):
            updated.snapshot = snapshot
            updated.lastError = nil
            updated.isStale = false
        case .failure(let failure):
            updated.lastError = failure is CancellationError ? "额度刷新已取消。"
                : (failure as? SubscriptionQuotaFailure)?.message ?? "额度查询失败，请稍后重试。"
            updated.isStale = updated.snapshot != nil
        }
        quotaStates[id] = updated
    }

    func cancelRefreshes() {
        // Manual refresh callers can outlive the settings view. Invalidate their
        // remaining batches as well as cancelling requests already in flight.
        batchGeneration = UUID()
        for refresh in refreshes.values { refresh.task.cancel() }
        activeGenerations.removeAll()
        for id in quotaStates.keys {
            quotaStates[id]?.isRefreshing = false
        }
        // Keep cancelled tasks tracked until their process has actually ended.
        activeRefreshCount = refreshes.count
    }

    private func mutate(status: String, change: (inout SubscriptionAccountCatalog) throws -> Void) -> Bool {
        guard canMutate() else {
            error = "正在执行请求或维护任务，请等待完成后管理账号。"
            return false
        }
        guard var candidate = catalog else {
            error = SubscriptionAccountSelectionFailure.unavailable.message
            return false
        }
        do {
            try change(&candidate)
            try candidate.validate()
        } catch {
            self.error = safeStoreError(error)
            return false
        }
        do {
            try commit(candidate)
            self.status = status
            error = nil
            return true
        } catch {
            // A failed readback can follow a successful write. Neither the old
            // nor candidate credentials are safe to present as authoritative.
            invalidateCatalog()
            self.error = safeStoreError(error)
            return false
        }
    }

    private func commit(_ candidate: SubscriptionAccountCatalog) throws {
        try store.save(candidate)
        let persisted = try store.load()
        guard persisted == candidate else { throw SubscriptionAccountStoreFailure.saveFailed }
        accept(persisted)
    }

    private func accept(_ loaded: SubscriptionAccountCatalog) {
        let oldVersions = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.credentialVersion) })
        let versions = Dictionary(uniqueKeysWithValues: loaded.accounts.map { ($0.id, $0.credentialVersion) })
        for (generation, refresh) in refreshes where versions[refresh.accountID] != refresh.credentialVersion {
            refresh.task.cancel()
            if activeGenerations[refresh.accountID] == generation { activeGenerations.removeValue(forKey: refresh.accountID) }
        }
        quotaStates = quotaStates.filter { versions[$0.key] != nil && versions[$0.key] == oldVersions[$0.key] }
        catalog = loaded
    }

    private func invalidateCatalog() {
        cancelRefreshes()
        catalog = nil
        quotaStates = [:]
        status = nil
    }

    private func setQuotaError(id: UUID, message: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        var state = quotaStates[id] ?? .init()
        state.lastError = message
        state.isStale = state.snapshot != nil
        quotaStates[id] = state
    }

    private static func clearCredential(id: UUID, catalog: inout SubscriptionAccountCatalog) throws {
        guard let index = catalog.accounts.firstIndex(where: { $0.id == id }) else {
            throw SubscriptionAccountSelectionFailure.missingAccount
        }
        catalog.accounts[index].token = nil
        catalog.accounts[index].credentialVersion = UUID()
    }

    private func safeStoreError(_ error: any Error) -> String {
        (error as? SubscriptionAccountStoreFailure)?.message
            ?? (error as? SubscriptionAccountSelectionFailure)?.message
            ?? (error as? LocalCredentialFailure)?.subscriptionMessage
            ?? "未能读取或保存账号，请检查本机数据目录后重新读取。"
    }
}
