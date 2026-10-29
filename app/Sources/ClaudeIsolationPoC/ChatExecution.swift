import Foundation
import CoreFoundation
import Darwin

struct ChatTranscriptMessage: Codable, Equatable, Sendable {
    let role: String
    let text: String
}

struct ChatProject: Encodable, Equatable, Sendable {
    static let tools: Set<String> = ["Read", "Write", "Edit", "Bash", "Glob", "Grep"]
    static let maximumRequests = 24
    static let maximumToolCalls = 64
    let directory: String

    func validate() throws {
        do { try ProjectDirectory.validateStoredPath(directory) }
        catch { throw ChatFailure.code("INVALID_PROJECT_DIRECTORY") }
    }
}

struct ChatRequest: Encodable, Sendable {
    let schema = "deepseek-text-chat/v1"
    let request_id: String
    var apiKey: String? = nil
    let model: String
    let messages: [ChatTranscriptMessage]
    var provider: ExecutionProvider = .deepseekAPI
    var subscriptionToken: String? = nil
    var text_skills: [TextSkillContext] = []
    var network: AppNetworkPolicy? = nil
    var runtime: AppRuntimeProfile? = nil
    var identity: ClaudeRequestIdentity? = nil
    var project: ChatProject? = nil
    // App-owned conversation UUID; only the broker identity envelope is encoded.
    var conversationSessionID: UUID? = nil

    private enum CodingKeys: String, CodingKey {
        case schema, request_id, apiKey, model, messages, provider, subscriptionToken, text_skills, network, runtime, identity, project
    }

    func validate() throws {
        guard UUID(uuidString: request_id) != nil else { throw ChatFailure.code("INVALID_REQUEST_ID") }
        try project?.validate()
        switch provider {
        case .deepseekAPI:
            guard subscriptionToken == nil, identity == nil else { throw ChatFailure.code("CREDENTIAL_MODE_MISMATCH") }
            guard ["deepseek-flash[1m]", "deepseek-flash"].contains(model) else { throw ChatFailure.code("MODEL_NOT_ALLOWED") }
            guard let apiKey, (16...512).contains(apiKey.utf8.count),
                  !apiKey.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
            else { throw ChatFailure.code("INVALID_API_KEY") }
        case .claudeSubscription:
            guard apiKey == nil else { throw ChatFailure.code("CREDENTIAL_MODE_MISMATCH") }
            guard ["sonnet", "opus", "haiku"].contains(model) else { throw ChatFailure.code("MODEL_NOT_ALLOWED") }
            guard let subscriptionToken else { throw ChatFailure.code("MISSING_SUBSCRIPTION_TOKEN") }
            do { try LocalCredentialFailure.validateSubscriptionToken(subscriptionToken) }
            catch { throw ChatFailure.code("INVALID_SUBSCRIPTION_TOKEN") }
            if let identity {
                do { try identity.validate() }
                catch { throw ChatFailure.code("INSTALLATION_IDENTITY_UNAVAILABLE") }
            }
        }
        guard !messages.isEmpty, messages.count <= 101, messages.count % 2 == 1 else { throw ChatFailure.code("INVALID_HISTORY") }
        var bytes = 0
        for (index, message) in messages.enumerated() {
            guard message.role == (index % 2 == 0 ? "user" : "assistant"),
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ChatFailure.code("INVALID_HISTORY") }
            bytes += message.text.utf8.count
            guard bytes <= 131_072 else { throw ChatFailure.code("HISTORY_LIMIT") }
        }
        var skillBytes = 0
        var skillNames: Set<String> = []
        guard text_skills.count <= 8 else { throw ChatFailure.code("INVALID_TEXT_SKILLS") }
        for skill in text_skills {
            guard !skill.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  skill.name.unicodeScalars.count <= 80,
                  !skill.name.unicodeScalars.contains(where: { [.control, .format].contains($0.properties.generalCategory) }),
                  skillNames.insert(skill.name).inserted,
                  !skill.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  skill.content.utf8.count <= 32_768
            else { throw ChatFailure.code("INVALID_TEXT_SKILLS") }
            skillBytes += skill.name.utf8.count + skill.content.utf8.count
            guard skillBytes <= 65_536 else { throw ChatFailure.code("INVALID_TEXT_SKILLS") }
        }
    }
}

