import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: TranslationViewModel
    @ObservedObject var execution: ExecutionViewModel
    @ObservedObject var skills: SkillsViewModel
    @ObservedObject var network: NetworkSettingsViewModel
    @ObservedObject var runtime: RuntimeSettingsViewModel
    @ObservedObject var loginReset: ClaudeLoginResetModel
    @ObservedObject var runtimeVersion: RuntimeVersionViewModel
    @ObservedObject var browser: BrowserVMController
    @ObservedObject var diagnostics: DiagnosticsSettingsModel
    @ObservedObject var chat: ConversationViewModel
    @ObservedObject var deviceIdentity: DeviceIdentitySettingsModel
    let configuration: AppConfiguration?
    @State private var pane = SettingsPane.execution
    @State private var showingLoginReset = false
    private enum SettingsPane: String, CaseIterable, Identifiable {
        case execution = "Claude Code", translation = "语言翻译", skills = "Skills", network = "网络", runtime = "运行环境", browser = "浏览器", diagnostics = "诊断", updates = "更新"
        var id: String { rawValue }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("设置分类", selection: $pane) {
                ForEach(SettingsPane.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("model-settings-purpose")
            if pane == .skills {
                SkillsSettingsView(model: skills)
            } else {
                ScrollView {
                    if pane == .execution { executionSettings }
                    else if pane == .translation { translationSettings }
                    else if pane == .network { NetworkSettingsView(model: network) }
                    else if pane == .updates { updateSettings }
                    else if pane == .browser { BrowserSettingsView(browser: browser) }
                    else if pane == .diagnostics { DiagnosticsSettingsView(model: diagnostics, chat: chat) }
                    else { RuntimeSettingsView(model: runtime) }
                }
            }
        }
        .padding(28).frame(width: 580, height: 620).background(WorkbenchTheme.canvas)
        .accessibilityIdentifier("model-settings")
        .disabled(loginReset.isBusy)
        .sheet(isPresented: $showingLoginReset) { ClaudeLoginResetView(model: loginReset) }
        .onAppear {
            model.restoreSavedKeyForSettings()
            execution.restoreSavedKeyForSettings()
            execution.restoreSavedSubscriptionTokenForSettings()
        }
    }

    private var executionSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Code 执行模型").font(.system(size: 21, weight: .semibold))
                Text("选择执行来源；语言翻译继续使用独立的 DeepSeek 配置。")
                    .font(.system(size: 13)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 16) {
                field("执行来源") {
                    Picker("执行来源", selection: $execution.provider) {
                        ForEach(ExecutionProvider.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("execution-provider")
                }
                if execution.provider == .deepseekAPI { deepseekExecutionSettings }
                else { subscriptionExecutionSettings }
                HStack {
                    Button("保存模型配置", action: execution.saveConfiguration)
                        .accessibilityIdentifier("save-execution-configuration")
                    Text(execution.configurationStatus).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                }
                HStack {
                    Button("测试 Claude Code 连接") { Task { await execution.testConnection() } }
                        .disabled(execution.testBusy).accessibilityIdentifier("test-execution-connection")
                    if execution.testBusy { ProgressView().controlSize(.small) }
                }
                if let status = execution.testStatus {
                    Text(status).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                }
                if let error = execution.error { WorkbenchErrorLine(text: error) }
            }.textFieldStyle(.roundedBorder)
            if execution.provider == .claudeSubscription {
                DeviceIdentitySettingsView(model: deviceIdentity, canReplace: canReplaceDeviceIdentity) {
                    // Recheck live state when the confirmation is accepted.
                    deviceIdentity.replaceDeviceID(isAllowed: canReplaceDeviceIdentity)
                }
            }
            Button("重置 Claude 本地登录状态…") {
                loginReset.prepare(); showingLoginReset = true
            }.accessibilityIdentifier("open-login-reset")
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("在会话中选择执行目录即可读写项目；连接测试仅发送固定文本。", systemImage: "folder")
                Text("发送会话或测试连接会运行官方 CLI，使用当前来源及统一代理。项目命令在隔离 VM 内运行，只有所选目录与本机共享；MCP、插件及项目设置中的自动 hooks 不启用。未选择目录时保持纯文本聊天，代理不可用时停止请求。")
                Text("来源和模型保存于 App 设置；API Key 与订阅 Token 分别保存到 App 专用本机明文文件，文件权限仅限当前 macOS 账号。同账号下其他程序仍可能读取。")
                Text("API Key 在打开设置时以遮罩恢复；订阅账号的旧 Token 不回显，更新时填写新值。修改凭据须单独保存，保存模型配置不保存凭据。凭据不写入会话、公开配置或日志；真实订阅 Token 由可信宿主桥接进程使用，不进入 VM。")
            }.font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("execution-settings")
    }

    private var canReplaceDeviceIdentity: Bool {
        chat.isTerminationWorkSettled && !chat.isTerminationInProgress && !chat.isLoginResetInProgress
            && execution.isTerminationWorkSettled && !execution.isTerminationInProgress && !execution.isLoginResetInProgress
            && !loginReset.isBusy && !runtimeVersion.isBusy
    }

    private var updateSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("更新").font(.system(size: 21, weight: .semibold))
                Text("从官方获取配套 CLI / SDK，本机封装；也可离线导入和回退。")
                    .font(.system(size: 13)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            RuntimeVersionSettingsView(model: runtimeVersion)
        }.accessibilityIdentifier("updates-settings")
    }

    private var deepseekExecutionSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            field("DeepSeek 官方服务地址") {
                Text("https://api.deepseek.com/anthropic").font(.system(size: 12)).textSelection(.enabled)
                    .accessibilityIdentifier("execution-endpoint").accessibilityLabel("执行模型 DeepSeek 官方服务地址")
                if execution.baseURL != "https://api.deepseek.com/anthropic" {
                    Button("使用 DeepSeek 官方地址") { execution.baseURL = "https://api.deepseek.com/anthropic" }
                        .accessibilityIdentifier("reset-execution-endpoint")
                }
            }
            field("执行模型") {
                Picker("执行模型", selection: $execution.modelName) {
                    if !["deepseek-flash[1m]", "deepseek-flash"].contains(execution.modelName) {
                        Text("请选择支持的 DeepSeek 模型").tag(execution.modelName)
                    }
                    Text("deepseek-flash[1m]").tag("deepseek-flash[1m]")
                    Text("deepseek-flash").tag("deepseek-flash")
                }.labelsHidden().accessibilityIdentifier("execution-model").accessibilityLabel("Claude Code 执行模型名称")
            }
            field("执行模型 API Key") {
                SecureField("输入 API Key", text: $execution.apiKey)
                    .accessibilityIdentifier("execution-api-key").accessibilityLabel("执行模型 API Key")
            }
            Button("复用当前翻译 Key") { execution.reuseTranslationKey(model.apiKey) }
                .accessibilityIdentifier("reuse-translation-key")
            HStack(spacing: 10) {
                Button("保存 API Key", action: execution.saveKey)
                    .disabled(execution.apiKey.isEmpty).accessibilityIdentifier("save-execution-key")
                Button("读取已保存 Key", action: execution.loadKey).accessibilityIdentifier("load-execution-key")
                Button("删除已保存 Key", role: .destructive, action: execution.deleteKey)
                    .accessibilityIdentifier("delete-execution-key")
            }.controlSize(.small)
            Text(execution.credentialStatus).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
        }
    }

    private var subscriptionExecutionSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            field("订阅模型") {
                Picker("订阅模型", selection: $execution.subscriptionModel) {
                    Text("Sonnet").tag("sonnet")
                    Text("Opus").tag("opus")
                    Text("Haiku").tag("haiku")
                }.labelsHidden().accessibilityIdentifier("subscription-model").accessibilityLabel("Claude 订阅模型")
            }
            if let accounts = execution.subscriptionAccounts {
                SubscriptionAccountsView(model: accounts, canManage: accounts.canMutate()) { id, startNew in
                    guard accounts.select(id: id) else { return }
                    if startNew { chat.newConversation() }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("在终端运行 claude setup-token，使用对应订阅账号完成浏览器授权，再添加账号并粘贴生成的 Token。")
                Text("Token 有效期一年；到期或撤销后需重新生成并保存。模型可用性及额度以订阅账号为准，连接测试也会消耗订阅额度。")
                Text("账号及 Token 保存于 App 专用本机文件，不读取系统钥匙串。额度查询可能因 Token 权限不足而不可用，不影响正常聊天。切换执行账号不改变翻译配置。")
            }.font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var translationSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("翻译模型").font(.system(size: 21, weight: .semibold))
                Text("用于将中文输入译为英语或日语，以及将输出译为中文。")
                    .font(.system(size: 13)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 16) {
                field("服务地址") {
                    TextField("HTTPS endpoint", text: $model.endpoint)
                        .accessibilityIdentifier("translation-endpoint").accessibilityLabel("翻译模型 HTTPS 服务地址")
                }
                field("模型名称") {
                    TextField("deepseek-flash", text: $model.modelName)
                        .accessibilityIdentifier("translation-model").accessibilityLabel("翻译模型名称")
                }
                HStack {
                    Button("保存模型配置", action: model.saveConfiguration)
                        .accessibilityIdentifier("save-translation-configuration")
                    Text(model.configurationStatus).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                }
                field("API Key") {
                    SecureField("输入翻译模型 API Key", text: $model.apiKey)
                        .accessibilityIdentifier("translation-api-key").accessibilityLabel("翻译模型 API Key")
                }
                HStack(spacing: 10) {
                    Button("保存 API Key", action: model.saveKey)
                        .disabled(model.apiKey.isEmpty).accessibilityIdentifier("save-translation-key")
                    Button("读取已保存 Key", action: model.loadKey).accessibilityIdentifier("load-translation-key")
                    Button("删除已保存 Key", role: .destructive, action: model.deleteKey)
                        .accessibilityIdentifier("delete-translation-key")
                }.controlSize(.small)
                if let status = model.credentialStatus {
                    Text(status).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText).accessibilityIdentifier("translation-credential-status")
                }
            }.textFieldStyle(.roundedBorder)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("新的请求使用当前配置；已保存的消息和译文保持原样。", systemImage: "arrow.triangle.2.circlepath")
                Text("点击翻译会将文本发送到这里配置的模型服务，并使用网络设置中的统一代理。代理不可用时停止请求。")
                Text("保存 API Key 会写入 App 专用本机明文文件，文件权限仅限当前 macOS 账号。同账号下其他程序仍可能读取。")
                Text("打开设置时自动恢复本机保存的 Key，以遮罩显示；更新或重启后可继续复用。修改 Key 后须单独点击“保存 API Key”，保存模型配置只保存地址和名称。Key 不写入会话、公开模型配置、日志或环境变量。")
            }
            .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            if configuration == nil {
                WorkbenchErrorLine(text: "缺少打包配置，翻译桥不可用。请从项目重新打包。")
            }
        }
        .accessibilityIdentifier("translation-settings")
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium))
            content()
        }
    }
}
