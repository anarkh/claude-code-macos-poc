import SwiftUI

struct ComposerView: View {
    @ObservedObject var chat: ConversationViewModel
    let configuration: AppConfiguration?
    let focusRequest: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(spacing: 0) {
                NativeComposerTextView(text: $chat.draft, enabled: chat.selectedID != nil,
                                       focusRequest: focusRequest,
                                       onSend: {
                                           if chat.canSend && configuration != nil { chat.send() }
                                       })
                    .id(chat.selectedID)
                    .frame(height: 102)
                HStack(spacing: 10) {
                    Picker("发送语言", selection: $chat.targetLanguage) {
                        ForEach(TargetLanguage.allCases) { language in
                            Text("译为\(language.title)").tag(language)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(width: 108)
                    .disabled(chat.selectedID == nil)
                    .accessibilityIdentifier("target-language")
                    .accessibilityLabel("选择发送给模型的语言")
                    Spacer(minLength: 0)
                    if chat.isCurrentConversationBusy {
                        Text(chat.activityStatus ?? "执行中…")
                            .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText).lineLimit(1)
                        Button(action: chat.stop) {
                            Image(systemName: "stop.fill").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(nsColor: .textBackgroundColor))
                                .frame(width: 30, height: 30)
                                .background(Color(nsColor: .labelColor), in: Circle())
                        }
                        .buttonStyle(.plain).help("停止当前回复")
                        .accessibilityIdentifier("stop-conversation")
                        .accessibilityLabel("停止当前回复")
                    } else {
                        Button(action: chat.send) {
                            Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(chat.canSend ? Color(nsColor: .textBackgroundColor) : WorkbenchTheme.secondaryText)
                                .frame(width: 30, height: 30)
                                .background(chat.canSend ? Color(nsColor: .labelColor) : WorkbenchTheme.subtleFill, in: Circle())
                        }
                        .buttonStyle(.plain).disabled(!chat.canSend || configuration == nil)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("自动翻译并发送（⌘↵）")
                        .accessibilityIdentifier("send-conversation")
                        .accessibilityLabel("自动翻译并发送给 Claude Code")
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 11).padding(.top, 5)
            }
            .background(WorkbenchTheme.editor, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(WorkbenchTheme.border, lineWidth: 1))
            HStack(spacing: 8) {
                Text("⌘↵ 发送 · 回车换行")
                Spacer(minLength: 0)
                if configuration == nil { Text("应用配置不可用") }
                else if chat.isBusy && !chat.isCurrentConversationBusy { Text("另一会话正在执行") }
                else { Text("发送时自动翻译为\(chat.targetLanguage.title)") }
            }
            .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
        }
    }
}