enum ChatEvent: Equatable, Sendable {
    case started
    case delta(String)
    case completed(String)
    case requestTrace(ChatRequestTrace)
    case toolActivity(tool: String, phase: String, toolID: String)
}

enum ChatFailure: Error, Sendable {
    case code(String)

    var message: String {
        switch self {
        case .code("MISSING_API_KEY"), .code("MISSING_KEY"), .code("INVALID_API_KEY"):
            return "请在设置中填写或保存对应模型的 API Key。"
        case .code("CHAT_NOT_CONFIGURED"), .code("INVALID_PROFILE"), .code("MODEL_NOT_ALLOWED"):
            return "请在设置中选择执行来源及其支持的模型。"
        case .code("MISSING_SUBSCRIPTION_TOKEN"), .code("INVALID_SUBSCRIPTION_TOKEN"):
            return "请在 Claude 订阅设置中填写并保存 claude setup-token 生成的有效 Token。"
        case .code("CREDENTIAL_MODE_MISMATCH"):
            return "执行来源与凭据不匹配，请检查 Claude Code 设置后重试。"
        case .code("INSTALLATION_IDENTITY_UNAVAILABLE"):
            return "无法读取或保存本机设备身份，本次模型请求未发送。请检查 App 数据目录权限；已有身份文件不会自动重建。"
        case .code("VM_IDENTITY_UNSUPPORTED"):
            return "当前运行包不支持稳定设备与会话身份。请在更新设置中选择新版运行包或此版本 App 的内置运行包。"
        case .code("VM_PROJECT_UNSUPPORTED"), .code("PROJECT_EXECUTION_UNSUPPORTED"), .code("VM_PROJECT_REQUIRED"):
            return "当前运行环境不支持项目目录执行。请更新支持项目执行的运行包后重试；本次未切换为纯文本请求。"
        case .code("INVALID_PROJECT_DIRECTORY"), .code("PROJECT_DIRECTORY_UNAVAILABLE"), .code("PROJECT_DIRECTORY_CHANGED"):
            return "执行目录不存在、权限不足或已发生变化。请重新选择可读写的项目文件夹。"
        case .code("PROJECT_DIRECTORY_PROTECTED"), .code("PROJECT_DIRECTORY_FORBIDDEN"):
            return "请选取具体的项目文件夹；整个用户主目录及 App 私有数据目录不能作为执行目录。"
        case .code("PROJECT_MOUNT_REJECTED"), .code("PROJECT_MOUNT_UNAVAILABLE"):
            return "隔离环境未能挂载所选执行目录，本次项目执行已停止。请检查目录权限和运行包。"
        case .code("PROJECT_TOOL_REJECTED"), .code("PROJECT_TOOL_CONTRACT"), .code("PROJECT_PATH_REJECTED"):
            return "项目工具请求超出所选目录或允许的工具范围，本次执行已停止。"
        case .code("PROJECT_CONTRACT_REJECTED"), .code("PROJECT_PROTOCOL_REJECTED"),
             .code("PROJECT_TOOL_PROTOCOL_REJECTED"), .code("PROJECT_TOOL_RESULT_REJECTED"), .code("PROJECT_TRANSCRIPT_REJECTED"):
            return "项目工具调用或执行结果未通过校验，本次执行已停止。请检查运行包或重试。"
        case .code("INVALID_IDENTITY"), .code("NATIVE_IDENTITY_MISMATCH"), .code("GUEST_IDENTITY_CONFIG_FAILED"):
            return "Claude 设备或会话身份未通过校验，本次请求已停止。请更新运行包后重试。"
        case .code("SUBSCRIPTION_PROTOCOL_REJECTED"):
            return "官方 CLI 的订阅协议未通过校验，请更新 App 后重试。"
        case .code("SUBSCRIPTION_HTTP_401"), .code("SUBSCRIPTION_HTTP_403"):
            return "Claude 订阅认证失败，请检查订阅权限；Token 过期时重新运行 claude setup-token 并保存。"
        case .code("SUBSCRIPTION_HTTP_429"):
            return "Claude 订阅额度或请求频率受限，请稍后重试；本次不会切换到 API 计费。"
        case .code("CREDENTIAL_STORE_UNAVAILABLE"):
            return "无法读取本机保存的凭据，请检查 App 凭据目录权限或文件格式后重试。"
        case .code("SUBSCRIPTION_ACCOUNT_REQUIRED"):
            return "请在设置中添加并选择一个 Claude 订阅账号，再重新发送。"
        case .code("CHAT_BRIDGE_MISSING"), .code("NODE_NOT_AVAILABLE"):
            return "文本会话运行文件不可用，请检查 App 的安装路径。"
        case .code("INVALID_HISTORY"), .code("HISTORY_LIMIT"), .code("INPUT_LIMIT"):
            return "会话内容超过文本通道限制，请新建会话后重试。"
        case .code("INVALID_TEXT_SKILLS"):
            return "文本 Skills 超过限制或内容无效，请在设置中减少启用项或重新导入。"
        case .code("CHAT_CANCELLED"), .code("PROCESS_INTERRUPTED"):
            return "已停止本次回复。"
        case .code("CHAT_TIMEOUT"), .code("TOTAL_TIMEOUT"), .code("PROVIDER_TIMEOUT"):
            return "模型回复超时，请稍后重试。"
        case .code("PROVIDER_HTTP_401"), .code("PROVIDER_HTTP_403"):
            return "模型服务拒绝了请求，请检查 API Key 和访问权限。"
        case .code("PROVIDER_HTTP_402"):
            return "模型账户余额不足，请检查 DeepSeek 账户。"
        case .code("PROVIDER_HTTP_429"):
            return "模型请求受到频率限制，请稍后重试。"
        case .code("NO_TOOLS_CONTRACT"), .code("PROVIDER_TOOL_RESPONSE"):
            return "文本会话检测到工具执行请求，本次回复已停止。"
        case .code("CHAT_RESPONSE_INVALID"), .code("CLI_TEXT_MISMATCH"), .code("PROVIDER_PROTOCOL_REJECTED"), .code("PROVIDER_STREAM_INCOMPLETE"):
            return "模型回复未通过完整性检查，已保留收到的原文。"
        case .code("CHAT_OUTPUT_TOO_LARGE"), .code("PROVIDER_OUTPUT_LIMIT"), .code("PROVIDER_RESPONSE_LIMIT"):
            return "模型回复超过本次文本通道限制，已保留收到的原文。"
        default:
            if case .code(let code) = self, code.hasPrefix("SUBSCRIPTION_HTTP_") {
                return "Claude 订阅服务未能完成请求，请稍后重试；不会切换到 API 计费。"
            }
            if case .code(let code) = self, let message = appNetworkFailureMessage(code) ?? appRuntimeFailureMessage(code) ?? appVMFailureMessage(code) { return message }
            return "文本会话执行失败，请检查模型配置后重试。"
        }
    }
}

