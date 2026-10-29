import CryptoKit
import Foundation

/// Exercises the App's account wiring with synthetic credentials and held
/// operations. No CLI, VM, credential file, Keychain, or network is accessed.
@MainActor
func subscriptionAccountsIntegrationChecks() async -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) {
        results.append(("subscription_accounts_integration_" + name, passed))
    }
    let suite = "subscription-accounts-integration-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        return [("subscription_accounts_integration_isolated_preferences", false)]
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    let tokenA = "sk-ant-oat01-integration-fixture-account-a"
    let tokenB = "sk-ant-oat01-integration-fixture-account-b"
    let accountA = SubscriptionAccount(label: "Account A", token: tokenA)
    let accountB = SubscriptionAccount(label: "Account B", token: tokenB)

    do {
        let translator = AccountsIntegrationTranslator(holdInput: true)
        let harness = try AccountsIntegrationHarness(defaults: defaults, accounts: [accountA, accountB],
                                                      currentID: accountA.id, translator: translator)
        defer { harness.chat.shutdown() }
        let conversationID = harness.chat.selectedID
        harness.chat.draft = "first account request"
        harness.chat.send()
        let translating = await accountsIntegrationWait { await translator.requestCount == 1 }
        check("switch_blocked_during_input_translation", translating && !harness.accounts.select(id: accountB.id)
              && harness.accounts.currentAccountID == accountA.id && harness.provider.requests().isEmpty)
        // A stale legacy editor value must never override the selected account.
        harness.execution.subscriptionToken = "sk-ant-oat01-integration-stale-editor-after-send"
        await translator.releaseInputs()
        let firstStarted = await accountsIntegrationWait { harness.provider.requests().count == 1 }
        check("send_uses_selected_account_snapshot", firstStarted
              && harness.provider.requests().first?.subscriptionToken == tokenA
              && harness.provider.requests().first?.provider == .claudeSubscription)
        check("switch_blocked_while_provider_streams", !harness.accounts.select(id: accountB.id)
              && harness.accounts.currentAccountID == accountA.id)
        let firstCompleted = harness.provider.complete()
        let firstSettled = await accountsIntegrationWait { harness.chat.isTerminationWorkSettled }
        check("request_finishes_before_switch", firstCompleted && firstSettled
              && harness.chat.messages.last(where: { $0.role == .assistant })?.state == .complete)
        check("next_account_selected_after_settlement", harness.accounts.select(id: accountB.id)
              && harness.accounts.currentAccountID == accountB.id)
        harness.chat.draft = "second account request"
        harness.chat.send()
        let secondStarted = await accountsIntegrationWait { harness.provider.requests().count == 2 }
        let secondRequest = harness.provider.requests().last
        check("next_send_uses_b_without_legacy_editor_token", secondStarted && secondRequest?.subscriptionToken == tokenB)
        check("continued_conversation_keeps_history_and_session", secondStarted
              && secondRequest?.conversationSessionID == conversationID
              && secondRequest?.messages.map(\.text) == ["en:first account request", AccountsIntegrationChat.reply,
                                                         "en:second account request"])
        let secondCompleted = harness.provider.complete()
        let secondSettled = await accountsIntegrationWait { harness.chat.isTerminationWorkSettled }
        check("two_account_requests_never_read_legacy_slot", secondCompleted && secondSettled
              && harness.legacyCredential.loads == 0 && harness.legacyCredential.saves == 0
              && harness.legacyCredential.deletes == 0 && harness.executionCredential.loads == 0)
        let translationRequests = await translator.requests
        check("account_switch_keeps_independent_translation_credential", translationRequests.count == 2
              && translationRequests.allSatisfy { $0.model.apiKey == harness.translationCredential.secret })

        check("selected_authorization_can_be_cleared_when_idle", harness.accounts.clearCredential(id: accountB.id))
        harness.chat.draft = "missing account authorization"
        harness.chat.send()
        check("missing_account_token_never_falls_back", !harness.chat.isBusy && harness.provider.requests().count == 2
              && harness.legacyCredential.loads == 0 && !harness.execution.subscriptionToken.isEmpty)
        harness.accountStore.loadFailure = .readFailed
        check("catalog_read_failure_invalidates_selection", !harness.accounts.load())
        harness.chat.draft = "unavailable account catalog"
        harness.chat.send()
        check("unavailable_catalog_never_falls_back", !harness.chat.isBusy && harness.provider.requests().count == 2
              && harness.legacyCredential.loads == 0)
    } catch { check("request_fixture_setup", false) }

    do {
        // Keep both token and credential version identical, so only the account
        // ID can distinguish this late result from the newly selected account.
        let sameTokenB = SubscriptionAccount(label: "Same token B", token: tokenA,
                                             credentialVersion: accountA.credentialVersion)
        let tester = AccountsIntegrationConnectionTester()
        let harness = try AccountsIntegrationHarness(defaults: defaults, accounts: [accountA, sameTokenB],
                                                      currentID: accountA.id, tester: tester)
        defer { harness.chat.shutdown() }
        let pending = Task { await harness.execution.testConnection() }
        let started = await accountsIntegrationWait { await tester.tokens.count == 1 }
        check("connection_test_blocks_account_mutation", started && !harness.accounts.select(id: sameTokenB.id))
        // Simulate a catalog readback changing independently while the request is
        // suspended; the ordinary UI remains correctly locked by the test gate.
        var changed = harness.accountStore.catalog
        changed.currentAccountID = sameTokenB.id
        try harness.accountStore.save(changed)
        check("external_selection_readback_changes_account", harness.accounts.load()
              && harness.accounts.currentAccountID == sameTokenB.id)
        await tester.release()
        await pending.value
        check("same_token_late_result_rejected_by_account_id", harness.execution.error == ExecutionConnectionFailure(code: "CONFIG_CHANGED").message
              && harness.execution.testStatus == "连接测试未通过。" && !harness.execution.testBusy)
        await harness.execution.testConnection()
        let testedTokens = await tester.tokens
        check("new_account_can_run_its_own_connection_test", testedTokens == [tokenA, tokenA]
              && harness.execution.error == nil && harness.execution.testStatus?.contains("CLAUDE_SUBSCRIPTION_CLI_OK") == true
              && harness.legacyCredential.loads == 0)
    } catch { check("connection_fixture_setup", false) }

    for terminating in [false, true] {
        let phase = terminating ? "termination" : "login_reset"
        do {
            let quota = AccountsIntegrationQuota()
            let harness = try AccountsIntegrationHarness(defaults: defaults, accounts: [accountA, accountB],
                                                          currentID: accountA.id, quota: quota)
            defer { harness.chat.shutdown() }
            let pending = Task { await harness.accounts.refresh(id: accountA.id) }
            let started = await accountsIntegrationWait { quota.tokens.count == 1 }
            if terminating { harness.execution.beginTermination() }
            else { harness.execution.beginLoginReset() }
            let cancelled = await accountsIntegrationWait { quota.cancellations == 1 }
            check(phase + "_cancels_quota_but_waits_for_cleanup", started && cancelled
                  && !harness.execution.isTerminationWorkSettled && !harness.accounts.isRefreshSettled
                  && harness.accounts.activeRefreshCount == 1)
            await harness.accounts.refresh(id: accountB.id)
            check(phase + "_blocks_new_refresh_and_account_mutation", quota.tokens == [tokenA]
                  && !harness.accounts.select(id: accountB.id) && harness.accounts.currentAccountID == accountA.id)
            if !terminating {
                do {
                    try harness.execution.clearSubscriptionForLoginReset()
                    check("login_reset_keeps_credentials_until_quota_cleanup", false)
                } catch {
                    check("login_reset_keeps_credentials_until_quota_cleanup",
                          error as? LoginResetLifecycleFailure == .workStillRunning
                          && harness.accounts.currentAccount?.token == tokenA)
                }
            }
            // A service may finish cleanup after cancellation. Even if it then
            // returns data, the cancelled task must not publish that snapshot.
            quota.release()
            await pending.value
            check(phase + "_settles_only_after_quota_returns", harness.execution.isTerminationWorkSettled
                  && harness.accounts.isRefreshSettled && harness.accounts.activeRefreshCount == 0)
            check(phase + "_discards_late_quota_success", harness.accounts.quotaStates[accountA.id]?.snapshot == nil)
            if terminating {
                check("termination_preserves_all_account_credentials", harness.accountStore.catalog.accounts == [accountA, accountB])
                harness.execution.endTermination()
            } else {
                try harness.execution.clearSubscriptionForLoginReset()
                let persistedA = harness.accountStore.catalog.accounts.first { $0.id == accountA.id }
                let persistedB = harness.accountStore.catalog.accounts.first { $0.id == accountB.id }
                check("login_reset_clears_only_current_account", persistedA?.token == nil
                      && persistedA?.credentialVersion != accountA.credentialVersion
                      && persistedB == accountB && harness.accounts.currentAccountID == accountA.id)
                check("login_reset_preserves_legacy_slot_and_other_scopes", harness.legacyCredential.secret == AccountsIntegrationHarness.legacyToken
                      && harness.legacyCredential.loads == 0 && harness.legacyCredential.saves == 0 && harness.legacyCredential.deletes == 0
                      && harness.executionCredential.deletes == 0 && harness.translationCredential.deletes == 0
                      && harness.execution.subscriptionToken.isEmpty)
                harness.execution.endLoginReset()
            }
            check(phase + "_releases_mutation_gate_after_completion", harness.accounts.select(id: accountB.id)
                  && harness.accounts.currentAccountID == accountB.id)
        } catch { check(phase + "_fixture_setup", false) }
    }
    return results
}

