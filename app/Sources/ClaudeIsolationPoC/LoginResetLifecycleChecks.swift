import CryptoKit
import Foundation

private actor ResetLifecycleTranslator: TranslationProviding {
    private var held: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    init(held: Bool = false) { self.held = held }
    func translate(_ request: TranslationRequest) async throws -> TranslationReply {
        calls += 1
        // Deliberately ignore cancellation until release: drain must time out,
        // rather than falsely assume cancellation ended secret-bearing work.
        if held { await withCheckedContinuation { waiters.append($0) } }
        let text = request.target == "zh" ? "中文译文" : "Translated input"
        return .init(ok: true, request_id: UUID().uuidString, original: request.text, translated: text,
                     revision: 1, translation_sha256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                     requires_confirmation: request.operation == "translate_input", error_code: nil, fixture_only: true)
    }
    func release() { held = false; let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}

private actor ResetLifecycleTester: ExecutionConnectionTesting {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    func test(apiKey: String, model: String) async throws -> ExecutionConnectionReply { try await reply(model) }
    func testSubscription(token: String, model: String) async throws -> ExecutionConnectionReply { try await reply(model) }
    private func reply(_ model: String) async throws -> ExecutionConnectionReply {
        calls += 1
        await withCheckedContinuation { waiters.append($0) }
        return .init(ok: true, code: "PASSED_TEXT_ONLY", model: model, ack: "CLAUDE_SUBSCRIPTION_CLI_OK", no_tools: true,
                     request_count: nil, cli: .init(exit_code: 0, signal: nil), cleanup: .init(temporary_removed: true, proxy_closed: true))
    }
    func release() { let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}

private final class ResetLifecycleChat: ChatProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func events(for request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock(); count += 1; lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.started)
            // The consumer can cancel independently of an underlying worker.
            continuation.onTermination = { _ in }
        }
    }
}

private final class ResetFailingConversationStore: ConversationPersisting {
    let original: ConversationSnapshot
    var rejectSave = false
    init(_ original: ConversationSnapshot) { self.original = original }
    func load() throws -> ConversationSnapshot { original }
    func save(_ snapshot: ConversationSnapshot) throws { if rejectSave { throw ConversationStoreFailure.saveFailed } }
}

private struct ResetStdioProcessMarker: Decodable {
    let pid: Int32
    let temporary_root_realpath: String
    let environment_keys: [String]
}

@MainActor
private func resetLifecycleAwait(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
    }
    return false
}

