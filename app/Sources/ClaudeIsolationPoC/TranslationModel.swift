import CryptoKit
import Darwin
import Foundation
import SwiftUI

enum TargetLanguage: String, CaseIterable, Identifiable {
    case english = "en", japanese = "ja"
    var id: String { rawValue }
    var title: String { self == .english ? "英语" : "日语" }
}

struct ModelConfiguration: Encodable, Equatable, Sendable {
    var endpoint: String
    var model: String
    var apiKey: String
}

struct TranslationRequest: Encodable, Sendable {
    let request_id: String
    let operation: String
    let text: String
    let target: String
    let model: ModelConfiguration
    var network: AppNetworkPolicy? = nil
    var runtime: AppRuntimeProfile? = nil
    enum CodingKeys: String, CodingKey { case operation, text, target, model, network, runtime }
}

struct TranslationReply: Decodable, Sendable {
    let ok: Bool
    let request_id: String?
    let original: String?
    let translated: String?
    let revision: Int?
    let translation_sha256: String?
    let requires_confirmation: Bool?
    let error_code: String?
    let fixture_only: Bool?
}

enum TranslationFailure: Error {
    case code(String)
    var message: String {
        switch self {
        case .code(let code):
            if let message = appNetworkFailureMessage(code) ?? appRuntimeFailureMessage(code) { return message }
            let known = ["MISSING_API_KEY": "请在设置中配置翻译模型 API Key。", "INVALID_ENDPOINT": "模型地址需要有效 HTTPS 地址。", "INVALID_CONFIG": "翻译模型配置无效，请检查服务地址、模型和 API Key。", "RATE_LIMITED": "翻译模型限流，请稍后重试。", "TIMEOUT": "翻译模型响应超时，请重试。", "HTTP_ERROR": "翻译服务返回错误，请检查配置与服务状态。", "TRANSPORT_ERROR": "无法连接翻译服务，请检查网络。", "REQUEST_TOO_LARGE": "输入过大，请缩短后重试。", "INPUT_TOO_LARGE": "输入过大，请缩短后重试。", "PLACEHOLDER_MISMATCH": "代码或命令保护校验失败，译文未被接受。", "FRAGMENT_INTEGRITY": "原文片段完整性校验失败，译文未被接受。", "TRANSLATION_BRIDGE_MISSING": "翻译桥未安装，请从项目重新打包。", "NODE_NOT_AVAILABLE": "配置的 Node 不可执行，请重新打包。", "TRANSLATION_RESPONSE_INVALID": "翻译响应未通过关联与摘要验证。", "TRANSLATION_PROCESS_FAILED": "翻译服务执行失败，译文未被接受。", "TRANSLATION_TIMEOUT": "翻译超时，请重试。", "TRANSLATION_OUTPUT_TOO_LARGE": "翻译响应过大，已停止处理。"]
            let bridgeCodes: Set<String> = ["INVALID_REQUEST", "REQUEST_TOO_LARGE", "INVALID_CONFIG", "INVALID_INPUT", "INPUT_TOO_LARGE", "EMPTY_SOURCE", "INVALID_TARGET", "INVALID_KEEP_RANGE", "RESERVED_PLACEHOLDER", "INVALID_SOURCE", "INVALID_TRANSLATION", "BUSY", "RATE_LIMITED", "TIMEOUT", "ABORTED", "TRANSPORT_ERROR", "RESPONSE_TOO_LARGE", "RESPONSE_SCHEMA", "INVALID_CONTENT_TYPE", "INVALID_JSON", "INCOMPLETE_COMPLETION", "INVALID_TRANSLATION_JSON", "TRANSLATION_SCHEMA", "HTTP_ERROR", "REDIRECT_REFUSED", "EMPTY_TRANSLATION", "PLACEHOLDER_MISMATCH", "UNEXPECTED_PROTECTED_CONTENT", "FRAGMENT_INTEGRITY", "TRANSLATION_CANCELLED", "STALE_TRANSLATION", "TRANSLATION_FAILED"]
            return known[code] ?? (bridgeCodes.contains(code) ? "翻译失败（\(code)），译文未被接受。" : "翻译响应错误类型无效，译文未被接受。")
        }
    }
}

