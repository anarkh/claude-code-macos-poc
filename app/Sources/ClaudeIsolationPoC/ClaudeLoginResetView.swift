import AppKit
import SwiftUI

struct ClaudeLoginResetView: View {
    @ObservedObject var model: ClaudeLoginResetModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重置 Claude 本地登录状态").font(.system(size: 21, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("清除当前订阅账号的授权。再次使用此账号时，需要保存新的 Token；其他账号保留。")
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("停止并等待当前聊天、翻译和连接测试退出", systemImage: "stop.circle")
                            Label("清除当前账号的 Token，保留账号名称及其他账号", systemImage: "key")
                            Label("清理已确认归属且停止使用的临时运行目录", systemImage: "folder")
                            Text(model.runtimeSummary).foregroundStyle(WorkbenchTheme.secondaryText)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    Text("保留会话、草稿、Skills、DeepSeek Key、模型、代理及语言时区设置。完成后打开空白会话，旧历史仍可在左侧查看。")
                    Divider()
                    Toggle("检查电脑上的 Claude 登录位置（仅扫描）", isOn: $model.inspectExternal)
                        .disabled(model.isBusy).accessibilityIdentifier("reset-inspect-external")
                        .onChange(of: model.inspectExternal) { _, enabled in if enabled { model.scanExternal() } }
                    if model.inspectExternal {
                        Text("只检查常见路径是否存在，不读取内容、不自动删除外部数据，也不访问钥匙串。")
                            .foregroundStyle(WorkbenchTheme.secondaryText)
                        ForEach(model.externalLocations) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.title).fontWeight(.medium)
                                    Spacer()
                                    Text(item.statusText).foregroundStyle(WorkbenchTheme.secondaryText)
                                    if let url = item.revealURL {
                                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                            .disabled(model.isBusy).controlSize(.small)
                                    }
                                }
                                Text(item.pathLabel).font(.system(size: 11, design: .monospaced))
                                Text(item.guidance).foregroundStyle(WorkbenchTheme.secondaryText)
                            }.padding(.vertical, 5)
                        }
                    }
                    Text("device_id、安装标识的来源和重置效果尚未验证，此功能不会改写它们，也不能解除服务端账号限制。")
                        .foregroundStyle(WorkbenchTheme.secondaryText)
                    if model.isBusy { HStack { ProgressView().controlSize(.small); Text(model.progress) } }
                    if let result = model.result {
                        Label(result, systemImage: "checkmark.circle").accessibilityIdentifier("login-reset-result")
                    }
                    if let error = model.error { WorkbenchErrorLine(text: error).accessibilityIdentifier("login-reset-error") }
                }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(model.result == nil ? "取消" : "完成") { dismiss() }
                    .disabled(model.isBusy).keyboardShortcut(.cancelAction).accessibilityIdentifier("close-login-reset")
                Spacer()
                Button("重置 App 登录状态…", role: .destructive) { confirming = true }
                    .disabled(model.isBusy || model.result != nil).accessibilityIdentifier("confirm-login-reset")
            }
        }.padding(24).frame(width: 650, height: 620).background(WorkbenchTheme.canvas)
            .interactiveDismissDisabled(model.isBusy)
            .confirmationDialog("确定重置 App 的 Claude 登录状态？", isPresented: $confirming, titleVisibility: .visible) {
                Button("清除当前授权并重置", role: .destructive) { Task { await model.reset() } }
            } message: {
                Text("当前请求将停止，当前账号的授权会被清除。其他账号、会话、Skills、DeepSeek Key 和设置会保留。已有迁移备份及电脑上的外部 Claude 数据不会删除。")
            }
    }
}
