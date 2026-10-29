import Darwin
import Foundation

struct ExecutionConnectionReply: Decodable, Sendable {
    let ok: Bool
    let code: String
    let model: String
    let ack: String?
    let no_tools: Bool
    // Subscription streaming validates the wire receipt internally but does not expose its count.
    let request_count: Int?
    let cli: CLIState
    let cleanup: Cleanup
    struct CLIState: Decodable, Sendable { let exit_code: Int?; let signal: String? }
    struct Cleanup: Decodable, Sendable { let temporary_removed: Bool; let proxy_closed: Bool }
}

struct ExecutionConnectionFailure: Error {
    let code: String
    var message: String {
        switch code {
        case "MISSING_KEY": "请配置执行模型 API Key，或读取已保存的 Key。"
        case "MISSING_SUBSCRIPTION_TOKEN", "INVALID_SUBSCRIPTION_TOKEN": "请填写或读取 claude setup-token 生成的订阅 Token。"
        case "SUBSCRIPTION_HTTP_401", "SUBSCRIPTION_HTTP_403": "Claude 订阅认证失败，请检查订阅权限；Token 过期时重新生成并保存。"
        case "SUBSCRIPTION_HTTP_429": "Claude 订阅额度或请求频率受限，请稍后重试；不会切换到 API 计费。"
        case "INVALID_PROFILE": "请为当前执行来源选择支持的模型；DeepSeek 地址必须为官方 Anthropic 接口。"
        case "BRIDGE_MISSING": "Claude Code 连接测试器不可用，请重新打包 App。"
        case "TIMEOUT": "Claude Code 连接测试超时。"
        case "CONFIG_CHANGED": "配置已更改，本次旧结果不作为当前配置的验证。"
        case "PROVIDER_HTTP_401": "DeepSeek 拒绝了 API Key，请检查或更换执行模型 Key。"
        case "PROVIDER_HTTP_402": "DeepSeek 账户余额不足，连接测试未通过。"
        case "PROVIDER_HTTP_429": "DeepSeek 当前限流，请稍后重试。"
        default: appNetworkFailureMessage(code) ?? appRuntimeFailureMessage(code) ?? appVMFailureMessage(code) ?? "Claude Code 连接测试未通过，请检查凭据和网络；未启动项目工具。"
        }
    }
}

protocol ExecutionConnectionTesting: Sendable {
    func test(apiKey: String, model: String) async throws -> ExecutionConnectionReply
    func testSubscription(token: String, model: String) async throws -> ExecutionConnectionReply
}

extension ExecutionConnectionTesting {
    func testSubscription(token: String, model: String) async throws -> ExecutionConnectionReply {
        throw ExecutionConnectionFailure(code: "BRIDGE_MISSING")
    }
}