protocol TranslationProviding: Sendable {
    func translate(_ request: TranslationRequest) async throws -> TranslationReply
}

struct AppConfiguration: Decodable, Sendable {
    let projectRoot: String
    let nodeExecutable: String
    let runtimePackages: (any RuntimePackageManaging)?

    init(projectRoot: String, nodeExecutable: String, runtimePackages: (any RuntimePackageManaging)? = nil) {
        self.projectRoot = projectRoot; self.nodeExecutable = nodeExecutable; self.runtimePackages = runtimePackages
    }
    private enum CodingKeys: String, CodingKey { case projectRoot, nodeExecutable }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        projectRoot = try fields.decode(String.self, forKey: .projectRoot)
        nodeExecutable = try fields.decode(String.self, forKey: .nodeExecutable)
        runtimePackages = nil
    }

    func resolvingClaudeRuntime() throws -> AppConfiguration {
        guard let runtimePackages else { return self }
        return AppConfiguration(projectRoot: try runtimePackages.resolvedRuntimeRoot().appendingPathComponent("Resources/Runtime", isDirectory: true).path, nodeExecutable: nodeExecutable)
    }

    static func load() throws -> AppConfiguration {
        guard let url = Bundle.main.url(forResource: "ProjectConfiguration", withExtension: "json") else {
            throw TranslationFailure.code("TRANSLATION_BRIDGE_MISSING")
        }
        let configured = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        // Packaged execution code belongs to the App, independent of the source checkout.
        let runtime = Bundle.main.resourceURL?.appendingPathComponent("Runtime", isDirectory: true)
        let configuration = AppConfiguration(projectRoot: runtime.flatMap {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("translation/stdio.mjs").path) ? $0.path : nil
        } ?? configured.projectRoot, nodeExecutable: configured.nodeExecutable,
            runtimePackages: RuntimePackageEnvironment.store)
        guard configuration.projectRoot.hasPrefix("/"), configuration.nodeExecutable.hasPrefix("/") else {
            throw TranslationFailure.code("NODE_NOT_AVAILABLE")
        }
        return configuration
    }
}

struct StdioTranslationProvider: TranslationProviding {
    let configuration: AppConfiguration
    var fixtureOnly = false
    var networkPolicyProvider: any NetworkPolicyProviding = SavedNetworkPolicyProvider()
    var runtimeProfileProvider: any RuntimeProfileProviding = SavedRuntimeProfileProvider()

    func translate(_ request: TranslationRequest) async throws -> TranslationReply {
        let controller = OwnedProcessController()
        try controller.registerWork()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { controller.finish() }
                    do { continuation.resume(returning: try execute(request, controller: controller)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { controller.cancel() }
    }

    private func execute(_ request: TranslationRequest, controller: OwnedProcessController) throws -> TranslationReply {
        var securedRequest = request
        do { securedRequest.network = fixtureOnly ? .defaultPolicy : try networkPolicyProvider.snapshot() }
        catch let failure as NetworkPolicyFailure { throw TranslationFailure.code(failure.code) }
        catch { throw TranslationFailure.code("NETWORK_POLICY_INVALID") }
        let runtime: AppRuntimeProfile
        do { runtime = fixtureOnly ? .japan : try runtimeProfileProvider.snapshot() }
        catch let failure as RuntimeProfileFailure { throw TranslationFailure.code(failure.code) }
        catch { throw TranslationFailure.code("RUNTIME_PROFILE_INVALID") }
        securedRequest.runtime = runtime
        let script = URL(fileURLWithPath: configuration.projectRoot).appendingPathComponent("translation/stdio.mjs")
        guard FileManager.default.fileExists(atPath: script.path) else { throw TranslationFailure.code("TRANSLATION_BRIDGE_MISSING") }
        guard FileManager.default.isExecutableFile(atPath: configuration.nodeExecutable) else { throw TranslationFailure.code("NODE_NOT_AVAILABLE") }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: configuration.nodeExecutable)
        process.arguments = [script.path] + (fixtureOnly ? ["--fixture"] : [])
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.projectRoot).appendingPathComponent("translation")
        // Never inherit user credentials, proxy settings, or keys through the environment.
        process.environment = runtime.processEnvironment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let timeout = DispatchWorkItem { if process.isRunning { controller.cancel(timedOut: true) } }
        try controller.install(process)
        do { try process.run() }
        catch { throw TranslationFailure.code("TRANSLATION_PROCESS_FAILED") }
        controller.didStart()
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { controller.terminateForCleanup(); process.waitUntilExit() }
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        }
        guard !controller.isCancelled else { throw CancellationError() }
        let payload = try JSONEncoder().encode(securedRequest)
        try input.fileHandleForWriting.write(contentsOf: payload + Data([10]))
        try input.fileHandleForWriting.close()
        var data = Data()
        while true {
            let chunk = try output.fileHandleForReading.read(upToCount: 16_384) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > 1_048_576 {
                process.terminate()
                throw TranslationFailure.code("TRANSLATION_OUTPUT_TOO_LARGE")
            }
        }
        process.waitUntilExit()
        if controller.isTimedOut { throw TranslationFailure.code("TRANSLATION_TIMEOUT") }
        if controller.isCancelled { throw CancellationError() }
        guard let reply = try? JSONDecoder().decode(TranslationReply.self, from: data) else {
            throw TranslationFailure.code(process.terminationStatus == 0 ? "TRANSLATION_RESPONSE_INVALID" : "TRANSLATION_PROCESS_FAILED")
        }
        if reply.ok {
            guard process.terminationStatus == 0, reply.fixture_only == fixtureOnly else { throw TranslationFailure.code("TRANSLATION_RESPONSE_INVALID") }
        }
        return reply
    }
}