protocol ChatProviding: Sendable {
    func events(for request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

struct UnavailableChatProvider: ChatProviding {
    func events(for request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ChatFailure.code("CHAT_NOT_CONFIGURED")) }
    }
}

enum LoginResetLifecycleFailure: Error, LocalizedError, Equatable {
    case notStarted, workStillRunning, drainTimedOut, credentialReadbackFailed, conversationReadbackFailed
    var errorDescription: String? {
        switch self {
        case .notStarted: "请先开始登录清理。"
        case .workStillRunning: "旧任务仍未完全退出，未删除订阅 Token。请停止任务后重试。"
        case .drainTimedOut: "等待旧任务退出超时，未删除订阅 Token。请稍后重试；必要时退出并重新打开 App。"
        case .credentialReadbackFailed: "订阅 Token 删除后回读验证未通过，请检查本机凭据文件。"
        case .conversationReadbackFailed: "新会话保存或回读验证失败，已有会话已保留。请检查磁盘和数据目录权限。"
        }
    }
}

@MainActor
func waitForLoginReset(timeoutSeconds: Double, until settled: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(max(0, timeoutSeconds)))
    while !settled() {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw LoginResetLifecycleFailure.drainTimedOut }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Includes dispatch work that outlives an AsyncThrowingStream consumer. Reset
