import CryptoKit
import Foundation

/// Exercises the conversation contract without calling a provider, accessing Keychain, or opening a window.
@MainActor
func conversationViewModelChecks() async -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { checks.append(("conversation: \(name)", passed)) }
    let suiteName = "conversation-checks-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        return [("conversation: isolated preferences available", false)]
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    do {
        let harness = ConversationCheckHarness(defaults: defaults)
        check("startup reads neither credential scope", harness.translationKey.loads == 0 && harness.executionKey.loads == 0)
        let startupRequests = await harness.translator.requests()
        check("startup calls neither provider", startupRequests.isEmpty && harness.chat.requests().isEmpty)
        harness.vm.draft = "请解释这个程序"
        harness.vm.send()
        let finished = await conversationCheckWait { !harness.vm.isBusy }
        let user = harness.vm.messages.first { $0.role == .user }
        let assistant = harness.vm.messages.first { $0.role == .assistant }
        let translationRequests = await harness.translator.requests()
        let chatRequests = harness.chat.requests()
        check("send completes without a separate translation approval", finished && assistant?.state == .complete)
        check("translated input becomes the sent user message", user?.text == "en:请解释这个程序" && user?.originalText == "请解释这个程序" && chatRequests.first?.messages.last?.text == user?.text)
        check("raw assistant whitespace, Unicode and code survive streaming", assistant?.text == ConversationCheckChat.rawReply)
        check("output is not translated automatically", translationRequests.count == 1 && translationRequests.first?.operation == "translate_input" && assistant?.translation == nil)
        check("send reads only the two app credential scopes", harness.translationKey.loads == 1 && harness.executionKey.loads == 1)
        check("conversation shows completed execution activity", harness.vm.messages.contains { $0.role == .activity && $0.text == "回复完成" && $0.state == .complete })
        if let assistant {
            harness.vm.translateMessage(assistant.id)
            let translated = await conversationCheckWait { !harness.vm.translatingMessageIDs.contains(assistant.id) }
            let final = harness.vm.messages.first { $0.id == assistant.id }
            let requests = await harness.translator.requests()
            check("explicit button stores Chinese below the assistant response", translated && final?.translation == "中文译文：\(ConversationCheckChat.rawReply)")
            check("Chinese translation never changes the original reply", final?.text == assistant.text && final?.state == .complete)
            check("output translation uses the full raw response and zh", requests.count == 2 && requests.last?.operation == "translate_output" && requests.last?.text == assistant.text && requests.last?.target == "zh")
        } else {
            check("explicit button stores Chinese below the assistant response", false)
            check("Chinese translation never changes the original reply", false)
            check("output translation uses the full raw response and zh", false)
        }
        harness.vm.draft = "再说一句"
        harness.vm.targetLanguage = .japanese
        harness.vm.send()
        let secondFinished = await conversationCheckWait { !harness.vm.isBusy }
        let secondRequests = harness.chat.requests()
        let expected = ["en:请解释这个程序", ConversationCheckChat.rawReply, "ja:再说一句"]
        check("next turn sends complete original conversation pairs", secondFinished && secondRequests.count == 2 && secondRequests.last?.messages.map(\.text) == expected && secondRequests.last?.messages.map(\.role) == ["user", "assistant", "user"])
        harness.vm.flushPersistence()
        if let bytes = try? JSONEncoder().encode(harness.store.snapshot) {
            check("conversation persistence contains no API credentials", !String(decoding: bytes, as: UTF8.self).contains("conversation-check-key"))
        } else { check("conversation persistence contains no API credentials", false) }
        harness.vm.shutdown()
    }

    do {
        let first = ConversationRecord(title: "已有会话", messages: [
            .init(role: .user, text: "complete user"),
            .init(role: .assistant, text: "complete assistant"),
            .init(role: .user, text: "failed user", state: .failed),
            .init(role: .assistant, text: "partial assistant", state: .cancelled),
            .init(role: .user, text: "orphan complete user"),
            .init(role: .activity, text: "old activity")
        ])
        let store = MemoryConversationStore(.init(selectedID: first.id, conversations: [first]))
        let harness = ConversationCheckHarness(defaults: defaults, store: store)
        harness.vm.draft = "下一轮"
        harness.vm.send()
        let finished = await conversationCheckWait { !harness.vm.isBusy }
        check("failed, cancelled, orphan and activity records never enter history", finished && harness.chat.requests().first?.messages.map(\.text) == ["complete user", "complete assistant", "en:下一轮"])
        harness.vm.shutdown()
    }

    do {
        let harness = ConversationCheckHarness(defaults: defaults)
        let firstID = harness.vm.selectedID!
        harness.vm.draft = "第一会话的草稿"
        harness.vm.targetLanguage = .japanese
        harness.vm.newConversation()
        let secondID = harness.vm.selectedID!
        harness.vm.draft = "第二会话的草稿"
        harness.vm.renameConversation(firstID, title: "  项目讨论  ")
        harness.vm.selectConversation(firstID)
        check("switch restores the selected session's draft and language", harness.vm.draft == "第一会话的草稿" && harness.vm.targetLanguage == .japanese)
        check("rename preserves conversation identity and content", harness.vm.selectedConversation?.id == firstID && harness.vm.selectedConversation?.title == "项目讨论")
        harness.vm.selectConversation(secondID)
        check("other session draft remains independent", harness.vm.draft == "第二会话的草稿" && harness.vm.targetLanguage == .english)
        harness.vm.flushPersistence()
        let restored = ConversationCheckHarness(defaults: defaults, store: harness.store)
        check("selected session, titles and drafts persist across restart", restored.vm.selectedID == secondID && restored.vm.draft == "第二会话的草稿" && restored.vm.conversations.first { $0.id == firstID }?.title == "项目讨论")
        harness.vm.deleteConversation(firstID)
        check("deleting an inactive conversation preserves the selected draft", harness.vm.selectedID == secondID && harness.vm.draft == "第二会话的草稿" && !harness.vm.conversations.contains { $0.id == firstID })
        harness.vm.deleteConversation(secondID)
        check("deleting the final conversation leaves one usable empty session", harness.vm.conversations.count == 1 && harness.vm.selectedID != nil && harness.vm.messages.isEmpty && harness.vm.draft.isEmpty)
        harness.vm.shutdown(); restored.vm.shutdown()
    }

    do {
        let interrupted = ConversationRecord(messages: [
            .init(role: .user, text: "翻译中的输入", state: .translating),
            .init(role: .assistant, text: "partial\n", state: .streaming),
            .init(role: .activity, text: "模型运行中", state: .running),
            .init(role: .assistant, text: "finished", translation: "已完成", state: .complete)
        ])
        let store = MemoryConversationStore(.init(selectedID: interrupted.id, conversations: [interrupted]))
        let harness = ConversationCheckHarness(defaults: defaults, store: store)
        check("restart marks unfinished messages cancelled and keeps partial text", harness.vm.messages.prefix(3).allSatisfy { $0.state == .cancelled && $0.error != nil } && harness.vm.messages[1].text == "partial\n")
        check("restart preserves completed original and translated messages", harness.vm.messages.last?.text == "finished" && harness.vm.messages.last?.translation == "已完成" && harness.vm.messages.last?.state == .complete)
        let restartedRequests = await harness.translator.requests()
        check("restart never resumes network or reads a credential", !harness.vm.isBusy && harness.chat.requests().isEmpty && restartedRequests.isEmpty && harness.translationKey.loads == 0 && harness.executionKey.loads == 0)
        harness.vm.flushPersistence()
        check("interruption state persists when the session is next saved", store.snapshot.conversations.first?.messages.prefix(3).allSatisfy { $0.state == .cancelled } == true)
        harness.vm.shutdown()
    }

    do {
        let chat = ConversationCheckChat(automatic: false)
        let harness = ConversationCheckHarness(defaults: defaults, chat: chat)
        let firstID = harness.vm.selectedID!
        harness.vm.draft = "正在执行的会话"
        harness.vm.send()
        let started = await conversationCheckWait { chat.requests().count == 1 }
        harness.vm.newConversation()
        let secondID = harness.vm.selectedID!
        harness.vm.draft = "新会话草稿"
        chat.emit(.delta(" 原始流式 "))
        let arrived = await conversationCheckWait { harness.vm.conversations.first { $0.id == firstID }?.messages.contains { $0.role == .assistant && $0.text == " 原始流式 " } == true }
        check("switching sessions during streaming keeps events on the originating session", started && arrived && harness.vm.selectedID == secondID && harness.vm.messages.isEmpty && harness.vm.draft == "新会话草稿")
        check("another session stays editable while the single execution remains busy", harness.vm.isBusy && !harness.vm.isCurrentConversationBusy && !harness.vm.canSend && harness.vm.activityStatus == nil)
        chat.emit(.completed(" 原始流式 ")); chat.finish()
        let finished = await conversationCheckWait { !harness.vm.isBusy }
        check("background completion does not change the selected session", finished && harness.vm.selectedID == secondID && harness.vm.draft == "新会话草稿" && harness.vm.conversations.first { $0.id == firstID }?.messages.contains { $0.role == .assistant && $0.state == .complete } == true)
        harness.vm.shutdown()
    }

    do {
        let chat = ConversationCheckChat(automatic: false)
        let harness = ConversationCheckHarness(defaults: defaults, chat: chat)
        harness.vm.draft = "停止流式回复"
        harness.vm.send()
        let started = await conversationCheckWait { chat.requests().count == 1 }
        chat.emit(.delta("部分原文\n 👋 "))
        let arrived = await conversationCheckWait { harness.vm.messages.contains { $0.role == .assistant && $0.text == "部分原文\n 👋 " } }
        harness.vm.draft = "下一次发送"
        harness.vm.stop()
        let stopped = await conversationCheckWait { !harness.vm.isBusy }
        chat.emit(.delta("不应该追加的旧结果")); chat.emit(.completed("不应该替换的旧结果")); chat.finish()
        let assistant = harness.vm.messages.first { $0.role == .assistant }
        check("stopping a stream keeps partial original text and cancellation visible", started && arrived && stopped && assistant?.text == "部分原文\n 👋 " && assistant?.state == .cancelled && assistant?.error != nil)
        check("late cancelled stream events cannot replace text or the edited draft", assistant?.text == "部分原文\n 👋 " && harness.vm.draft == "下一次发送")
        harness.vm.send()
        let restarted = await conversationCheckWait { chat.requests().count == 2 }
        check("the next request excludes a stopped partial conversation pair", restarted && chat.requests().last?.messages.map(\.text) == ["en:下一次发送"])
        chat.emit(.delta("new reply")); chat.emit(.completed("new reply")); chat.finish()
        check("a stopped stream leaves the conversation usable for a new turn", await conversationCheckWait { !harness.vm.isBusy } && harness.vm.messages.last { $0.role == .assistant }?.state == .complete)
        harness.vm.shutdown()
    }

    do {
        let translator = ConversationCheckTranslator(holdInputs: true)
        let harness = ConversationCheckHarness(defaults: defaults, translator: translator)
        let deletedID = harness.vm.selectedID!
        harness.vm.draft = "删除运行中的会话"
        harness.vm.send()
        let translating = await conversationCheckWaitAsync { await translator.requests().count == 1 }
        harness.vm.deleteConversation(deletedID)
        await translator.releaseInputs()
        let finished = await conversationCheckWait { !harness.vm.isBusy }
        check("deleting during translation cannot resurrect the session or start the CLI", translating && finished && !harness.vm.conversations.contains { $0.id == deletedID } && harness.chat.requests().isEmpty)
        check("late deleted-session result cannot affect the replacement session", harness.vm.conversations.count == 1 && harness.vm.messages.isEmpty && harness.vm.selectedID != deletedID)
        harness.vm.shutdown()
    }

    do {
        let translator = ConversationCheckTranslator(holdInputs: true)
        let harness = ConversationCheckHarness(defaults: defaults, translator: translator)
        harness.vm.draft = "发送前的输入"
        harness.vm.send()
        let translating = await conversationCheckWaitAsync { await translator.requests().count == 1 }
        harness.vm.draft = "执行期间编辑的下一条"
        harness.vm.stop()
        await translator.releaseInputs()
        let finished = await conversationCheckWait { !harness.vm.isBusy }
        check("stop preserves a draft edited while execution was active", translating && finished && harness.vm.draft == "执行期间编辑的下一条")
        check("late cancelled input never reaches chat execution", harness.chat.requests().isEmpty && harness.vm.messages.first { $0.role == .user }?.state == .cancelled)
        harness.vm.shutdown()
    }

    do {
        let translator = ConversationCheckTranslator(holdInputs: true)
        let harness = ConversationCheckHarness(defaults: defaults, translator: translator)
        harness.vm.draft = "需要恢复的原稿"
        harness.vm.send()
        _ = await conversationCheckWaitAsync { await translator.requests().count == 1 }
        harness.vm.stop()
        await translator.releaseInputs()
        let finished = await conversationCheckWait { !harness.vm.isBusy }
        check("stop restores the original input when the next draft is empty", finished && harness.vm.draft == "需要恢复的原稿" && harness.chat.requests().isEmpty)
        harness.vm.shutdown()
    }

    do {
        let translator = ConversationCheckTranslator(badHash: true)
        let harness = ConversationCheckHarness(defaults: defaults, translator: translator)
        harness.vm.draft = "不接受错误摘要"
        harness.vm.send()
        let finished = await conversationCheckWait { !harness.vm.isBusy }
        check("a bad translation digest fails visibly and never starts chat", finished && harness.chat.requests().isEmpty && harness.vm.messages.first { $0.role == .user }?.state == .failed && harness.vm.messages.first { $0.role == .user }?.error != nil)
        check("failed input translation restores the editable draft", harness.vm.draft == "不接受错误摘要")
        harness.vm.shutdown()
    }

    do {
        let translator = ConversationCheckTranslator(holdInputs: true)
        let harness = ConversationCheckHarness(defaults: defaults, translator: translator)
        harness.translation.apiKey = "original-translation-memory-key"
        harness.execution.apiKey = "original-execution-memory-key"
        harness.vm.targetLanguage = .japanese
        harness.vm.draft = "发送时捕获配置"
        harness.vm.send()
        _ = await conversationCheckWaitAsync { await translator.requests().count == 1 }
        harness.translation.modelName = "new-translation-model"
        harness.translation.endpoint = "https://example.com/new-endpoint"
        harness.translation.apiKey = "changed-translation-memory-key"
        harness.execution.modelName = "deepseek-flash"
        harness.execution.apiKey = "changed-execution-memory-key"
        harness.vm.targetLanguage = .english
        await translator.releaseInputs()
        let finished = await conversationCheckWait { !harness.vm.isBusy }
        let translated = await translator.requests().first
        let request = harness.chat.requests().first
        check("in-flight translation keeps the send-time model, credential and target", translated?.model.model == "deepseek-flash" && translated?.model.endpoint == "https://api.deepseek.com/chat/completions" && translated?.model.apiKey == "original-translation-memory-key" && translated?.target == "ja")
        check("in-flight CLI execution keeps the send-time model and credential", finished && request?.model == "deepseek-flash[1m]" && request?.apiKey == "original-execution-memory-key" && request?.messages.last?.text == "ja:发送时捕获配置")
        check("in-memory settings credentials avoid any Keychain read", harness.translationKey.loads == 0 && harness.executionKey.loads == 0)
        harness.vm.shutdown()
    }

    do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-corrupt-check-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("conversations.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let original = Data("{\"schemaVersion\":999,\"conversations\":[]}".utf8)
            try original.write(to: file)
            let harness = ConversationCheckHarness(defaults: defaults, persistence: FileConversationStore(fileURL: file))
            harness.vm.draft = "内存中的草稿"
            harness.vm.newConversation()
            harness.vm.flushPersistence()
            let persistedBytes = try Data(contentsOf: file)
            let corruptStartupRequests = await harness.translator.requests()
            check("a corrupt or future-version store stays visible and unchanged", harness.vm.persistenceError != nil && persistedBytes == original)
            check("a corrupt store still provides a usable in-memory conversation", harness.vm.selectedID != nil && !harness.vm.conversations.isEmpty && harness.chat.requests().isEmpty && corruptStartupRequests.isEmpty)
            harness.vm.shutdown()
            try FileManager.default.removeItem(at: directory)
        } catch {
            check("a corrupt or future-version store stays visible and unchanged", false)
            check("a corrupt store still provides a usable in-memory conversation", false)
            try? FileManager.default.removeItem(at: directory)
        }
    }
    do {
        let selected = TextSkill(name: "reply-style", content: "Keep `example()` unchanged. 日本語の指示。", isEnabled: true)
        let disabled = TextSkill(name: "unused", content: "This disabled instruction must not be sent.")
        let skills = SkillsViewModel(store: MemoryTextSkillStore(.init(skills: [selected, disabled])))
        let translator = ConversationCheckTranslator(holdInputs: true)
        let harness = ConversationCheckHarness(defaults: defaults, translator: translator, skills: skills)
        harness.vm.draft = "只翻译我的输入"
        harness.vm.send()
        _ = await conversationCheckWaitAsync { await translator.requests().count == 1 }
        skills.setEnabled(selected.id, enabled: false)
        await translator.releaseInputs()
        let finished = await conversationCheckWait { !harness.vm.isBusy }
        let request = harness.chat.requests().first
        let translations = await translator.requests()
        check("enabled text skills are captured before translation and keep their original language", finished && request?.text_skills == [.init(name: selected.name, content: selected.content)])
        check("disabled skills and skill instructions never enter the translation request or user transcript", translations.first?.text == "只翻译我的输入" && request?.messages.last?.text == "en:只翻译我的输入" && request?.text_skills.contains { $0.name == disabled.name } == false)
        check("execution timeline names the applied text skills", harness.vm.messages.contains { $0.role == .activity && $0.text == "应用文本 Skills：reply-style" })
        harness.vm.draft = "下次停用"
        harness.vm.send()
        _ = await conversationCheckWaitAsync { await translator.requests().count == 2 }
        await translator.releaseInputs()
        let nextFinished = await conversationCheckWait { !harness.vm.isBusy }
        check("settings changes apply to the next request", nextFinished && harness.chat.requests().last?.text_skills.isEmpty == true)
        harness.vm.shutdown()
    }

    do {
        let store = MemoryTextSkillStore()
        store.loadFailure = .invalidFormat
        let harness = ConversationCheckHarness(defaults: defaults, skills: SkillsViewModel(store: store))
        harness.vm.draft = "Skills 损坏时保留草稿"
        harness.vm.send()
        let requests = await harness.translator.requests()
        check("a broken skill store blocks send before credential or provider access", !harness.vm.isBusy && requests.isEmpty && harness.chat.requests().isEmpty && harness.translationKey.loads == 0 && harness.executionKey.loads == 0)
        check("a broken skill store shows an actionable error and restores the draft", harness.vm.draft == "Skills 损坏时保留草稿" && harness.vm.messages.first { $0.role == .user }?.error?.contains("Skills") == true)
        harness.vm.shutdown()
    }
    do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-local-credentials-\(UUID().uuidString)")
        defer {
            do { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
            catch { check("local credential fixture cleanup", false) }
        }
        let firstTranslationStore = FileCredentialStore(scope: .translation, directoryURL: directory)
        let firstExecutionStore = FileCredentialStore(scope: .execution, directoryURL: directory)
        try firstTranslationStore.save("conversation-file-translation-key")
        try firstExecutionStore.save("conversation-file-execution-key")
        // A new instance exercises the same cold-start file load as the App.
        let translationStore = FileCredentialStore(scope: .translation, directoryURL: directory)
        let executionStore = FileCredentialStore(scope: .execution, directoryURL: directory)
        let translator = ConversationCheckTranslator(), provider = ConversationCheckChat()
        let translation = TranslationViewModel(provider: translator, configurationStore: .init(defaults: defaults), credentials: translationStore)
        let execution = ExecutionViewModel(store: .init(defaults: defaults), credentials: executionStore)
        translation.endpoint = "https://api.deepseek.com/chat/completions"; translation.modelName = "deepseek-flash"
        execution.baseURL = "https://api.deepseek.com/anthropic"; execution.modelName = "deepseek-flash[1m]"
        let vm = ConversationViewModel(translation: translation, execution: execution, translator: translator,
            provider: provider, store: MemoryConversationStore(), translationCredentials: translationStore, executionCredentials: executionStore)
        check("file credential cold start keeps settings inputs empty", translation.apiKey.isEmpty && execution.apiKey.isEmpty)
        vm.draft = "第一次自动读取"; vm.send()
        let firstFinished = await conversationCheckWait { !vm.isBusy }
        let firstInput = await translator.requests().first
        check("first send automatically reads both saved local files", firstFinished && firstInput?.model.apiKey == "conversation-file-translation-key" && provider.requests().first?.apiKey == "conversation-file-execution-key")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("translation-key.json"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("execution-key.json"))
        vm.draft = "第二次复用内存"; vm.send()
        let secondFinished = await conversationCheckWait { !vm.isBusy }
        check("later sends reuse cached credentials without disk reads", secondFinished && provider.requests().count == 2 && provider.requests().last?.apiKey == "conversation-file-execution-key")
        if let reply = vm.messages.last(where: { $0.role == .assistant }) {
            vm.translateMessage(reply.id)
            let translated = await conversationCheckWait { !vm.translatingMessageIDs.contains(reply.id) }
            let outputRequest = await translator.requests().last
            check("output translation reuses the shared translation cache", translated && outputRequest?.operation == "translate_output" && outputRequest?.model.apiKey == "conversation-file-translation-key")
        } else { check("output translation reuses the shared translation cache", false) }
        execution.apiKey = "conversation-file-updated-execution-key"; execution.saveKey(); execution.apiKey = ""
        vm.draft = "保存新 Key 后使用"; vm.send()
        let updatedFinished = await conversationCheckWait { !vm.isBusy }
        check("settings save updates the next send shared file cache", updatedFinished && execution.error == nil && provider.requests().last?.apiKey == "conversation-file-updated-execution-key")
        execution.deleteKey()
        let previousRequests = provider.requests().count
        vm.draft = "删除 Key 后失败"; vm.send()
        check("settings delete prevents cached credential reuse", !vm.isBusy && execution.apiKey.isEmpty && provider.requests().count == previousRequests && vm.draft == "删除 Key 后失败" && vm.messages.last(where: { $0.role == .user })?.error != nil)
        vm.shutdown()
    } catch { check("local credential integration fixture setup", false) }
    do {
        let harness = ConversationCheckHarness(defaults: defaults)
        harness.execution.provider = .claudeSubscription
        harness.execution.subscriptionModel = "sonnet"
        harness.execution.apiKey = "unused-deepseek-key-must-not-be-sent"
        harness.vm.draft = "订阅模式解释代码"
        harness.vm.send()
        let finished = await conversationCheckWait { !harness.vm.isBusy }
        let request = harness.chat.requests().first
        let translated = await harness.translator.requests().first
        check("subscription sends only OAuth token and selected model", finished && request?.provider == .claudeSubscription && request?.subscriptionToken == "sk-ant-oat01-conversation-offline-fixture" && request?.apiKey == nil && request?.model == "sonnet")
        check("subscription execution never reads DeepSeek execution key", harness.executionKey.loads == 0 && harness.subscriptionKey.loads == 1)
        check("subscription input translation keeps DeepSeek key and endpoint", translated?.model.apiKey == "conversation-check-key" && translated?.model.endpoint == "https://api.deepseek.com/chat/completions" && translated?.model.model == "deepseek-flash")
        if let assistant = harness.vm.messages.last(where: { $0.role == .assistant }) {
            harness.vm.translateMessage(assistant.id)
            let done = await conversationCheckWait { !harness.vm.translatingMessageIDs.contains(assistant.id) }
            let replyTranslation = await harness.translator.requests().last
            check("subscription output translation still uses independent DeepSeek", done && replyTranslation?.target == "zh" && replyTranslation?.model.apiKey == "conversation-check-key")
        } else { check("subscription output translation still uses independent DeepSeek", false) }
        harness.execution.provider = .deepseekAPI
        harness.vm.draft = "切换回 DeepSeek"
        harness.vm.send()
        let switched = await conversationCheckWait { !harness.vm.isBusy }
        let apiRequest = harness.chat.requests().last
        check("switching back uses preserved DeepSeek key without subscription token", switched && apiRequest?.provider == .deepseekAPI && apiRequest?.apiKey == "unused-deepseek-key-must-not-be-sent" && apiRequest?.subscriptionToken == nil)
        check("provider switch preserves conversation history", apiRequest?.messages.count == 3 && apiRequest?.messages.first?.text == request?.messages.first?.text)
        check("credentials never enter persisted conversation text", !harness.vm.messages.contains { $0.text.contains("sk-ant-oat01") || $0.text.contains("unused-deepseek-key") })
        harness.vm.shutdown()
    }
    do {
        let harness = ConversationCheckHarness(defaults: defaults)
        harness.execution.provider = .claudeSubscription
        try harness.subscriptionKey.delete()
        harness.vm.draft = "缺少订阅 Token"
        harness.vm.send()
        let requests = await harness.translator.requests()
        check("missing subscription token blocks before provider and restores draft", !harness.vm.isBusy && requests.isEmpty && harness.chat.requests().isEmpty && harness.vm.draft == "缺少订阅 Token" && harness.vm.messages.last(where: { $0.role == .user })?.error?.contains("setup-token") == true)
        check("missing subscription token never falls back to DeepSeek", harness.executionKey.loads == 0)
        harness.vm.shutdown()
    } catch { check("subscription missing token fixture setup", false) }
    do {
        let translator = ConversationCheckTranslator(holdInputs: true)
        let harness = ConversationCheckHarness(defaults: defaults, translator: translator)
        harness.execution.provider = .claudeSubscription
        harness.vm.draft = "模式切换期间保持请求快照"
        harness.vm.send()
        let translating = await conversationCheckWaitAsync { await translator.requests().count == 1 }
        harness.execution.provider = .deepseekAPI
        harness.execution.subscriptionToken = "sk-ant-oat01-different-offline-fixture"
        harness.execution.subscriptionModel = "opus"
        await translator.releaseInputs()
        let finished = await conversationCheckWait { !harness.vm.isBusy }
        let captured = harness.chat.requests().first
        check("inflight subscription snapshot survives settings changes", translating && finished && captured?.provider == .claudeSubscription && captured?.model == "sonnet" && captured?.subscriptionToken == "sk-ant-oat01-conversation-offline-fixture" && captured?.apiKey == nil)
        harness.vm.shutdown()
    }
    do {
        let chat = ConversationCheckChat(automatic: false)
        let harness = ConversationCheckHarness(defaults: defaults, chat: chat)
        harness.vm.draft = "查看同一次请求"
        harness.vm.send()
        let launched = await conversationCheckWait { !chat.requests().isEmpty }
        if launched, let request = chat.requests().first, let runID = UUID(uuidString: request.request_id) {
            let requestTrace = requestTraceFixture(runID: runID)
            let persistedRequest = requestTrace.persisted(captureBody: false, capturedAt: Date(timeIntervalSince1970: 0))
            chat.emit(.requestTrace(requestTrace))
            let recorded = await conversationCheckWait { harness.vm.messages.last(where: { $0.role == .assistant })?.requestTraces?.count == 1 }
            if let record = harness.vm.selectedConversation, let user = record.messages.first(where: { $0.role == .user }),
               let assistant = record.messages.first(where: { $0.role == .assistant }) {
                check("user and assistant share the same live attempt", recorded && user.runID == runID && assistant.runID == runID && user.requestTraces == nil && harness.vm.requestTraces(for: user, in: record) == [persistedRequest] && harness.vm.requestTraces(for: assistant, in: record) == [persistedRequest])
                check("user request sheet follows assistant execution state", harness.vm.requestDetailsMessage(for: user, in: record).id == assistant.id && harness.vm.requestDetailsMessage(for: user, in: record).state == .running)
            } else { check("user and assistant share the same live attempt", false) }
            let response = requestTraceFixture(runID: runID, phase: .response)
            let persistedResponse = response.persisted(captureBody: false, capturedAt: Date(timeIntervalSince1970: 0))
            chat.emit(.requestTrace(response)); chat.emit(.delta(ConversationCheckChat.rawReply)); chat.emit(.completed(ConversationCheckChat.rawReply)); chat.finish()
            let finished = await conversationCheckWait { !harness.vm.isBusy }
            if let record = harness.vm.selectedConversation, let assistant = record.messages.first(where: { $0.role == .assistant }),
               let user = record.messages.first(where: { $0.role == .user }) {
                check("terminal trace replaces its attempt while retaining only its summary", finished && assistant.requestTraces == [persistedResponse] && harness.vm.requestTraces(for: user, in: record) == [persistedResponse])
                harness.vm.translateMessage(assistant.id)
                _ = await conversationCheckWait { !harness.vm.translatingMessageIDs.contains(assistant.id) }
                let translated = harness.vm.messages.first { $0.id == assistant.id }
                check("output translation leaves the CLI trace unchanged", translated?.translation != nil && translated?.requestTraces == [persistedResponse] && chat.requests().count == 1)
                let restored = ConversationCheckHarness(defaults: defaults, store: harness.store)
                if let saved = restored.vm.selectedConversation, let savedUser = saved.messages.first(where: { $0.role == .user }) {
                    check("restart preserves trace lookup for both messages", restored.vm.requestTraces(for: savedUser, in: saved) == [persistedResponse] && restored.chat.requests().isEmpty)
                } else { check("restart preserves trace lookup for both messages", false) }
                restored.vm.shutdown()
            } else { check("terminal trace replaces its attempt while retaining only its summary", false) }
        } else { check("trace test obtains a CLI run", false) }
        harness.vm.shutdown()
    }
    do {
        let chat = ConversationCheckChat(automatic: false)
        let harness = ConversationCheckHarness(defaults: defaults, chat: chat)
        harness.vm.draft = "请求失败时保存"
        harness.vm.send()
        _ = await conversationCheckWait { !chat.requests().isEmpty }
        if let request = chat.requests().first, let runID = UUID(uuidString: request.request_id) {
            let requestTrace = requestTraceFixture(runID: runID)
            let failedTrace = requestTraceFixture(runID: runID, phase: .error)
            let persistedFailure = failedTrace.persisted(captureBody: false, capturedAt: Date(timeIntervalSince1970: 0))
            chat.emit(.requestTrace(requestTrace)); chat.emit(.requestTrace(failedTrace)); chat.fail(.code("PROVIDER_CONNECTION_FAILED"))
            let finished = await conversationCheckWait { !harness.vm.isBusy }
            let assistant = harness.vm.messages.first { $0.role == .assistant }
            check("failed reply retains request summary and transport outcome", finished && assistant?.state == .failed && assistant?.requestTraces == [persistedFailure] && harness.vm.draft == "请求失败时保存")
            let restored = ConversationCheckHarness(defaults: defaults, store: harness.store)
            check("failed trace is readable after restart without replay", restored.vm.messages.first(where: { $0.role == .assistant })?.requestTraces == [persistedFailure] && restored.chat.requests().isEmpty)
            restored.vm.shutdown()
        } else { check("failed trace fixture run", false) }
        harness.vm.shutdown()
    }
    do {
        let chat = ConversationCheckChat(automatic: false)
        let harness = ConversationCheckHarness(defaults: defaults, chat: chat)
        harness.vm.draft = "停止后保留请求"
        harness.vm.send()
        _ = await conversationCheckWait { !chat.requests().isEmpty }
        if let request = chat.requests().first, let runID = UUID(uuidString: request.request_id) {
            let requestTrace = requestTraceFixture(runID: runID)
            let persistedRequest = requestTrace.persisted(captureBody: false, capturedAt: Date(timeIntervalSince1970: 0))
            chat.emit(.requestTrace(requestTrace))
            _ = await conversationCheckWait { harness.vm.messages.first(where: { $0.role == .assistant })?.requestTraces?.count == 1 }
            let restored = ConversationCheckHarness(defaults: defaults, store: harness.store)
            let cancelled = persistedRequest.markingInterrupted()
            check("restart marks an unfinished request cancelled without inventing time", restored.vm.messages.first(where: { $0.role == .assistant })?.state == .cancelled && restored.vm.messages.first(where: { $0.role == .assistant })?.requestTraces == [cancelled] && restored.chat.requests().isEmpty)
            restored.vm.shutdown()
            harness.vm.stop(); chat.finish()
            let stopped = await conversationCheckWait { !harness.vm.isBusy }
            check("stop keeps request summary and cancellation on the same run", stopped && harness.vm.messages.first(where: { $0.role == .assistant })?.requestTraces == [cancelled] && harness.vm.draft == "停止后保留请求")
        } else { check("cancel trace fixture run", false) }
        harness.vm.shutdown()
    }
    do {
        let chat = ConversationCheckChat(automatic: false)
        let harness = ConversationCheckHarness(defaults: defaults, chat: chat)
        harness.vm.draft = "阻止凭据进入请求记录"
        harness.vm.send()
        _ = await conversationCheckWait { !chat.requests().isEmpty }
        if let request = chat.requests().first, let runID = UUID(uuidString: request.request_id) {
            let body = "{\"model\":\"deepseek-flash[1m]\",\"messages\":[{\"content\":\"conversation-check-key\"}]}"
            chat.emit(.requestTrace(requestTraceFixture(runID: runID, body: body))); chat.finish()
            let finished = await conversationCheckWait { !harness.vm.isBusy }
            check("known credential is rejected before any trace persists", finished && harness.vm.messages.first(where: { $0.role == .assistant })?.state == .failed && harness.store.snapshot.conversations.flatMap(\.messages).allSatisfy { ($0.requestTraces ?? []).isEmpty })
        } else { check("credential trace fixture run", false) }
        harness.vm.shutdown()
    }
    do {
        let harness = ConversationCheckHarness(defaults: defaults, translator: ConversationCheckTranslator(badHash: true))
        harness.vm.draft = "翻译失败没有CLI请求"
        harness.vm.send()
        let finished = await conversationCheckWait { !harness.vm.isBusy }
        check("input translation failure never creates a CLI request trace", finished && harness.chat.requests().isEmpty && harness.vm.messages.allSatisfy { $0.requestTraces == nil })
        harness.vm.shutdown()
    }
    checks += await conversationProjectLifecycleChecks(defaults: defaults)
    checks += await conversationPrivacyLifecycleChecks(defaults: defaults)
    return checks
}

