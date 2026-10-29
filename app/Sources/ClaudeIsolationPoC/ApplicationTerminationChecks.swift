import AppKit
import CryptoKit
import Foundation

private actor TerminationFixtureTranslator: TranslationProviding {
    private var held = false
    private let cooperative: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    init(cooperative: Bool = true) { self.cooperative = cooperative }
    func hold() { held = true }
    func translate(_ request: TranslationRequest) async throws -> TranslationReply {
        calls += 1
        if held {
            if cooperative { try await Task.sleep(for: .seconds(60)) }
            else { await withCheckedContinuation { waiters.append($0) } }
        }
        let text = request.target == "zh" ? "离线译文" : "Offline translation"
        return .init(ok: true, request_id: UUID().uuidString, original: request.text, translated: text,
                     revision: 1, translation_sha256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                     requires_confirmation: request.operation == "translate_input", error_code: nil, fixture_only: true)
    }
    func release() {
        held = false
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor TerminationFixtureTester: ExecutionConnectionTesting {
    private let cooperative: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    init(cooperative: Bool = true) { self.cooperative = cooperative }
    func test(apiKey: String, model: String) async throws -> ExecutionConnectionReply { try await reply(model) }
    func testSubscription(token: String, model: String) async throws -> ExecutionConnectionReply { try await reply(model) }
    private func reply(_ model: String) async throws -> ExecutionConnectionReply {
        calls += 1
        if cooperative { try await Task.sleep(for: .seconds(60)) }
        else { await withCheckedContinuation { waiters.append($0) } }
        return .init(ok: true, code: "PASSED_TEXT_ONLY", model: model, ack: "OFFLINE_FIXTURE", no_tools: true,
                     request_count: nil, cli: .init(exit_code: 0, signal: nil), cleanup: .init(temporary_removed: true, proxy_closed: true))
    }
    func release() {
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class TerminationFixtureChat: ChatProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var cancelled = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return started }
    var cancellations: Int { lock.lock(); defer { lock.unlock() }; return cancelled }
    func events(for request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock(); started += 1; lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.started)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.cancelled += 1; self.lock.unlock()
            }
        }
    }
}

private final class TerminationFixtureStore: ConversationPersisting {
    var snapshot: ConversationSnapshot
    var rejectSave = false
    var rejectReadback = false
    private(set) var saves = 0
    init(_ snapshot: ConversationSnapshot) { self.snapshot = snapshot }
    func load() throws -> ConversationSnapshot { rejectReadback ? .empty : snapshot }
    func save(_ snapshot: ConversationSnapshot) throws {
        if rejectSave { throw ConversationStoreFailure.saveFailed }
        try snapshot.validate(); self.snapshot = snapshot; saves += 1
    }
}

@MainActor
private final class TerminationFixtureBrowser: BrowserTerminationManaging {
    private(set) var isTerminationWorkSettled: Bool
    private(set) var terminationSaveFailure: String?
    private(set) var acknowledgementCalls = 0
    private(set) var admissionClosed = false
    private(set) var networkClosed = false
    private(set) var profileLeaseHeld: Bool
    private(set) var restoreCalls = 0
    private(set) var shutdownTask: Task<Void, Error>?
    private let shutdownDelay: Double
    init(settled: Bool, shutdownDelay: Double = 0.20, saveFailure: String? = nil) {
        isTerminationWorkSettled = settled; profileLeaseHeld = !settled
        self.shutdownDelay = shutdownDelay
        terminationSaveFailure = saveFailure
    }
    func beginTermination() {
        admissionClosed = true; networkClosed = true
        guard !isTerminationWorkSettled, shutdownTask == nil else { return }
        shutdownTask = Task { @MainActor in
            try await Task.sleep(for: .seconds(shutdownDelay))
            isTerminationWorkSettled = true; profileLeaseHeld = false
        }
    }
    func endTermination() { admissionClosed = false; restoreCalls += 1 }
    func acknowledgeTerminationSaveFailure() throws {
        guard isTerminationWorkSettled else { throw BrowserRuntimeFailure.shutdown }
        acknowledgementCalls += 1; terminationSaveFailure = nil
    }
}

