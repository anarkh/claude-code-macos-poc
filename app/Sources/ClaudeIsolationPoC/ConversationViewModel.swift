import CryptoKit
import Foundation
import SwiftUI

/// Session state is owned by the app. Only complete user/assistant pairs enter the next text request.
@MainActor
final class ConversationViewModel: ObservableObject {
    @Published private(set) var conversations: [ConversationRecord] = []
    @Published var selectedID: UUID?
    @Published private(set) var persistenceError: String?
    @Published private(set) var diagnosticError: String?
    @Published private var projectDirectoryErrors: [UUID: String] = [:]
    @Published private(set) var translatingMessageIDs: Set<UUID> = []
    @Published private var activeConversationID: UUID?
    @Published private var status: String?
    @Published private(set) var isLoginResetInProgress = false
    @Published private(set) var isTerminationInProgress = false
    private var isWorkSuspended: Bool { isLoginResetInProgress || isTerminationInProgress }
    private let translation: TranslationViewModel
    private let execution: ExecutionViewModel
    private let translator: any TranslationProviding
    private let provider: any ChatProviding
    private let store: any ConversationPersisting
    private let translationCredentials: any AppCredentialStoring
    private let executionCredentials: any AppCredentialStoring
    private let subscriptionCredentials: any AppCredentialStoring
    private let fixtureOnly: Bool
    private let skills: SkillsViewModel?
    private let diagnostics: DiagnosticsSettingsModel
    private let diagnosticNow: () -> Date
    private var traceExpiryTask: Task<Void, Never>?
    private var pendingBodyCleanup = false
    private var activeTraceRequests: [String: (trace: ChatRequestTrace, capturedAt: Date)] = [:]
    private var captureBodiesForActiveRun = false
    private var bodyClearedForActiveRun = false
    private var canPersist = true
    private var saveTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var translationTasks: [UUID: Task<Void, Never>] = [:]
    private var activeToken: UUID?
    private var activeUserID: UUID?
    private var activeAssistantID: UUID?
    private var activeOriginal = ""
    private var activeProjectDirectory: String?
    private var activeToolActivities: [String: (tool: String, messageID: UUID)] = [:]

    init(translation: TranslationViewModel, execution: ExecutionViewModel,
         translator: any TranslationProviding, provider: any ChatProviding,
         store: any ConversationPersisting = FileConversationStore(),
         translationCredentials: any AppCredentialStoring = FileCredentialStore(scope: .translation),
         executionCredentials: any AppCredentialStoring = FileCredentialStore(scope: .execution),
         subscriptionCredentials: any AppCredentialStoring = FileCredentialStore(scope: .subscription),
         fixtureOnly: Bool = false, skills: SkillsViewModel? = nil,
         diagnostics: DiagnosticsSettingsModel? = nil, diagnosticNow: @escaping () -> Date = Date.init) {
        self.translation = translation; self.execution = execution
        self.translator = translator; self.provider = provider; self.store = store
        self.translationCredentials = translationCredentials; self.executionCredentials = executionCredentials
        self.subscriptionCredentials = subscriptionCredentials
        self.fixtureOnly = fixtureOnly
        self.skills = skills
        self.diagnostics = diagnostics ?? DiagnosticsSettingsModel()
        self.diagnosticNow = diagnosticNow
        do {
            let snapshot = try store.load()
            try snapshot.validate()
            conversations = snapshot.conversations
            selectedID = snapshot.selectedID ?? conversations.first?.id
            for index in conversations.indices {
                for message in conversations[index].messages.indices {
                    if [.translating, .running, .streaming].contains(conversations[index].messages[message].state) {
                        conversations[index].messages[message].state = .cancelled
                        conversations[index].messages[message].error = "上次执行已中断，可重新发送。"
                        if let traces = conversations[index].messages[message].requestTraces {
                            conversations[index].messages[message].requestTraces = traces.map { $0.markingInterrupted() }
                        }
                    }
                }
            }
        } catch {
            canPersist = false
            persistenceError = (error as? ConversationStoreFailure)?.message ?? "无法读取会话文件，原文件已保留。本次会话仅保存在内存中。"
        }
        if conversations.isEmpty { let record = ConversationRecord(); conversations = [record]; selectedID = record.id }
        expireRequestBodies()
    }

