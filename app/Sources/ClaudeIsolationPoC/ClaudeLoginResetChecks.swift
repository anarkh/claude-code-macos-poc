import CryptoKit
import Darwin
import Foundation

private actor LoginResetCheckTranslator: TranslationProviding {
    private var held: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    init(held: Bool = false) { self.held = held }
    func translate(_ request: TranslationRequest) async throws -> TranslationReply {
        calls += 1
        // Keep the worker alive after cancellation so the coordinator must drain it.
        if held { await withCheckedContinuation { waiters.append($0) } }
        let translated = "Offline translated fixture"
        return .init(ok: true, request_id: request.request_id, original: request.text, translated: translated,
                     revision: 1, translation_sha256: SHA256.hash(data: Data(translated.utf8)).map { String(format: "%02x", $0) }.joined(),
                     requires_confirmation: request.operation == "translate_input", error_code: nil, fixture_only: true)
    }
    func release() {
        held = false
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class LoginResetCheckChat: ChatProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func events(for request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock(); count += 1; lock.unlock()
        return AsyncThrowingStream { $0.finish(throwing: ChatFailure.code("UNEXPECTED_FIXTURE_CHAT")) }
    }
}

private final class LoginResetCheckTokenStore: AppCredentialStoring {
    let file: FileCredentialStore
    private(set) var deleteCount = 0
    init(file: FileCredentialStore) { self.file = file }
    func load() throws -> String? { try file.load() }
    func save(_ key: String) throws { try file.save(key) }
    func delete() throws { try file.delete(); deleteCount += 1 }
}

@MainActor
private struct LoginResetCheckFixture {
    static let token = "sk-ant-oat01-coordinator-fake-token"
    static let executionKey = "coordinator-fake-execution-key"
    static let translationKey = "coordinator-fake-translation-key"
    let tokens: FileCredentialStore
    private let tokenCounter: LoginResetCheckTokenStore?
    var tokenDeleteCount: Int? { tokenCounter?.deleteCount }
    let executionKeyStore: FileCredentialStore
    let translationKeyStore: FileCredentialStore
    let execution: ExecutionViewModel
    let translation: TranslationViewModel
    let chat: ConversationViewModel
    let chatProvider: LoginResetCheckChat
    let conversationStore: FileConversationStore
    let original: ConversationSnapshot
    let model: ClaudeLoginResetModel

    init(root: URL, defaults: UserDefaults, runtimeRoot: URL,
         translator: LoginResetCheckTranslator = .init(), processAlive: @escaping (Int32) -> Bool = { _ in false },
         externalHome: URL? = nil, countTokenDeletes: Bool = false) throws {
        let credentials = root.appendingPathComponent("Credentials", isDirectory: true)
        tokens = .init(scope: .subscription, directoryURL: credentials)
        tokenCounter = countTokenDeletes ? .init(file: tokens) : nil
        let subscriptionCredentials: any AppCredentialStoring
        if let tokenCounter { subscriptionCredentials = tokenCounter } else { subscriptionCredentials = tokens }
        executionKeyStore = .init(scope: .execution, directoryURL: credentials)
        translationKeyStore = .init(scope: .translation, directoryURL: credentials)
        try tokens.save(Self.token)
        try executionKeyStore.save(Self.executionKey)
        try translationKeyStore.save(Self.translationKey)
        translation = .init(provider: translator, configurationStore: .init(defaults: defaults), credentials: translationKeyStore)
        translation.apiKey = Self.translationKey
        translation.inputText = "保留翻译输入草稿"; translation.outputText = "保留翻译输出草稿"
        translation.saveConfiguration()
        execution = .init(store: .init(defaults: defaults), credentials: executionKeyStore, subscriptionCredentials: subscriptionCredentials)
        execution.provider = .claudeSubscription; execution.modelName = "deepseek-flash[1m]"; execution.subscriptionModel = "opus"
        execution.apiKey = Self.executionKey; execution.subscriptionToken = Self.token
        execution.saveConfiguration()
        let selected = ConversationRecord(title: "原会话", draft: "保留原会话草稿", messages: [
            .init(role: .user, text: "保留用户原文", translation: "Retained input"),
            .init(role: .assistant, text: "Retained answer", translation: "保留回答译文")
        ])
        let other = ConversationRecord(title: "其他会话", draft: "保留其他草稿", targetLanguage: "ja", messages: [
            .init(role: .assistant, text: "Other retained answer")
        ])
        original = .init(selectedID: selected.id, conversations: [selected, other])
        conversationStore = .init(fileURL: root.appendingPathComponent("History/conversations.json"))
        try conversationStore.save(original)
        chatProvider = .init()
        chat = .init(translation: translation, execution: execution, translator: translator, provider: chatProvider,
                     store: conversationStore, translationCredentials: translationKeyStore, executionCredentials: executionKeyStore,
                     subscriptionCredentials: subscriptionCredentials, fixtureOnly: true)
        model = .init(chat: chat, execution: execution, translation: translation,
                      runtime: .init(tempRoot: runtimeRoot, processAlive: processAlive),
                      externalScanner: .init(home: externalHome ?? root.appendingPathComponent("ExternalHome")), timeoutSeconds: 2)
    }
}

@MainActor
private func loginResetCheckAwait(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
    }
    return false
}