struct StdioExecutionConnectionTester: ExecutionConnectionTesting {
    let configuration: AppConfiguration
    var networkPolicyProvider: any NetworkPolicyProviding = SavedNetworkPolicyProvider()
    var runtimeProfileProvider: any RuntimeProfileProviding = SavedRuntimeProfileProvider()
    var installationIdentityStore: any InstallationIdentityProviding = FileInstallationIdentityStore()
    func testSubscription(token: String, model: String) async throws -> ExecutionConnectionReply {
        let request = ChatRequest(request_id: UUID().uuidString, model: model,
                                  messages: [.init(role: "user", text: "Reply with exactly CLAUDE_SUBSCRIPTION_CLI_OK and nothing else.")],
                                  provider: .claudeSubscription, subscriptionToken: token)
        let provider = StdioChatProvider(configuration: configuration,
                                         networkPolicyProvider: networkPolicyProvider, runtimeProfileProvider: runtimeProfileProvider,
                                         installationIdentityStore: installationIdentityStore)
        var completedText: String?
        do {
            for try await event in provider.events(for: request) {
                if case .completed(let text) = event { completedText = text }
            }
        } catch let failure as ChatFailure {
            if case .code(let code) = failure { throw ExecutionConnectionFailure(code: code) }
        } catch { throw ExecutionConnectionFailure(code: "SUBSCRIPTION_TEST_FAILED") }
        guard completedText?.trimmingCharacters(in: .whitespacesAndNewlines) == "CLAUDE_SUBSCRIPTION_CLI_OK" else {
            throw ExecutionConnectionFailure(code: "INVALID_REPLY")
        }
        // The chat parser accepts completion only after native exit, no-tools and cleanup receipts.
        return .init(ok: true, code: "PASSED_TEXT_ONLY", model: model, ack: "CLAUDE_SUBSCRIPTION_CLI_OK", no_tools: true,
                     request_count: nil, cli: .init(exit_code: 0, signal: nil), cleanup: .init(temporary_removed: true, proxy_closed: true))
    }
    func test(apiKey: String, model: String) async throws -> ExecutionConnectionReply {
        let controller = OwnedProcessController()
        try controller.registerWork()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { controller.finish() }
                    do { continuation.resume(returning: try execute(apiKey: apiKey, model: model, controller: controller)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { controller.cancel() }
    }
    private func execute(apiKey: String, model: String, controller: OwnedProcessController) throws -> ExecutionConnectionReply {
        let configuration: AppConfiguration
        do { configuration = try self.configuration.resolvingClaudeRuntime() }
        catch { throw ExecutionConnectionFailure(code: "RUNTIME_PACKAGE_INVALID") }
        let network: AppNetworkPolicy
        do { network = try networkPolicyProvider.snapshot() }
        catch let failure as NetworkPolicyFailure { throw ExecutionConnectionFailure(code: failure.code) }
        catch { throw ExecutionConnectionFailure(code: "NETWORK_POLICY_INVALID") }
        let runtime: AppRuntimeProfile
        do { runtime = try runtimeProfileProvider.snapshot() }
        catch let failure as RuntimeProfileFailure { throw ExecutionConnectionFailure(code: failure.code) }
        catch { throw ExecutionConnectionFailure(code: "RUNTIME_PROFILE_INVALID") }
        let script = URL(fileURLWithPath: configuration.projectRoot).appendingPathComponent("sdk/vm-text-smoke.mjs")
        guard FileManager.default.fileExists(atPath: script.path), FileManager.default.isExecutableFile(atPath: configuration.nodeExecutable) else {
            throw ExecutionConnectionFailure(code: "BRIDGE_MISSING")
        }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: configuration.nodeExecutable)
        process.arguments = [script.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        var environment = runtime.processEnvironment
        environment["TMPDIR"] = FileManager.default.temporaryDirectory.path
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let timeout = DispatchWorkItem { if process.isRunning { controller.cancel(timedOut: true) } }
        try controller.install(process)
        try process.run()
        controller.didStart()
        DispatchQueue.global().asyncAfter(deadline: .now() + 260, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { controller.terminateForCleanup(); process.waitUntilExit() }
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        }
        guard !controller.isCancelled else { throw CancellationError() }
        let networkObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(network))
        let runtimeObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(runtime))
        let payload = try JSONSerialization.data(withJSONObject: ["schema": "deepseek-text-smoke/v1", "apiKey": apiKey, "model": model, "network": networkObject, "runtime": runtimeObject])
        try input.fileHandleForWriting.write(contentsOf: payload + Data([10]))
        try input.fileHandleForWriting.close()
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 65_536 else { throw ExecutionConnectionFailure(code: "INVALID_REPLY") }
        }
        process.waitUntilExit()
        if controller.isTimedOut { throw ExecutionConnectionFailure(code: "TIMEOUT") }
        guard !controller.isCancelled else { throw CancellationError() }
        guard let reply = try? JSONDecoder().decode(ExecutionConnectionReply.self, from: data), reply.model == model else {
            throw ExecutionConnectionFailure(code: "INVALID_REPLY")
        }
        guard process.terminationStatus == 0, reply.ok, reply.ack == "DEEPSEEK_CLI_OK", reply.no_tools,
              reply.request_count.map({ (1...3).contains($0) }) == true, reply.cli.exit_code == 0, reply.cli.signal == nil,
              reply.cleanup.temporary_removed, reply.cleanup.proxy_closed else {
            throw ExecutionConnectionFailure(code: reply.code)
        }
        return reply
    }
}