@MainActor
private struct ConversationCheckHarness {
    let translator: ConversationCheckTranslator
    let chat: ConversationCheckChat
    let translationKey = ConversationCheckCredential()
    let executionKey = ConversationCheckCredential()
    let subscriptionKey = ConversationCheckCredential("sk-ant-oat01-conversation-offline-fixture")
    let store: MemoryConversationStore
    let translation: TranslationViewModel
    let execution: ExecutionViewModel
    let vm: ConversationViewModel

    init(defaults: UserDefaults,
         translator: ConversationCheckTranslator = .init(),
         chat: ConversationCheckChat = .init(),
         store: MemoryConversationStore = .init(),
         persistence: (any ConversationPersisting)? = nil, skills: SkillsViewModel? = nil,
         diagnostics: DiagnosticsSettingsModel? = nil, diagnosticNow: @escaping () -> Date = Date.init) {
        self.translator = translator; self.chat = chat; self.store = store
        translation = TranslationViewModel(provider: translator, configurationStore: .init(defaults: defaults), credentials: translationKey)
        translation.endpoint = "https://api.deepseek.com/chat/completions"
        translation.modelName = "deepseek-flash"
        execution = ExecutionViewModel(store: .init(defaults: defaults), credentials: executionKey, subscriptionCredentials: subscriptionKey)
        execution.baseURL = "https://api.deepseek.com/anthropic"
        execution.modelName = "deepseek-flash[1m]"
        vm = ConversationViewModel(translation: translation, execution: execution, translator: translator,
                                   provider: chat, store: persistence ?? store,
                                   translationCredentials: translationKey, executionCredentials: executionKey, subscriptionCredentials: subscriptionKey, skills: skills,
                                   diagnostics: diagnostics, diagnosticNow: diagnosticNow)
    }
}

