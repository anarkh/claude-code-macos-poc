import Darwin
import Foundation

/// Translation exercises the real transport against a reserved, non-listening
/// loopback port. Chat/connection exercise Swift broker stdio error forwarding
/// with synthetic offline brokers; VM transport belongs to VM integration checks.
func networkBridgeChecks(configuration: AppConfiguration) async -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else { return [("network_bridge_loopback_socket_created", false)] }
    defer { close(socketDescriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketDescriptor, $0, &length) }
    }
    guard bound == 0, named == 0 else { return [("network_bridge_loopback_port_reserved", false)] }
    let policy = AppNetworkPolicy(proxyURL: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))")
    let policies = FixedNetworkPolicyProvider(policy: policy)
    let key = "offline-stdio-network-test-key-NOT-VALID"
    let translationRequest = TranslationRequest(request_id: "local-offline-network-check", operation: "translate_input",
        text: "本地代理拒绝测试。", target: "en", model: .init(endpoint: "https://api.deepseek.com",
        model: "deepseek-flash", apiKey: key))
    do {
        let reply = try await StdioTranslationProvider(configuration: configuration, networkPolicyProvider: policies, runtimeProfileProvider: FixedRuntimeProfileProvider()).translate(translationRequest)
        checks.append(("network_translation_real_stdio_proxy_failure_is_explicit", !reply.ok && reply.error_code == "PROXY_CONNECT_FAILED"))
    } catch { checks.append(("network_translation_real_stdio_proxy_failure_is_explicit", false)) }
    let brokerRoot = FileManager.default.temporaryDirectory.appendingPathComponent("network-broker-fixture-\(UUID().uuidString)")
    let brokerConfiguration: AppConfiguration
    do {
        let sdk = brokerRoot.appendingPathComponent("sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let common = """
        // Offline synthetic broker: no provider, CLI, VM or socket is started.
        const chunks = [];
        for await (const chunk of process.stdin) chunks.push(chunk);
        const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        const validPolicy = input.network?.schema === 'app-network-policy/v1' &&
          input.network?.proxyURL === '\(policy.proxyURL)' && input.network?.dnsPolicy === 'proxy-only';
        const code = validPolicy ? 'PROXY_CONNECT_FAILED' : 'NETWORK_POLICY_INVALID';
        const emit = value => process.stdout.write(JSON.stringify(value) + '\\n');
        """
        let chat = common + """

        emit({schema:'deepseek-text-chat-event/v1',request_id:input.request_id,model:input.model,
          fixture_only:false,type:'error',code});
        process.exitCode = 1;
        """
        let connection = common + """

        emit({ok:false,code,model:input.model,ack:null,no_tools:true,request_count:0,
          cli:{exit_code:1,signal:null},cleanup:{temporary_removed:true,proxy_closed:true}});
        process.exitCode = 1;
        """
        try Data(chat.utf8).write(to: sdk.appendingPathComponent("vm-text-chat.mjs"))
        try Data(connection.utf8).write(to: sdk.appendingPathComponent("vm-text-smoke.mjs"))
        brokerConfiguration = AppConfiguration(projectRoot: brokerRoot.path, nodeExecutable: configuration.nodeExecutable)
    } catch {
        checks.append(("network_broker_fixture_setup", false))
        do { if FileManager.default.fileExists(atPath: brokerRoot.path) { try FileManager.default.removeItem(at: brokerRoot) } }
        catch { checks.append(("network_broker_fixture_cleanup", false)) }
        return checks
    }
    let chatRequest = ChatRequest(request_id: UUID().uuidString.lowercased(), apiKey: key, model: "deepseek-flash[1m]",
        messages: [.init(role: "user", text: "Reply only LOCAL_OFFLINE_PROBE.")])
    var completed = false
    do {
        for try await event in StdioChatProvider(configuration: brokerConfiguration, networkPolicyProvider: policies, runtimeProfileProvider: FixedRuntimeProfileProvider()).events(for: chatRequest) {
            if case .completed = event { completed = true }
        }
        checks.append(("network_chat_offline_broker_stdio_proxy_error_is_forwarded", false))
    } catch let failure as ChatFailure {
        if case .code(let code) = failure {
            checks.append(("network_chat_offline_broker_stdio_proxy_error_is_forwarded", code == "PROXY_CONNECT_FAILED" && !completed))
        } else { checks.append(("network_chat_offline_broker_stdio_proxy_error_is_forwarded", false)) }
    } catch { checks.append(("network_chat_offline_broker_stdio_proxy_error_is_forwarded", false)) }
    do {
        _ = try await StdioExecutionConnectionTester(configuration: brokerConfiguration, networkPolicyProvider: policies, runtimeProfileProvider: FixedRuntimeProfileProvider()).test(apiKey: key, model: "deepseek-flash[1m]")
        checks.append(("network_connection_offline_broker_stdio_proxy_error_is_forwarded", false))
    } catch let failure as ExecutionConnectionFailure {
        checks.append(("network_connection_offline_broker_stdio_proxy_error_is_forwarded", failure.code == "PROXY_CONNECT_FAILED"))
    } catch { checks.append(("network_connection_offline_broker_stdio_proxy_error_is_forwarded", false)) }

    let subscriptionRequest = ChatRequest(request_id: UUID().uuidString, model: "sonnet",
        messages: [.init(role: "user", text: "Reply only LOCAL_OFFLINE_PROBE.")],
        provider: .claudeSubscription, subscriptionToken: "sk-ant-oat01-offline-network-fixture")
    do {
        for try await _ in StdioChatProvider(configuration: brokerConfiguration, networkPolicyProvider: policies, runtimeProfileProvider: FixedRuntimeProfileProvider(), installationIdentityStore: FixtureInstallationIdentityStore()).events(for: subscriptionRequest) {}
        checks.append(("network_subscription_offline_broker_stdio_proxy_error_is_forwarded", false))
    } catch let failure as ChatFailure {
        if case .code(let code) = failure { checks.append(("network_subscription_offline_broker_stdio_proxy_error_is_forwarded", code == "PROXY_CONNECT_FAILED")) }
    } catch { checks.append(("network_subscription_offline_broker_stdio_proxy_error_is_forwarded", false)) }
    do {
        _ = try await StdioExecutionConnectionTester(configuration: brokerConfiguration, networkPolicyProvider: policies, runtimeProfileProvider: FixedRuntimeProfileProvider(), installationIdentityStore: FixtureInstallationIdentityStore()).testSubscription(token: "sk-ant-oat01-offline-network-fixture", model: "sonnet")
        checks.append(("network_subscription_connection_offline_broker_stdio_proxy_error_is_forwarded", false))
    } catch let failure as ExecutionConnectionFailure { checks.append(("network_subscription_connection_offline_broker_stdio_proxy_error_is_forwarded", failure.code == "PROXY_CONNECT_FAILED")) }
    catch { checks.append(("network_subscription_connection_offline_broker_stdio_proxy_error_is_forwarded", false)) }

    let invalid = FixedNetworkPolicyProvider(policy: .init(proxyURL: "http://must-not-resolve.invalid:7897"))
    let unavailable = AppConfiguration(projectRoot: "/nonexistent-local-network-check", nodeExecutable: "/nonexistent-local-node")
    do {
        _ = try await StdioTranslationProvider(configuration: unavailable, networkPolicyProvider: invalid, runtimeProfileProvider: FixedRuntimeProfileProvider()).translate(translationRequest)
        checks.append(("network_translation_bad_policy_rejected_before_launch", false))
    } catch let failure as TranslationFailure {
        if case .code(let code) = failure { checks.append(("network_translation_bad_policy_rejected_before_launch", code == "NETWORK_POLICY_INVALID")) }
    } catch { checks.append(("network_translation_bad_policy_rejected_before_launch", false)) }
    do {
        for try await _ in StdioChatProvider(configuration: unavailable, networkPolicyProvider: invalid, runtimeProfileProvider: FixedRuntimeProfileProvider()).events(for: chatRequest) {}
        checks.append(("network_chat_bad_policy_rejected_before_launch", false))
    } catch let failure as ChatFailure {
        if case .code(let code) = failure { checks.append(("network_chat_bad_policy_rejected_before_launch", code == "NETWORK_POLICY_INVALID")) }
    } catch { checks.append(("network_chat_bad_policy_rejected_before_launch", false)) }
    do {
        _ = try await StdioExecutionConnectionTester(configuration: unavailable, networkPolicyProvider: invalid, runtimeProfileProvider: FixedRuntimeProfileProvider()).test(apiKey: key, model: "deepseek-flash[1m]")
        checks.append(("network_connection_bad_policy_rejected_before_launch", false))
    } catch let failure as ExecutionConnectionFailure {
        checks.append(("network_connection_bad_policy_rejected_before_launch", failure.code == "NETWORK_POLICY_INVALID"))
    } catch { checks.append(("network_connection_bad_policy_rejected_before_launch", false)) }
    checks.append(("network_all_bridges_show_actionable_proxy_failure",
        ChatFailure.code("PROXY_CONNECT_FAILED").message.contains("Clash") &&
        TranslationFailure.code("PROXY_CONNECT_FAILED").message.contains("Clash") &&
        ExecutionConnectionFailure(code: "PROXY_CONNECT_FAILED").message.contains("Clash")))
    do {
        try FileManager.default.removeItem(at: brokerRoot)
        checks.append(("network_broker_fixture_cleanup", true))
    } catch { checks.append(("network_broker_fixture_cleanup", false)) }
    return checks
}
