import Combine
import Foundation
import SwiftUI

@MainActor
final class ExecutionViewModel: ObservableObject {
    @Published var provider: ExecutionProvider = .deepseekAPI { didSet { if oldValue != provider { configurationStatus = "执行来源已更改，尚未保存。"; testStatus = nil } } }
    @Published var baseURL = "https://api.deepseek.com/anthropic" { didSet { if oldValue != baseURL { configurationStatus = "配置已更改，尚未保存。" } } }
    @Published var modelName = "" { didSet { if oldValue != modelName { configurationStatus = "配置已更改，尚未保存。" } } }
    @Published var apiKey = "" { didSet { if restoringCredentialBinding { return }; if isWorkSuspended { restoringCredentialBinding = true; apiKey = oldValue; restoringCredentialBinding = false; return }; if oldValue != apiKey { credentialStatus = apiKey.isEmpty ? "凭据未载入。" : "凭据仅在本次运行内存中。" } } }
    @Published var subscriptionModel = "sonnet" { didSet { if oldValue != subscriptionModel { configurationStatus = "配置已更改，尚未保存。" } } }
    @Published var subscriptionToken = "" { didSet { if restoringCredentialBinding { return }; if isWorkSuspended && !clearingSubscriptionForReset { restoringCredentialBinding = true; subscriptionToken = oldValue; restoringCredentialBinding = false; return }; if oldValue != subscriptionToken { subscriptionCredentialStatus = subscriptionToken.isEmpty ? "订阅 Token 未载入。" : "订阅 Token 仅在本次运行内存中。" } } }
    @Published private(set) var configurationStatus = "尚未配置执行模型。"
    @Published private(set) var credentialStatus = "凭据未载入。"
    @Published private(set) var subscriptionCredentialStatus = "订阅 Token 未载入。"
    @Published private(set) var error: String?
    @Published private(set) var testBusy = false
    @Published private(set) var testStatus: String?
    @Published private(set) var isLoginResetInProgress = false
    @Published private(set) var isTerminationInProgress = false
    private var isWorkSuspended: Bool { isLoginResetInProgress || isTerminationInProgress }
    private var clearingSubscriptionForReset = false
    private var restoringCredentialBinding = false
    private var connectionTask: Task<ExecutionConnectionReply, Error>?
    private let store: ExecutionConfigurationStore
    private let credentials: any AppCredentialStoring
    private let subscriptionCredentials: any AppCredentialStoring
    private let tester: (any ExecutionConnectionTesting)?
    let subscriptionAccounts: SubscriptionAccountsModel?
    private var accountObservation: AnyCancellable?

    init(store: ExecutionConfigurationStore = .init(), credentials: any AppCredentialStoring = FileCredentialStore(scope: .execution),
         subscriptionCredentials: any AppCredentialStoring = FileCredentialStore(scope: .subscription), tester: (any ExecutionConnectionTesting)? = nil,
         subscriptionAccounts: SubscriptionAccountsModel? = nil) {
        self.store = store
        self.credentials = credentials
        self.subscriptionCredentials = subscriptionCredentials
        self.tester = tester
        self.subscriptionAccounts = subscriptionAccounts
        switch store.load() {
        case .missing: break
        case .configured(let profile):
            baseURL = profile.baseURL
            modelName = profile.model
            provider = profile.provider
            subscriptionModel = profile.subscriptionModel
            configurationStatus = subscriptionAccounts == nil ? "公开配置已保存；启动时未读取密钥。" : "模型配置已保存；订阅账号独立管理。"
        case .invalid(let failure):
            configurationStatus = "已保存配置无效。"
            error = failure.message
        }
        accountObservation = subscriptionAccounts?.$catalog.dropFirst().sink { [weak self] _ in
            self?.testStatus = nil
            if self?.provider == .claudeSubscription { self?.error = nil }
            self?.objectWillChange.send()
        }
    }

