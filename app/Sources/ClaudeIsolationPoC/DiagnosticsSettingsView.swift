import SwiftUI

struct DiagnosticsSettingsView: View {
    @ObservedObject var model: DiagnosticsSettingsModel
    @ObservedObject var chat: ConversationViewModel
    @State private var confirmingClear = false
    @State private var clearStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("请求诊断").font(.system(size: 21, weight: .semibold))
                Text("默认只记录请求摘要，排查问题时可选择短期保留正文。")
                    .font(.system(size: 13)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 12) {
                Toggle("保存新请求的完整正文（24 小时）", isOn: Binding(
                    get: { model.captureBodies }, set: model.setCaptureBodies
                ))
                .accessibilityIdentifier("diagnostics-capture-bodies")
                Text("从下一次发送生效，正在执行的请求继续使用开始时的设置。正文会去除已知凭据，但仍可能包含提示词、代码或其他敏感信息。")
                    .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                Text(model.captureBodies ? "已开启正文采集 · 新正文在采集 24 小时后过期。" : "仅保存摘要 · 新请求不保存诊断正文。")
                    .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                    .accessibilityIdentifier("diagnostics-capture-status")
                if let error = model.error { WorkbenchErrorLine(text: error) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("本机诊断副本").font(.system(size: 14, weight: .semibold))
                Text("新正文到期后无法查看或导出；App 运行时清理过期副本，退出期间到期的副本在下次启动时清理。旧版本已保存的正文不会自动删除，可在此手动清理。")
                Text("清理仅删除请求诊断正文，保留对话内容和请求摘要。关闭正文采集不会立即删除已有副本。")
                Button("清理全部请求正文…", role: .destructive) { confirmingClear = true }
                    .accessibilityIdentifier("diagnostics-clear-all-bodies")
                if let clearStatus {
                    Text(clearStatus).accessibilityIdentifier("diagnostics-clear-status")
                }
                if let error = chat.diagnosticError { WorkbenchErrorLine(text: error) }
            }
            .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("在消息的请求详情中预览诊断后再复制或保存。导出默认包含摘要；包含正文需要单独勾选，导出的文件和剪贴板内容由你自行管理。")
                .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("diagnostics-settings")
        .alert("清理全部请求正文？", isPresented: $confirmingClear) {
            Button("取消", role: .cancel) {}
            Button("清理正文", role: .destructive) {
                chat.clearRequestBodies()
                clearStatus = chat.diagnosticError == nil ? "已清理全部请求诊断正文。" : nil
            }
        } message: {
            Text("所有会话中的请求诊断正文（包括旧版本记录）将被删除，无法恢复。对话消息和请求摘要会保留。")
        }
    }
}