protocol AppCredentialStoring {
    func load() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

struct ConfirmedTranslation: Equatable {
    let draftRevision: Int
    let requestID: String
    let sha256: String
}

struct AcceptedTranslation {
    let draftRevision: Int
    let requestID: String
    let invocationID: String
    let original: String
    let translated: String
    let sha256: String
    let bridgeRevision: Int
    var confirmation: ConfirmedTranslation { .init(draftRevision: draftRevision, requestID: requestID, sha256: sha256) }
}

@MainActor
final class TranslationViewModel: ObservableObject {
    @Published var inputText = "" { didSet { if oldValue != inputText { invalidateInput() } } }
    @Published var outputText = "" { didSet { if oldValue != outputText { invalidateOutput() } } }
    @Published var targetLanguage = TargetLanguage.english { didSet { if oldValue != targetLanguage { invalidateInput() } } }
    @Published var endpoint = "https://api.deepseek.com/chat/completions" { didSet { if oldValue != endpoint { invalidateBoth() } } }
    @Published var modelName = "deepseek-flash" { didSet { if oldValue != modelName { invalidateBoth() } } }
    @Published var apiKey = "" { didSet { if restoringCredentialBinding { return }; if isWorkSuspended { restoringCredentialBinding = true; apiKey = oldValue; restoringCredentialBinding = false; return }; if oldValue != apiKey { invalidateBoth(); credentialStatus = apiKey.isEmpty ? "凭据未载入。" : "凭据仅在本次运行内存中。" } } }
    @Published private(set) var inputTranslation: AcceptedTranslation?
    @Published private(set) var outputTranslation: AcceptedTranslation?
    @Published private(set) var confirmation: ConfirmedTranslation?
    @Published private(set) var inputBusy = false
    @Published private(set) var outputBusy = false
    @Published private(set) var inputError: String?
    @Published private(set) var outputError: String?
    @Published private(set) var credentialStatus: String?
    @Published private(set) var configurationStatus = "公开配置尚未保存。"
    @Published private(set) var isLoginResetInProgress = false
    @Published private(set) var isTerminationInProgress = false
    private var isWorkSuspended: Bool { isLoginResetInProgress || isTerminationInProgress }
    private var restoringCredentialBinding = false
    private var inputTask: Task<TranslationReply, Error>?
    private var outputTask: Task<TranslationReply, Error>?
    private var inputRevision = 0, outputRevision = 0
    private var inputRequestID: String?, outputRequestID: String?
    private let provider: any TranslationProviding
    private let configurationStore: TranslationConfigurationStore
    private let credentials: any AppCredentialStoring