@MainActor
private struct TerminationFixture {
    let translator: TerminationFixtureTranslator
    let tester: TerminationFixtureTester
    let provider: TerminationFixtureChat
    let translation: TranslationViewModel
    let execution: ExecutionViewModel
    let chat: ConversationViewModel
    let store: TerminationFixtureStore
    let registry = OwnedProcessRegistry()

    init(defaults: UserDefaults, cooperative: Bool = true,
         translationCredentials: any AppCredentialStoring = MemoryAppCredentialStore("quit-fake-translation-key"),
         executionCredentials: any AppCredentialStoring = MemoryAppCredentialStore("quit-fake-execution-key"),
         subscriptionCredentials: any AppCredentialStoring = MemoryAppCredentialStore("sk-ant-oat01-quit-fake-token", scope: .subscription)) {
        let translator = TerminationFixtureTranslator(cooperative: cooperative)
        let tester = TerminationFixtureTester(cooperative: cooperative)
        let provider = TerminationFixtureChat()
        let translation = TranslationViewModel(provider: translator, configurationStore: .init(defaults: defaults), credentials: translationCredentials)
        translation.apiKey = "quit-fake-translation-key"
        let execution = ExecutionViewModel(store: .init(defaults: defaults), credentials: executionCredentials,
                                       subscriptionCredentials: subscriptionCredentials, tester: tester)
        execution.apiKey = "quit-fake-execution-key"; execution.modelName = "deepseek-flash[1m]"
        execution.subscriptionToken = "sk-ant-oat01-quit-fake-token"
        let record = ConversationRecord(title: "退出保留", draft: "保留发送草稿", messages: [.init(role: .assistant, text: "保留原文", translation: "保留译文")])
        let store = TerminationFixtureStore(.init(selectedID: record.id, conversations: [record]))
        let chat = ConversationViewModel(translation: translation, execution: execution, translator: translator, provider: provider,
                                     store: store, translationCredentials: translationCredentials, executionCredentials: executionCredentials,
                                     subscriptionCredentials: subscriptionCredentials, fixtureOnly: true)
        self.translator = translator; self.tester = tester; self.provider = provider
        self.translation = translation; self.execution = execution; self.store = store; self.chat = chat
    }

    func coordinator(timeoutSeconds: Double = 1) -> ApplicationTerminationCoordinator {
        ApplicationTerminationCoordinator(chat: chat, execution: execution, translation: translation,
                                          registry: registry, timeoutSeconds: timeoutSeconds)
    }
}

@MainActor
private func terminationFixtureAwait(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
    }
    return false
}

