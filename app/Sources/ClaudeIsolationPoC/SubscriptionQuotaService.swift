import Foundation

struct SubscriptionQuotaWindow: Equatable, Sendable, Identifiable {
    let id: String
    let usedPercentage: Double
    let resetsAt: Date?

    var remainingPercentage: Double { 100 - usedPercentage }
    var title: String {
        switch id {
        case "five_hour": "5 小时"
        case "seven_day": "每周"
        case "seven_day_opus": "Opus 每周"
        case "seven_day_sonnet": "Sonnet 每周"
        case "seven_day_oauth_apps": "OAuth 应用每周"
        default: "额度"
        }
    }
    func isExpired(at date: Date = Date()) -> Bool { resetsAt.map { $0 <= date } ?? false }
}

struct SubscriptionQuotaSnapshot: Equatable, Sendable {
    let windows: [SubscriptionQuotaWindow]
    let queriedAt: Date
}

struct SubscriptionQuotaFailure: Error, Equatable, Sendable {
    let code: String

    init(code: String) { self.code = Self.allowedCodes.contains(code) ? code : "QUOTA_QUERY_FAILED" }

    var message: String {
        switch code {
        case "QUOTA_TOKEN_INVALID": "当前账号尚未保存有效的订阅 Token。"
        case "QUOTA_UNAUTHORIZED": "额度查询认证失败，请检查当前账号授权是否已失效。"
        case "QUOTA_FORBIDDEN": "当前授权没有额度查询权限。setup-token 仅支持模型请求；此结果不表示额度耗尽。"
        case "QUOTA_RATE_LIMITED": "额度查询暂时受到频率限制，请稍后手动刷新；此结果不表示额度耗尽。"
        case "QUOTA_SERVICE_UNAVAILABLE": "Claude 额度服务暂不可用，请稍后刷新。"
        case "QUOTA_HTTP_REJECTED": "Claude 未接受额度查询，当前额度暂不可用。"
        case "QUOTA_RESPONSE_INVALID", "PROXY_RESPONSE_TOO_LARGE": "额度服务返回的数据无法识别，未更新已保存的查询结果。"
        case "QUOTA_BRIDGE_MISSING", "QUOTA_PROCESS_FAILED": "额度查询组件不可用，请重新安装当前版本 App。"
        case "QUOTA_TIMEOUT", "QUOTA_INPUT_TIMEOUT": "额度查询超时，请检查代理后重试。"
        case "QUOTA_CANCELLED", "NETWORK_CANCELLED": "额度查询已取消。"
        default: appNetworkFailureMessage(code) ?? "额度查询失败，请检查当前账号授权和代理配置后重试。"
        }
    }

    static let allowedCodes: Set<String> = ["QUOTA_INPUT_INVALID", "QUOTA_INPUT_TIMEOUT", "QUOTA_TOKEN_INVALID",
        "QUOTA_UNAUTHORIZED", "QUOTA_FORBIDDEN", "QUOTA_RATE_LIMITED", "QUOTA_SERVICE_UNAVAILABLE",
        "QUOTA_HTTP_REJECTED", "QUOTA_RESPONSE_INVALID", "QUOTA_CANCELLED", "QUOTA_QUERY_FAILED",
        "QUOTA_BRIDGE_MISSING", "QUOTA_PROCESS_FAILED", "QUOTA_TIMEOUT",
        "NETWORK_POLICY_REQUIRED", "NETWORK_POLICY_INVALID", "NETWORK_REQUEST_INVALID", "NETWORK_CANCELLED",
        "PROXY_CONNECT_FAILED", "PROXY_CONNECT_REJECTED", "PROXY_TIMEOUT", "PROXY_TLS_FAILED",
        "PROXY_REQUEST_FAILED", "PROXY_RESPONSE_TOO_LARGE"]
}

protocol SubscriptionQuotaFetching: Sendable {
    func fetch(token: String) async throws -> SubscriptionQuotaSnapshot
}

struct StdioSubscriptionQuotaService: SubscriptionQuotaFetching {
    let configuration: AppConfiguration
    var networkPolicyProvider: any NetworkPolicyProviding = SavedNetworkPolicyProvider()