    init(provider: any TranslationProviding, configurationStore: TranslationConfigurationStore = .init(), credentials: any AppCredentialStoring = FileCredentialStore(scope: .translation)) {
        self.provider = provider
        self.configurationStore = configurationStore
        self.credentials = credentials
        switch configurationStore.load() {
        case .missing: break
        case .configured(let profile):
            endpoint = profile.endpoint; modelName = profile.model
            configurationStatus = "翻译模型公开配置已保存。"
        case .invalid(let failure): configurationStatus = failure.message
        }
    }
    func saveConfiguration() {
        guard !isWorkSuspended else { credentialStatus = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        do {
            try configurationStore.save(.init(endpoint: endpoint, model: modelName))
            configurationStatus = "翻译模型公开配置已保存。"
        } catch let failure as TranslationConfigurationError { configurationStatus = failure.message }
        catch { configurationStatus = "无法保存翻译模型公开配置。" }
    }
    var inputIsConfirmed: Bool { inputTranslation.map { $0.confirmation == confirmation && $0.draftRevision == inputRevision } ?? false }
    var canConfirm: Bool { !isWorkSuspended && !inputBusy && inputError == nil && inputTranslation?.draftRevision == inputRevision }
    // Full admission is deliberately closed, independently of any evidence display.
    var canSendToClaude: Bool { false }
    var canTranslateInput: Bool { !isWorkSuspended && !inputBusy && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canTranslateOutput: Bool { !isWorkSuspended && !outputBusy && !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func invalidateInput() {
        inputRevision += 1; inputRequestID = nil; inputTranslation = nil; confirmation = nil; inputError = nil
    }
    private func invalidateOutput() {
        outputRevision += 1; outputRequestID = nil; outputTranslation = nil; outputError = nil
    }
    private func invalidateBoth() { invalidateInput(); invalidateOutput() }
    private var model: ModelConfiguration { .init(endpoint: endpoint, model: modelName, apiKey: apiKey) }
    private func makeRequest(operation: String, text: String, target: String) throws -> TranslationRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationFailure.code("MISSING_API_KEY") }
        guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw TranslationFailure.code("INVALID_ENDPOINT")
        }
        return .init(request_id: UUID().uuidString.lowercased(), operation: operation, text: text, target: target, model: model)
    }
    private func accept(_ reply: TranslationReply, request: TranslationRequest, draftRevision: Int) throws -> AcceptedTranslation {
        if !reply.ok { throw TranslationFailure.code(reply.error_code ?? "TRANSLATION_RESPONSE_INVALID") }
        guard let bridgeRequestID = reply.request_id, UUID(uuidString: bridgeRequestID) != nil, reply.original == request.text,
              let translated = reply.translated, let sha = reply.translation_sha256,
              let revision = reply.revision, revision > 0, reply.requires_confirmation == (request.operation == "translate_input"),
              sha == SHA256.hash(data: Data(translated.utf8)).map({ String(format: "%02x", $0) }).joined() else {
            throw TranslationFailure.code("TRANSLATION_RESPONSE_INVALID")
        }
        return .init(draftRevision: draftRevision, requestID: bridgeRequestID, invocationID: request.request_id, original: request.text, translated: translated, sha256: sha, bridgeRevision: revision)
    }
    var isTerminationWorkSettled: Bool { !inputBusy && !outputBusy && inputTask == nil && outputTask == nil }
    func beginTermination() {
        isTerminationInProgress = true
        inputTask?.cancel(); outputTask?.cancel()
    }
    func endTermination() { isTerminationInProgress = false }

    func beginLoginReset() {
        isLoginResetInProgress = true
        inputTask?.cancel(); outputTask?.cancel()
    }
    func drainForLoginReset(timeoutSeconds: Double = 8) async throws {
        guard isLoginResetInProgress else { throw LoginResetLifecycleFailure.notStarted }
        try await waitForLoginReset(timeoutSeconds: timeoutSeconds) {
            !self.inputBusy && !self.outputBusy && self.inputTask == nil && self.outputTask == nil
        }
    }
    func endLoginReset() { isLoginResetInProgress = false }