@MainActor
private final class AccountsIntegrationHarness {
    static let legacyToken = "sk-ant-oat01-integration-legacy-slot"
    let legacyCredential = AccountsIntegrationCredential(legacyToken)
    let translationCredential = AccountsIntegrationCredential("integration-translation-fake-key")
    let executionCredential = AccountsIntegrationCredential("integration-execution-fake-key")
    let accountStore: MemorySubscriptionAccountStore
    let accounts: SubscriptionAccountsModel
    let provider = AccountsIntegrationChat()
    let translation: TranslationViewModel
    let execution: ExecutionViewModel
    let chat: ConversationViewModel
    let loginReset: ClaudeLoginResetModel
    let runtimeVersion: RuntimeVersionViewModel

    init(defaults: UserDefaults, accounts records: [SubscriptionAccount], currentID: UUID?,
         translator: AccountsIntegrationTranslator = .init(),
         tester: (any ExecutionConnectionTesting)? = nil, quota: (any SubscriptionQuotaFetching)? = nil) throws {
        accountStore = MemorySubscriptionAccountStore(catalog: .init(currentAccountID: currentID, accounts: records))
        accounts = SubscriptionAccountsModel(store: accountStore, quotaService: quota)
        guard accounts.load() else { throw SubscriptionAccountStoreFailure.readFailed }
        translation = TranslationViewModel(provider: translator, configurationStore: .init(defaults: defaults), credentials: translationCredential)
        translation.endpoint = "https://api.deepseek.com/chat/completions"
        translation.modelName = "deepseek-flash"
        execution = ExecutionViewModel(store: .init(defaults: defaults), credentials: executionCredential,
                                       subscriptionCredentials: legacyCredential, tester: tester, subscriptionAccounts: accounts)
        execution.provider = .claudeSubscription
        execution.subscriptionToken = "sk-ant-oat01-integration-stale-editor"
        chat = ConversationViewModel(translation: translation, execution: execution, translator: translator,
                                     provider: provider, store: MemoryConversationStore(),
                                     translationCredentials: translationCredential, executionCredentials: executionCredential,
                                     subscriptionCredentials: legacyCredential)
        let unusedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("account-integration-unused-\(UUID().uuidString)")
        loginReset = ClaudeLoginResetModel(chat: chat, execution: execution, translation: translation,
                                           runtime: .init(tempRoot: unusedRoot, processAlive: { _ in false }),
                                           externalScanner: .init(home: unusedRoot))
        runtimeVersion = RuntimeVersionViewModel(store: AccountsIntegrationRuntimeStore(), registry: OwnedProcessRegistry())
        configureAccountLifecycle(accounts, chat: chat, execution: execution, loginReset: loginReset, runtimeVersion: runtimeVersion)
    }
}