private struct LoginResetCheckMetadata: Equatable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    init(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw OwnedRuntimeCleanupFailure.scanUnavailable }
        device = info.st_dev; inode = info.st_ino; mode = info.st_mode; size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }
}

@MainActor
func claudeLoginResetChecks() async -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { checks.append(("claude_login_reset_" + name, passed)) }
    let manager = FileManager.default
    let suite = "com.claude-isolation-poc.coordinator-checks." + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suite) else { return [("claude_login_reset_preferences_fixture", false)] }
    // macOS Foundation can normalize /private/var back to /var. Inject the
    // physical POSIX path so the runtime's no-follow ancestor traversal is valid.
    guard let physical = realpath(manager.temporaryDirectory.path, nil) else {
        defaults.removePersistentDomain(forName: suite)
        return [("claude_login_reset_physical_temp", false)]
    }
    let temporary = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        .appendingPathComponent("login-reset-coordinator-" + UUID().uuidString)
    free(physical)
    defer {
        OwnedProcessRegistry.shared.endLoginReset()
        defaults.removePersistentDomain(forName: suite)
        do { if manager.fileExists(atPath: temporary.path) { try manager.removeItem(at: temporary) } }
        catch { check("fixture_cleanup", false) }
    }
    var sequence = 0
    func scope() throws -> (URL, URL) {
        sequence += 1
        let root = temporary.appendingPathComponent("case-\(sequence)")
        let runtime = root.appendingPathComponent("Runtime", isDirectory: true)
        try manager.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (root, runtime)
    }
    func makeRun(_ runtime: URL, pid: Int32 = 12_345, state: String = "not-started") throws -> URL {
        let run = runtime.appendingPathComponent("claude-deepseek-chat-ABC123", isDirectory: true)
        try manager.createDirectory(at: run, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(run.path, &info) == 0 else { throw OwnedRuntimeCleanupFailure.invalidDirectory }
        let manifest: [String: Any] = ["schema": "claude-isolation-owned-run/v1", "run_id": UUID().uuidString,
            "uid": getuid(), "pid": pid, "kind": "chat", "directory_dev": String(UInt32(bitPattern: info.st_dev)),
            "directory_ino": String(info.st_ino), "native_state": state, "native_pid": NSNull()]
        let receipt = run.appendingPathComponent(OwnedRuntimeCleanupService.manifestName)
        try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys).write(to: receipt)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        return run
    }
    do {
        let (root, runtime) = try scope(), run = try makeRun(runtime)
        let unrelated = runtime.appendingPathComponent("unrelated-preserved.txt")
        try Data("unrelated fixture".utf8).write(to: unrelated)
        try Data("fake transient state".utf8).write(to: run.appendingPathComponent("state.json"))
        let fixture = try LoginResetCheckFixture(root: root, defaults: defaults, runtimeRoot: runtime)
        let executionBytes = try Data(contentsOf: fixture.executionKeyStore.fileURL)
        let translationBytes = try Data(contentsOf: fixture.translationKeyStore.fileURL)
        let executionConfiguration = defaults.data(forKey: ExecutionConfigurationStore.storageKey)
        let translationConfiguration = defaults.data(forKey: TranslationConfigurationStore.storageKey)
        fixture.model.prepare(); fixture.model.scanExternal()
        check("default_has_no_external_rows", !fixture.model.inspectExternal && fixture.model.externalLocations.isEmpty)
        check("prepare_finds_owned_runtime_without_deleting_token", try fixture.model.runtimeSummary.contains("可清理 1 项") && fixture.tokens.load() == LoginResetCheckFixture.token && manager.fileExists(atPath: fixture.tokens.fileURL.path))
        await fixture.model.reset()
        check("coordinator_completes_and_releases_gates", fixture.model.error == nil && fixture.model.result != nil && fixture.model.progress == "完成" && !fixture.model.isBusy && !fixture.chat.isLoginResetInProgress && !fixture.execution.isLoginResetInProgress && !fixture.translation.isLoginResetInProgress)
        let reopenedTokens = FileCredentialStore(scope: .subscription, directoryURL: fixture.tokens.directoryURL)
        check("token_removed_from_file_cache_and_bound_input", try fixture.execution.subscriptionToken.isEmpty && fixture.tokens.load() == nil && reopenedTokens.load() == nil && !manager.fileExists(atPath: fixture.tokens.fileURL.path))
        let reopenedExecution = ExecutionViewModel(store: .init(defaults: defaults), credentials: fixture.executionKeyStore, subscriptionCredentials: reopenedTokens)
        reopenedExecution.restoreSavedSubscriptionTokenForSettings()
        check("reopened_settings_cannot_restore_old_token", reopenedExecution.subscriptionToken.isEmpty)
        let persisted = try FileConversationStore(fileURL: fixture.conversationStore.fileURL).load()
        check("empty_new_session_and_history_drafts_survive_reopen", fixture.chat.messages.isEmpty && fixture.chat.draft.isEmpty && fixture.chat.selectedID != fixture.original.selectedID && Array(fixture.chat.conversations.dropFirst()) == fixture.original.conversations && persisted.conversations == fixture.chat.conversations && persisted.selectedID == fixture.chat.selectedID)
        check("deepseek_credentials_preserved_in_memory_and_files", try fixture.execution.apiKey == LoginResetCheckFixture.executionKey && fixture.translation.apiKey == LoginResetCheckFixture.translationKey && Data(contentsOf: fixture.executionKeyStore.fileURL) == executionBytes && Data(contentsOf: fixture.translationKeyStore.fileURL) == translationBytes)
        check("public_profiles_and_translation_drafts_preserved", defaults.data(forKey: ExecutionConfigurationStore.storageKey) == executionConfiguration && defaults.data(forKey: TranslationConfigurationStore.storageKey) == translationConfiguration && fixture.execution.provider == .claudeSubscription && fixture.execution.subscriptionModel == "opus" && fixture.execution.modelName == "deepseek-flash[1m]" && fixture.translation.inputText == "保留翻译输入草稿" && fixture.translation.outputText == "保留翻译输出草稿")
        check("owned_runtime_cleaned_and_unrelated_file_preserved", !manager.fileExists(atPath: run.path) && manager.fileExists(atPath: unrelated.path) && fixture.model.runtimeSummary.contains("已删除 1 项"))
        check("reset_does_not_start_chat_or_external_scan", fixture.chatProvider.calls == 0 && fixture.model.externalLocations.isEmpty)
    } catch { check("successful_reset_fixture", false) }

    for failure in ["unavailable", "symlink"] {
        do {
            let (root, runtime) = try scope()
            let injected = root.appendingPathComponent("UnavailableRuntime")
            if failure == "symlink" { try manager.createSymbolicLink(at: injected, withDestinationURL: runtime) }
            let fixture = try LoginResetCheckFixture(root: root, defaults: defaults, runtimeRoot: injected)
            fixture.model.prepare()
            check(failure + "_prepare_reports_scan_failure", fixture.model.runtimeSummary.contains("暂时无法检查"))
            await fixture.model.reset()
            let reopened = FileCredentialStore(scope: .subscription, directoryURL: fixture.tokens.directoryURL)
            check(failure + "_runtime_blocks_before_token_delete", try fixture.model.error?.contains("尚未删除 Token") == true && fixture.model.result == nil && manager.fileExists(atPath: fixture.tokens.fileURL.path) && reopened.load() == LoginResetCheckFixture.token && fixture.execution.subscriptionToken == LoginResetCheckFixture.token)
            check(failure + "_runtime_preserves_conversation_and_releases_gate", try fixture.chat.conversations == fixture.original.conversations && fixture.chat.selectedID == fixture.original.selectedID && fixture.conversationStore.load() == fixture.original && !fixture.model.isBusy && !fixture.chat.isLoginResetInProgress && !fixture.execution.isLoginResetInProgress && !fixture.translation.isLoginResetInProgress)
        } catch { check(failure + "_runtime_fixture", false) }
    }

    for ownerState in ["active", "pending"] {
        do {
            let (root, runtime) = try scope()
            let run = try makeRun(runtime, state: ownerState == "pending" ? "pending" : "not-started")
            let receipt = run.appendingPathComponent(OwnedRuntimeCleanupService.manifestName)
            let before = try Data(contentsOf: receipt)
            let fixture = try LoginResetCheckFixture(root: root, defaults: defaults, runtimeRoot: runtime, processAlive: { ownerState == "active" && $0 == 12_345 })
            await fixture.model.reset()
            check(ownerState + "_owner_blocks_before_token_delete", try fixture.model.error?.contains("尚未删除 Token") == true && manager.fileExists(atPath: fixture.tokens.fileURL.path) && fixture.tokens.load() == LoginResetCheckFixture.token && fixture.execution.subscriptionToken == LoginResetCheckFixture.token)
            check(ownerState + "_owner_retains_runtime_and_history", try Data(contentsOf: receipt) == before && fixture.conversationStore.load() == fixture.original && fixture.chat.selectedID == fixture.original.selectedID)
        } catch { check(ownerState + "_owner_fixture", false) }
    }

    do {
        let (root, runtime) = try scope(), translator = LoginResetCheckTranslator(held: true)
        let fixture = try LoginResetCheckFixture(root: root, defaults: defaults, runtimeRoot: runtime, translator: translator, countTokenDeletes: true)
        let translation = Task { await fixture.translation.translateInput() }
        check("singleflight_translation_fixture_started", await loginResetCheckAwait { await translator.calls == 1 })
        let first = Task { await fixture.model.reset() }
        let busy = await loginResetCheckAwait { fixture.model.isBusy && fixture.translation.isLoginResetInProgress }
        await fixture.model.reset()
        fixture.model.prepare(); fixture.model.inspectExternal = true; fixture.model.scanExternal()
        check("singleflight_duplicate_cannot_clear_token_or_open_session", busy && fixture.model.isBusy && fixture.tokenDeleteCount == 0 && fixture.chat.conversations == fixture.original.conversations && fixture.model.externalLocations.isEmpty)
        await translator.release(); await translation.value; await first.value
        check("singleflight_completes_once_after_actual_drain", fixture.model.error == nil && !fixture.model.isBusy && fixture.tokenDeleteCount == 1 && fixture.chat.conversations.count == fixture.original.conversations.count + 1 && fixture.chat.messages.isEmpty && fixture.chat.draft.isEmpty)
        check("cancelled_translation_cannot_publish_or_start_chat", fixture.translation.inputTranslation == nil && fixture.translation.inputText == "保留翻译输入草稿" && fixture.chatProvider.calls == 0)
    } catch { check("singleflight_fixture", false) }

    do {
        let (root, runtime) = try scope()
        let home = root.appendingPathComponent("ExternalHome", isDirectory: true)
        let cliFile = home.appendingPathComponent(".claude.json"), cliDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let link = appSupport.appendingPathComponent("Claude-3p")
        let target = root.appendingPathComponent("ExternalLinkTarget", isDirectory: true)
        try manager.createDirectory(at: cliDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        let cliBytes = Data("not JSON; fake external account, project and MCP settings".utf8)
        let historyBytes = Data("fake external skill and history sentinel".utf8)
        let targetBytes = Data("fake linked account sentinel".utf8)
        let history = cliDirectory.appendingPathComponent("retain.txt"), targetFile = target.appendingPathComponent("retain.txt")
        try cliBytes.write(to: cliFile); try historyBytes.write(to: history); try targetBytes.write(to: targetFile)
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        // The scanner must still classify inaccessible content from metadata.
        defer {
            let restoredFile = chmod(cliFile.path, 0o600), restoredDirectory = chmod(cliDirectory.path, 0o700)
            if restoredFile != 0 || restoredDirectory != 0 { check("external_fixture_permissions_restored", false) }
        }
        guard chmod(cliFile.path, 0) == 0, chmod(cliDirectory.path, 0) == 0 else { throw OwnedRuntimeCleanupFailure.scanUnavailable }
        let fileBefore = try LoginResetCheckMetadata(cliFile), directoryBefore = try LoginResetCheckMetadata(cliDirectory)
        let linkBefore = try LoginResetCheckMetadata(link), targetBefore = try LoginResetCheckMetadata(targetFile)
        let fixture = try LoginResetCheckFixture(root: root, defaults: defaults, runtimeRoot: runtime, externalHome: home)
        fixture.model.scanExternal()
        check("external_scan_requires_explicit_opt_in", fixture.model.externalLocations.isEmpty && !fixture.model.inspectExternal)
        fixture.model.inspectExternal = true; fixture.model.scanExternal()
        let rows = fixture.model.externalLocations
        check("external_metadata_classifies_present_absent_and_link", rows.count == 10 && rows.first(where: { $0.id == ".claude.json" })?.status == .present && rows.first(where: { $0.id == ".claude" })?.status == .present && rows.first(where: { $0.id == "Library/Application Support/Claude" })?.status == .absent && rows.first(where: { $0.id == "Library/Application Support/Claude-3p" })?.status == .link)
        check("external_links_and_manual_locations_have_no_reveal_target", rows.first(where: { $0.id == "Library/Application Support/Claude-3p" })?.revealURL == nil && rows.filter { $0.status == .manual }.count == 2 && rows.filter { $0.status != .present }.allSatisfy { $0.revealURL == nil })
        await fixture.model.reset()
        check("external_metadata_preserved_through_scan_and_reset", try LoginResetCheckMetadata(cliFile) == fileBefore && LoginResetCheckMetadata(cliDirectory) == directoryBefore && LoginResetCheckMetadata(link) == linkBefore && LoginResetCheckMetadata(targetFile) == targetBefore && fixture.model.error == nil)
        guard chmod(cliFile.path, 0o600) == 0, chmod(cliDirectory.path, 0o700) == 0 else { throw OwnedRuntimeCleanupFailure.scanUnavailable }
        check("external_content_and_link_unchanged", try Data(contentsOf: cliFile) == cliBytes && Data(contentsOf: history) == historyBytes && Data(contentsOf: targetFile) == targetBytes && manager.destinationOfSymbolicLink(atPath: link.path) == target.path)
        fixture.model.inspectExternal = false
        check("external_opt_out_clears_rows", fixture.model.externalLocations.isEmpty)
        fixture.model.inspectExternal = true; fixture.model.scanExternal(); fixture.model.prepare()
        check("prepare_restores_no_external_scan_default", !fixture.model.inspectExternal && fixture.model.externalLocations.isEmpty)
    } catch { check("external_metadata_fixture", false) }
    return checks
}