    func fetch(token: String) async throws -> SubscriptionQuotaSnapshot {
        try Task.checkCancellation()
        do { try LocalCredentialFailure.validateSubscriptionToken(token) }
        catch { throw SubscriptionQuotaFailure(code: "QUOTA_TOKEN_INVALID") }
        // Freeze the policy before dispatch, just as the caller freezes the account identity.
        let network: AppNetworkPolicy
        do { network = try networkPolicyProvider.snapshot(); try network.validate() }
        catch let failure as NetworkPolicyFailure { throw SubscriptionQuotaFailure(code: failure.code) }
        catch { throw SubscriptionQuotaFailure(code: "NETWORK_POLICY_INVALID") }
        let controller = OwnedProcessController()
        try controller.registerWork()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { controller.finish() }
                    do { continuation.resume(returning: try execute(token: token, network: network, controller: controller)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { controller.cancel() }
    }

    private func execute(token: String, network: AppNetworkPolicy, controller: OwnedProcessController) throws -> SubscriptionQuotaSnapshot {
        // This is an App-owned host utility. Do not resolve a selected (possibly older) guest runtime package.
        let script = URL(fileURLWithPath: configuration.projectRoot).appendingPathComponent("sdk/subscription-quota.mjs")
        guard configuration.projectRoot.hasPrefix("/"), configuration.nodeExecutable.hasPrefix("/"),
              FileManager.default.fileExists(atPath: script.path),
              FileManager.default.isExecutableFile(atPath: configuration.nodeExecutable) else {
            throw SubscriptionQuotaFailure(code: "QUOTA_BRIDGE_MISSING")
        }
        let process = Process(), input = Pipe(), output = Pipe()
        var inputClosed = false
        process.executableURL = URL(fileURLWithPath: configuration.nodeExecutable)
        process.arguments = [script.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let timeout = DispatchWorkItem { if process.isRunning { controller.cancel(timedOut: true) } }
        try controller.install(process)
        do { try process.run() }
        catch { throw SubscriptionQuotaFailure(code: "QUOTA_PROCESS_FAILED") }
        controller.didStart()
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { controller.terminateForCleanup(); process.waitUntilExit() }
            if !inputClosed { input.fileHandleForWriting.closeFile() }
            output.fileHandleForReading.closeFile()
        }
        guard !controller.isCancelled else { throw CancellationError() }
        struct Request: Encodable {
            let schema = "claude-subscription-quota-request/v1"
            let subscriptionToken: String
            let network: AppNetworkPolicy
        }
        do {
            let payload = try JSONEncoder().encode(Request(subscriptionToken: token, network: network)) + Data([10])
            try input.fileHandleForWriting.write(contentsOf: payload)
            try input.fileHandleForWriting.close()
            inputClosed = true
            var data = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 8_192), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= 65_536 else { throw SubscriptionQuotaFailure(code: "QUOTA_RESPONSE_INVALID") }
            }
            process.waitUntilExit()
            if controller.isTimedOut { throw SubscriptionQuotaFailure(code: "QUOTA_TIMEOUT") }
            guard !controller.isCancelled else { throw CancellationError() }
            let snapshot = try Self.decodeResponse(data)
            guard process.terminationStatus == 0 else { throw SubscriptionQuotaFailure(code: "QUOTA_PROCESS_FAILED") }
            return snapshot
        } catch {
            if controller.isTimedOut { throw SubscriptionQuotaFailure(code: "QUOTA_TIMEOUT") }
            if controller.isCancelled { throw CancellationError() }
            if let failure = error as? SubscriptionQuotaFailure { throw failure }
            throw SubscriptionQuotaFailure(code: "QUOTA_PROCESS_FAILED")
        }
    }

    static func decodeResponse(_ data: Data) throws -> SubscriptionQuotaSnapshot {
        guard data.count <= 65_536 else { throw SubscriptionQuotaFailure(code: "QUOTA_RESPONSE_INVALID") }
        let reply: Reply
        do { reply = try JSONDecoder().decode(Reply.self, from: data) }
        catch { throw SubscriptionQuotaFailure(code: "QUOTA_RESPONSE_INVALID") }
        guard reply.ok else { throw SubscriptionQuotaFailure(code: reply.code ?? "QUOTA_QUERY_FAILED") }
        guard let queriedAt = reply.queriedAt, let windows = reply.windows else {
            throw SubscriptionQuotaFailure(code: "QUOTA_RESPONSE_INVALID")
        }
        return .init(windows: windows.map { .init(id: $0.id, usedPercentage: $0.usedPercentage,
            resetsAt: $0.resetsAt.map(Date.init(timeIntervalSince1970:))) }, queriedAt: Date(timeIntervalSince1970: queriedAt))
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private struct Reply: Decodable {
        let ok: Bool
        let windows: [Window]?
        let queriedAt: Double?
        let code: String?
        enum CodingKeys: String, CodingKey { case schema, ok, windows, queriedAt, code }
        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            let all = try decoder.container(keyedBy: Key.self)
            guard try fields.decode(String.self, forKey: .schema) == "claude-subscription-quota-response/v1" else {
                throw SubscriptionQuotaFailure(code: "QUOTA_RESPONSE_INVALID")
            }
            ok = try fields.decode(Bool.self, forKey: .ok)
            let allowed: Set<String> = ok ? ["schema", "ok", "windows", "queriedAt"] : ["schema", "ok", "code"]
            guard Set(all.allKeys.map(\.stringValue)) == allowed else {
                throw SubscriptionQuotaFailure(code: "QUOTA_RESPONSE_INVALID")
            }
            if ok {
                windows = try fields.decode([Window].self, forKey: .windows)
                queriedAt = try fields.decode(Double.self, forKey: .queriedAt)
                code = nil
                guard let windows, windows.count <= 5, Set(windows.map(\.id)).count == windows.count,
                      let queriedAt, queriedAt.isFinite, queriedAt >= 0, queriedAt <= 253_402_300_799 else {
                    throw SubscriptionQuotaFailure(code: "QUOTA_RESPONSE_INVALID")
                }
            } else {
                windows = nil; queriedAt = nil
                code = try fields.decode(String.self, forKey: .code)
            }
        }
    }
    private struct Window: Decodable {
        let id: String
        let usedPercentage: Double
        let resetsAt: Double?
        enum CodingKeys: String, CodingKey { case id, usedPercentage, resetsAt }
        init(from decoder: any Decoder) throws {
            let all = try decoder.container(keyedBy: Key.self)
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            guard Set(all.allKeys.map(\.stringValue)) == ["id", "usedPercentage", "resetsAt"] else {
                throw SubscriptionQuotaFailure(code: "QUOTA_RESPONSE_INVALID")
            }
            id = try fields.decode(String.self, forKey: .id)
            usedPercentage = try fields.decode(Double.self, forKey: .usedPercentage)
            resetsAt = try fields.decodeIfPresent(Double.self, forKey: .resetsAt)
            guard ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps"].contains(id),
                  usedPercentage.isFinite, (0...100).contains(usedPercentage),
                  resetsAt.map({ $0.isFinite && (0...253_402_300_799).contains($0) }) ?? true else {
                throw SubscriptionQuotaFailure(code: "QUOTA_RESPONSE_INVALID")
            }
        }
    }
}