private final class AccountsIntegrationCredential: AppCredentialStoring {
    private(set) var secret: String?
    private(set) var loads = 0, saves = 0, deletes = 0
    init(_ value: String) { secret = value }
    func load() throws -> String? { loads += 1; return secret }
    func save(_ value: String) throws { saves += 1; secret = value }
    func delete() throws { deletes += 1; secret = nil }
}

private actor AccountsIntegrationTranslator: TranslationProviding {
    private var holdInput: Bool
    private(set) var requests: [TranslationRequest] = []
    private var pending: [(TranslationRequest, CheckedContinuation<TranslationReply, any Error>)] = []
    var requestCount: Int { requests.count }
    init(holdInput: Bool = false) { self.holdInput = holdInput }
    func translate(_ request: TranslationRequest) async throws -> TranslationReply {
        requests.append(request)
        if holdInput { return try await withCheckedThrowingContinuation { pending.append((request, $0)) } }
        return reply(request)
    }
    func releaseInputs() {
        holdInput = false
        let waiting = pending; pending.removeAll()
        for (request, continuation) in waiting { continuation.resume(returning: reply(request)) }
    }
    private func reply(_ request: TranslationRequest) -> TranslationReply {
        let text = "\(request.target):\(request.text)"
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(ok: true, request_id: request.request_id, original: request.text, translated: text,
                     revision: 1, translation_sha256: digest, requires_confirmation: true, error_code: nil, fixture_only: false)
    }
}