/// closes launch admission before cancellation and waits for worker cleanup.
final class OwnedProcessRegistry: @unchecked Sendable {
    static let shared = OwnedProcessRegistry()
    private let lock = NSLock()
    private var resetting = false
    private var terminating = false
    private var workers: [UUID: OwnedProcessController] = [:]
    var activeCount: Int { lock.lock(); defer { lock.unlock() }; return workers.count }
    var isLoginResetInProgress: Bool { lock.lock(); defer { lock.unlock() }; return resetting }

    var isTerminationInProgress: Bool { lock.lock(); defer { lock.unlock() }; return terminating }

    // Share the admission lock with worker registration so no request can
    // capture a runtime while its active-version pointer is being replaced.
    func performRuntimeSwitchWhenIdle(_ change: () throws -> Void) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !resetting, !terminating, workers.isEmpty else { return false }
        try change()
        return true
    }

    fileprivate func register(_ controller: OwnedProcessController, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard !terminating else { throw ApplicationTerminationFailure.workAdmissionClosed }
        guard !resetting else { throw LoginResetLifecycleFailure.workStillRunning }
        workers[id] = controller
    }
    fileprivate func finished(_ id: UUID) {
        lock.lock(); workers.removeValue(forKey: id); lock.unlock()
    }
    func beginTermination() {
        lock.lock(); terminating = true; let active = Array(workers.values); lock.unlock()
        for controller in active { controller.cancel() }
    }
    func endTermination() { lock.lock(); terminating = false; lock.unlock() }
    func beginLoginReset() {
        lock.lock(); resetting = true; let active = Array(workers.values); lock.unlock()
        for controller in active { controller.cancel() }
    }
    @MainActor
    func drainForLoginReset(timeoutSeconds: Double = 8) async throws {
        guard isLoginResetInProgress else { throw LoginResetLifecycleFailure.notStarted }
        try await waitForLoginReset(timeoutSeconds: timeoutSeconds) { self.activeCount == 0 }
    }
    func endLoginReset() { lock.lock(); resetting = false; lock.unlock() }
}