    deinit { traceExpiryTask?.cancel() }

    var selectedConversation: ConversationRecord? { conversations.first { $0.id == selectedID } }
    var messages: [ConversationMessage] { selectedConversation?.messages ?? [] }
    func requestTraces(for message: ConversationMessage, in conversation: ConversationRecord) -> [ChatRequestTrace] {
        requestDetailsMessage(for: message, in: conversation).requestTraces ?? []
    }
    func requestDetailsMessage(for message: ConversationMessage, in conversation: ConversationRecord) -> ConversationMessage {
        guard let runID = message.runID else { return message }
        return conversation.messages.first { $0.role == .assistant && $0.runID == runID } ?? message
    }
    var draft: String {
        get { selectedConversation?.draft ?? "" }
        set { guard !isWorkSuspended, let id = selectedID else { return }; mutate(id) { $0.draft = newValue }; scheduleSave() }
    }
    var targetLanguage: TargetLanguage {
        get { TargetLanguage(rawValue: selectedConversation?.targetLanguage ?? "en") ?? .english }
        set { guard !isWorkSuspended, let id = selectedID else { return }; mutate(id) { $0.targetLanguage = newValue.rawValue }; scheduleSave() }
    }
    var isBusy: Bool { activeToken != nil }
    var isCurrentConversationBusy: Bool { isBusy && activeConversationID == selectedID }
    var canSend: Bool { !isWorkSuspended && !isBusy && selectedID != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var activityStatus: String? { isCurrentConversationBusy ? status : nil }
    var projectDirectoryError: String? { selectedID.flatMap { projectDirectoryErrors[$0] } }
    var canChangeProjectDirectory: Bool { selectedID.map { canChangeProjectDirectory(in: $0) } ?? false }

    func canChangeProjectDirectory(in id: UUID) -> Bool {
        !isWorkSuspended && conversations.contains { $0.id == id } && !(isBusy && activeConversationID == id)
    }

    /// The picker passes its original session ID even if the selection changes while it is open.
    @discardableResult
    func setProjectDirectory(_ path: String?, for id: UUID) -> Bool {
        guard conversations.contains(where: { $0.id == id }) else { return false }
        guard canChangeProjectDirectory(in: id) else {
            projectDirectoryErrors[id] = "此会话正在执行或停止中，结束后才能更换执行目录。"
            return false
        }
        do {
            let normalized = try path.map { try ProjectDirectory.normalized($0) }
            mutate(id) { $0.projectDirectory = normalized }
            projectDirectoryErrors.removeValue(forKey: id)
            flushPersistence()
            return true
        } catch {
            projectDirectoryErrors[id] = errorMessage(error)
            return false
        }
    }

    func newConversation() {
        guard !isWorkSuspended else { return }
        let record = ConversationRecord()
        conversations.insert(record, at: 0); selectedID = record.id; flushPersistence()
    }
    func selectConversation(_ id: UUID) {
        guard !isWorkSuspended else { return }
        guard conversations.contains(where: { $0.id == id }) else { return }
        selectedID = id; flushPersistence()
    }
    func renameConversation(_ id: UUID, title: String) {
        guard !isWorkSuspended else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        mutate(id) { $0.title = String(title.prefix(120)) }; flushPersistence()
    }
    func deleteConversation(_ id: UUID) {
        guard !isWorkSuspended else { return }
        if activeConversationID == id { stop() }
        for message in conversations.first(where: { $0.id == id })?.messages ?? [] {
            translationTasks[message.id]?.cancel()
            translatingMessageIDs.remove(message.id)
        }
        conversations.removeAll { $0.id == id }
        projectDirectoryErrors.removeValue(forKey: id)
        if selectedID == id { selectedID = conversations.first?.id }
        if conversations.isEmpty { newConversation() } else { flushPersistence() }
    }

    func send() {
        guard canSend, let record = selectedConversation else { return }
        let project: ChatProject?
        do {
            project = try record.projectDirectory.map { directory in
                try validateBoundProjectDirectory(directory)
                return ChatProject(directory: directory)
            }
            projectDirectoryErrors.removeValue(forKey: record.id)
        } catch {
            projectDirectoryErrors[record.id] = errorMessage(error)
            return
        }
        let token = UUID(), userID = UUID(), original = record.draft
        activeToken = token; activeConversationID = record.id; activeUserID = userID
        activeAssistantID = nil; activeOriginal = original; status = "正在翻译输入…"
        activeProjectDirectory = project?.directory
        activeToolActivities.removeAll()
        captureBodiesForActiveRun = diagnostics.captureBodies
        bodyClearedForActiveRun = false
        activeTraceRequests.removeAll()
        mutate(record.id) {
            $0.draft = ""
            if $0.title == "新会话" { $0.title = String(original.trimmingCharacters(in: .whitespacesAndNewlines).prefix(36)) }
            $0.messages.append(.init(id: userID, role: .user, text: original, originalText: original, state: .translating, runID: token))
        }
        addActivity(record.id, "正在翻译输入…", state: .translating)
        flushPersistence()
        // Settings and credentials are captured only for this explicit Send action, before suspension.
        do {
            let textSkills = try skills?.enabledContexts() ?? []
            let inputRequest = try translationRequest(operation: "translate_input", text: original, target: record.targetLanguage)
            let executionProvider = execution.provider
            let key: String?, subscriptionToken: String?, model: String
            switch executionProvider {
            case .deepseekAPI:
                guard execution.baseURL == "https://api.deepseek.com/anthropic",
                      ["deepseek-flash[1m]", "deepseek-flash"].contains(execution.modelName) else {
                    throw ChatFailure.code("INVALID_PROFILE")
                }
                key = try credential(execution.apiKey, from: executionCredentials)
                subscriptionToken = nil
                model = execution.modelName
            case .claudeSubscription:
                guard ["sonnet", "opus", "haiku"].contains(execution.subscriptionModel) else {
                    throw ChatFailure.code("INVALID_PROFILE")
                }
                do {
                    if let accounts = execution.subscriptionAccounts {
                        subscriptionToken = try accounts.currentSelection().token
                    } else {
                        subscriptionToken = execution.subscriptionToken.isEmpty ? try subscriptionCredentials.load() : execution.subscriptionToken
                    }
                } catch SubscriptionAccountSelectionFailure.missingAccount {
                    throw ChatFailure.code("SUBSCRIPTION_ACCOUNT_REQUIRED")
                } catch SubscriptionAccountSelectionFailure.missingCredential {
                    throw ChatFailure.code("MISSING_SUBSCRIPTION_TOKEN")
                } catch { throw ChatFailure.code("CREDENTIAL_STORE_UNAVAILABLE") }
                guard let subscriptionToken else { throw ChatFailure.code("MISSING_SUBSCRIPTION_TOKEN") }
                do { try LocalCredentialFailure.validateSubscriptionToken(subscriptionToken) }
                catch { throw ChatFailure.code("INVALID_SUBSCRIPTION_TOKEN") }
                key = nil
                model = execution.subscriptionModel
            }
            runTask = Task { [weak self] in
                guard let self else { return }
                defer { self.finish(token) }
                do {
                    try Task.checkCancellation()
                    let reply = try await self.translator.translate(inputRequest)
                    try Task.checkCancellation()
                    let translated = try self.accept(reply, request: inputRequest)
                    guard self.isActive(token, in: record.id) else { return }
                    self.update(record.id, userID) { $0.text = translated; $0.state = .complete; $0.error = nil }
                    self.finishActivity(record.id, "输入已翻译为\(record.targetLanguage == "ja" ? "日语" : "英语")")
                    if !textSkills.isEmpty {
                        self.addActivity(record.id, "应用文本 Skills：\(textSkills.map(\.name).joined(separator: "、"))")
                    }
                    let assistantID = UUID()
                    self.activeAssistantID = assistantID
                    self.status = "正在启动 Claude Code…"
                    self.addActivity(record.id, "正在启动 Claude Code…", state: .running)
                    self.mutate(record.id) { $0.messages.append(.init(id: assistantID, role: .assistant, text: "", state: .running, runID: token, requestTraces: [])) }
                    if let project { try self.validateBoundProjectDirectory(project.directory) }
                    let request = ChatRequest(request_id: token.uuidString, apiKey: key, model: model,
                                              messages: self.transcript(record.id, latestUser: userID),
                                              provider: executionProvider, subscriptionToken: subscriptionToken, text_skills: textSkills,
                                              project: project, conversationSessionID: record.id)
                    var completed = false
                    for try await event in self.provider.events(for: request) {
                        try Task.checkCancellation()
                        guard self.isActive(token, in: record.id) else { return }
                        switch event {
                        case .started:
                            self.status = "模型正在回复…"
                            self.finishActivity(record.id, "Claude Code 已启动")
                        case .delta(let text):
                            self.update(record.id, assistantID) { $0.text += text; $0.state = .streaming }
                            self.scheduleSave()
                        case .completed(let text):
                            guard self.activeToolActivities.isEmpty else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
                            self.update(record.id, assistantID) { $0.text = text; $0.state = .complete }
                            self.addActivity(record.id, "回复完成")
                            completed = true
                        case .toolActivity(let tool, let phase, let toolID):
                            try self.acceptToolActivity(tool: tool, phase: phase, toolID: toolID, conversation: record.id)
                            self.flushPersistence()
                        case .requestTrace(let trace):
                            try self.acceptTrace(trace, runID: token, conversation: record.id, assistant: assistantID,
                                                 knownSecrets: [key, subscriptionToken].compactMap { $0 })
                            self.flushPersistence()
                        }
                    }
                    guard completed else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
                } catch {
                    self.failRun(token, conversation: record.id, user: userID, error: error)
                }
            }
        } catch {
            failRun(token, conversation: record.id, user: userID, error: error)
            finish(token)
        }
    }

    func stop() {
        guard isBusy, let id = activeConversationID else { return }
        status = "正在停止…"
        runTask?.cancel()
        if let messageID = activeAssistantID { update(id, messageID) {
            $0.state = .cancelled; $0.error = "已停止。"
            $0.requestTraces = $0.requestTraces?.map { $0.markingInterrupted() }
        } }
        else if let messageID = activeUserID { update(id, messageID) { $0.state = .cancelled; $0.error = "已停止。" } }
        finishToolActivities(in: id, state: .cancelled)
        finishActivity(id, "已停止", state: .cancelled)
        restoreDraft(id); flushPersistence()
    }

    func translateMessage(_ messageID: UUID) {
        guard !isWorkSuspended, let record = selectedConversation,
              let message = record.messages.first(where: { $0.id == messageID }),
              message.role == .assistant, message.state == .complete,
              !message.text.isEmpty, !translatingMessageIDs.contains(messageID) else { return }
        do {
            let request = try translationRequest(operation: "translate_output", text: message.text, target: "zh")
            translatingMessageIDs.insert(messageID)
            update(record.id, messageID) { $0.error = nil }
            translationTasks[messageID] = Task { [weak self] in
                guard let self else { return }
                defer { self.translatingMessageIDs.remove(messageID); self.translationTasks.removeValue(forKey: messageID); self.flushPersistence() }
                do {
                    try Task.checkCancellation()
                    let reply = try await self.translator.translate(request)
                    try Task.checkCancellation()
                    let text = try self.accept(reply, request: request)
                    self.update(record.id, messageID) { $0.translation = text; $0.error = nil }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.update(record.id, messageID) { $0.error = self.errorMessage(error) }
                }
            }
        } catch { update(record.id, messageID) { $0.error = errorMessage(error) }; flushPersistence() }
    }

    func flushPersistence() {
        saveTask?.cancel(); saveTask = nil
        pruneExpiredRequestBodies()
        guard canPersist else {
            if pendingBodyCleanup { diagnosticError = "诊断正文已从当前视图清理，但会话文件不可写，磁盘副本仍可能保留。请先解决会话文件错误。" }
            return
        }
        do {
            try store.save(.init(selectedID: selectedID, conversations: conversations))
            persistenceError = nil
            pendingBodyCleanup = false; diagnosticError = nil
        } catch {
            persistenceError = (error as? ConversationStoreFailure)?.message ?? "会话保存失败，请检查磁盘空间和访问权限。"
            if pendingBodyCleanup { diagnosticError = "诊断正文已从当前视图清理，但磁盘保存失败，旧副本仍可能保留。请检查权限和磁盘空间后重试。" }
        }
        scheduleTraceExpiration()
    }

    func expireRequestBodies() {
        pruneExpiredRequestBodies()
        if pendingBodyCleanup { flushPersistence() }
        else { scheduleTraceExpiration() }
    }

    func clearRequestBodies(conversationID: UUID? = nil, runID: UUID? = nil) {
        for index in conversations.indices where conversationID == nil || conversations[index].id == conversationID {
            for message in conversations[index].messages.indices {
                guard runID == nil || conversations[index].messages[message].runID == runID,
                      let traces = conversations[index].messages[message].requestTraces else { continue }
                let cleared = traces.map { $0.removingBody() }
                if cleared != traces {
                    conversations[index].messages[message].requestTraces = cleared
                    pendingBodyCleanup = true
                }
            }
        }
        if activeToken != nil, conversationID == nil || conversationID == activeConversationID,
           runID == nil || runID == activeToken {
            bodyClearedForActiveRun = true
        }
        if pendingBodyCleanup { flushPersistence() }
    }

    private func pruneExpiredRequestBodies() {
        let now = diagnosticNow()
        for index in conversations.indices {
            for message in conversations[index].messages.indices {
                guard let traces = conversations[index].messages[message].requestTraces else { continue }
                let retained = traces.map { $0.removingExpiredBody(now: now) }
                if retained != traces {
                    conversations[index].messages[message].requestTraces = retained
                    pendingBodyCleanup = true
                }
            }
        }
    }

    private func scheduleTraceExpiration() {
        traceExpiryTask?.cancel(); traceExpiryTask = nil
        guard !isTerminationInProgress else { return }
        let now = diagnosticNow()
        let next = conversations.flatMap(\.messages).flatMap { $0.requestTraces ?? [] }
            .filter(\.hasBody).compactMap(\.expiresAt).min()
        let wait = pendingBodyCleanup ? 60.0 : next.map { max(0.01, $0.timeIntervalSince(now)) }
        guard let wait else { return }
        traceExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(min(wait, 86_400))) }
            catch { return } // Rescheduling or closing the view model cancels this timer.
            self?.expireRequestBodies()
        }
    }
    func beginLoginReset() {
        isLoginResetInProgress = true
        stop()
        for task in translationTasks.values { task.cancel() }
        saveTask?.cancel(); saveTask = nil
    }
    func drainForLoginReset(timeoutSeconds: Double = 8) async throws {
        guard isLoginResetInProgress else { throw LoginResetLifecycleFailure.notStarted }
        try await waitForLoginReset(timeoutSeconds: timeoutSeconds) {
            self.runTask == nil && !self.isBusy && self.translationTasks.isEmpty
        }
    }
    func endLoginReset() { isLoginResetInProgress = false }

    /// Starts with no previous conversation transcript while retaining every
    /// existing record. Do not claim completion until the exact snapshot reads back.
    func completeLoginReset() throws {
        guard isLoginResetInProgress else { throw LoginResetLifecycleFailure.notStarted }
        guard runTask == nil, !isBusy, translationTasks.isEmpty else { throw LoginResetLifecycleFailure.workStillRunning }
        guard canPersist else { throw LoginResetLifecycleFailure.conversationReadbackFailed }
        let record = ConversationRecord()
        let snapshot = ConversationSnapshot(selectedID: record.id, conversations: [record] + conversations)
        do {
            try store.save(snapshot)
            guard try store.load() == snapshot else { throw LoginResetLifecycleFailure.conversationReadbackFailed }
        } catch {
            persistenceError = "新会话保存或回读验证失败，已有会话已保留。"
            throw LoginResetLifecycleFailure.conversationReadbackFailed
        }
        conversations = snapshot.conversations; selectedID = record.id
        persistenceError = nil
    }

    var isTerminationWorkSettled: Bool { runTask == nil && !isBusy && translationTasks.isEmpty }
    func beginTermination() {
        isTerminationInProgress = true
        traceExpiryTask?.cancel(); traceExpiryTask = nil
        stop()
        for task in translationTasks.values { task.cancel() }
        saveTask?.cancel(); saveTask = nil
    }
    func endTermination() { isTerminationInProgress = false; expireRequestBodies() }

    /// Only persist after cancelled tasks have released their captured state.
    /// Quit keeps the current selection, history, draft and all credentials.
    func persistForTermination() throws {
        guard isTerminationInProgress, isTerminationWorkSettled else {
            throw ApplicationTerminationFailure.drainTimedOut(["聊天与消息翻译"])
        }
        guard canPersist else { throw ApplicationTerminationFailure.persistenceFailed }
        pruneExpiredRequestBodies()
        let snapshot = ConversationSnapshot(selectedID: selectedID, conversations: conversations)
        do {
            try store.save(snapshot)
            guard try store.load() == snapshot else { throw ApplicationTerminationFailure.persistenceFailed }
            persistenceError = nil
            pendingBodyCleanup = false; diagnosticError = nil
        } catch {
            persistenceError = "会话保存或回读验证失败，App 已保持打开。请检查磁盘空间和数据目录权限后重试退出。"
            throw ApplicationTerminationFailure.persistenceFailed
        }
    }

    // Cancellation alone is insufficient for App quit; the application delegate
    // uses ApplicationTerminationCoordinator to await every task and owned worker.
    func shutdown() { beginTermination(); flushPersistence() }

    private func translationRequest(operation: String, text: String, target: String) throws -> TranslationRequest {
        let key = try credential(translation.apiKey, from: translationCredentials)
        let model = ModelConfiguration(endpoint: translation.endpoint, model: translation.modelName, apiKey: key)
        try TranslationPublicConfiguration(endpoint: model.endpoint, model: model.model).validate()
        return .init(request_id: UUID().uuidString, operation: operation, text: text, target: target, model: model)
    }
    private func credential(_ inMemory: String, from store: any AppCredentialStoring) throws -> String {
        if !inMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return inMemory }
        do {
            guard let key = try store.load(), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatFailure.code("MISSING_KEY") }
            return key
        } catch let error as ChatFailure { throw error }
        catch { throw ChatFailure.code("CREDENTIAL_STORE_UNAVAILABLE") }
    }
    private func accept(_ reply: TranslationReply, request: TranslationRequest) throws -> String {
        guard reply.ok else { throw TranslationFailure.code(reply.error_code ?? "TRANSLATION_RESPONSE_INVALID") }
        guard reply.fixture_only == fixtureOnly, reply.original == request.text,
              let text = reply.translated, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let id = reply.request_id, UUID(uuidString: id) != nil,
              let revision = reply.revision, revision > 0,
              reply.requires_confirmation == (request.operation == "translate_input"),
              reply.translation_sha256 == SHA256.hash(data: Data(text.utf8)).map({ String(format: "%02x", $0) }).joined() else {
            throw TranslationFailure.code("TRANSLATION_RESPONSE_INVALID")
        }
        return text
    }
    private func transcript(_ conversation: UUID, latestUser: UUID) -> [ChatTranscriptMessage] {
        var result: [ChatTranscriptMessage] = [], pending: ConversationMessage?
        for message in conversations.first(where: { $0.id == conversation })?.messages ?? [] {
            if message.id == latestUser { result.append(.init(role: "user", text: message.text)); break }
            guard message.role != .activity else { continue }
            if message.role == .user { pending = message.state == .complete ? message : nil }
            else {
                if message.state == .complete, let user = pending {
                    result.append(.init(role: "user", text: user.text)); result.append(.init(role: "assistant", text: message.text))
                }
                pending = nil
            }
        }
        return result
    }
    private func isActive(_ token: UUID, in id: UUID) -> Bool { activeToken == token && conversations.contains { $0.id == id } }
    private func acceptTrace(_ trace: ChatRequestTrace, runID: UUID, conversation: UUID, assistant: UUID, knownSecrets: [String]) throws {
        try trace.validate(runID: runID, knownSecrets: knownSecrets)
        guard trace.schema == "claude-request-trace/v1",
              let record = conversations.first(where: { $0.id == conversation }),
              let message = record.messages.first(where: { $0.id == assistant && $0.runID == runID }) else {
            throw ChatFailure.code("CHAT_RESPONSE_INVALID")
        }
        var traces = message.requestTraces ?? []
        if let index = traces.firstIndex(where: { $0.attemptID == trace.attemptID }) {
            guard traces[index].phase == .request, trace.phase != .request,
                  let original = activeTraceRequests[trace.attemptID], original.trace.hasSameRequest(as: trace) else {
                throw ChatFailure.code("CHAT_RESPONSE_INVALID")
            }
            var retained = trace.persisted(captureBody: captureBodiesForActiveRun, capturedAt: original.capturedAt)
                .removingExpiredBody(now: diagnosticNow())
            if bodyClearedForActiveRun { retained = retained.removingBody() }
            traces[index] = retained
            activeTraceRequests.removeValue(forKey: trace.attemptID)
        } else {
            guard trace.phase == .request, traces.count < (activeProjectDirectory == nil ? 3 : ChatProject.maximumRequests), trace.attempt == traces.count + 1,
                  traces.allSatisfy({ $0.phase != .request }) else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
            let capturedAt = diagnosticNow()
            activeTraceRequests[trace.attemptID] = (trace, capturedAt)
            var retained = trace.persisted(captureBody: captureBodiesForActiveRun, capturedAt: capturedAt)
            if bodyClearedForActiveRun { retained = retained.removingBody() }
            traces.append(retained)
        }
        update(conversation, assistant) { $0.requestTraces = traces }
    }
    private func finish(_ token: UUID) {
        guard activeToken == token else { return }
        if let id = activeConversationID { projectDirectoryErrors.removeValue(forKey: id) }
        activeToken = nil; activeConversationID = nil; activeUserID = nil; activeAssistantID = nil
        activeTraceRequests.removeAll(); captureBodiesForActiveRun = false; bodyClearedForActiveRun = false
        activeProjectDirectory = nil; activeToolActivities.removeAll()
        status = nil; runTask = nil; activeOriginal = ""; flushPersistence()
    }
    private func failRun(_ token: UUID, conversation: UUID, user: UUID, error: Error) {
        guard isActive(token, in: conversation) else { return }
        let cancelled = error is CancellationError || Task.isCancelled
        let text = cancelled ? "已停止。" : errorMessage(error)
        update(conversation, activeAssistantID ?? user) {
            $0.state = cancelled ? .cancelled : .failed; $0.error = text
            if cancelled { $0.requestTraces = $0.requestTraces?.map { $0.markingInterrupted() } }
        }
        finishToolActivities(in: conversation, state: cancelled ? .cancelled : .failed)
        finishActivity(conversation, cancelled ? "已停止" : "执行失败", state: cancelled ? .cancelled : .failed)
        restoreDraft(conversation)
    }
    private func restoreDraft(_ id: UUID) { mutate(id) { if $0.draft.isEmpty { $0.draft = activeOriginal } } }
    private func errorMessage(_ error: Error) -> String {
        if let error = error as? TranslationFailure { return error.message }
        if let error = error as? ChatFailure { return error.message }
        if let error = error as? ExecutionConfigurationError { return error.message }
        if let error = error as? TranslationConfigurationError { return error.message }
        if let error = error as? TextSkillFailure { return error.message }
        if let error = error as? ProjectDirectoryFailure { return error.message }
        if let error = error as? BoundProjectDirectoryFailure { return error.message }
        return "执行失败，请检查设置和网络后重试。"
    }
    private func validateBoundProjectDirectory(_ directory: String) throws {
        guard try ProjectDirectory.normalized(directory) == directory else {
            throw BoundProjectDirectoryFailure.locationChanged
        }
    }

    private func acceptToolActivity(tool: String, phase: String, toolID: String, conversation: UUID) throws {
        let labels = ["Read": "读取文件", "Write": "写入文件", "Edit": "编辑文件", "Bash": "运行项目命令", "Glob": "查找文件", "Grep": "搜索内容"]
        guard activeProjectDirectory != nil, let label = labels[tool], !toolID.isEmpty else {
            throw ChatFailure.code("CHAT_RESPONSE_INVALID")
        }
        switch phase {
        case "started":
            guard activeToolActivities[toolID] == nil else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
            let messageID = UUID()
            activeToolActivities[toolID] = (tool, messageID)
            mutate(conversation) { $0.messages.append(.init(id: messageID, role: .activity, text: "\(label)（\(tool)）：开始", state: .running)) }
            status = "正在\(label)…"
        case "completed", "failed":
            guard let activity = activeToolActivities[toolID], activity.tool == tool else {
                throw ChatFailure.code("CHAT_RESPONSE_INVALID")
            }
            activeToolActivities.removeValue(forKey: toolID)
            update(conversation, activity.messageID) {
                $0.text = "\(label)（\(tool)）：\(phase == "failed" ? "失败" : "完成")"
                $0.state = phase == "failed" ? .failed : .complete
            }
            if activeToolActivities.isEmpty { status = "模型正在回复…" }
        default: throw ChatFailure.code("CHAT_RESPONSE_INVALID")
        }
    }

    private func finishToolActivities(in conversation: UUID, state: ConversationMessageState) {
        for activity in activeToolActivities.values {
            update(conversation, activity.messageID) {
                $0.text = "\(activity.tool)：\(state == .cancelled ? "已停止" : "执行失败")"
                $0.state = state
            }
        }
        activeToolActivities.removeAll()
    }

    private func mutate(_ id: UUID, _ action: (inout ConversationRecord) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        action(&conversations[index]); conversations[index].updatedAt = Date()
    }
    private func update(_ conversation: UUID, _ message: UUID, _ action: (inout ConversationMessage) -> Void) {
        mutate(conversation) { record in
            guard let index = record.messages.firstIndex(where: { $0.id == message }) else { return }
            action(&record.messages[index])
        }
    }
    private func addActivity(_ id: UUID, _ text: String, state: ConversationMessageState = .complete) {
        mutate(id) { $0.messages.append(.init(role: .activity, text: text, state: state)) }
    }
    private func finishActivity(_ id: UUID, _ text: String, state: ConversationMessageState = .complete) {
        mutate(id) { record in
            if let index = record.messages.lastIndex(where: { $0.role == .activity && [.translating, .running].contains($0.state) }) {
                record.messages[index].text = text; record.messages[index].state = state
            } else { record.messages.append(.init(role: .activity, text: text, state: state)) }
        }
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flushPersistence()
        }
    }
}

/// Explicit test modes never write or replace the user's real conversation file.
final class MemoryConversationStore: ConversationPersisting {
    var snapshot: ConversationSnapshot
    init(_ snapshot: ConversationSnapshot = .empty) { self.snapshot = snapshot }
    func load() throws -> ConversationSnapshot { snapshot }
    func save(_ snapshot: ConversationSnapshot) throws { try snapshot.validate(); self.snapshot = snapshot }
}

private enum BoundProjectDirectoryFailure: Error {
    case locationChanged
    var message: String { "执行目录的位置已变化。请重新选择目录，确认允许访问的位置后重试。" }
}