@MainActor
func loginResetLifecycleChecks() async -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { checks.append(("login_reset_lifecycle_" + name, passed)) }
    let suite = "com.claude-isolation-poc.login-reset-lifecycle.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return [("login_reset_lifecycle_preferences", false)] }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("login-reset-lifecycle-\(UUID().uuidString)")
    defer {
        OwnedProcessRegistry.shared.endLoginReset()
        defaults.removePersistentDomain(forName: suite)
        do { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
        catch { check("fixture_cleanup", false) }
    }
    let fakeToken = "sk-ant-oat01-lifecycle-fake-token"
    let executionKey = "lifecycle-execution-fake-key"
    let translationKey = "lifecycle-translation-fake-key"
    do {
        let tokenStore = FileCredentialStore(scope: .subscription, directoryURL: directory)
        try tokenStore.save(fakeToken)
        let execStore = FileCredentialStore(scope: .execution, directoryURL: directory)
        let transStore = FileCredentialStore(scope: .translation, directoryURL: directory)
        try execStore.save(executionKey); try transStore.save(translationKey)
        let execBytes = try Data(contentsOf: execStore.fileURL), transBytes = try Data(contentsOf: transStore.fileURL)
        let translator = ResetLifecycleTranslator(held: true), chat = ResetLifecycleChat()
        let translation = TranslationViewModel(provider: translator, configurationStore: .init(defaults: defaults), credentials: transStore)
        translation.apiKey = translationKey
        let execution = ExecutionViewModel(store: .init(defaults: defaults), credentials: execStore, subscriptionCredentials: tokenStore)
        execution.modelName = "deepseek-flash[1m]"; execution.provider = .claudeSubscription
        execution.subscriptionToken = fakeToken; execution.apiKey = executionKey; execution.saveConfiguration()
        let profile = defaults.data(forKey: ExecutionConfigurationStore.storageKey)
        let old = ConversationRecord(title: "保留会话", draft: "保留草稿", messages: [.init(role: .assistant, text: "保留原文", translation: "保留译文")])
        let history = MemoryConversationStore(.init(selectedID: old.id, conversations: [old]))
        let vm = ConversationViewModel(translation: translation, execution: execution, translator: translator, provider: chat,
                                      store: history, translationCredentials: transStore, executionCredentials: execStore,
                                      subscriptionCredentials: tokenStore, fixtureOnly: true)
        vm.send()
        check("input_translation_started", await resetLifecycleAwait { await translator.calls == 1 })
        OwnedProcessRegistry.shared.beginLoginReset(); vm.beginLoginReset(); execution.beginLoginReset(); translation.beginLoginReset()
        let blockedDraft = vm.draft
        vm.draft = "清理期间禁止修改"; vm.send(); vm.newConversation(); vm.deleteConversation(old.id)
        execution.subscriptionToken = "sk-ant-oat01-should-not-replace-token"
        execution.saveSubscriptionToken(); execution.loadSubscriptionToken(); execution.restoreSavedSubscriptionTokenForSettings(); execution.deleteSubscriptionToken()
        execution.apiKey = "should-not-replace-execution-key"; execution.saveKey(); execution.loadKey(); execution.deleteKey()
        translation.apiKey = "should-not-replace-translation-key"; translation.saveKey(); translation.loadKey(); translation.deleteKey()
        await execution.testConnection(); await translation.translateInput()
        check("gate_blocks_send_and_conversation_mutations", !vm.canSend && vm.draft == blockedDraft && vm.conversations.count == 1 && chat.calls == 0)
        check("gate_blocks_token_binding_and_storage_mutations", try execution.subscriptionToken == fakeToken && (try tokenStore.load()) == fakeToken)
        check("gate_preserves_deepseek_memory_and_files", try execution.apiKey == executionKey && translation.apiKey == translationKey && (try Data(contentsOf: execStore.fileURL)) == execBytes && (try Data(contentsOf: transStore.fileURL)) == transBytes)
        var timedOut = false
        do { try await vm.drainForLoginReset(timeoutSeconds: 0.04) } catch LoginResetLifecycleFailure.drainTimedOut { timedOut = true }
        check("uncooperative_translation_times_out_before_token_delete", timedOut && FileManager.default.fileExists(atPath: tokenStore.fileURL.path))
        await translator.release()
        try await vm.drainForLoginReset(); try await translation.drainForLoginReset(); try await execution.drainForLoginReset()
        try await OwnedProcessRegistry.shared.drainForLoginReset()
        check("cancelled_translation_cannot_start_claude", chat.calls == 0 && !vm.isBusy && vm.draft == old.draft)
        let preserved = vm.conversations
        try execution.clearSubscriptionForLoginReset()
        check("reset_removes_token_file_cache_and_bound_input", try execution.subscriptionToken.isEmpty && (try tokenStore.load()) == nil && !FileManager.default.fileExists(atPath: tokenStore.fileURL.path))
        try vm.completeLoginReset()
        check("new_conversation_has_no_history_and_old_records_survive", vm.messages.isEmpty && vm.draft.isEmpty && Array(vm.conversations.dropFirst()) == preserved && history.snapshot.conversations == vm.conversations && history.snapshot.selectedID == vm.selectedID)
        check("configuration_and_deepseek_persisted_values_unchanged", try defaults.data(forKey: ExecutionConfigurationStore.storageKey) == profile && (try Data(contentsOf: execStore.fileURL)) == execBytes && (try Data(contentsOf: transStore.fileURL)) == transBytes)
        vm.endLoginReset(); execution.endLoginReset(); translation.endLoginReset(); OwnedProcessRegistry.shared.endLoginReset()
        vm.draft = "清理之后重新发送"; vm.send()
        check("post_reset_subscription_does_not_fallback_or_reuse_auth", chat.calls == 0 && !vm.isBusy && vm.messages.last(where: { $0.role == .user })?.error == ChatFailure.code("MISSING_SUBSCRIPTION_TOKEN").message)
        check("missing_token_stops_before_translation", await translator.calls == 1)
    } catch { check("file_backed_conversation_reset_fixture", false) }

    do {
        let tester = ResetLifecycleTester()
        let tokens = MemoryAppCredentialStore(fakeToken, scope: .subscription)
        let vm = ExecutionViewModel(store: .init(defaults: defaults), credentials: MemoryAppCredentialStore(executionKey), subscriptionCredentials: tokens, tester: tester)
        vm.provider = .claudeSubscription; vm.subscriptionToken = fakeToken
        let running = Task { await vm.testConnection() }
        check("subscription_connection_fixture_started", await resetLifecycleAwait { await tester.calls == 1 })
        vm.beginLoginReset()
        var timedOut = false, clearBlocked = false
        do { try await vm.drainForLoginReset(timeoutSeconds: 0.04) } catch LoginResetLifecycleFailure.drainTimedOut { timedOut = true }
        do { try vm.clearSubscriptionForLoginReset() } catch LoginResetLifecycleFailure.workStillRunning { clearBlocked = true }
        check("connection_test_retains_auth_until_real_completion", timedOut && clearBlocked && tokens.deleteCount == 0 && tokens.key == fakeToken)
        await tester.release(); await running.value
        try await vm.drainForLoginReset()
        check("cancelled_connection_cannot_publish_success", !vm.testBusy && vm.testStatus == "连接测试已停止。")
        tokens.deleteFailure = .deleteFailed
        var deleteFailed = false
        do { try vm.clearSubscriptionForLoginReset() } catch { deleteFailed = true }
        check("failed_deletion_retains_disk_and_input", deleteFailed && tokens.key == fakeToken && vm.subscriptionToken == fakeToken)
        tokens.deleteFailure = nil
        try vm.clearSubscriptionForLoginReset()
        vm.endLoginReset(); await vm.testConnection()
        check("cleared_connection_requires_new_token", await tester.calls == 1 && vm.error?.contains("订阅 Token") == true)
    } catch { check("connection_cancellation_fixture", false) }

    do {
        let translator = ResetLifecycleTranslator(held: true)
        let vm = TranslationViewModel(provider: translator, configurationStore: .init(defaults: defaults), credentials: MemoryAppCredentialStore(translationKey))
        vm.apiKey = translationKey; vm.inputText = "输入草稿"; vm.outputText = "原始输出"
        let input = Task { await vm.translateInput() }, output = Task { await vm.translateOutput() }
        check("both_translation_tasks_started", await resetLifecycleAwait { await translator.calls == 2 })
        vm.beginLoginReset()
        var timedOut = false
        do { try await vm.drainForLoginReset(timeoutSeconds: 0.04) } catch LoginResetLifecycleFailure.drainTimedOut { timedOut = true }
        check("both_translations_are_in_drain", timedOut && !vm.canTranslateInput && !vm.canTranslateOutput)
        await translator.release(); await input.value; await output.value
        try await vm.drainForLoginReset()
        check("cancelled_translations_keep_drafts_and_key", vm.inputText == "输入草稿" && vm.outputText == "原始输出" && vm.apiKey == translationKey && vm.inputTranslation == nil && vm.outputTranslation == nil)
        vm.endLoginReset()
    } catch { check("translation_cancellation_fixture", false) }

    do {
        let translator = ResetLifecycleTranslator(held: true), chat = ResetLifecycleChat()
        let translation = TranslationViewModel(provider: translator, configurationStore: .init(defaults: defaults), credentials: MemoryAppCredentialStore(translationKey))
        translation.apiKey = translationKey
        let execution = ExecutionViewModel(store: .init(defaults: defaults), credentials: MemoryAppCredentialStore(executionKey), subscriptionCredentials: MemoryAppCredentialStore(scope: .subscription))
        let assistant = ConversationMessage(role: .assistant, text: "原始回答")
        let old = ConversationRecord(title: "翻译中的会话", draft: "保留草稿", messages: [assistant])
        let store = MemoryConversationStore(.init(selectedID: old.id, conversations: [old]))
        let vm = ConversationViewModel(translation: translation, execution: execution, translator: translator, provider: chat, store: store,
                                      translationCredentials: MemoryAppCredentialStore(translationKey), executionCredentials: MemoryAppCredentialStore(executionKey), subscriptionCredentials: MemoryAppCredentialStore(scope: .subscription), fixtureOnly: true)
        vm.translateMessage(assistant.id)
        check("message_translation_started", await resetLifecycleAwait { await translator.calls == 1 })
        vm.beginLoginReset(); vm.translateMessage(assistant.id)
        var timedOut = false
        do { try await vm.drainForLoginReset(timeoutSeconds: 0.04) } catch LoginResetLifecycleFailure.drainTimedOut { timedOut = true }
        await translator.release(); try await vm.drainForLoginReset()
        check("message_translation_drains_without_overwriting_raw_reply", timedOut && vm.messages.first?.text == assistant.text && vm.messages.first?.translation == nil && vm.draft == old.draft)
        vm.endLoginReset()
        let badStore = ResetFailingConversationStore(.init(selectedID: old.id, conversations: [old]))
        let bad = ConversationViewModel(translation: translation, execution: execution, translator: translator, provider: chat, store: badStore,
                                       translationCredentials: MemoryAppCredentialStore(), executionCredentials: MemoryAppCredentialStore(), subscriptionCredentials: MemoryAppCredentialStore(scope: .subscription))
        bad.beginLoginReset(); badStore.rejectSave = true
        var saveFailed = false
        do { try bad.completeLoginReset() } catch LoginResetLifecycleFailure.conversationReadbackFailed { saveFailed = true }
        check("new_conversation_write_failure_is_explicit_and_preserves_selection", saveFailed && bad.selectedID == old.id && bad.conversations == [old])
        badStore.rejectSave = false
        var readbackFailed = false
        do { try bad.completeLoginReset() } catch LoginResetLifecycleFailure.conversationReadbackFailed { readbackFailed = true }
        check("false_successful_save_requires_persistence_readback", readbackFailed && bad.selectedID == old.id)
        bad.endLoginReset()
    } catch { check("message_and_persistence_fixture", false) }

    do {
        // A separate registry avoids coupling this process fixture to App work.
        let registry = OwnedProcessRegistry(), controller = OwnedProcessController()
        try controller.registerWork(in: registry)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["20"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try controller.install(process); try process.run(); controller.didStart()
        registry.beginLoginReset()
        var timedOut = false
        do { try await registry.drainForLoginReset(timeoutSeconds: 0.04) } catch LoginResetLifecycleFailure.drainTimedOut { timedOut = true }
        check("process_worker_is_tracked_after_consumer_cancellation", timedOut && registry.activeCount == 1)
        let denied = OwnedProcessController()
        var launchBlocked = false
        do { try denied.registerWork(in: registry) } catch { launchBlocked = true }
        check("reset_admission_rejects_new_process_workers", launchBlocked && registry.activeCount == 1)
        let exited = await resetLifecycleAwait { !process.isRunning }
        check("owned_process_has_exited_before_worker_finish", exited)
        controller.finish(); try await registry.drainForLoginReset()
        check("process_registry_settles_only_after_worker_finish", registry.activeCount == 0)
        registry.endLoginReset()
    } catch { check("owned_process_fixture", false) }
    return checks
}

/// Actual Node children with fake credentials, no network and no CLI. Each
/// bridge must remain in the registry after its consumer cancels until exit.
@MainActor
func loginResetStdioChecks(configuration: AppConfiguration) async -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { checks.append(("login_reset_stdio_" + name, passed)) }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("login-reset-stdio-\(UUID().uuidString)")
    let registry = OwnedProcessRegistry.shared
    defer {
        registry.endLoginReset()
        do { if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) } }
        catch { check("fixture_cleanup", false) }
    }
    do {
        let cleanupTemporaryRoot = try OwnedRuntimeCleanupService.defaultTemporaryRoot().path
        let sdk = temporary.appendingPathComponent("sdk"), translation = temporary.appendingPathComponent("translation")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: translation, withIntermediateDirectories: true)
        let program = """
        import {realpathSync, writeFileSync} from 'node:fs';
        import os from 'node:os';
        process.stdin.resume();
        process.on('SIGTERM', () => setTimeout(() => process.exit(0), 300));
        writeFileSync('pid.json', JSON.stringify({pid:process.pid, temporary_root_realpath:realpathSync(os.tmpdir()), environment_keys:Object.keys(process.env).sort()}));
        setInterval(() => {}, 1000);
        """
        for file in [sdk.appendingPathComponent("deepseek-text-chat.mjs"), sdk.appendingPathComponent("vm-text-smoke.mjs"), translation.appendingPathComponent("stdio.mjs")] {
            try Data(program.utf8).write(to: file)
        }
        let fixture = AppConfiguration(projectRoot: temporary.path, nodeExecutable: configuration.nodeExecutable)
        for kind in ["chat", "translation", "connection"] {
            let marker = (kind == "translation" ? translation : sdk).appendingPathComponent("pid.json")
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
            let request = ChatRequest(request_id: UUID().uuidString, model: "sonnet", messages: [.init(role: "user", text: "offline drain check")],
                                      provider: .claudeSubscription, subscriptionToken: "sk-ant-oat01-drain-fake-token")
            let consumer = Task<Void, Never> {
                do {
                    switch kind {
                    case "chat":
                        for try await _ in StdioChatProvider(configuration: fixture, fixtureOnly: true).events(for: request) {}
                    case "translation":
                        _ = try await StdioTranslationProvider(configuration: fixture, fixtureOnly: true).translate(.init(
                            request_id: UUID().uuidString, operation: "translate_input", text: "离线测试", target: "en",
                            model: .init(endpoint: "https://api.deepseek.com", model: "deepseek-flash", apiKey: "offline-fake-translation-key")))
                    default:
                        _ = try await StdioExecutionConnectionTester(configuration: fixture, networkPolicyProvider: FixedNetworkPolicyProvider(policy: .defaultPolicy), runtimeProfileProvider: FixedRuntimeProfileProvider()).test(apiKey: "offline-fake-execution-key", model: "deepseek-flash[1m]")
                    }
                } catch {
                    // This fixture intentionally stops without a reply; either
                    // cancellation or a sanitized bridge error is expected.
                    check(kind + "_cancel_has_no_reply", true)
                }
            }
            let started = await resetLifecycleAwait {
                guard let data = try? Data(contentsOf: marker) else { return false }
                return (try? JSONDecoder().decode(ResetStdioProcessMarker.self, from: data)) != nil
            }
            check(kind + "_process_started", started && registry.activeCount == 1)
            let processMarker = try JSONDecoder().decode(ResetStdioProcessMarker.self, from: Data(contentsOf: marker))
            if kind != "translation" {
                check(kind + "_controlled_temporary_root_matches_cleanup", processMarker.temporary_root_realpath == cleanupTemporaryRoot)
            }
            // Foundation adds its own encoding field when launching a macOS
            // Process. Keep the application-provided whitelist exact as well.
            let expectedKeys = AppRuntimeProfile.japan.processEnvironment.keys.sorted()
                + (kind == "translation" ? [] : ["TMPDIR"]) + ["__CF_USER_TEXT_ENCODING"]
            check(kind + "_controlled_environment_keys", processMarker.environment_keys == expectedKeys.sorted())
            registry.beginLoginReset(); consumer.cancel()
            var earlyDrainBlocked = false
            do { try await registry.drainForLoginReset(timeoutSeconds: 0.04) }
            catch LoginResetLifecycleFailure.drainTimedOut { earlyDrainBlocked = true }
            check(kind + "_waits_actual_process_exit", earlyDrainBlocked && registry.activeCount == 1)
            try await registry.drainForLoginReset(timeoutSeconds: 4)
            await consumer.value
            check(kind + "_worker_completely_drained", registry.activeCount == 0)
            registry.endLoginReset()
        }
    } catch { check("fixture_execution", false) }
    return checks
}