private final class ConversationCheckCredential: AppCredentialStoring {
    var loads = 0
    private var stored: String?
    init(_ stored: String? = "conversation-check-key") { self.stored = stored }
    func load() throws -> String? { loads += 1; return stored }
    func save(_ value: String) throws { stored = value }
    func delete() throws { stored = nil }
}

private actor ConversationCheckTranslator: TranslationProviding {
    private let holdInputs: Bool
    private let badHash: Bool
    private var captured: [TranslationRequest] = []
    private var pending: [(TranslationRequest, CheckedContinuation<TranslationReply, any Error>)] = []
    init(holdInputs: Bool = false, badHash: Bool = false) { self.holdInputs = holdInputs; self.badHash = badHash }
    func requests() -> [TranslationRequest] { captured }
    func translate(_ request: TranslationRequest) async throws -> TranslationReply {
        captured.append(request)
        if holdInputs && request.operation == "translate_input" {
            return try await withCheckedThrowingContinuation { pending.append((request, $0)) }
        }
        return reply(request)
    }
    func releaseInputs() {
        let current = pending; pending = []
        for (request, continuation) in current { continuation.resume(returning: reply(request)) }
    }
    private func reply(_ request: TranslationRequest) -> TranslationReply {
        let translated = request.operation == "translate_input" ? "\(request.target):\(request.text)" : "中文译文：\(request.text)"
        let digest = SHA256.hash(data: Data(translated.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(ok: true, request_id: UUID().uuidString, original: request.text, translated: translated,
                     revision: 1, translation_sha256: badHash ? String(repeating: "0", count: 64) : digest,
                     requires_confirmation: request.operation == "translate_input", error_code: nil, fixture_only: false)
    }
}

private final class ConversationCheckChat: ChatProviding, @unchecked Sendable {
    static let rawReply = " \nHello 日本語 👋\n```swift\nprint(\"hello\")\n```\n\n"
    private let automatic: Bool
    private let lock = NSLock()
    private var captured: [ChatRequest] = []
    private var continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation?
    init(automatic: Bool = true) { self.automatic = automatic }
    func requests() -> [ChatRequest] { lock.withLock { captured } }
    func events(for request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { stream in
            lock.withLock { captured.append(request); continuation = stream }
            stream.yield(.started)
            if automatic {
                stream.yield(.delta(" \nHello 日本語 👋\n"))
                stream.yield(.delta("```swift\nprint(\"hello\")\n```\n\n"))
                stream.yield(.completed(Self.rawReply))
                stream.finish()
            }
        }
    }
    func emit(_ event: ChatEvent) { lock.withLock { continuation }?.yield(event) }
    func finish() { lock.withLock { continuation }?.finish() }
    func fail(_ error: ChatFailure) { lock.withLock { continuation }?.finish(throwing: error) }
}

@MainActor
private func conversationCheckWait(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<1_000 {
        if predicate() { return true }
        do { try await Task.sleep(for: .milliseconds(2)) } catch { return false }
    }
    return predicate()
}

@MainActor
private func conversationCheckWaitAsync(_ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<1_000 {
        if await predicate() { return true }
        do { try await Task.sleep(for: .milliseconds(2)) } catch { return false }
    }
    return await predicate()
}

@MainActor
private func conversationPrivacyLifecycleChecks(defaults: UserDefaults) async -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { checks.append(("conversation privacy: \(name)", passed)) }

    do {
        let harness = ConversationCheckHarness(defaults: defaults)
        harness.execution.provider = .claudeSubscription
        let firstID = harness.vm.selectedID
        harness.vm.draft = "第一轮"; harness.vm.send()
        let firstFinished = await conversationCheckWait { !harness.vm.isBusy }
        harness.vm.draft = "第二轮"; harness.vm.send()
        let secondFinished = await conversationCheckWait { !harness.vm.isBusy }
        let firstRequests = harness.chat.requests()
        check("subscription turns share their App conversation session and keep distinct request IDs", firstFinished && secondFinished && firstRequests.count == 2 && firstRequests.allSatisfy { $0.conversationSessionID == firstID } && Set(firstRequests.map(\.request_id)).count == 2)
        harness.vm.newConversation()
        let secondID = harness.vm.selectedID
        harness.vm.draft = "另一段对话"; harness.vm.send()
        let newFinished = await conversationCheckWait { !harness.vm.isBusy }
        check("a new App conversation receives another session ID", newFinished && firstID != secondID && harness.chat.requests().last?.conversationSessionID == secondID)
        harness.vm.shutdown()
        let restored = ConversationCheckHarness(defaults: defaults, store: harness.store)
        restored.execution.provider = .claudeSubscription
        if let firstID { restored.vm.selectConversation(firstID) }
        restored.vm.draft = "重启后继续原对话"; restored.vm.send()
        let restoredFinished = await conversationCheckWait { !restored.vm.isBusy }
        check("restoring an existing conversation retains its session ID", restoredFinished && restored.chat.requests().first?.conversationSessionID == firstID)
        do {
            let persisted = String(decoding: try JSONEncoder().encode(harness.store.snapshot), as: UTF8.self)
            check("conversation identity persistence contains no OAuth token field or value", !persisted.contains("subscriptionToken") && !persisted.contains("sk-ant-oat01-conversation-offline-fixture"))
        } catch { check("conversation identity persistence contains no OAuth token field or value", false) }
        restored.vm.shutdown()
    }

    do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-summary-check-\(UUID().uuidString)")
        defer {
            do { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
            catch { check("summary fixture cleanup", false) }
        }
        let file = directory.appendingPathComponent("conversations.json")
        let disk = FileConversationStore(fileURL: file)
        let chat = ConversationCheckChat(automatic: false)
        let harness = ConversationCheckHarness(defaults: defaults, chat: chat, persistence: disk)
        harness.vm.draft = "默认仅保存摘要"; harness.vm.send()
        _ = await conversationCheckWait { !chat.requests().isEmpty }
        if let request = chat.requests().first, let runID = UUID(uuidString: request.request_id) {
            let trace = conversationPrivacyTrace(runID: runID)
            chat.emit(.requestTrace(trace))
            chat.emit(.requestTrace(conversationPrivacyTrace(runID: runID, phase: .response)))
            chat.emit(.completed("正常回复")); chat.finish()
            let finished = await conversationCheckWait { !harness.vm.isBusy }
            let saved = try disk.load()
            let diagnostic = saved.conversations.flatMap(\.messages).flatMap { $0.requestTraces ?? [] }.first
            let bytes = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            check("default summary persists transport outcome without body or identity header", finished && diagnostic?.schema == "claude-request-trace/v2" && diagnostic?.bodyAvailability == .notCaptured && diagnostic?.body.isEmpty == true && diagnostic?.bodyBytes == trace.bodyBytes && diagnostic?.status == 200 && diagnostic?.headers["x-claude-code-session-id"] == nil && !bytes.contains("diagnostic-only-content-marker") && !bytes.contains("fixture-device-identity") && !bytes.contains("x-claude-code-session-id"))
            check("summary mode preserves ordinary user and assistant messages", saved.conversations.flatMap(\.messages).contains { $0.role == .user && $0.originalText == "默认仅保存摘要" } && saved.conversations.flatMap(\.messages).contains { $0.role == .assistant && $0.text == "正常回复" })
        } else { check("summary fixture starts one request", false) }
        harness.vm.shutdown()
    } catch { check("summary disk readback fixture", false) }

    do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-retention-check-\(UUID().uuidString)")
        defer {
            do { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
            catch { check("retention fixture cleanup", false) }
        }
        let file = directory.appendingPathComponent("conversations.json")
        let disk = FileConversationStore(fileURL: file)
        let clock = ConversationDiagnosticClock()
        let capturedAt = clock.now
        let diagnostics = DiagnosticsSettingsModel()
        diagnostics.setCaptureBodies(true)
        let chat = ConversationCheckChat(automatic: false)
        let harness = ConversationCheckHarness(defaults: defaults, chat: chat, persistence: disk, diagnostics: diagnostics, diagnosticNow: { clock.now })
        harness.vm.draft = "明确开启正文采集"; harness.vm.send()
        _ = await conversationCheckWait { !chat.requests().isEmpty }
        if let request = chat.requests().first, let runID = UUID(uuidString: request.request_id) {
            let trace = conversationPrivacyTrace(runID: runID)
            chat.emit(.requestTrace(trace))
            _ = await conversationCheckWait { harness.vm.messages.last(where: { $0.role == .assistant })?.requestTraces?.first?.hasBody == true }
            clock.now = capturedAt.addingTimeInterval(120)
            chat.emit(.requestTrace(conversationPrivacyTrace(runID: runID, phase: .response)))
            chat.emit(.completed("正文生命周期不影响这段回复")); chat.finish()
            let finished = await conversationCheckWait { !harness.vm.isBusy }
            let captured = try disk.load().conversations.flatMap(\.messages).flatMap { $0.requestTraces ?? [] }.first
            check("explicit capture retains one body for 24 hours from the request event", finished && captured?.bodyAvailability == .available && captured?.body == trace.body && captured?.capturedAt == capturedAt && captured?.expiresAt == capturedAt.addingTimeInterval(86_400) && captured?.phase == .response)
            harness.vm.shutdown()
            var snapshot = try disk.load()
            let legacyRun = UUID()
            let legacyTrace = requestTraceFixture(runID: legacyRun, phase: .response, body: "{\"model\":\"deepseek-flash[1m]\",\"messages\":[{\"content\":\"legacy-private-body-marker\"}]}")
            let legacy = ConversationRecord(title: "历史 v1", messages: [
                .init(role: .user, text: "历史输入", runID: legacyRun),
                .init(role: .assistant, text: "历史回复", runID: legacyRun, requestTraces: [legacyTrace])
            ])
            snapshot.conversations.append(legacy)
            try disk.save(snapshot)
            let overdueStore = MemoryConversationStore(snapshot)
            let overdue = ConversationCheckHarness(defaults: defaults, store: overdueStore, diagnosticNow: { capturedAt.addingTimeInterval(86_401) })
            let overdueTrace = overdueStore.snapshot.conversations.flatMap(\.messages).flatMap { $0.requestTraces ?? [] }.first { $0.attemptID == trace.attemptID }
            check("startup prunes bodies whose retention elapsed while the App was closed", overdueTrace?.bodyAvailability == .expired && overdueTrace?.body.isEmpty == true && overdueStore.snapshot.conversations.first { $0.id == legacy.id } == legacy && overdue.chat.requests().isEmpty && overdue.translationKey.loads == 0 && overdue.executionKey.loads == 0)
            overdue.vm.shutdown()
            let restored = ConversationCheckHarness(defaults: defaults, persistence: disk, diagnosticNow: { clock.now })
            let restoredTrace = restored.vm.conversations.flatMap(\.messages).flatMap { $0.requestTraces ?? [] }.first { $0.attemptID == trace.attemptID }
            check("restart preserves unexpired consented body even when future capture is off", restoredTrace == captured && restored.chat.requests().isEmpty && restored.translationKey.loads == 0 && restored.executionKey.loads == 0)
            let contentBeforeExpiry = conversationRecordsWithoutTraces(restored.vm.conversations)
            clock.now = capturedAt.addingTimeInterval(86_400)
            restored.vm.expireRequestBodies()
            let expiredSnapshot = try disk.load()
            let expired = expiredSnapshot.conversations.flatMap(\.messages).flatMap { $0.requestTraces ?? [] }.first { $0.attemptID == trace.attemptID }
            let expiredBytes = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            check("24-hour boundary removes the new body from memory and disk", expired?.bodyAvailability == .expired && expired?.body.isEmpty == true && expired?.bodyBytes == trace.bodyBytes && expired?.status == 200 && !expiredBytes.contains("diagnostic-only-content-marker") && restored.vm.messages.last(where: { $0.role == .assistant })?.requestTraces?.first == expired)
            check("automatic expiry preserves all conversation content and legacy v1 bodies", conversationRecordsWithoutTraces(expiredSnapshot.conversations) == contentBeforeExpiry && expiredSnapshot.conversations.first { $0.id == legacy.id } == legacy && expiredBytes.contains("legacy-private-body-marker"))
            restored.vm.clearRequestBodies(conversationID: legacy.id)
            let clearedSnapshot = try disk.load()
            let clearedLegacy = clearedSnapshot.conversations.first { $0.id == legacy.id }?.messages.last?.requestTraces?.first
            let clearedBytes = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            check("manual cleanup removes legacy body while retaining its messages and transport summary", clearedLegacy?.bodyAvailability == .removed && clearedLegacy?.body.isEmpty == true && clearedLegacy?.status == 200 && conversationRecordsWithoutTraces(clearedSnapshot.conversations) == contentBeforeExpiry && !clearedBytes.contains("legacy-private-body-marker"))
            restored.vm.shutdown()
        } else { check("retention fixture starts one request", false); harness.vm.shutdown() }
    } catch { check("retention disk readback fixture", false) }

    for captureAtSend in [false, true] {
        let diagnostics = DiagnosticsSettingsModel()
        diagnostics.setCaptureBodies(captureAtSend)
        let translator = ConversationCheckTranslator(holdInputs: true)
        let chat = ConversationCheckChat(automatic: false)
        let harness = ConversationCheckHarness(defaults: defaults, translator: translator, chat: chat, diagnostics: diagnostics)
        harness.vm.draft = "发送后修改诊断开关"; harness.vm.send()
        let translating = await conversationCheckWaitAsync { await translator.requests().count == 1 }
        diagnostics.setCaptureBodies(!captureAtSend)
        await translator.releaseInputs()
        _ = await conversationCheckWait { !chat.requests().isEmpty }
        if let request = chat.requests().first, let runID = UUID(uuidString: request.request_id) {
            chat.emit(.requestTrace(conversationPrivacyTrace(runID: runID)))
            chat.emit(.requestTrace(conversationPrivacyTrace(runID: runID, phase: .response)))
            chat.emit(.completed("保持发送时的采集设置")); chat.finish()
            let finished = await conversationCheckWait { !harness.vm.isBusy }
            let trace = harness.vm.messages.last(where: { $0.role == .assistant })?.requestTraces?.first
            check("in-flight capture stays \(captureAtSend ? "enabled" : "disabled") when settings change during translation", translating && finished && trace?.hasBody == captureAtSend && trace?.bodyAvailability == (captureAtSend ? .available : .notCaptured))
        } else { check("capture setting fixture starts one request", false) }
        harness.vm.shutdown()
    }

    for clearBeforeRequest in [false, true] {
        let diagnostics = DiagnosticsSettingsModel()
        diagnostics.setCaptureBodies(true)
        let chat = ConversationCheckChat(automatic: false)
        let harness = ConversationCheckHarness(defaults: defaults, chat: chat, diagnostics: diagnostics)
        harness.vm.draft = "采集中途清除正文"; harness.vm.send()
        _ = await conversationCheckWait { !chat.requests().isEmpty }
        if let request = chat.requests().first, let runID = UUID(uuidString: request.request_id) {
            if clearBeforeRequest { harness.vm.clearRequestBodies(conversationID: harness.vm.selectedID, runID: runID) }
            chat.emit(.requestTrace(conversationPrivacyTrace(runID: runID)))
            let recorded = await conversationCheckWait { harness.vm.messages.last(where: { $0.role == .assistant })?.requestTraces?.count == 1 }
            if !clearBeforeRequest { harness.vm.clearRequestBodies(conversationID: harness.vm.selectedID, runID: runID) }
            chat.emit(.requestTrace(conversationPrivacyTrace(runID: runID, phase: .response)))
            chat.emit(.completed("清理后仍然正常完成")); chat.finish()
            let finished = await conversationCheckWait { !harness.vm.isBusy }
            let assistant = harness.vm.messages.last { $0.role == .assistant }
            let stored = harness.store.snapshot.conversations.flatMap(\.messages).flatMap { $0.requestTraces ?? [] }.first
            check("cleanup \(clearBeforeRequest ? "before" : "after") first trace cannot be undone by the terminal event", recorded && finished && assistant?.state == .complete && assistant?.text == "清理后仍然正常完成" && stored?.phase == .response && stored?.bodyAvailability == .removed && stored?.body.isEmpty == true)
        } else { check("in-flight cleanup fixture starts one request", false) }
        harness.vm.shutdown()
    }

    do {
        let runID = UUID(), clock = ConversationDiagnosticClock()
        let trace = conversationPrivacyTrace(runID: runID, phase: .response).persisted(captureBody: true, capturedAt: clock.now)
        let record = ConversationRecord(messages: [.init(role: .user, text: "不能损坏的输入", runID: runID), .init(role: .assistant, text: "不能损坏的回复", runID: runID, requestTraces: [trace])])
        let disk = ConversationFailingDiagnosticStore(.init(selectedID: record.id, conversations: [record]))
        let harness = ConversationCheckHarness(defaults: defaults, persistence: disk, diagnosticNow: { clock.now })
        disk.failSave = true
        harness.vm.clearRequestBodies(conversationID: record.id)
        check("cleanup save failure reports that disk may still retain the body", harness.vm.diagnosticError != nil && harness.vm.persistenceError != nil && harness.vm.messages.last?.requestTraces?.first?.body.isEmpty == true && disk.snapshot.conversations.first?.messages.last?.requestTraces == [trace])
        disk.failSave = false
        harness.vm.flushPersistence()
        check("successful cleanup retry clears the warning and persists only the summary", harness.vm.diagnosticError == nil && harness.vm.persistenceError == nil && disk.snapshot.conversations.first?.messages.last?.requestTraces?.first?.bodyAvailability == .removed && conversationRecordsWithoutTraces(disk.snapshot.conversations) == conversationRecordsWithoutTraces([record]))
        harness.vm.shutdown()
    }
    return checks
}

@MainActor
private final class ConversationDiagnosticClock {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
}

private final class ConversationFailingDiagnosticStore: ConversationPersisting {
    var snapshot: ConversationSnapshot
    var failSave = false
    init(_ snapshot: ConversationSnapshot) { self.snapshot = snapshot }
    func load() throws -> ConversationSnapshot { snapshot }
    func save(_ snapshot: ConversationSnapshot) throws {
        if failSave { throw ConversationStoreFailure.saveFailed }
        try snapshot.validate()
        self.snapshot = snapshot
    }
}

private func conversationRecordsWithoutTraces(_ records: [ConversationRecord]) -> [ConversationRecord] {
    records.map { record in
        var copy = record
        for index in copy.messages.indices { copy.messages[index].requestTraces = nil }
        return copy
    }
}

private func conversationPrivacyTrace(runID: UUID, phase: ChatRequestTracePhase = .request) -> ChatRequestTrace {
    let body = "{\"model\":\"deepseek-flash[1m]\",\"messages\":[{\"role\":\"user\",\"content\":\"diagnostic-only-content-marker\"}],\"metadata\":{\"device_id\":\"fixture-device-identity\"}}"
    return .init(attemptID: "\(runID.uuidString):1", attempt: 1, phase: phase, wireModel: "deepseek-flash[1m]",
                 headers: ["content-type": "application/json", "x-claude-code-session-id": "E621719D-B094-41C0-99A1-FA5A5EC652E5"],
                 proxy: .init(url: "http://127.0.0.1:7897"), body: body, bodyBytes: body.utf8.count,
                 status: phase == .response ? 200 : nil, durationMS: phase == .request ? nil : 120,
                 outcome: phase == .request ? nil : "http")
}


@MainActor
private func conversationProjectLifecycleChecks(defaults: UserDefaults) async -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { checks.append(("conversation project: " + name, passed)) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-project-checks-\(UUID().uuidString)", isDirectory: true)
    let firstDirectory = root.appendingPathComponent("项目 one", isDirectory: true)
    let secondDirectory = root.appendingPathComponent("別の project", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let firstPath = try ProjectDirectory.normalized(firstDirectory.path)
        let secondPath = try ProjectDirectory.normalized(secondDirectory.path)

        do {
            let harness = ConversationCheckHarness(defaults: defaults)
            let firstID = harness.vm.selectedID!
            harness.vm.draft = "保留原草稿"
            check("new sessions begin without a project", harness.vm.selectedConversation?.projectDirectory == nil)
            check("selection saves a canonical Unicode path", harness.vm.setProjectDirectory(firstDirectory.path, for: firstID) && harness.vm.selectedConversation?.projectDirectory == firstPath)
            harness.vm.newConversation()
            let secondID = harness.vm.selectedID!
            check("another session does not inherit a project", harness.vm.selectedConversation?.projectDirectory == nil)
            check("late picker selection targets its original session", harness.vm.setProjectDirectory(secondDirectory.path, for: firstID) && harness.vm.selectedID == secondID && harness.vm.selectedConversation?.projectDirectory == nil && harness.vm.conversations.first { $0.id == firstID }?.projectDirectory == secondPath)
            harness.vm.selectConversation(firstID)
            check("switching restores the bound directory and original draft", harness.vm.selectedConversation?.projectDirectory == secondPath && harness.vm.draft == "保留原草稿")
            harness.vm.flushPersistence()
            let restored = ConversationCheckHarness(defaults: defaults, store: harness.store)
            check("restart restores selection and bound directory without starting providers", restored.vm.selectedID == firstID && restored.vm.selectedConversation?.projectDirectory == secondPath && restored.chat.requests().isEmpty && restored.translationKey.loads == 0)
            harness.vm.clearRequestBodies()
            check("diagnostic cleanup keeps the project binding", harness.vm.selectedConversation?.projectDirectory == secondPath)
            check("removing a binding preserves session identity and draft", harness.vm.setProjectDirectory(nil, for: firstID) && harness.vm.selectedID == firstID && harness.vm.selectedConversation?.projectDirectory == nil && harness.vm.draft == "保留原草稿")
            harness.vm.deleteConversation(firstID)
            check("late picker completion cannot recreate a deleted session", !harness.vm.setProjectDirectory(firstPath, for: firstID) && !harness.vm.conversations.contains { $0.id == firstID } && harness.vm.selectedID == secondID)
            harness.vm.shutdown(); restored.vm.shutdown()
        }

        do {
            let missing = root.appendingPathComponent("removed", isDirectory: true)
            try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
            let harness = ConversationCheckHarness(defaults: defaults)
            let id = harness.vm.selectedID!
            _ = harness.vm.setProjectDirectory(missing.path, for: id)
            harness.vm.draft = "不应发送到纯文本模式"
            try FileManager.default.removeItem(at: missing)
            harness.vm.send()
            let translationRequests = await harness.translator.requests()
            check("missing project blocks send before translation or credentials", !harness.vm.isBusy && harness.vm.messages.isEmpty && harness.chat.requests().isEmpty && translationRequests.isEmpty && harness.translationKey.loads == 0 && harness.executionKey.loads == 0)
            check("missing project retains the draft and binding with an actionable error", harness.vm.draft == "不应发送到纯文本模式" && harness.vm.selectedConversation?.projectDirectory != nil && harness.vm.projectDirectoryError?.contains("重新选择") == true)
            check("choosing a valid replacement clears the directory error", harness.vm.setProjectDirectory(firstPath, for: id) && harness.vm.projectDirectoryError == nil)
            harness.vm.shutdown()
        }

        do {
            let disappearing = root.appendingPathComponent("removed-during-translation", isDirectory: true)
            try FileManager.default.createDirectory(at: disappearing, withIntermediateDirectories: true)
            let translator = ConversationCheckTranslator(holdInputs: true)
            let harness = ConversationCheckHarness(defaults: defaults, translator: translator)
            _ = harness.vm.setProjectDirectory(disappearing.path, for: harness.vm.selectedID!)
            harness.vm.draft = "执行前再次检查目录"
            harness.vm.send()
            _ = await conversationCheckWaitAsync { await translator.requests().count == 1 }
            try FileManager.default.removeItem(at: disappearing)
            await translator.releaseInputs()
            let finished = await conversationCheckWait { !harness.vm.isBusy }
            check("directory disappearance during translation prevents VM execution", finished && harness.chat.requests().isEmpty && harness.vm.messages.last(where: { $0.role == .assistant })?.state == .failed && harness.vm.messages.last(where: { $0.role == .assistant })?.error?.contains("重新选择") == true)
            check("pre-execution directory failure never removes the binding or draft", harness.vm.selectedConversation?.projectDirectory != nil && harness.vm.draft == "执行前再次检查目录")
            harness.vm.shutdown()
        }

        do {
            let translator = ConversationCheckTranslator(holdInputs: true)
            let chat = ConversationCheckChat(automatic: false)
            let harness = ConversationCheckHarness(defaults: defaults, translator: translator, chat: chat)
            let firstID = harness.vm.selectedID!
            _ = harness.vm.setProjectDirectory(firstPath, for: firstID)
            harness.vm.draft = "保持发送时的项目目录"
            harness.vm.send()
            let translating = await conversationCheckWaitAsync { await translator.requests().count == 1 }
            check("running session cannot change or remove its project", !harness.vm.canChangeProjectDirectory && !harness.vm.setProjectDirectory(secondPath, for: firstID) && !harness.vm.setProjectDirectory(nil, for: firstID) && harness.vm.selectedConversation?.projectDirectory == firstPath)
            harness.vm.newConversation()
            let secondID = harness.vm.selectedID!
            check("another session can choose its own directory during execution", harness.vm.canChangeProjectDirectory && harness.vm.setProjectDirectory(secondPath, for: secondID))
            await translator.releaseInputs()
            let started = await conversationCheckWait { chat.requests().count == 1 }
            check("in-flight request freezes the original session directory", translating && started && chat.requests().first?.project?.directory == firstPath && chat.requests().first?.conversationSessionID == firstID)
            chat.emit(.toolActivity(tool: "Read", phase: "started", toolID: "read-1"))
            let reading = await conversationCheckWait { harness.vm.conversations.first { $0.id == firstID }?.messages.contains { $0.role == .activity && $0.text == "读取文件（Read）：开始" && $0.state == .running } == true }
            chat.emit(.toolActivity(tool: "Read", phase: "completed", toolID: "read-1"))
            for tool in ["Write", "Edit", "Bash", "Glob", "Grep"] {
                chat.emit(.toolActivity(tool: tool, phase: "started", toolID: "tool-\(tool)"))
                chat.emit(.toolActivity(tool: tool, phase: tool == "Bash" ? "failed" : "completed", toolID: "tool-\(tool)"))
            }
            chat.emit(.completed("项目执行完成")); chat.finish()
            let finished = await conversationCheckWait { !harness.vm.isBusy }
            let activities = harness.vm.conversations.first { $0.id == firstID }?.messages.filter { $0.role == .activity } ?? []
            check("tool activity stays in the originating session and completes without raw inputs", reading && finished && harness.vm.selectedID == secondID && harness.vm.messages.isEmpty && activities.contains { $0.text == "读取文件（Read）：完成" && $0.state == .complete } && activities.contains { $0.text == "运行项目命令（Bash）：失败" && $0.state == .failed } && activities.filter { $0.text.contains("）：完成") }.count == 5)
            check("finished session unlocks its project selection", harness.vm.canChangeProjectDirectory(in: firstID) && harness.vm.setProjectDirectory(secondPath, for: firstID))
            harness.vm.shutdown()
        }

        do {
            let chat = ConversationCheckChat(automatic: false)
            let harness = ConversationCheckHarness(defaults: defaults, chat: chat)
            _ = harness.vm.setProjectDirectory(firstPath, for: harness.vm.selectedID!)
            harness.vm.draft = "停止项目命令"
            harness.vm.send()
            _ = await conversationCheckWait { chat.requests().count == 1 }
            chat.emit(.toolActivity(tool: "Bash", phase: "started", toolID: "command-1"))
            _ = await conversationCheckWait { harness.vm.messages.contains { $0.role == .activity && $0.text.contains("（Bash）：开始") } }
            harness.vm.stop()
            let finished = await conversationCheckWait { !harness.vm.isBusy }
            check("cancellation settles tool activity and retains the project", finished && harness.vm.messages.contains { $0.role == .activity && $0.text == "Bash：已停止" && $0.state == .cancelled } && harness.vm.selectedConversation?.projectDirectory == firstPath && harness.vm.canChangeProjectDirectory)
            harness.vm.shutdown()
        }

        do {
            let chat = ConversationCheckChat(automatic: false)
            let harness = ConversationCheckHarness(defaults: defaults, chat: chat)
            _ = harness.vm.setProjectDirectory(firstPath, for: harness.vm.selectedID!)
            harness.vm.draft = "项目工具循环请求记录"
            harness.vm.send()
            _ = await conversationCheckWait { chat.requests().count == 1 }
            if let request = chat.requests().first, let runID = UUID(uuidString: request.request_id) {
                for attempt in 1...24 {
                    for phase: ChatRequestTracePhase in [.request, .response] {
                        let base = requestTraceFixture(runID: runID, phase: phase)
                        let trace = ChatRequestTrace(attemptID: "\(runID.uuidString):\(attempt)", attempt: attempt, phase: phase,
                            wireModel: base.wireModel, headers: base.headers, proxy: base.proxy, body: base.body,
                            bodyBytes: base.bodyBytes, status: base.status, durationMS: base.durationMS, outcome: base.outcome)
                        chat.emit(.requestTrace(trace))
                    }
                }
                chat.emit(.completed("请求循环完成")); chat.finish()
                let finished = await conversationCheckWait { !harness.vm.isBusy }
                let assistant = harness.vm.messages.last { $0.role == .assistant }
                check("project execution accepts and persists up to 24 sequential request traces", finished && assistant?.state == .complete && assistant?.requestTraces?.count == 24 && harness.store.snapshot.schemaVersion == 3 && harness.vm.persistenceError == nil)
            } else { check("project trace fixture starts one request", false) }
            harness.vm.shutdown()
        }
    } catch { check("temporary project fixture setup or operation", false) }
    if FileManager.default.fileExists(atPath: root.path) {
        do { try FileManager.default.removeItem(at: root) }
        catch { check("temporary project fixture cleanup", false) }
    }
    return checks
}
