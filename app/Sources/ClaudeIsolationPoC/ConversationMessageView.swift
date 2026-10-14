import SwiftUI

struct ConversationMessageView: View {
    let message: ConversationMessage
    let isTranslating: Bool
    let translate: () -> Void
    let showRequestDetails: () -> Void

    var body: some View {
        Group {
            switch message.role {
            case .user: userMessage
            case .assistant: assistantMessage
            case .activity: activityMessage
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("message-\(message.id.uuidString)")
    }

    private var userMessage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("你").font(.system(size: 12, weight: .semibold))
                if message.state == .translating {
                    ProgressView().controlSize(.mini)
                    Text("正在翻译输入…").font(.system(size: 11))
                        .foregroundStyle(WorkbenchTheme.secondaryText)
                }
                Spacer(minLength: 8)
                requestDetailsButton
            }
            messageText(message.text)
                .accessibilityIdentifier("user-message-translated-\(message.id.uuidString)")
            if let original = message.originalText, original != message.text {
                DisclosureGroup("中文原文") {
                    Text(verbatim: original).font(.system(size: 13)).lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding(.top, 6)
                }
                .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            messageError
        }
        .padding(16)
        .background(WorkbenchTheme.subtleFill, in: RoundedRectangle(cornerRadius: 14))
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sparkle").font(.system(size: 15))
                    .foregroundStyle(WorkbenchTheme.secondaryText).frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text("Claude Code").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                requestDetailsButton
            }
            VStack(alignment: .leading, spacing: 10) {
                messageText(message.text)
                    .accessibilityIdentifier("assistant-original-\(message.id.uuidString)")
                if message.state == .streaming {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("正在生成…").font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
                    }
                }
                if !message.text.isEmpty && message.state == .complete {
                    Button(action: translate) {
                        HStack(spacing: 6) {
                            if isTranslating { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "character.bubble") }
                            Text(isTranslating ? "正在翻译…" : (message.translation == nil ? "翻译为中文" : "重新翻译为中文"))
                        }
                        .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless).disabled(isTranslating)
                    .accessibilityIdentifier("translate-message-\(message.id.uuidString)")
                    .help("将这条回复翻译为中文，原文保留")
                }
                if let translation = message.translation {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("中文译文").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(WorkbenchTheme.secondaryText)
                        messageText(translation)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WorkbenchTheme.subtleFill, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("assistant-translation-\(message.id.uuidString)")
                }
                messageError
                if message.state == .cancelled {
                    Label("已停止", systemImage: "stop.circle").font(.system(size: 11))
                        .foregroundStyle(WorkbenchTheme.secondaryText)
                }
            }
            .padding(.leading, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var activityMessage: some View {
        HStack(alignment: .center, spacing: 12) {
            if message.state == .translating || message.state == .running || message.state == .streaming {
                ProgressView().controlSize(.mini).frame(width: 20, height: 20)
            } else {
                Image(systemName: activitySymbol).font(.system(size: 12))
                    .foregroundStyle(message.state == .failed ? .red : WorkbenchTheme.secondaryText)
                    .frame(width: 20, height: 20).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: message.text).font(.system(size: 12))
                    .foregroundStyle(WorkbenchTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                messageError
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("activity-\(message.id.uuidString)")
    }

    @ViewBuilder private var messageError: some View {
        if let error = message.error { WorkbenchErrorLine(text: error) }
    }
    private var requestDetailsButton: some View {
        Button(action: showRequestDetails) {
            Label("请求详情", systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(WorkbenchTheme.secondaryText)
        }
        .buttonStyle(.borderless)
        .disabled(message.runID == nil)
        .help(message.runID == nil ? "这条旧消息未记录请求详情" : "查看本次 Claude Code 对话的实际请求")
        .accessibilityIdentifier("request-details-message-\(message.id.uuidString)")
        .accessibilityLabel(message.runID == nil ? "请求详情，旧消息未记录" : "请求详情")
    }
    private func messageText(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 14)).lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
    private var activitySymbol: String {
        switch message.state {
        case .complete: "checkmark.circle"
        case .failed: "xmark.circle"
        case .cancelled: "stop.circle"
        case .translating, .running, .streaming: "ellipsis.circle"
        }
    }
}
