import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var chat: ConversationViewModel
    @ObservedObject var browser: BrowserVMController
    let configuration: AppConfiguration?
    @Environment(\.openSettings) private var openSettings
    @State private var composerFocusRequest = 0
    @State private var renameID: UUID?
    @State private var renameTitle = ""
    @State private var deletionID: UUID?
    @State private var requestDetailsMessageID: UUID?
    @State private var smokeTestScheduled = false
    @State private var isNearBottom = true
    @State private var showingBrowser = false
    private var isOfflineDemo: Bool { CommandLine.arguments.contains("--ui-fixture") }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if showingBrowser {
                BrowserView(browser: browser).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    if let error = chat.persistenceError {
                        WorkbenchErrorLine(text: error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 28).padding(.vertical, 10)
                            .accessibilityIdentifier("conversation-persistence-error")
                    }
                    conversation
                    ComposerView(chat: chat, configuration: configuration, focusRequest: composerFocusRequest)
                        .frame(maxWidth: WorkbenchTheme.contentWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WorkbenchTheme.canvas)
            }
        }
        .frame(minWidth: 880, minHeight: 620)
        .background(WorkbenchTheme.canvas)
        .sheet(isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            renameSheet
        }
        .sheet(isPresented: Binding(get: { requestDetailsMessageID != nil }, set: { if !$0 { requestDetailsMessageID = nil } })) {
            requestDetailsSheet
        }
        .alert("删除会话？", isPresented: Binding(get: { deletionID != nil }, set: { if !$0 { deletionID = nil } })) {
            Button("取消", role: .cancel) { deletionID = nil }
            Button("删除", role: .destructive) {
                if let id = deletionID { chat.deleteConversation(id) }
                deletionID = nil
            }
        } message: {
            Text("此会话的本地对话记录会被删除。")
        }
        .onAppear { scheduleSmokeTest() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 16, weight: .medium))
                Text("Claude 工作台").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.top, 23).padding(.bottom, 23)

            Button(action: newConversation) {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil").frame(width: 18)
                    Text("新建会话")
                    Spacer(minLength: 0)
                    Text("⌘N").foregroundStyle(WorkbenchTheme.secondaryText)
                }
                .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).keyboardShortcut("n", modifiers: .command)
            .accessibilityIdentifier("new-conversation")
            .padding(.horizontal, 8).padding(.bottom, 24)

            Button { showingBrowser = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "globe").frame(width: 18)
                    Text("浏览器")
                    Spacer(minLength: 0)
                    if browser.state != .idle {
                        Circle().fill(browser.state == .running ? Color.green : Color.orange).frame(width: 6, height: 6)
                    }
                }
                .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 36)
                .background(showingBrowser ? WorkbenchTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("open-browser")
                .accessibilityAddTraits(showingBrowser ? .isSelected : [])
                .padding(.horizontal, 8).padding(.bottom, 18)

            Text("会话").font(.system(size: 11, weight: .medium))
                .foregroundStyle(WorkbenchTheme.secondaryText)
                .padding(.horizontal, 18).padding(.bottom, 9)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(chat.conversations) { record in
                        Button {
                            showingBrowser = false
                            chat.selectConversation(record.id)
                            composerFocusRequest += 1
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "bubble.left").font(.system(size: 12)).frame(width: 17)
                                    .foregroundStyle(WorkbenchTheme.secondaryText)
                                Text(record.title).font(.system(size: 13)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.primary).padding(.horizontal, 10).frame(height: 36)
                            .background(!showingBrowser && chat.selectedID == record.id ? WorkbenchTheme.selection : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("conversation-\(record.id.uuidString)")
                        .accessibilityLabel("会话：\(record.title)")
                        .accessibilityAddTraits(!showingBrowser && chat.selectedID == record.id ? .isSelected : [])
                        .contextMenu {
                            Button("重命名") {
                                renameTitle = record.title
                                renameID = record.id
                            }
                            Button("删除会话…", role: .destructive) { deletionID = record.id }
                        }
                    }
                }.padding(.horizontal, 8)
            }
            .accessibilityIdentifier("conversation-list")
            .frame(maxHeight: .infinity)

            if isOfflineDemo {
                Label("离线演示", systemImage: "desktopcomputer")
                    .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .accessibilityIdentifier("offline-fixture-label")
            }
            Divider().padding(.horizontal, 12)
            Button { openSettings() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape").frame(width: 18)
                    Text("设置")
                    Spacer()
                    Text("⌘,").foregroundStyle(WorkbenchTheme.secondaryText)
                }
                .font(.system(size: 13)).padding(.horizontal, 18).frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("open-settings")
            .accessibilityLabel("打开模型设置")
        }
        .frame(width: 240)
        .frame(maxHeight: .infinity)
        .background(WorkbenchTheme.sidebar)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(chat.selectedConversation?.title ?? "新会话")
                .font(.system(size: 14, weight: .medium)).lineLimit(1)
                .accessibilityIdentifier("current-conversation-title")
            Spacer(minLength: 12)
            if chat.isCurrentConversationBusy {
                ProgressView().controlSize(.small)
                Text(chat.activityStatus ?? "执行中…").font(.system(size: 12))
                    .foregroundStyle(WorkbenchTheme.secondaryText).lineLimit(1)
            }
        }
        .padding(.horizontal, 26).frame(height: 54)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if chat.messages.isEmpty { emptyConversation }
                        else {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(chat.messages.enumerated()), id: \.element.id) { entry in
                                    let message = entry.element
                                    ConversationMessageView(
                                        message: message,
                                        isTranslating: chat.translatingMessageIDs.contains(message.id),
                                        translate: { chat.translateMessage(message.id) },
                                        showRequestDetails: { requestDetailsMessageID = message.id }
                                    )
                                    .padding(.top, spacingBeforeMessage(at: entry.offset))
                                    .id(message.id)
                                }
                            }
                        }
                        GeometryReader { marker in
                            Color.clear.preference(key: ConversationBottomPreference.self,
                                                   value: marker.frame(in: .named("conversation-viewport")).maxY)
                        }
                        .frame(height: 1).id("conversation-bottom")
                    }
                    .frame(maxWidth: WorkbenchTheme.contentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 20)
                }
                .coordinateSpace(name: "conversation-viewport")
                .accessibilityIdentifier("conversation-timeline")
                .onPreferenceChange(ConversationBottomPreference.self) { bottom in
                    isNearBottom = bottom <= viewport.size.height + 90
                }
                .onChange(of: chat.selectedID) { _, _ in
                    isNearBottom = true
                    scrollToLatest(proxy)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    if isNearBottom || chat.messages.last?.role == .user { scrollToLatest(proxy) }
                }
                .onChange(of: chat.messages.last?.text) { _, _ in
                    if isNearBottom && chat.isCurrentConversationBusy { scrollToLatest(proxy) }
                }
                .onAppear { scrollToLatest(proxy) }
                .overlay(alignment: .bottomTrailing) {
                    if !isNearBottom {
                        Button {
                            isNearBottom = true
                            scrollToLatest(proxy)
                        } label: {
                            Image(systemName: "arrow.down").font(.system(size: 12, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(WorkbenchTheme.surface, in: Circle())
                                .overlay(Circle().stroke(WorkbenchTheme.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain).help("查看最新消息")
                        .accessibilityLabel("滚动到最新消息")
                        .accessibilityIdentifier("scroll-to-latest")
                        .padding(20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今天想做什么？").font(.system(size: 26, weight: .semibold))
            Text("用中文描述任务。发送后，译文和模型的执行过程会显示在这里。")
                .font(.system(size: 14)).foregroundStyle(WorkbenchTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if chat.selectedID == nil {
                Button("新建会话", action: newConversation).buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .padding(.top, 58).padding(.bottom, 64)
        .accessibilityIdentifier("empty-conversation")
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重命名会话").font(.system(size: 17, weight: .semibold))
            TextField("会话名称", text: $renameTitle)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("rename-conversation-title")
                .onSubmit { commitRename() }
            HStack {
                Spacer()
                Button("取消") { renameID = nil }.keyboardShortcut(.cancelAction)
                Button("保存", action: commitRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 360)
    }

    @ViewBuilder private var requestDetailsSheet: some View {
        if let record = chat.selectedConversation,
           let message = record.messages.first(where: { $0.id == requestDetailsMessageID }) {
            RequestDetailsView(message: chat.requestDetailsMessage(for: message, in: record),
                               traces: chat.requestTraces(for: message, in: record))
        }
    }

    private func newConversation() {
        showingBrowser = false
        chat.newConversation()
        composerFocusRequest += 1
    }
    private func commitRename() {
        let title = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = renameID, !title.isEmpty else { return }
        chat.renameConversation(id, title: title)
        renameID = nil
    }
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
    }
    private func spacingBeforeMessage(at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        switch chat.messages[index].role {
        case .activity: return chat.messages[index - 1].role == .assistant ? 8 : 6
        case .assistant: return chat.messages[index - 1].role == .activity ? 14 : 20
        case .user: return 24
        }
    }
    private func scheduleSmokeTest() {
        guard CommandLine.arguments.contains("--smoke-test"), !smokeTestScheduled else { return }
        smokeTestScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let windows = NSApplication.shared.windows.filter { $0.isVisible && $0.contentView != nil }
            let passed = !windows.isEmpty
            print("{\"schema\":\"mac-app-window-smoke/v1\",\"status\":\"\(passed ? "passed" : "failed")\",\"visible_own_windows\":\(windows.count),\"conversation_ui\":true,\"project_execution_enabled\":false,\"real_model_called\":false,\"keychain_accessed\":false}")
            fflush(stdout)
            NSApplication.shared.terminate(nil)
        }
    }
}

private struct ConversationBottomPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
