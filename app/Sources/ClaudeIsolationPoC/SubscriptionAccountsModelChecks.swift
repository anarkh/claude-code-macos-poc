import Foundation

private final class SubscriptionAccountsModelFixtureStore: SubscriptionAccountStoring {
    var catalog = SubscriptionAccountCatalog()
    var loadFailure: (any Error)?
    var saveFailure: (any Error)?
    func load() throws -> SubscriptionAccountCatalog {
        if let loadFailure { throw loadFailure }
        try catalog.validate()
        return catalog
    }
    func save(_ catalog: SubscriptionAccountCatalog) throws {
        if let saveFailure { throw saveFailure }
        try catalog.validate()
        self.catalog = catalog
    }
}

private actor SubscriptionAccountsQuotaFixture: SubscriptionQuotaFetching {
    private(set) var tokens: [String] = []
    private var pending: [Int: CheckedContinuation<SubscriptionQuotaSnapshot, Error>] = [:]
    private(set) var peakActive = 0

    func fetch(token: String) async throws -> SubscriptionQuotaSnapshot {
        let index = tokens.count
        tokens.append(token)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            peakActive = max(peakActive, pending.count)
        }
    }

    func succeed(_ index: Int, used: Double) {
        guard let continuation = pending.removeValue(forKey: index) else { preconditionFailure("Missing quota fixture request") }
        continuation.resume(returning: .init(windows: [
            .init(id: "five_hour", usedPercentage: used, resetsAt: Date(timeIntervalSince1970: 2_000_000_000)),
            .init(id: "seven_day", usedPercentage: used / 2, resetsAt: nil)
        ], queriedAt: Date(timeIntervalSince1970: 1_900_000_000)))
    }

    func fail(_ index: Int, error: any Error) {
        guard let continuation = pending.removeValue(forKey: index) else { preconditionFailure("Missing quota fixture request") }
        continuation.resume(throwing: error)
    }

    func calls() -> Int { tokens.count }
}

@MainActor
private func waitForSubscriptionQuotaCalls(_ fixture: SubscriptionAccountsQuotaFixture, _ count: Int) async -> Bool {
    for _ in 0..<2_000 {
        if await fixture.calls() >= count { return true }
        await Task.yield()
    }
    return false
}

