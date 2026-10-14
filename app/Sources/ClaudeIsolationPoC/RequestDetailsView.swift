import AppKit
import SwiftUI

struct RequestDetailsView: View {
    let message: ConversationMessage
    let traces: [ChatRequestTrace]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAttemptID: String?
    @State private var showHeaders = false
    @State private var copyStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("请求详情").font(.system(size: 18, weight: .semibold))
                    Text("Claude Code 对话").font(.system(size: 12))
                        .foregroundStyle(WorkbenchTheme.secondaryText)
                    Text("认证头不显示，仅保留安全白名单请求头。Key / Token 不记录，正文随会话保存在本机。")
                        .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("request-details-privacy-note")
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("request-details-close")
            }
            .padding(22)
            Divider()

            if let trace = selectedTrace {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        attemptSelector
                        requestSummary(trace)
                        headersSection(trace)
                        bodySection(trace)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(22)
                }
                .accessibilityIdentifier("request-details-scroll")
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(30)
            }
        }
        .frame(width: 780, height: 640)
        .background(WorkbenchTheme.canvas)
        .accessibilityIdentifier("request-details-sheet")
        .onChange(of: selectedTrace?.attemptID) { _, _ in copyStatus = nil }
    }

    private var selectedTrace: ChatRequestTrace? {
        traces.first(where: { $0.attemptID == selectedAttemptID }) ?? traces.last
    }

    @ViewBuilder private var attemptSelector: some View {
        if traces.count > 1 {
            Picker("实际请求", selection: Binding(
                get: { selectedTrace?.attemptID ?? "" },
                set: { selectedAttemptID = $0 }
            )) {
                ForEach(traces) { trace in
                    Text("请求 \(trace.attempt)").tag(trace.attemptID)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("request-details-attempt-picker")
        }
    }

    private func requestSummary(_ trace: ChatRequestTrace) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if isWaiting(trace) { ProgressView().controlSize(.mini) }
                else {
                    Image(systemName: trace.outcome == "cancelled" ? "stop.circle" : (isFailure(trace) ? "exclamationmark.circle" : "checkmark.circle"))
                        .foregroundStyle(isFailure(trace) ? .red : WorkbenchTheme.secondaryText)
                        .accessibilityHidden(true)
                }
                Text(phaseDescription(trace)).font(.system(size: 12, weight: .medium))
                    .accessibilityIdentifier("request-details-phase")
                Spacer()
                Text("请求 \(trace.attempt) / \(traces.count)")
                    .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                summaryRow("URL", value: trace.url, identifier: "request-details-url")
                summaryRow("方法", value: trace.method, identifier: "request-details-method")
                summaryRow("模型", value: trace.wireModel, identifier: "request-details-model")
                summaryRow("来源", value: trace.provider.title, identifier: "request-details-provider")
                summaryRow("代理", value: proxyDescription(trace), identifier: "request-details-proxy")
                summaryRow("HTTP 状态", value: trace.status.map(String.init) ?? (isWaiting(trace) ? "等待响应" : "未收到 HTTP 响应"), identifier: "request-details-status")
                summaryRow("耗时", value: trace.durationMS.map { String(format: "%.1f ms", $0) } ?? (isWaiting(trace) ? "进行中" : "未记录"), identifier: "request-details-duration")
            }
            if let error = trace.errorCode {
                WorkbenchErrorLine(text: error)
                    .accessibilityIdentifier("request-details-error")
            } else if trace.phase == .request, let error = message.error {
                WorkbenchErrorLine(text: error)
                    .accessibilityIdentifier("request-details-error")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchTheme.subtleFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private func summaryRow(_ label: String, value: String, identifier: String) -> some View {
        GridRow(alignment: .top) {
            Text(verbatim: label).font(.system(size: 11, weight: .medium))
                .foregroundStyle(WorkbenchTheme.secondaryText)
            Text(verbatim: value).font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier)
        }
    }

    private func headersSection(_ trace: ChatRequestTrace) -> some View {
        DisclosureGroup(isExpanded: $showHeaders) {
            rawTextBlock(headersText(trace), identifier: "request-details-headers")
                .padding(.top, 8)
        } label: {
            Text("请求头（已脱敏）").font(.system(size: 12, weight: .semibold))
        }
        .accessibilityIdentifier("request-details-headers-disclosure")
    }

    private func bodySection(_ trace: ChatRequestTrace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("实际请求正文").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    copyStatus = NSPasteboard.general.setString(trace.body, forType: .string)
                        ? "已复制请求正文" : "复制失败，请选择正文后手动复制。"
                } label: {
                    Label("复制正文", systemImage: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("request-details-copy-body")
            }
            HStack(spacing: 12) {
                Text("\(trace.bodyBytes) 字节")
                if trace.secretsRedacted { Text("凭据已脱敏") }
            }
            .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
            .accessibilityIdentifier("request-details-body-flags")
            if let copyStatus {
                Text(verbatim: copyStatus).font(.system(size: 11))
                    .foregroundStyle(WorkbenchTheme.secondaryText)
                    .accessibilityIdentifier("request-details-copy-status")
            }
            rawTextBlock(trace.body, identifier: "request-details-body", minimumHeight: 200)
        }
    }

    private func rawTextBlock(_ text: String, identifier: String, minimumHeight: CGFloat = 64) -> some View {
        Text(verbatim: text).font(.system(size: 12, design: .monospaced)).lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
            .padding(12)
            .background(WorkbenchTheme.codeFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkbenchTheme.border, lineWidth: 1))
            .accessibilityIdentifier(identifier)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if [.translating, .running, .streaming].contains(message.state), message.runID != nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 25))
                    .foregroundStyle(WorkbenchTheme.secondaryText)
            }
            Text(message.runID == nil ? "这条旧消息未记录请求详情" : "尚未记录实际请求")
                .font(.system(size: 14, weight: .medium))
            Text(verbatim: emptyDescription).font(.system(size: 12))
                .foregroundStyle(WorkbenchTheme.secondaryText)
                .multilineTextAlignment(.center)
            if let error = message.error { WorkbenchErrorLine(text: error) }
        }
        .accessibilityIdentifier("request-details-empty")
    }

    private var emptyDescription: String {
        guard message.runID != nil else { return "只能查看记录此功能启用后的实际请求。" }
        switch message.state {
        case .translating: return "输入翻译进行中，Claude Code 尚未发出请求。"
        case .running: return "Claude Code 正在启动，请求记录到达后将在此更新。"
        case .streaming: return "等待本次 Claude Code 对话的请求记录。"
        case .failed: return "本次执行失败，未收到实际请求记录。"
        case .cancelled: return "本次执行已停止，未收到实际请求记录。"
        case .complete: return "本次 Claude Code 对话未收到实际请求记录。"
        }
    }

    private func headersText(_ trace: ChatRequestTrace) -> String {
        trace.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private func proxyDescription(_ trace: ChatRequestTrace) -> String {
        if let url = trace.proxy.url { return "\(trace.proxy.mode) · \(url)" }
        return trace.proxy.mode == "unavailable" ? "未记录代理" : trace.proxy.mode
    }

    private func isWaiting(_ trace: ChatRequestTrace) -> Bool {
        trace.phase == .request && ![.complete, .failed, .cancelled].contains(message.state)
    }

    private func isFailure(_ trace: ChatRequestTrace) -> Bool {
        (trace.phase == .error && trace.outcome != "cancelled") || (trace.status.map { $0 >= 400 } ?? false)
            || (trace.phase == .request && message.state == .failed)
    }

    private func phaseDescription(_ trace: ChatRequestTrace) -> String {
        switch trace.phase {
        case .request:
            switch message.state {
            case .cancelled: return "已停止 · 未收到响应记录"
            case .failed: return "执行失败 · 未收到响应记录"
            case .complete: return "请求已发出 · 未收到响应记录"
            case .translating, .running, .streaming: return "请求已发出 · 等待响应"
            }
        case .response: return isFailure(trace) ? "HTTP 请求失败" : "响应已完成"
        case .error: return trace.outcome == "cancelled" ? "请求已停止" : "请求失败"
        }
    }
}