private final class AccountsIntegrationChat: ChatProviding, @unchecked Sendable {
    static let reply = "Synthetic account reply"
    private let lock = NSLock()
    private var captured: [ChatRequest] = []
    private var continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation?
    func requests() -> [ChatRequest] { lock.withLock { captured } }
    func events(for request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { stream in
            lock.withLock { captured.append(request); continuation = stream }
            stream.yield(.started)
        }
    }
    func complete() -> Bool {
        let stream = lock.withLock { let value = continuation; continuation = nil; return value }
        guard let stream else { return false }
        stream.yield(.completed(Self.reply))
        stream.finish()
        return true
    }
}

private actor AccountsIntegrationConnectionTester: ExecutionConnectionTesting {
    private(set) var tokens: [String] = []
    private var released = false
    private var pending: [(String, CheckedContinuation<ExecutionConnectionReply, any Error>)] = []
    func test(apiKey: String, model: String) async throws -> ExecutionConnectionReply {
        throw ExecutionConnectionFailure(code: "INVALID_PROFILE")
    }
    func testSubscription(token: String, model: String) async throws -> ExecutionConnectionReply {
        tokens.append(token)
        if released { return reply(model) }
        return try await withCheckedThrowingContinuation { pending.append((model, $0)) }
    }
    func release() {
        released = true
        let waiting = pending; pending.removeAll()
        for (model, continuation) in waiting { continuation.resume(returning: reply(model)) }
    }
    private func reply(_ model: String) -> ExecutionConnectionReply {
        .init(ok: true, code: "PASSED_TEXT_ONLY", model: model, ack: "CLAUDE_SUBSCRIPTION_CLI_OK", no_tools: true,
              request_count: 1, cli: .init(exit_code: 0, signal: nil), cleanup: .init(temporary_removed: true, proxy_closed: true))
    }
}

private final class AccountsIntegrationQuota: SubscriptionQuotaFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String] = []
    private var cancelledCount = 0
    private var released = false
    private var pending: [CheckedContinuation<SubscriptionQuotaSnapshot, any Error>] = []
    var tokens: [String] { lock.withLock { captured } }
    var cancellations: Int { lock.withLock { cancelledCount } }
    func fetch(token: String) async throws -> SubscriptionQuotaSnapshot {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready = lock.withLock {
                    captured.append(token)
                    if released { return true }
                    pending.append(continuation)
                    return false
                }
                if ready { continuation.resume(returning: Self.reply) }
            }
        } onCancel: { self.lock.withLock { self.cancelledCount += 1 } }
    }
    func release() {
        let waiting = lock.withLock {
            released = true
            let value = pending; pending.removeAll()
            return value
        }
        for continuation in waiting { continuation.resume(returning: Self.reply) }
    }
    private static var reply: SubscriptionQuotaSnapshot {
        .init(windows: [.init(id: "five_hour", usedPercentage: 42, resetsAt: Date(timeIntervalSince1970: 2_000_000_000))],
              queriedAt: Date(timeIntervalSince1970: 1_900_000_000))
    }
}

private struct AccountsIntegrationRuntimeStore: RuntimePackageManaging {
    func snapshot() throws -> RuntimePackageSnapshot {
        let info = RuntimePackageInfo(id: "account-integration-fixture", version: "1.0.0", cliVersion: "1.0.0",
                                      sdkVersion: "1.0.0", nodeVersion: "1.0.0")
        return .init(bundled: info, current: info, previous: nil, pending: nil)
    }
    func importPackage(at: URL, shouldCancel: @Sendable () -> Bool,
                       progress: @Sendable (Double) -> Void) throws -> RuntimePackageInfo { throw RuntimePackageFailure.invalidPackage }
    func requestRollback() throws { throw RuntimePackageFailure.noPrevious }
    func activatePending() throws { throw RuntimePackageFailure.noPending }
    func cancelPending() throws { throw RuntimePackageFailure.noPending }
    func resolvedRuntimeRoot() throws -> URL { throw RuntimePackageFailure.invalidState }
}

@MainActor
private func accountsIntegrationWait(_ predicate: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<1_000 {
        if await predicate() { return true }
        do { try await Task.sleep(for: .milliseconds(2)) }
        catch { return false }
    }
    return await predicate()
}