/// Keeps termination limited to the Process created by a single provider call.
/// Install before `run()`, then call `didStart()` immediately after `run()` to
/// cover cancellation racing with launch. Call `finish()` only after exit.
final class OwnedProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private let workID = UUID()
    private var registry: OwnedProcessRegistry?

    func registerWork(in registry: OwnedProcessRegistry = .shared) throws {
        try registry.register(self, id: workID)
        self.registry = registry
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var isTimedOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }

    func install(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw ChatFailure.code("CHAT_CANCELLED") }
        guard self.process == nil else { throw ChatFailure.code("CHAT_PROCESS_FAILED") }
        self.process = process
    }

    func didStart() {
        lock.lock()
        let shouldStop = cancelled
        let owned = process
        lock.unlock()
        if shouldStop, let owned { terminate(owned) }
    }

    /// Multi-stage maintenance keeps one admission/cancellation lease while
    /// replacing only a process which has actually exited.
    func clearFinishedProcess(_ finished: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard process === finished, !finished.isRunning else { throw ChatFailure.code("CHAT_PROCESS_FAILED") }
        process = nil
    }

    func cancel(timedOut: Bool = false) {
        lock.lock()
        cancelled = true
        self.timedOut = self.timedOut || timedOut
        let owned = process
        lock.unlock()
        if let owned { terminate(owned) }
    }

    func finish() {
        lock.lock()
        process = nil
        let completedRegistry = registry
        registry = nil
        lock.unlock()
        completedRegistry?.finished(workID)
    }

    /// Cleanup after a protocol or provider failure must not relabel that
    /// failure as a user cancellation.
    func terminateForCleanup() {
        lock.lock()
        let owned = process
        lock.unlock()
        if let owned { terminate(owned) }
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        // Give an owned VM launcher time to stop its guest and descendants before escalation.
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

/// Validates each event before exposing it to the conversation. Completion is
/// held until EOF and a successful process exit have both been observed.
struct ChatEventParser {
    private let requestID: String
    private let model: String
    private let fixtureOnly: Bool
    private let provider: ExecutionProvider
    private let projectExecution: Bool
    private let knownSecrets: [String]
    private var started = false
    private var terminalText: String?
    private var cumulativeText = ""
    private var requestTraces: [ChatRequestTrace] = []
    private var toolCalls: [String: (tool: String, phase: String)] = [:]
    private var maximumRequests: Int { projectExecution ? ChatProject.maximumRequests : 3 }

    init(requestID: String, model: String, fixtureOnly: Bool, provider: ExecutionProvider = .deepseekAPI,
         projectExecution: Bool = false, knownSecrets: [String] = []) {
        self.requestID = requestID
        self.model = model
        self.fixtureOnly = fixtureOnly
        self.provider = provider
        self.projectExecution = projectExecution
        self.knownSecrets = knownSecrets
    }

    mutating func consume(_ data: Data) throws -> ChatEvent? {
        guard terminalText == nil,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["schema"] as? String == "deepseek-text-chat-event/v1",
              value["request_id"] as? String == requestID,
              value["model"] as? String == model,
              boolean(value["fixture_only"]) == fixtureOnly,
              let type = value["type"] as? String
        else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
        let common: Set<String> = ["schema", "request_id", "model", "type", "fixture_only"]
        switch type {
        case "started":
            guard Set(value.keys) == common.union(["no_tools"]), !started, boolean(value["no_tools"]) == !projectExecution
            else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
            started = true
            return .started
        case "delta":
            guard Set(value.keys) == common.union(["text"]), started,
                  let text = value["text"] as? String, !text.isEmpty
            else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
            guard cumulativeText.utf8.count + text.utf8.count <= 524_288 else { throw ChatFailure.code("CHAT_OUTPUT_TOO_LARGE") }
            cumulativeText += text
            return .delta(text)
        case "tool_activity":
            guard projectExecution, started,
                  Set(value.keys) == common.union(["tool_id", "tool", "phase"]),
                  let toolID = value["tool_id"] as? String, !toolID.isEmpty, toolID.utf8.count <= 128,
                  toolID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
                  let tool = value["tool"] as? String, ChatProject.tools.contains(tool),
                  let phase = value["phase"] as? String, ["started", "completed", "failed"].contains(phase)
            else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
            if phase == "started" {
                guard toolCalls[toolID] == nil, toolCalls.count < ChatProject.maximumToolCalls
                else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
            } else {
                guard let previous = toolCalls[toolID], previous.tool == tool, previous.phase == "started"
                else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
            }
            toolCalls[toolID] = (tool, phase)
            return .toolActivity(tool: tool, phase: phase, toolID: toolID)
        case "request_trace":
            guard Set(value.keys) == common.union(["trace"]), let traceValue = value["trace"] as? [String: Any],
                  let runID = UUID(uuidString: requestID),
                  let traceData = try? JSONSerialization.data(withJSONObject: traceValue),
                  let trace = try? JSONDecoder().decode(ChatRequestTrace.self, from: traceData),
                  trace.schema == "claude-request-trace/v1",
                  trace.provider == provider, trace.attemptID == "\(requestID):\(trace.attempt)"
            else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
            try trace.validate(runID: runID, knownSecrets: knownSecrets)
            guard trace.attempt <= maximumRequests else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
            if let index = requestTraces.firstIndex(where: { $0.attemptID == trace.attemptID }) {
                guard requestTraces[index].phase == .request, trace.phase != .request,
                      requestTraces[index].hasSameRequest(as: trace)
                else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
                requestTraces[index] = trace
            } else {
                guard trace.phase == .request, requestTraces.count < maximumRequests,
                      trace.attempt == requestTraces.count + 1,
                      requestTraces.allSatisfy({ $0.phase != .request })
                else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
                requestTraces.append(trace)
            }
            return .requestTrace(trace)
        case "completed":
            guard Set(value.keys) == common.union(["text", "no_tools", "cli_exit", "cli_signal", "temporary_removed", "proxy_closed", "request_count"]),
                  started, let text = value["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text == cumulativeText,
                  boolean(value["no_tools"]) == !projectExecution, integer(value["cli_exit"]) == 0,
                  value["cli_signal"] is NSNull,
                  boolean(value["temporary_removed"]) == true, boolean(value["proxy_closed"]) == true,
                  let requests = integer(value["request_count"]), (1...maximumRequests).contains(requests),
                  toolCalls.values.allSatisfy({ $0.phase != "started" }),
                  requestTraces.isEmpty || (requestTraces.count == requests && requestTraces.allSatisfy({ $0.phase != .request }))
            else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
            terminalText = text
            return nil
        case "error":
            guard Set(value.keys) == common.union(["code"]), let code = value["code"] as? String,
                  safeErrorCodes.contains(code) || ["INVALID_IDENTITY", "VM_IDENTITY_UNSUPPORTED", "NATIVE_IDENTITY_MISMATCH", "GUEST_IDENTITY_CONFIG_FAILED"].contains(code)
                    || projectErrorCodes.contains(code)
                    || appNetworkFailureMessage(code) != nil || appRuntimeFailureMessage(code) != nil || appVMFailureCodes.contains(code) || isHTTPError(code)
            else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
            throw ChatFailure.code(code)
        default:
            throw ChatFailure.code("CHAT_RESPONSE_INVALID")
        }
    }

    func finish(processSucceeded: Bool) throws -> ChatEvent {
        guard processSucceeded else { throw ChatFailure.code("CHAT_PROCESS_FAILED") }
        guard let terminalText else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
        return .completed(terminalText)
    }

    private func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int.min), number.doubleValue < Double(Int.max)
        else { return nil }
        return number.intValue
    }

    private func isHTTPError(_ code: String) -> Bool {
        let prefix = code.hasPrefix("SUBSCRIPTION_HTTP_") ? "SUBSCRIPTION_HTTP_" : "PROVIDER_HTTP_"
        guard code.hasPrefix(prefix), let status = Int(code.dropFirst(prefix.count)) else { return false }
        return (400...599).contains(status) && code == "\(prefix)\(status)"
    }

    private var safeErrorCodes: Set<String> {
        ["INVALID_INPUT", "INVALID_REQUEST_ID", "INVALID_API_KEY", "INVALID_SUBSCRIPTION_TOKEN", "MISSING_SUBSCRIPTION_TOKEN", "CREDENTIAL_MODE_MISMATCH", "PROVIDER_NOT_ALLOWED", "SUBSCRIPTION_PROTOCOL_REJECTED", "SUBSCRIPTION_HTTP_401", "SUBSCRIPTION_HTTP_403", "SUBSCRIPTION_HTTP_429", "MODEL_NOT_ALLOWED", "INVALID_HISTORY", "HISTORY_LIMIT", "INVALID_TEXT_SKILLS", "INVALID_ARGUMENTS", "INVALID_INPUT_JSON", "INPUT_LIMIT", "INPUT_TIMEOUT", "MISSING_EVENT_SINK", "INVALID_TEST_DEPENDENCIES", "CLI_REQUEST_REJECTED", "SANDBOX_PROFILE_REJECTED", "CLI_ARGUMENT_REJECTED", "CLI_MANAGED_POLICY_REJECTED", "CLI_PERMISSION_DENIED", "CLI_PATH_UNAVAILABLE", "CLI_MODEL_REJECTED", "PROVIDER_TIMEOUT", "SDK_IMPORT_FAILED", "PROVIDER_PROTOCOL_REJECTED", "PROVIDER_STREAM_ERROR", "PROVIDER_TOOL_RESPONSE", "PROVIDER_RESPONSE_LIMIT", "PROVIDER_OUTPUT_LIMIT", "PROVIDER_STREAM_INCOMPLETE", "CHAT_CANCELLED", "INPUT_VALIDATION_FAILED", "RUNTIME_INITIALIZATION_FAILED", "TEMPORARY_SETUP_FAILED", "LOCAL_PROXY_START_FAILED", "SANDBOX_PROFILE_SETUP_FAILED", "SDK_QUERY_START_FAILED", "SDK_ITERATION_FAILED", "QUERY_CLEANUP_FAILED", "CLI_CLEANUP_FAILED", "PROCESS_INTERRUPTED", "TOTAL_TIMEOUT", "LOCAL_AUTH_REJECTED", "LOCAL_ROUTE_REJECTED", "REQUEST_LIMIT", "REQUEST_BODY_LIMIT", "INVALID_REQUEST_JSON", "NO_TOOLS_CONTRACT", "DUPLICATE_NATIVE_INIT", "PROVIDER_REDIRECT_REJECTED", "PROVIDER_INVALID_HTTP_STATUS", "PROVIDER_CONNECTION_FAILED", "CLI_LAUNCH_CONTRACT", "CLI_PROCESS_ERROR", "CLI_NOT_STARTED", "CLI_TEXT_MISMATCH", "CLI_EXIT_FAILED", "CLI_CHANGED", "CLI_READBACK_FAILED", "TEMPORARY_CLEANUP_FAILED", "CHAT_FAILED", "NATIVE_PLATFORM_UNSUPPORTED", "NATIVE_PACKAGE_MISSING", "NATIVE_PATH_UNAVAILABLE", "NATIVE_DIGEST_MISMATCH", "SDK_VERSION_MISMATCH"]
    }

    private var projectErrorCodes: Set<String> {
        ["VM_PROJECT_UNSUPPORTED", "PROJECT_EXECUTION_UNSUPPORTED", "VM_PROJECT_REQUIRED", "INVALID_PROJECT_DIRECTORY",
         "PROJECT_DIRECTORY_UNAVAILABLE", "PROJECT_DIRECTORY_CHANGED", "PROJECT_DIRECTORY_PROTECTED",
         "PROJECT_DIRECTORY_FORBIDDEN", "PROJECT_CONTRACT_REJECTED", "PROJECT_PROTOCOL_REJECTED",
         "PROJECT_TOOL_PROTOCOL_REJECTED", "PROJECT_TOOL_RESULT_REJECTED", "PROJECT_TRANSCRIPT_REJECTED",
         "PROJECT_MOUNT_REJECTED", "PROJECT_MOUNT_UNAVAILABLE", "PROJECT_TOOL_REJECTED",
         "PROJECT_TOOL_CONTRACT", "PROJECT_PATH_REJECTED"]
    }
}

