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
            chat.emit(.requestTrace(requestTrace))
            let recorded = await conversationCheckWait { harness.vm.messages.last(where: { $0.role == .assistant })?.requestTraces?.count == 1 }
            if let record = harness.vm.selectedConversation, let user = record.messages.first(where: { $0.role == .user }),
               let assistant = record.messages.first(where: { $0.role == .assistant }) {
                check("user and assistant share the same live attempt", recorded && user.runID == runID && assistant.runID == runID && user.requestTraces == nil && harness.vm.requestTraces(for: user, in: record) == [requestTrace] && harness.vm.requestTraces(for: assistant, in: record) == [requestTrace])
                check("user request sheet follows assistant execution state", harness.vm.requestDetailsMessage(for: user, in: record).id == assistant.id && harness.vm.requestDetailsMessage(for: user, in: record).state == .running)
            } else { check("user and assistant share the same live attempt", false) }
            let response = requestTraceFixture(runID: runID, phase: .response)
            chat.emit(.requestTrace(response)); chat.emit(.delta(ConversationCheckChat.rawReply)); chat.emit(.completed(ConversationCheckChat.rawReply)); chat.finish()
            let finished = await conversationCheckWait { !harness.vm.isBusy }
            if let record = harness.vm.selectedConversation, let assistant = record.messages.first(where: { $0.role == .assistant }),
               let user = record.messages.first(where: { $0.role == .user }) {
                check("terminal trace replaces its attempt without duplicating full body", finished && assistant.requestTraces == [response] && harness.vm.requestTraces(for: user, in: record) == [response])
                harness.vm.translateMessage(assistant.id)
                _ = await conversationCheckWait { !harness.vm.translatingMessageIDs.contains(assistant.id) }
                let translated = harness.vm.messages.first { $0.id == assistant.id }
                check("output translation leaves the CLI trace unchanged", translated?.translation != nil && translated?.requestTraces == [response] && chat.requests().count == 1)
                let restored = ConversationCheckHarness(defaults: defaults, store: harness.store)
                if let saved = restored.vm.selectedConversation, let savedUser = saved.messages.first(where: { $0.role == .user }) {
                    check("restart preserves trace lookup for both messages", restored.vm.requestTraces(for: savedUser, in: saved) == [response] && restored.chat.requests().isEmpty)
                } else { check("restart preserves trace lookup for both messages", false) }
                restored.vm.shutdown()
            } else { check("terminal trace replaces its attempt without duplicating full body", false) }
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
            chat.emit(.requestTrace(requestTrace)); chat.emit(.requestTrace(failedTrace)); chat.fail(.code("PROVIDER_CONNECTION_FAILED"))
            let finished = await conversationCheckWait { !harness.vm.isBusy }
            let assistant = harness.vm.messages.first { $0.role == .assistant }
            check("failed reply retains full actual request and transport outcome", finished && assistant?.state == .failed && assistant?.requestTraces == [failedTrace] && harness.vm.draft == "请求失败时保存")
            let restored = ConversationCheckHarness(defaults: defaults, store: harness.store)
            check("failed trace is readable after restart without replay", restored.vm.messages.first(where: { $0.role == .assistant })?.requestTraces == [failedTrace] && restored.chat.requests().isEmpty)
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
            chat.emit(.requestTrace(requestTrace))
            _ = await conversationCheckWait { harness.vm.messages.first(where: { $0.role == .assistant })?.requestTraces?.count == 1 }
            let restored = ConversationCheckHarness(defaults: defaults, store: harness.store)
            let cancelled = requestTrace.markingInterrupted()
            check("restart marks an unfinished request cancelled without inventing time", restored.vm.messages.first(where: { $0.role == .assistant })?.state == .cancelled && restored.vm.messages.first(where: { $0.role == .assistant })?.requestTraces == [cancelled] && restored.chat.requests().isEmpty)
            restored.vm.shutdown()
            harness.vm.stop(); chat.finish()
            let stopped = await conversationCheckWait { !harness.vm.isBusy }
            check("stop keeps request body and cancellation on the same run", stopped && harness.vm.messages.first(where: { $0.role == .assistant })?.requestTraces == [cancelled] && harness.vm.draft == "停止后保留请求")
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
         persistence: (any ConversationPersisting)? = nil, skills: SkillsViewModel? = nil) {
        self.translator = translator; self.chat = chat; self.store = store
        translation = TranslationViewModel(provider: translator, configurationStore: .init(defaults: defaults), credentials: translationKey)
        translation.endpoint = "https://api.deepseek.com/chat/completions"
        translation.modelName = "deepseek-flash"
        execution = ExecutionViewModel(store: .init(defaults: defaults), credentials: executionKey, subscriptionCredentials: subscriptionKey)
        execution.baseURL = "https://api.deepseek.com/anthropic"
        execution.modelName = "deepseek-flash[1m]"
        vm = ConversationViewModel(translation: translation, execution: execution, translator: translator,
                                   provider: chat, store: persistence ?? store,
                                   translationCredentials: translationKey, executionCredentials: executionKey, subscriptionCredentials: subscriptionKey, skills: skills)
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