/// Uses in-memory catalogs and a controllable service; no filesystem, model
/// requests, user credentials, App preferences or VM processes are involved.
@MainActor
func subscriptionAccountsModelChecks() async -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("subscription_accounts_model_" + name, passed)) }
    let tokenA = "sk-ant-oat01-model-fixture-account-a"
    let tokenB = "sk-ant-oat01-model-fixture-account-b"
    let tokenA2 = "sk-ant-oat01-model-fixture-account-a-updated"

    let storage = SubscriptionAccountsModelFixtureStore()
    let model = SubscriptionAccountsModel(store: storage)
    check("initial_does_not_load", !model.hasLoaded && model.accounts.isEmpty)
    do { _ = try model.currentSelection(); check("unloaded_selection_fails", false) }
    catch { check("unloaded_selection_fails", error is SubscriptionAccountSelectionFailure) }
    check("explicit_load_empty", model.load() && model.hasLoaded && model.currentAccountID == nil)
    check("first_add_selects", model.add(label: " A ", token: tokenA) && model.currentAccount?.label == "A")
    guard let idA = model.currentAccountID else { check("first_account_available", false); return results }
    check("second_add_preserves_selection", model.add(label: "B", token: tokenB) && model.currentAccountID == idA)
    guard let idB = model.accounts.first(where: { $0.label == "B" })?.id else {
        check("second_account_available", false); return results
    }
    let savedCatalog = model.catalog
    check("invalid_label_preserves_catalog", !model.rename(id: idA, label: " ") && model.catalog == savedCatalog)
    check("invalid_token_preserves_catalog", !model.updateToken(id: idA, token: "invalid") && model.catalog == savedCatalog)
    model.canMutate = { false }
    check("busy_rejects_switch", !model.select(id: idB) && model.currentAccountID == idA)
    check("busy_rejects_add_and_delete", !model.add(label: "C", token: tokenA) && !model.remove(id: idA) && model.catalog == savedCatalog)
    model.canMutate = { true }
    do {
        let frozen = try model.currentSelection()
        check("manual_select_commits", model.select(id: idB) && model.currentAccountID == idB)
        let selectedB = try model.currentSelection()
        check("selection_snapshot_stays_a", frozen.id == idA && frozen.token == tokenA && selectedB.token == tokenB)
        check("rename_keeps_credential_version", model.rename(id: idA, label: "Primary") && model.accounts.first(where: { $0.id == idA })?.credentialVersion == frozen.credentialVersion)
        check("update_rotates_credential_version", model.updateToken(id: idA, token: tokenA2) && model.accounts.first(where: { $0.id == idA })?.credentialVersion != frozen.credentialVersion)
        check("frozen_token_unmodified", frozen.token == tokenA)
    } catch { check("immutable_selection_fixture", false) }
    let reopened = SubscriptionAccountsModel(store: storage)
    check("reload_restores_selected_account", reopened.load() && reopened.currentAccountID == idB && reopened.currentAccount?.token == tokenB)
    check("remove_selected_does_not_auto_switch", model.remove(id: idB) && model.currentAccountID == nil && model.accounts.count == 1)
    do { _ = try model.currentSelection(); check("no_selection_rejected", false) }
    catch { check("no_selection_rejected", error is SubscriptionAccountSelectionFailure) }
    check("clear_credential_keeps_record", model.select(id: idA) && model.clearCredential(id: idA) && model.currentAccountID == idA && model.accounts.count == 1 && model.currentAccount?.token == nil)
    do { _ = try model.currentSelection(); check("missing_credential_rejected", false) }
    catch { check("missing_credential_rejected", error is SubscriptionAccountSelectionFailure) }
    check("restore_token", model.updateToken(id: idA, token: tokenA))
    storage.saveFailure = SubscriptionAccountStoreFailure.saveFailed
    check("save_failure_invalidates_authoritative_state", !model.rename(id: idA, label: "Not saved") && !model.hasLoaded && model.error != nil)
    storage.saveFailure = nil
    check("reload_after_failed_save_preserves_old_record", model.load() && model.currentAccount?.label == "Primary")
    storage.loadFailure = NSError(domain: "private-" + tokenA, code: 1)
    check("load_failure_does_not_expose_secret", !model.load() && !(model.error ?? "").contains(tokenA) && !model.hasLoaded)
    check("failed_load_cannot_add", !model.add(label: "C", token: tokenB))

    let accountA = SubscriptionAccount(label: "A", token: tokenA)
    let accountB = SubscriptionAccount(label: "B", token: tokenB)
    let resetModel = SubscriptionAccountsModel(store: MemorySubscriptionAccountStore(catalog: .init(currentAccountID: accountB.id, accounts: [accountA, accountB])))
    check("reset_catalog_loaded", resetModel.load())
    do {
        try resetModel.clearCurrentCredentialForReset()
        check("reset_preserves_other_accounts", resetModel.accounts.first(where: { $0.id == accountA.id }) == accountA && resetModel.currentAccount?.token == nil && resetModel.currentAccount?.label == "B" && resetModel.currentAccountID == accountB.id)
    } catch { check("reset_preserves_other_accounts", false) }
    let quotaStore = MemorySubscriptionAccountStore(catalog: .init(currentAccountID: accountA.id, accounts: [accountA, accountB]))
    let quotaFixture = SubscriptionAccountsQuotaFixture()
    let quota = SubscriptionAccountsModel(store: quotaStore, quotaService: quotaFixture)
    check("quota_catalog_loaded", quota.load())
    let first = Task { await quota.refresh(id: accountA.id) }
    check("first_query_started", await waitForSubscriptionQuotaCalls(quotaFixture, 1))
    let duplicate = Task { await quota.refresh(id: accountA.id) }
    for _ in 0..<20 { await Task.yield() }
    check("duplicate_refresh_coalesced", await quotaFixture.calls() == 1)
    check("a_b_a_switches", quota.select(id: accountB.id) && quota.select(id: accountA.id))
    await quotaFixture.succeed(0, used: 25)
    await first.value; await duplicate.value
    check("quota_result_bound_to_a", quota.quotaStates[accountA.id]?.snapshot?.windows.first?.usedPercentage == 25 && quota.quotaStates[accountB.id] == nil)
    check("page_reload_retains_matching_cached_quota", quota.load() && quota.quotaStates[accountA.id]?.snapshot?.windows.first?.usedPercentage == 25)
    check("completed_query_settled", quota.isRefreshSettled && !quota.quotaStates[accountA.id]!.isRefreshing)
    let failedRefresh = Task { await quota.refresh(id: accountA.id) }
    check("failed_refresh_started", await waitForSubscriptionQuotaCalls(quotaFixture, 2))
    await quotaFixture.fail(1, error: SubscriptionQuotaFailure(code: "QUOTA_FORBIDDEN"))
    await failedRefresh.value
    check("failure_keeps_last_value_marked_stale", quota.quotaStates[accountA.id]?.snapshot?.windows.first?.usedPercentage == 25 && quota.quotaStates[accountA.id]?.isStale == true && quota.quotaStates[accountA.id]?.lastError != nil)
    do { check("quota_failure_does_not_block_chat", try quota.currentSelection().token == tokenA) }
    catch { check("quota_failure_does_not_block_chat", false) }

    let oldCredentialQuery = Task { await quota.refresh(id: accountA.id) }
    check("old_credential_query_started", await waitForSubscriptionQuotaCalls(quotaFixture, 3))
    check("credential_change_clears_cached_quota", quota.updateToken(id: accountA.id, token: tokenA2) && quota.quotaStates[accountA.id] == nil)
    let newCredentialQuery = Task { await quota.refresh(id: accountA.id) }
    check("new_credential_query_started", await waitForSubscriptionQuotaCalls(quotaFixture, 4))
    await quotaFixture.succeed(3, used: 70)
    await newCredentialQuery.value
    check("cancelled_old_query_still_tracked_until_end", !quota.isRefreshSettled && quota.activeRefreshCount == 1)
    await quotaFixture.succeed(2, used: 11)
    await oldCredentialQuery.value
    check("late_old_credential_result_ignored", quota.quotaStates[accountA.id]?.snapshot?.windows.first?.usedPercentage == 70 && quota.isRefreshSettled)
    check("query_used_frozen_token_versions", await quotaFixture.tokens == [tokenA, tokenA, tokenA, tokenA2])

    let beforeRemoval = Task { await quota.refresh(id: accountB.id) }
    check("removed_account_query_started", await waitForSubscriptionQuotaCalls(quotaFixture, 5))
    check("delete_account_during_query", quota.remove(id: accountB.id))
    await quotaFixture.succeed(4, used: 80)
    await beforeRemoval.value
    check("removed_account_result_not_recreated", quota.quotaStates[accountB.id] == nil && quota.accounts.count == 1)
    let unknownFailure = Task { await quota.refresh(id: accountA.id) }
    check("unknown_error_query_started", await waitForSubscriptionQuotaCalls(quotaFixture, 6))
    await quotaFixture.fail(5, error: NSError(domain: "private-" + tokenA2, code: 4, userInfo: [NSLocalizedDescriptionKey: tokenA2]))
    await unknownFailure.value
    check("raw_query_error_not_exposed", quota.quotaStates[accountA.id]?.lastError != nil && !(quota.quotaStates[accountA.id]?.lastError ?? "").contains(tokenA2))

    let cancelQuery = Task { await quota.refresh(id: accountA.id) }
    check("cancel_query_started", await waitForSubscriptionQuotaCalls(quotaFixture, 7))
    quota.cancelRefreshes()
    quota.canRefresh = { false }
    await quota.refresh(id: accountA.id)
    check("lifecycle_refuses_new_query", await quotaFixture.calls() == 7)
    do { try quota.clearCurrentCredentialForReset(); check("reset_waits_for_query_end", false) }
    catch { check("reset_waits_for_query_end", error is LoginResetLifecycleFailure) }
    await quotaFixture.succeed(6, used: 0)
    await cancelQuery.value
    check("cancelled_success_not_applied", quota.quotaStates[accountA.id]?.snapshot?.windows.first?.usedPercentage == 70 && quota.isRefreshSettled)
    quota.canMutate = { false }
    do {
        try quota.clearCurrentCredentialForReset()
        check("reset_can_clear_after_normal_gate_closes", quota.currentAccount?.token == nil && quota.currentAccountID == accountA.id)
    } catch { check("reset_can_clear_after_normal_gate_closes", false) }
    quota.canRefresh = { true }
    await quota.refresh(id: accountA.id)
    check("missing_token_not_queried", await quotaFixture.calls() == 7 && quota.quotaStates[accountA.id]?.lastError != nil)

    let batchFixture = SubscriptionAccountsQuotaFixture()
    let accountC = SubscriptionAccount(label: "C", token: "sk-ant-oat01-model-fixture-account-c")
    let batch = SubscriptionAccountsModel(store: MemorySubscriptionAccountStore(catalog: .init(currentAccountID: accountA.id, accounts: [accountA, accountB, accountC])), quotaService: batchFixture)
    check("batch_catalog_loaded", batch.load())
    let batchTask = Task { await batch.refreshAll() }
    check("batch_first_two_started", await waitForSubscriptionQuotaCalls(batchFixture, 2))
    check("batch_only_two_parallel", await batchFixture.calls() == 2)
    await batchFixture.succeed(0, used: 15)
    await batchFixture.succeed(1, used: 20)
    check("batch_third_started", await waitForSubscriptionQuotaCalls(batchFixture, 3))
    await batchFixture.succeed(2, used: 30)
    await batchTask.value
    check("batch_parallelism_bounded", await batchFixture.peakActive <= 2 && batch.isRefreshSettled && batch.quotaStates.count == 3)

    let cancelledBatchFixture = SubscriptionAccountsQuotaFixture()
    let cancelledBatch = SubscriptionAccountsModel(store: MemorySubscriptionAccountStore(catalog: .init(currentAccountID: accountA.id, accounts: [accountA, accountB, accountC])), quotaService: cancelledBatchFixture)
    check("cancelled_batch_catalog_loaded", cancelledBatch.load())
    let cancelledBatchTask = Task { await cancelledBatch.refreshAll() }
    check("cancelled_batch_first_two_started", await waitForSubscriptionQuotaCalls(cancelledBatchFixture, 2))
    cancelledBatch.cancelRefreshes()
    await cancelledBatchFixture.succeed(0, used: 10)
    await cancelledBatchFixture.succeed(1, used: 20)
    await cancelledBatchTask.value
    check("cancelled_batch_does_not_start_later_accounts", await cancelledBatchFixture.calls() == 2 && cancelledBatch.isRefreshSettled)
    check("cancelled_batch_does_not_publish_late_results", cancelledBatch.quotaStates.values.allSatisfy { !$0.isRefreshing && $0.snapshot == nil })
    let restartedBatchTask = Task { await cancelledBatch.refreshAll() }
    check("explicit_batch_after_cancel_starts", await waitForSubscriptionQuotaCalls(cancelledBatchFixture, 4))
    await cancelledBatchFixture.succeed(2, used: 15)
    await cancelledBatchFixture.succeed(3, used: 25)
    check("explicit_batch_after_cancel_reaches_later_accounts", await waitForSubscriptionQuotaCalls(cancelledBatchFixture, 5))
    await cancelledBatchFixture.succeed(4, used: 35)
    await restartedBatchTask.value
    check("explicit_batch_after_cancel_completes", cancelledBatch.isRefreshSettled && cancelledBatch.quotaStates.values.allSatisfy { $0.snapshot != nil && !$0.isRefreshing })
    return results
}