struct StdioChatProvider: ChatProviding {
    let configuration: AppConfiguration
    var fixtureOnly = false
    var networkPolicyProvider: any NetworkPolicyProviding = SavedNetworkPolicyProvider()
    var runtimeProfileProvider: any RuntimeProfileProviding = SavedRuntimeProfileProvider()
    var installationIdentityStore: any InstallationIdentityProviding = FileInstallationIdentityStore()

    func events(for request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let controller = OwnedProcessController()
            do { try controller.registerWork() }
            catch { continuation.finish(throwing: ChatFailure.code("CHAT_CANCELLED")); return }
            continuation.onTermination = { reason in
                if case .cancelled = reason { controller.cancel() }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { controller.finish() }
                do {
                    try execute(request, controller: controller, emit: { continuation.yield($0) })
                    continuation.finish()
                } catch {
                    if controller.isTimedOut { continuation.finish(throwing: ChatFailure.code("CHAT_TIMEOUT")) }
                    else if controller.isCancelled { continuation.finish(throwing: ChatFailure.code("CHAT_CANCELLED")) }
                    else { continuation.finish(throwing: error as? ChatFailure ?? ChatFailure.code("CHAT_PROCESS_FAILED")) }
                }
            }
        }
    }

    private func execute(_ request: ChatRequest, controller: OwnedProcessController, emit: (ChatEvent) -> Void) throws {
        try request.validate()
        if let project = request.project {
            do {
                guard try ProjectDirectory.normalized(project.directory) == project.directory else {
                    throw ChatFailure.code("PROJECT_DIRECTORY_CHANGED")
                }
            } catch let failure as ChatFailure { throw failure }
            catch { throw ChatFailure.code("PROJECT_DIRECTORY_UNAVAILABLE") }
        }
        let configuration = self.configuration
        let runtimeConfiguration: AppConfiguration
        do { runtimeConfiguration = fixtureOnly ? configuration : try configuration.resolvingClaudeRuntime() }
        catch { throw ChatFailure.code("RUNTIME_PACKAGE_INVALID") }
        var securedRequest = request
        do { securedRequest.network = fixtureOnly ? .defaultPolicy : try networkPolicyProvider.snapshot() }
        catch let failure as NetworkPolicyFailure { throw ChatFailure.code(failure.code) }
        catch { throw ChatFailure.code("NETWORK_POLICY_INVALID") }
        let runtime: AppRuntimeProfile
        do { runtime = fixtureOnly ? .japan : try runtimeProfileProvider.snapshot() }
        catch let failure as RuntimeProfileFailure { throw ChatFailure.code(failure.code) }
        catch { throw ChatFailure.code("RUNTIME_PROFILE_INVALID") }
        securedRequest.runtime = runtime
        if request.provider == .claudeSubscription && !fixtureOnly {
            do {
                let deviceID = try installationIdentityStore.loadOrCreateDeviceID()
                securedRequest.identity = ClaudeRequestIdentity(device_id: deviceID,
                    session_id: (request.conversationSessionID ?? UUID(uuidString: request.request_id)!).uuidString.lowercased())
                try securedRequest.validate()
            } catch { throw ChatFailure.code("INSTALLATION_IDENTITY_UNAVAILABLE") }
        }
        let payload = try JSONEncoder().encode(securedRequest)
        guard payload.count <= 1_048_576 else { throw ChatFailure.code("INPUT_LIMIT") }
        let script = URL(fileURLWithPath: configuration.projectRoot).appendingPathComponent(
            fixtureOnly ? "sdk/deepseek-text-chat.mjs" : "sdk/vm-text-chat.mjs")
        guard FileManager.default.fileExists(atPath: script.path) else { throw ChatFailure.code("CHAT_BRIDGE_MISSING") }
        guard FileManager.default.isExecutableFile(atPath: configuration.nodeExecutable) else { throw ChatFailure.code("NODE_NOT_AVAILABLE") }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: configuration.nodeExecutable)
        // Keep request observation in this App's broker while the verified
        // runtime continues to own its pinned protocol helpers and VM assets.
        process.arguments = [script.path] + (fixtureOnly ? ["--fixture"] : ["--runtime-root", runtimeConfiguration.projectRoot])
        process.currentDirectoryURL = script.deletingLastPathComponent()
        var environment = runtime.processEnvironment
        // The App owns the parent of runtime directories; do not inherit a
        // caller-supplied TMPDIR or let Node choose a different default root.
        environment["TMPDIR"] = FileManager.default.temporaryDirectory.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try controller.install(process)
        do { try process.run() }
        catch { throw ChatFailure.code("CHAT_PROCESS_FAILED") }
        controller.didStart()
        let timeout = DispatchWorkItem { if process.isRunning { controller.cancel(timedOut: true) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + (request.project == nil ? 260 : 580), execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { controller.terminateForCleanup(); process.waitUntilExit() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        guard !controller.isCancelled else { throw ChatFailure.code("CHAT_CANCELLED") }
        try input.fileHandleForWriting.write(contentsOf: payload + Data([10]))
        try input.fileHandleForWriting.close()
        var parser = ChatEventParser(requestID: request.request_id, model: request.model, fixtureOnly: fixtureOnly,
                                     provider: request.provider,
                                     projectExecution: request.project != nil,
                                     knownSecrets: [request.apiKey, request.subscriptionToken].compactMap { $0 })
        var pending = Data()
        var totalBytes = 0
        let maximumStreamBytes = request.project == nil ? 33_554_432 : 67_108_864
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ChatFailure.code("CHAT_PROCESS_FAILED")
            }
            if count == 0 { break }
            totalBytes += count
            guard totalBytes <= maximumStreamBytes else { throw ChatFailure.code("CHAT_OUTPUT_TOO_LARGE") }
            pending.append(contentsOf: buffer.prefix(count))
            while let newline = pending.firstIndex(of: 10) {
                var frame = pending.subdata(in: 0..<newline)
                pending.removeSubrange(0...newline)
                if frame.last == 13 { frame.removeLast() }
                guard !frame.isEmpty, frame.count <= 4_194_304 else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
                if let event = try parser.consume(frame) { emit(event) }
            }
            guard pending.count <= 4_194_304 else { throw ChatFailure.code("CHAT_OUTPUT_TOO_LARGE") }
            guard !controller.isCancelled else { throw ChatFailure.code("CHAT_CANCELLED") }
        }
        guard pending.isEmpty else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
        process.waitUntilExit()
        guard !controller.isCancelled else { throw ChatFailure.code("CHAT_CANCELLED") }
        emit(try parser.finish(processSucceeded: process.terminationReason == .exit && process.terminationStatus == 0))
    }
}