    func saveConfiguration() {
        guard !isWorkSuspended else { error = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        do {
            if provider == .deepseekAPI {
                guard baseURL == "https://api.deepseek.com/anthropic" else { throw ExecutionConfigurationError.invalidBaseURL }
                guard ["deepseek-flash[1m]", "deepseek-flash"].contains(modelName) else { throw ExecutionConfigurationError.invalidModel }
            }
            try store.save(.init(baseURL: baseURL, model: modelName, provider: provider, subscriptionModel: subscriptionModel))
            configurationStatus = "公开配置已保存。"
            error = nil
        } catch let failure as ExecutionConfigurationError { error = failure.message }
        catch { self.error = "无法保存执行模型配置。" }
    }

    func reuseTranslationKey(_ key: String) {
        guard !isWorkSuspended else { error = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "翻译模型尚未载入 API Key，请先在翻译设置中填写或读取。"
            return
        }
        apiKey = key
        credentialStatus = "已复用翻译 Key，仅在本次运行内存中。"
        error = nil
    }

    func saveKey() {
        guard !isWorkSuspended else { error = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "请先输入执行模型 API Key。"
            return
        }
        do {
            try credentials.save(apiKey)
            credentialStatus = "已保存到本机。"
            error = nil
        } catch let failure as LocalCredentialFailure { credentialStatus = "密钥保存失败。"; error = failure.message }
        catch { credentialStatus = "密钥保存失败。"; self.error = "无法保存执行模型 API Key，请检查本机凭据文件的访问权限。" }
    }

    func loadKey() {
        guard !isWorkSuspended else { error = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        do {
            guard let key = try credentials.load(), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                error = "本 App 尚未保存执行模型 API Key。"
                return
            }
            apiKey = key
            credentialStatus = "已读取已保存的 API Key。"
            error = nil
        } catch let failure as LocalCredentialFailure { error = failure.message }
        catch { self.error = "无法读取执行模型 API Key，请检查本机凭据文件的访问权限。" }
    }

    func restoreSavedKeyForSettings() {
        guard !isWorkSuspended else { error = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        guard apiKey.isEmpty else { return }
        do {
            guard let key = try credentials.load(), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                credentialStatus = "本 App 尚未保存执行模型 API Key。"
                return
            }
            apiKey = key
            credentialStatus = "已自动恢复本机保存的 API Key。"
        } catch let failure as LocalCredentialFailure { credentialStatus = failure.message }
        catch { credentialStatus = "无法自动恢复执行模型 API Key，请检查本机凭据文件的访问权限。" }
    }

    func deleteKey() {
        guard !isWorkSuspended else { error = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        do {
            try credentials.delete()
            apiKey = ""
            credentialStatus = "已删除执行模型保存的 Key，并清空内存中的 Key。"
            error = nil
        } catch let failure as LocalCredentialFailure { error = failure.message }
        catch { self.error = "无法删除已保存的执行模型 API Key，请检查本机凭据文件的访问权限。" }
    }

    func saveSubscriptionToken() {
        guard !isWorkSuspended else { error = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        guard subscriptionAccounts == nil else {
            error = "请在账号列表中更新对应账号的 Token。"
            return
        }
        do {
            try LocalCredentialFailure.validate(subscriptionToken, scope: .subscription)
            try subscriptionCredentials.save(subscriptionToken)
            subscriptionCredentialStatus = "订阅 Token 已保存到本机。"
            error = nil
        } catch let failure as LocalCredentialFailure { subscriptionCredentialStatus = "订阅 Token 保存失败。"; error = failure.subscriptionMessage }
        catch { subscriptionCredentialStatus = "订阅 Token 保存失败。"; self.error = "无法保存订阅 Token，请检查本机凭据文件的访问权限。" }
    }

    func loadSubscriptionToken() {
        guard !isWorkSuspended else { error = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        guard subscriptionAccounts == nil else {
            error = "请在账号列表中选择要使用的账号。"
            return
        }
        do {
            guard let token = try subscriptionCredentials.load() else {
                error = "本 App 尚未保存订阅 Token，请先运行 claude setup-token 并粘贴结果。"
                return
            }
            try LocalCredentialFailure.validate(token, scope: .subscription)
            subscriptionToken = token
            subscriptionCredentialStatus = "已读取本机保存的订阅 Token。"
            error = nil
        } catch let failure as LocalCredentialFailure { error = failure.subscriptionMessage }
        catch { self.error = "无法读取订阅 Token，请检查本机凭据文件的访问权限。" }
    }

    func restoreSavedSubscriptionTokenForSettings() {
        guard !isWorkSuspended else { error = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        guard subscriptionAccounts == nil else { return }
        guard subscriptionToken.isEmpty else { return }
        do {
            guard let token = try subscriptionCredentials.load() else {
                subscriptionCredentialStatus = "本 App 尚未保存订阅 Token。"
                return
            }
            try LocalCredentialFailure.validate(token, scope: .subscription)
            subscriptionToken = token
            subscriptionCredentialStatus = "已自动恢复本机保存的订阅 Token。"
        } catch let failure as LocalCredentialFailure { subscriptionCredentialStatus = failure.subscriptionMessage }
        catch { subscriptionCredentialStatus = "无法自动恢复订阅 Token，请检查本机凭据文件的访问权限。" }
    }

    func deleteSubscriptionToken() {
        guard !isWorkSuspended else { error = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        guard subscriptionAccounts == nil else {
            error = "请在账号列表中清除对应账号的授权。"
            return
        }
        do {
            try subscriptionCredentials.delete()
            subscriptionToken = ""
            subscriptionCredentialStatus = "已删除本机保存的订阅 Token，并清空内存中的 Token。"
            error = nil
        } catch let failure as LocalCredentialFailure { error = failure.subscriptionMessage }
        catch { self.error = "无法删除订阅 Token，请检查本机凭据文件的访问权限。" }
    }

    var isTerminationWorkSettled: Bool {
        !testBusy && connectionTask == nil && (subscriptionAccounts?.isRefreshSettled ?? true)
    }
    func beginTermination() {
        isTerminationInProgress = true
        connectionTask?.cancel()
        subscriptionAccounts?.cancelRefreshes()
    }
    func endTermination() { isTerminationInProgress = false }

    func beginLoginReset() {
        isLoginResetInProgress = true
        connectionTask?.cancel()
        subscriptionAccounts?.cancelRefreshes()
    }

    func drainForLoginReset(timeoutSeconds: Double = 8) async throws {
        guard isLoginResetInProgress else { throw LoginResetLifecycleFailure.notStarted }
        try await waitForLoginReset(timeoutSeconds: timeoutSeconds) { self.isTerminationWorkSettled }
    }

    func endLoginReset() { isLoginResetInProgress = false }

    func clearSubscriptionForLoginReset() throws {
        guard isLoginResetInProgress else { throw LoginResetLifecycleFailure.notStarted }
        guard isTerminationWorkSettled, OwnedProcessRegistry.shared.activeCount == 0 else {
            throw LoginResetLifecycleFailure.workStillRunning
        }
        if let subscriptionAccounts {
            try subscriptionAccounts.clearCurrentCredentialForReset()
            clearingSubscriptionForReset = true
            subscriptionToken = ""
            clearingSubscriptionForReset = false
            testStatus = nil
            subscriptionCredentialStatus = "当前账号的授权已清除，其他账号已保留。"
            error = nil
            return
        }
        try subscriptionCredentials.delete()
        // Clear the bound input after disk commit even if readback fails; an old
        // Token must not remain available for a later send following deletion.
        clearingSubscriptionForReset = true
        subscriptionToken = ""
        clearingSubscriptionForReset = false
        testStatus = nil
        guard try subscriptionCredentials.load() == nil else { throw LoginResetLifecycleFailure.credentialReadbackFailed }
        if let fileStore = subscriptionCredentials as? FileCredentialStore {
            let persisted = FileCredentialStore(scope: .subscription, directoryURL: fileStore.directoryURL)
            guard try persisted.load() == nil else { throw LoginResetLifecycleFailure.credentialReadbackFailed }
        }
        subscriptionCredentialStatus = "旧订阅登录已清除；再次使用订阅时请保存新的 Token。"
        error = nil
    }

    private func ownedConnectionTest(_ operation: @escaping @Sendable () async throws -> ExecutionConnectionReply) async throws -> ExecutionConnectionReply {
        let task = Task {
            try Task.checkCancellation()
            let reply = try await operation()
            try Task.checkCancellation()
            return reply
        }
        connectionTask = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func testConnection() async {
        guard !isWorkSuspended, !testBusy else { return }
        testBusy = true
        defer { connectionTask = nil; testBusy = false }
        testStatus = "正在运行固定文本连接测试…"
        do {
            try Task.checkCancellation()
            guard let tester else { throw ExecutionConnectionFailure(code: "BRIDGE_MISSING") }
            if provider == .claudeSubscription {
                guard ["sonnet", "opus", "haiku"].contains(subscriptionModel) else { throw ExecutionConnectionFailure(code: "INVALID_PROFILE") }
                let accountSelection = try subscriptionAccounts?.currentSelection()
                if subscriptionAccounts == nil && subscriptionToken.isEmpty {
                    loadSubscriptionToken()
                    guard !subscriptionToken.isEmpty else { testStatus = "连接测试未通过。"; return }
                }
                let selectedToken = accountSelection?.token ?? subscriptionToken, selectedModel = subscriptionModel
                try LocalCredentialFailure.validate(selectedToken, scope: .subscription)
                let result = try await ownedConnectionTest { try await tester.testSubscription(token: selectedToken, model: selectedModel) }
                try Task.checkCancellation()
                let currentSelection = try subscriptionAccounts?.currentSelection()
                guard provider == .claudeSubscription, subscriptionModel == selectedModel,
                      currentSelection?.id == accountSelection?.id,
                      currentSelection?.credentialVersion == accountSelection?.credentialVersion,
                      (currentSelection?.token ?? subscriptionToken) == selectedToken else {
                    throw ExecutionConnectionFailure(code: "CONFIG_CHANGED")
                }
                testStatus = "官方 CLI 已通过 Claude 订阅文本连接测试：\(result.ack ?? "")。工具关闭。"
                error = nil
                return
            }
            guard baseURL == "https://api.deepseek.com/anthropic", ["deepseek-flash[1m]", "deepseek-flash"].contains(modelName) else {
                throw ExecutionConnectionFailure(code: "INVALID_PROFILE")
            }
            if apiKey.isEmpty {
                loadKey()
                guard !apiKey.isEmpty else {
                    testStatus = "连接测试未通过。"
                    return
                }
            }
            guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ExecutionConnectionFailure(code: "MISSING_KEY") }
            let selectedModel = modelName, selectedKey = apiKey, selectedURL = baseURL
            let result = try await ownedConnectionTest { try await tester.test(apiKey: selectedKey, model: selectedModel) }
            try Task.checkCancellation()
            guard provider == .deepseekAPI, modelName == selectedModel, apiKey == selectedKey, baseURL == selectedURL else {
                throw ExecutionConnectionFailure(code: "CONFIG_CHANGED")
            }
            testStatus = "官方 CLI 已通过 DeepSeek 文本连接测试：\(result.ack ?? "")。工具关闭。"
            error = nil
        } catch is CancellationError { testStatus = "连接测试已停止。"; error = nil }
        catch let failure as LocalCredentialFailure { error = provider == .claudeSubscription ? failure.subscriptionMessage : failure.message; testStatus = "连接测试未通过。" }
        catch let failure as SubscriptionAccountSelectionFailure { error = failure.message; testStatus = "连接测试未通过。" }
        catch let failure as ExecutionConnectionFailure { error = failure.message; testStatus = "连接测试未通过。" }
        catch { self.error = "连接测试发生错误；未启动项目工具。"; testStatus = "连接测试未通过。" }
    }
}
