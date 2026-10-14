import SwiftUI

@MainActor
final class NetworkSettingsViewModel: ObservableObject {
    @Published var proxyURL = ""
    @Published private(set) var status = "网络配置不可用"
    @Published private(set) var error: String?
    private let store: any NetworkConfigurationPersisting

    init(store: any NetworkConfigurationPersisting = NetworkConfigurationStore()) {
        self.store = store
        do {
            proxyURL = try store.load().proxyURL
            status = "执行、翻译和连接测试均使用此代理。"
        } catch {
            self.error = (error as? NetworkPolicyFailure ?? .invalid).message
        }
    }

    func save() { persist(AppNetworkPolicy(proxyURL: proxyURL)) }
    func restoreDefault() { persist(.defaultPolicy) }

    private func persist(_ policy: AppNetworkPolicy) {
        do {
            try policy.validate()
            try store.save(policy)
            guard try store.load() == policy else { throw NetworkPolicyFailure.persistenceFailed }
            proxyURL = policy.proxyURL
            status = "已保存 · 下一次请求使用此代理。"
            error = nil
        } catch {
            self.error = (error as? NetworkPolicyFailure ?? .persistenceFailed).message
        }
    }
}

struct NetworkSettingsView: View {
    @ObservedObject var model: NetworkSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("统一代理出口").font(.system(size: 21, weight: .semibold))
                Text("Claude Code 执行、语言翻译和连接测试共用此设置。")
                    .font(.system(size: 13)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("HTTP 代理地址").font(.system(size: 12, weight: .medium))
                    TextField("http://127.0.0.1:7897", text: $model.proxyURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("network-proxy-url").accessibilityLabel("HTTP 代理地址")
                }
                Text("仅支持本机 127.0.0.1 的 HTTP 代理，请填写 Clash 的 HTTP 或 Mixed 端口。")
                    .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                HStack(spacing: 10) {
                    Button("保存网络配置", action: model.save).accessibilityIdentifier("save-network-configuration")
                    Button("恢复默认", action: model.restoreDefault).accessibilityIdentifier("restore-network-default")
                }
                Text(model.status).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                    .accessibilityIdentifier("network-configuration-status")
                if let error = model.error { WorkbenchErrorLine(text: error) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("代理失效时停止请求", systemImage: "network")
                Text("目标域名由代理端解析。代理连接失败或拒绝请求时，请求会停止，不会直连。")
                Text("如需日本出口，请在 Clash 中选择日本节点，并让模型服务域名使用该节点。App 不会替你修改 Clash 规则。")
                Text("上述请求不在本地查询目标域名 DNS，包括 Type 64 / 65。")
                Text("按类型返回 NODATA 的 DNS 过滤器另见技术方案，尚未运行；这里不会修改整台 Mac 的 DNS 设置。")
            }
            .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("network-settings")
    }
}