    func translateInput() async {
        guard canTranslateInput else { return }
        inputTranslation = nil; confirmation = nil; inputError = nil; inputBusy = true
        let draft = inputRevision
        defer { inputTask = nil; inputBusy = false }
        do {
            try Task.checkCancellation()
            let request = try makeRequest(operation: "translate_input", text: inputText, target: targetLanguage.rawValue)
            inputRequestID = request.request_id
            let provider = self.provider
            let task = Task {
                try Task.checkCancellation()
                let reply = try await provider.translate(request)
                try Task.checkCancellation()
                return reply
            }
            inputTask = task
            let reply = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard inputRevision == draft && inputRequestID == request.request_id else { return }
            inputTranslation = try accept(reply, request: request, draftRevision: draft)
        } catch {
            guard inputRevision == draft else { return }
            inputError = (error as? TranslationFailure)?.message ?? "翻译执行失败，译文未被接受。"
        }
    }
    func confirmInput() {
        guard canConfirm, let translation = inputTranslation, translation.draftRevision == inputRevision,
              translation.invocationID == inputRequestID,
              translation.sha256 == SHA256.hash(data: Data(translation.translated.utf8)).map({ String(format: "%02x", $0) }).joined() else { return }
        confirmation = translation.confirmation
    }
    func translateOutput() async {
        guard canTranslateOutput else { return }
        outputTranslation = nil; outputError = nil; outputBusy = true
        let draft = outputRevision
        defer { outputTask = nil; outputBusy = false }
        do {
            try Task.checkCancellation()
            let request = try makeRequest(operation: "translate_output", text: outputText, target: "zh")
            outputRequestID = request.request_id
            let provider = self.provider
            let task = Task {
                try Task.checkCancellation()
                let reply = try await provider.translate(request)
                try Task.checkCancellation()
                return reply
            }
            outputTask = task
            let reply = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard outputRevision == draft && outputRequestID == request.request_id else { return }
            outputTranslation = try accept(reply, request: request, draftRevision: draft)
        } catch {
            guard outputRevision == draft else { return }
            outputError = (error as? TranslationFailure)?.message ?? "翻译执行失败，原文仍可查看。"
        }
    }
    func saveKey() {
        guard !isWorkSuspended else { credentialStatus = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            credentialStatus = "请先填写 API Key。"
            return
        }
        do {
            try credentials.save(apiKey)
            credentialStatus = "已保存到本机。"
        } catch let failure as LocalCredentialFailure { credentialStatus = failure.message }
        catch { credentialStatus = "无法保存翻译模型 API Key，请检查本机凭据文件的访问权限。" }
    }
    func loadKey() {
        guard !isWorkSuspended else { credentialStatus = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        do {
            guard let key = try credentials.load(), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                credentialStatus = "本 App 尚未保存翻译模型 API Key。"
                return
            }
            apiKey = key
            credentialStatus = "已读取已保存的 API Key。"
        } catch let failure as LocalCredentialFailure { credentialStatus = failure.message }
        catch { credentialStatus = "无法读取翻译模型 API Key，请检查本机凭据文件的访问权限。" }
    }
    func restoreSavedKeyForSettings() {
        guard !isWorkSuspended else { credentialStatus = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        guard apiKey.isEmpty else { return }
        do {
            guard let key = try credentials.load(), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                credentialStatus = "本 App 尚未保存翻译模型 API Key。"
                return
            }
            apiKey = key
            credentialStatus = "已自动恢复本机保存的 API Key。"
        } catch let failure as LocalCredentialFailure { credentialStatus = failure.message }
        catch { credentialStatus = "无法自动恢复翻译模型 API Key，请检查本机凭据文件的访问权限。" }
    }
    func deleteKey() {
        guard !isWorkSuspended else { credentialStatus = isTerminationInProgress ? "正在退出 App，请等待任务停止。" : "正在清理登录，请等待完成。"; return }
        do {
            try credentials.delete()
            apiKey = ""
            credentialStatus = "已删除已保存的翻译模型 API Key，并清空内存中的 Key。"
        } catch let failure as LocalCredentialFailure { credentialStatus = failure.message }
        catch { credentialStatus = "无法删除已保存的翻译模型 API Key，请检查本机凭据文件的访问权限。" }
    }
}