@MainActor
func applicationTerminationChecks() async -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { checks.append(("application_termination_" + name, passed)) }
    let suite = "com.claude-isolation-poc.termination.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return [("application_termination_preferences", false)] }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("application-termination-\(UUID().uuidString)")
    defer {
        defaults.removePersistentDomain(forName: suite)
        do { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
        catch { check("fixture_cleanup", false) }
    }
    do {
        let translationKey = FileCredentialStore(scope: .translation, directoryURL: directory)
        let executionKey = FileCredentialStore(scope: .execution, directoryURL: directory)
        let token = FileCredentialStore(scope: .subscription, directoryURL: directory)
        try translationKey.save("quit-fake-translation-key"); try executionKey.save("quit-fake-execution-key")
        try token.save("sk-ant-oat01-quit-fake-token")
        let before = try [translationKey, executionKey, token].map { try Data(contentsOf: $0.fileURL) }
        let fixture = TerminationFixture(defaults: defaults, translationCredentials: translationKey,
                                         executionCredentials: executionKey, subscriptionCredentials: token)
        let originalID = fixture.chat.selectedID, originalAssistantID = fixture.chat.messages[0].id
        fixture.chat.send()
        check("active_chat_started", await terminationFixtureAwait { fixture.provider.calls == 1 })
        await fixture.translator.hold()
        fixture.chat.translateMessage(originalAssistantID)
        fixture.translation.inputText = "设置输入草稿"; fixture.translation.outputText = "设置输出原文"
        let input = Task { await fixture.translation.translateInput() }
        let output = Task { await fixture.translation.translateOutput() }
        let connection = Task { await fixture.execution.testConnection() }
        check("message_and_settings_translations_started", await terminationFixtureAwait { await fixture.translator.calls == 4 })
        check("connection_test_started", await terminationFixtureAwait { await fixture.tester.calls == 1 })
        // This owned process is inert and gets no credential, network or model.
        let process = Process(), controller = OwnedProcessController()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        try controller.registerWork(in: fixture.registry)
        // Observe real exit directly. Launching on MainActor and waiting from
        // another thread can delay Foundation's waiter beyond the fixture's deadline.
        process.terminationHandler = { _ in controller.finish() }
        do { try controller.install(process); try process.run(); controller.didStart() }
        catch { controller.finish(); throw error }
        let coordinator = fixture.coordinator()
        let first = Task { try await coordinator.requestTermination() }
        let duplicate = Task { try await coordinator.requestTermination() }
        check("all_admission_closed_before_drain", await terminationFixtureAwait {
            fixture.chat.isTerminationInProgress && fixture.translation.isTerminationInProgress && fixture.execution.isTerminationInProgress && fixture.registry.isTerminationInProgress
        })
        var launchBlocked = false
        do { try OwnedProcessController().registerWork(in: fixture.registry) }
        catch ApplicationTerminationFailure.workAdmissionClosed { launchBlocked = true }
        check("new_owned_process_cannot_launch", launchBlocked)
        fixture.chat.newConversation(); fixture.chat.send()
        await fixture.translation.translateInput(); await fixture.execution.testConnection()
        let translationCalls = await fixture.translator.calls, connectionCalls = await fixture.tester.calls
        check("new_ui_work_cannot_start", translationCalls == 4 && connectionCalls == 1 && fixture.provider.calls == 1)
        do { try await first.value; try await duplicate.value }
        catch {
            check("complete_drain_owned_cancel_requested", controller.isCancelled)
            check("complete_drain_owned_process_exited", !process.isRunning)
            check("complete_drain_owned_registry_settled", fixture.registry.activeCount == 0)
            throw error
        }
        await input.value; await output.value; await connection.value
        check("quit_waits_all_tasks_and_actual_process_exit", coordinator.isReadyToTerminate && fixture.chat.isTerminationWorkSettled && fixture.translation.isTerminationWorkSettled && fixture.execution.isTerminationWorkSettled && fixture.registry.activeCount == 0 && !process.isRunning)
        check("chat_consumer_cancelled", fixture.provider.cancellations == 1 && !fixture.chat.isBusy)
        check("cancelled_settings_results_not_published", fixture.translation.inputTranslation == nil && fixture.translation.outputTranslation == nil && fixture.execution.testStatus == "连接测试已停止。")
        check("history_selection_draft_and_translations_retained", fixture.chat.conversations.count == 1 && fixture.chat.selectedID == originalID && fixture.chat.draft == "保留发送草稿" && fixture.chat.messages.first?.translation == "保留译文" && fixture.store.snapshot.conversations == fixture.chat.conversations && fixture.store.snapshot.selectedID == originalID)
        check("credential_files_and_bound_keys_retained", try before == [translationKey, executionKey, token].map { try Data(contentsOf: $0.fileURL) } && fixture.execution.subscriptionToken == "sk-ant-oat01-quit-fake-token" && fixture.execution.apiKey == "quit-fake-execution-key" && fixture.translation.apiKey == "quit-fake-translation-key")
        check("settings_drafts_retained", fixture.translation.inputText == "设置输入草稿" && fixture.translation.outputText == "设置输出原文")
        let saveCount = fixture.store.saves
        try await coordinator.requestTermination()
        check("completed_quit_is_idempotent", fixture.store.saves == saveCount)
    } catch {
        check("complete_drain_fixture", false)
        if case ApplicationTerminationFailure.drainTimedOut(let pending) = error {
            let labels = ["聊天与消息翻译": "chat", "设置翻译": "translation", "连接测试": "connection",
                          "模型与虚拟机进程": "owned_process", "已开始的登录清理": "login_reset",
                          "运行包导入": "runtime_import", "浏览器保存与关机": "browser"]
            for work in pending { check("complete_drain_pending_" + (labels[work] ?? "unknown"), false) }
        } else if error is ApplicationTerminationFailure {
            check("complete_drain_coordinator_error", false)
        } else {
            check("complete_drain_setup_or_readback_error", false)
        }
    }

    // Providers intentionally ignore cancellation: the app must remain open
    // until their real completion, even when a UI task has already been stopped.
    for kind in ["chat_input_translation", "settings_translation", "connection"] {
        let fixture = TerminationFixture(defaults: defaults, cooperative: false)
        await fixture.translator.hold()
        let active: Task<Void, Never>?
        if kind == "chat_input_translation" { fixture.chat.send(); active = nil }
        else if kind == "settings_translation" {
            fixture.translation.inputText = "超时后保留输入"
            active = Task { await fixture.translation.translateInput() }
        } else { active = Task { await fixture.execution.testConnection() } }
        check(kind + "_started", await terminationFixtureAwait {
            if kind == "connection" { return await fixture.tester.calls == 1 }
            return await fixture.translator.calls == 1
        })
        let coordinator = fixture.coordinator(timeoutSeconds: 0.04)
        var pending: [String] = []
        do { try await coordinator.requestTermination() }
        catch ApplicationTerminationFailure.drainTimedOut(let work) { pending = work }
        catch { check(kind + "_expected_timeout_error", false) }
        check(kind + "_timeout_denies_quit_and_reports_pending", !pending.isEmpty && !coordinator.isReadyToTerminate)
        check(kind + "_timeout_reopens_only_quit_admission", !fixture.chat.isTerminationInProgress && !fixture.translation.isTerminationInProgress && !fixture.execution.isTerminationInProgress && !fixture.registry.isTerminationInProgress && !fixture.chat.isLoginResetInProgress)
        check(kind + "_timeout_preserves_credentials", fixture.execution.subscriptionToken == "sk-ant-oat01-quit-fake-token" && fixture.execution.apiKey == "quit-fake-execution-key" && fixture.translation.apiKey == "quit-fake-translation-key")
        await fixture.translator.release(); await fixture.tester.release(); await active?.value
        check(kind + "_eventually_settles", await terminationFixtureAwait {
            fixture.chat.isTerminationWorkSettled && fixture.translation.isTerminationWorkSettled && fixture.execution.isTerminationWorkSettled
        })
        do { try await coordinator.requestTermination(); check(kind + "_retry_succeeds", coordinator.isReadyToTerminate) }
        catch { check(kind + "_retry_succeeds", false) }
    }

    do {
        let fixture = TerminationFixture(defaults: defaults)
        let pendingController = OwnedProcessController()
        try pendingController.registerWork(in: fixture.registry) // Prelaunch work is also owned.
        let coordinator = fixture.coordinator(timeoutSeconds: 0.04)
        let delegate = ClaudeIsolationApplicationDelegate()
        delegate.terminationCoordinator = coordinator
        var replies: [Bool] = [], failures: [String] = []
        delegate.terminationReply = { replies.append($0) }; delegate.terminationFailure = { failures.append($0) }
        let first = delegate.applicationShouldTerminate(NSApplication.shared)
        let second = delegate.applicationShouldTerminate(NSApplication.shared)
        check("appkit_intercepts_and_deduplicates_quit", first == .terminateCancel && second == .terminateCancel)
        check("appkit_timeout_replies_false_once", await terminationFixtureAwait { replies == [false] && failures.count == 1 })
        check("worker_timeout_message_is_actionable", failures.first?.contains("模型与虚拟机进程") == true && failures.first?.contains("保持打开") == true)
        check("unlaunched_owned_work_was_cancelled", pendingController.isCancelled && fixture.registry.activeCount == 1)
        pendingController.finish()
        let retry = delegate.applicationShouldTerminate(NSApplication.shared)
        check("appkit_retry_intercepts_until_ready", retry == .terminateCancel)
        check("appkit_success_replies_true_once", await terminationFixtureAwait { replies == [false, true] })
        check("appkit_completed_quit_is_immediate", delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    } catch { check("appkit_lifecycle_fixture", false) }

    for readback in [false, true] {
        let fixture = TerminationFixture(defaults: defaults)
        fixture.store.rejectSave = !readback; fixture.store.rejectReadback = readback
        let coordinator = fixture.coordinator()
        var persistenceFailed = false
        do { try await coordinator.requestTermination() }
        catch ApplicationTerminationFailure.persistenceFailed { persistenceFailed = true }
        catch { check("persistence_expected_error", false) }
        check(readback ? "readback_failure_denies_quit" : "save_failure_denies_quit", persistenceFailed && !coordinator.isReadyToTerminate && !fixture.chat.isTerminationInProgress && fixture.chat.persistenceError != nil)
    }
    do {
        let fixture = TerminationFixture(defaults: defaults)
        let profileURL = directory.appendingPathComponent("browser-profile-fixture.raw")
        let profileData = Data("synthetic retained browser login fixture".utf8)
        try profileData.write(to: profileURL)
        let browser = TerminationFixtureBrowser(settled: false, shutdownDelay: 0.20)
        // Scale 12s coordinator / 20s browser deadlines to 120ms / 200ms.
        // Timing out the quit must retain the live VM's profile lease and data.
        let coordinator = ApplicationTerminationCoordinator(chat: fixture.chat, execution: fixture.execution,
            translation: fixture.translation, browser: browser, registry: fixture.registry, timeoutSeconds: 0.12)
        let beforeSaves = fixture.store.saves
        var pending: [String] = []
        do { try await coordinator.requestTermination() }
        catch ApplicationTerminationFailure.drainTimedOut(let work) { pending = work }
        catch { check("browser_pending_expected_timeout", false) }
        check("browser_pending_denies_quit", pending == ["浏览器保存与关机"] && !coordinator.isReadyToTerminate)
        check("browser_pending_restore_admission", browser.restoreCalls == 1 && !browser.admissionClosed &&
              !fixture.chat.isTerminationInProgress && !fixture.registry.isTerminationInProgress)
        let afterTimeout = try Data(contentsOf: profileURL)
        check("browser_shorter_quit_deadline_retains_live_profile", afterTimeout == profileData && browser.profileLeaseHeld &&
              browser.networkClosed && !browser.isTerminationWorkSettled && fixture.store.saves == beforeSaves)
        check("browser_timeout_message_allows_manual_stop", ApplicationTerminationFailure.drainTimedOut(pending).localizedDescription.contains("手动强制停止"))
        try await browser.shutdownTask?.value
        check("browser_finishes_normal_shutdown_after_failed_quit", browser.isTerminationWorkSettled && !browser.profileLeaseHeld)
        try await coordinator.requestTermination()
        check("browser_settled_retry_persists_and_allows_quit", coordinator.isReadyToTerminate && fixture.store.saves > beforeSaves &&
              fixture.store.snapshot.selectedID == fixture.chat.selectedID && fixture.store.snapshot.conversations == fixture.chat.conversations)
        check("browser_settled_retry_keeps_profile", try Data(contentsOf: profileURL) == profileData)
    } catch { check("browser_pending_fixture", false) }
    do {
        let fixture = TerminationFixture(defaults: defaults)
        let browser = TerminationFixtureBrowser(settled: true)
        let coordinator = ApplicationTerminationCoordinator(chat: fixture.chat, execution: fixture.execution,
            translation: fixture.translation, browser: browser, registry: fixture.registry, timeoutSeconds: 0.12)
        let beforeSaves = fixture.store.saves
        try await coordinator.requestTermination()
        check("browser_already_settled_saves_and_allows_quit", coordinator.isReadyToTerminate && fixture.store.saves > beforeSaves &&
              fixture.store.snapshot.conversations == fixture.chat.conversations && browser.restoreCalls == 0 && browser.admissionClosed)
    } catch { check("browser_settled_fixture", false) }
    do {
        let fixture = TerminationFixture(defaults: defaults)
        var markers = BrowserSerialMarkers()
        _ = markers.consume(Data("BROWSER_SESSION_READY\nBROWSER_SESSION_STOP_FAILED\n".utf8))
        let failure = markers.saveFailure(forced: false)
        let browser = TerminationFixtureBrowser(settled: false, saveFailure: failure)
        let coordinator = ApplicationTerminationCoordinator(chat: fixture.chat, execution: fixture.execution,
            translation: fixture.translation, browser: browser, registry: fixture.registry)
        let beforeSaves = fixture.store.saves
        let profileURL = directory.appendingPathComponent("browser-save-gate-fixture.raw")
        let profileData = Data("synthetic unconfirmed retained profile".utf8)
        try profileData.write(to: profileURL)
        do { try coordinator.acknowledgeBrowserSaveFailure(); check("browser_running_acknowledgement_denied", false) }
        catch { check("browser_running_acknowledgement_denied", browser.acknowledgementCalls == 0 && browser.terminationSaveFailure == failure) }
        var receivedFailure: String?
        do { try await coordinator.requestTermination() }
        catch ApplicationTerminationFailure.browserSaveUnconfirmed(let message) { receivedFailure = message }
        catch { check("browser_save_gate_expected_error", false) }
        check("browser_unconfirmed_save_denies_quit_after_drain", receivedFailure == failure && failure != nil && browser.isTerminationWorkSettled && !coordinator.isReadyToTerminate)
        check("browser_save_gate_keeps_chat_and_profile", fixture.store.saves == beforeSaves && !browser.profileLeaseHeld && browser.terminationSaveFailure == failure)
        check("browser_save_gate_retains_profile_bytes", try Data(contentsOf: profileURL) == profileData)
        check("browser_save_gate_restores_admission", browser.restoreCalls == 1 && !browser.admissionClosed && !fixture.chat.isTerminationInProgress && !fixture.registry.isTerminationInProgress)
        try coordinator.acknowledgeBrowserSaveFailure()
        try await coordinator.requestTermination()
        check("browser_explicit_settled_acknowledgement_retries_persistence", browser.acknowledgementCalls == 1 && browser.terminationSaveFailure == nil && coordinator.isReadyToTerminate && fixture.store.saves > beforeSaves)
        check("browser_acknowledged_quit_retains_profile_bytes", try Data(contentsOf: profileURL) == profileData)
    } catch { check("browser_save_gate_fixture", false) }
    for stillQuit in [false, true] {
        let fixture = TerminationFixture(defaults: defaults)
        let browser = TerminationFixtureBrowser(settled: true, saveFailure: "未收到 Firefox 正常保存确认。资料盘保留。")
        let coordinator = ApplicationTerminationCoordinator(chat: fixture.chat, execution: fixture.execution,
            translation: fixture.translation, browser: browser, registry: fixture.registry)
        let delegate = ClaudeIsolationApplicationDelegate()
        delegate.terminationCoordinator = coordinator
        let beforeSaves = fixture.store.saves
        var replies: [Bool] = [], decisions: [String] = [], unexpectedFailures: [String] = []
        delegate.terminationReply = { replies.append($0) }
        delegate.terminationFailure = { unexpectedFailures.append($0) }
        delegate.browserSaveFailureDecision = { decisions.append($0); return stillQuit }
        check("browser_save_decision_intercepts_quit", delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        check(stillQuit ? "browser_still_quit_acknowledges_then_saves" : "browser_continue_keeps_app_and_save_gate", await terminationFixtureAwait {
            replies == [stillQuit] && decisions.count == 1 && unexpectedFailures.isEmpty &&
                coordinator.isReadyToTerminate == stillQuit && browser.acknowledgementCalls == (stillQuit ? 1 : 0) &&
                (stillQuit ? fixture.store.saves > beforeSaves : fixture.store.saves == beforeSaves && browser.terminationSaveFailure != nil)
        })
    }
    do {
        let fixture = TerminationFixture(defaults: defaults)
        let browser = TerminationFixtureBrowser(settled: true)
        let delegate = ClaudeIsolationApplicationDelegate()
        delegate.terminationCoordinator = ApplicationTerminationCoordinator(chat: fixture.chat, execution: fixture.execution,
            translation: fixture.translation, browser: browser, registry: fixture.registry)
        var replies: [Bool] = [], decisions = 0, failures: [String] = []
        delegate.terminationReply = { replies.append($0) }
        delegate.terminationFailure = { failures.append($0) }
        delegate.browserSaveFailureDecision = { _ in decisions += 1; return false }
        _ = delegate.applicationShouldTerminate(NSApplication.shared)
        check("browser_confirmed_save_exits_without_extra_prompt", await terminationFixtureAwait {
            replies == [true] && decisions == 0 && failures.isEmpty && browser.acknowledgementCalls == 0
        })
    }
    let registry = OwnedProcessRegistry()
    registry.beginLoginReset(); registry.beginTermination(); registry.endTermination()
    check("failed_quit_does_not_reopen_login_reset_gate", registry.isLoginResetInProgress && !registry.isTerminationInProgress)
    registry.endLoginReset()
    return checks
}
