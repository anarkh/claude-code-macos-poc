import SwiftUI

struct SubscriptionAccountsView: View {
    @ObservedObject var model: SubscriptionAccountsModel
    let canManage: Bool
    /// The parent coordinates account selection with the active conversation.
    /// `true` requests a new conversation after the account is selected.
    let onSelect: (UUID, Bool) -> Void
    @State private var editor: SubscriptionAccountEditor?
    @State private var confirmation: SubscriptionAccountConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Claude 订阅账号").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("刷新额度") { Task { await model.refreshAll() } }
                    .disabled(!model.accounts.contains { $0.token != nil } || isRefreshing)
                    .accessibilityIdentifier("refresh-subscription-quotas")
                Button("添加账号…") { editor = .add }
                    .disabled(!canManage || !model.hasLoaded)
                    .accessibilityIdentifier("add-subscription-account")
            }
            Text("每个账号独立保存，手动切换后用于下一次发送。额度在打开本页时刷新，也可手动刷新。")
                .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("额度查询失败不代表额度耗尽；Token 缺少查询权限时显示不可用，不影响使用该 Token 聊天。")
                .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if !model.hasLoaded {
                Button("重新读取账号") {
                    if model.load() { Task { await model.refreshAll() } }
                }.accessibilityIdentifier("reload-subscription-accounts")
            } else if model.accounts.isEmpty {
                Text("尚未添加 Claude 订阅账号。")
                    .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                    .accessibilityIdentifier("subscription-accounts-empty")
            }
            ForEach(model.accounts) { account in accountCard(account) }

            if !canManage {
                Text("请等待当前请求、连接测试或维护任务完成后再修改或切换账号。")
                    .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            if let status = model.status {
                Text(status).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                    .accessibilityIdentifier("subscription-accounts-status")
            }
            if let error = model.error { WorkbenchErrorLine(text: error) }
        }
        .accessibilityIdentifier("subscription-accounts")
        .task {
            if model.load() { await model.refreshAll() }
        }
        .onDisappear { model.cancelRefreshes() }
        .sheet(item: $editor) { selection in
            SubscriptionAccountEditorSheet(model: model, editor: selection, canManage: canManage)
        }
        .alert(confirmation?.title ?? "账号操作", isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { operation in
            switch operation {
            case .select(let account):
                Button("继续当前会话") { onSelect(account.id, false) }
                    .disabled(!canManage)
                Button("切换并新建会话") { onSelect(account.id, true) }
                    .disabled(!canManage)
            case .clear(let account):
                Button("清除授权", role: .destructive) { _ = model.clearCredential(id: account.id) }
                    .disabled(!canManage)
            case .remove(let account):
                Button("删除账号", role: .destructive) { _ = model.remove(id: account.id) }
                    .disabled(!canManage)
            }
            Button("取消", role: .cancel) {}
        } message: { operation in
            Text(operation.message)
        }
    }

    private var isRefreshing: Bool { model.quotaStates.values.contains { $0.isRefreshing } }

    private func accountCard(_ account: SubscriptionAccount) -> some View {
        let quota = model.quotaStates[account.id]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(account.label).font(.system(size: 13, weight: .semibold))
                        if account.id == model.currentAccountID {
                            Text("当前账号").font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(WorkbenchTheme.selection, in: Capsule())
                                .accessibilityIdentifier("current-subscription-account")
                        }
                    }
                    Text(account.token == nil ? "尚未保存授权" : "已保存授权")
                        .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
                }
                Spacer()
                if account.id != model.currentAccountID {
                    Button("使用此账号") { confirmation = .select(.init(account)) }
                        .disabled(!canManage || account.token == nil)
                        .accessibilityIdentifier("select-subscription-account-\(account.id.uuidString)")
                }
                Menu("管理") {
                    Button("重命名…") { editor = .rename(.init(account)) }
                    Button(account.token == nil ? "添加授权…" : "更新授权…") { editor = .token(.init(account)) }
                    Button("清除授权…", role: .destructive) { confirmation = .clear(.init(account)) }
                        .disabled(account.token == nil)
                    Divider()
                    Button("删除账号…", role: .destructive) { confirmation = .remove(.init(account)) }
                }
                .disabled(!canManage)
                .accessibilityIdentifier("manage-subscription-account-\(account.id.uuidString)")
            }
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 10) {
                quotaWindow("five_hour", quota: quota)
                quotaWindow("seven_day", quota: quota)
                if let snapshot = quota?.snapshot {
                    ForEach(snapshot.windows.filter { !["five_hour", "seven_day"].contains($0.id) }, id: \.id) { window in
                        SubscriptionQuotaWindowView(windowID: window.id, window: window, stale: quota?.isStale == true)
                    }
                }
            }
            HStack(spacing: 8) {
                if quota?.isRefreshing == true { ProgressView().controlSize(.small) }
                if let snapshot = quota?.snapshot {
                    Text("更新于 \(snapshot.queriedAt.formatted(date: .abbreviated, time: .shortened))")
                    if quota?.isStale == true { Text("· 旧数据") }
                } else {
                    Text(quota?.isRefreshing == true ? "正在查询额度…" : "尚未取得额度数据")
                }
                Spacer()
                Button("刷新") { Task { await model.refresh(id: account.id) } }
                    .disabled(account.token == nil || quota?.isRefreshing == true)
                    .accessibilityIdentifier("refresh-subscription-account-\(account.id.uuidString)")
            }
            .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
            .controlSize(.small)
            if let error = quota?.lastError { WorkbenchErrorLine(text: error) }
        }
        .padding(14)
        .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(WorkbenchTheme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subscription-account-\(account.id.uuidString)")
    }

    private func quotaWindow(_ id: String, quota: SubscriptionAccountQuotaState?) -> some View {
        SubscriptionQuotaWindowView(windowID: id,
            window: quota?.snapshot?.windows.first { $0.id == id }, stale: quota?.isStale == true)
    }
}

private struct SubscriptionQuotaWindowView: View {
    let windowID: String
    let window: SubscriptionQuotaWindow?
    let stale: Bool

    var body: some View {
        // Only the displayed countdown changes here; this never issues a query.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let expired = window?.resetsAt.map { $0 <= context.date } ?? false
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    if let window {
                        Text("\(expired || stale ? "上次" : "")已用 \(percentage(window.usedPercentage))% · 剩余 \(percentage(100 - window.usedPercentage))%")
                            .monospacedDigit()
                    } else {
                        Text("--").monospacedDigit()
                    }
                }.font(.system(size: 11))
                if let window {
                    ProgressView(value: window.usedPercentage, total: 100)
                        .tint(expired || stale ? .secondary : .accentColor)
                        .accessibilityLabel("\(title)，\(expired || stale ? "上次查询" : "")已用百分之\(percentage(window.usedPercentage))")
                } else {
                    Capsule().fill(WorkbenchTheme.subtleFill).frame(height: 4)
                        .accessibilityLabel("\(title)，额度暂不可用")
                }
                if let resetsAt = window?.resetsAt {
                    Text(expired ? "已到重置时间，请刷新额度。" : "\(resetsAt.formatted(.dateTime.month().day().hour().minute())) 重置 · \(remaining(until: resetsAt, from: context.date))")
                        .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
                }
            }
        }
    }

    private var title: String {
        switch windowID {
        case "five_hour": "5 小时额度"
        case "seven_day": "每周额度"
        case "seven_day_sonnet": "Sonnet 每周额度"
        case "seven_day_opus": "Opus 每周额度"
        case "seven_day_oauth_apps": "OAuth 应用每周额度"
        default: windowID
        }
    }

    private func percentage(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func remaining(until date: Date, from now: Date) -> String {
        let minutes = max(1, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes >= 1_440 { return "\(minutes / 1_440) 天 \((minutes % 1_440) / 60) 小时后" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟后" }
        return "\(minutes) 分钟后"
    }
}

private struct SubscriptionAccountViewReference {
    let id: UUID
    let label: String

    init(_ account: SubscriptionAccount) {
        id = account.id
        label = account.label
    }
}

private enum SubscriptionAccountEditor: Identifiable {
    case add, rename(SubscriptionAccountViewReference), token(SubscriptionAccountViewReference)
    var id: String {
        switch self {
        case .add: "add"
        case .rename(let account): "rename-\(account.id)"
        case .token(let account): "token-\(account.id)"
        }
    }
    var title: String {
        switch self {
        case .add: "添加 Claude 账号"
        case .rename: "重命名账号"
        case .token: "更新账号授权"
        }
    }
}

private struct SubscriptionAccountEditorSheet: View {
    @ObservedObject var model: SubscriptionAccountsModel
    let editor: SubscriptionAccountEditor
    let canManage: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var token = ""

    init(model: SubscriptionAccountsModel, editor: SubscriptionAccountEditor, canManage: Bool) {
        self.model = model
        self.editor = editor
        self.canManage = canManage
        switch editor {
        case .add: _label = State(initialValue: "")
        case .rename(let account), .token(let account): _label = State(initialValue: account.label)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editor.title).font(.system(size: 18, weight: .semibold))
            if showsLabel {
                TextField("账号名称", text: $label)
                    .accessibilityIdentifier("subscription-account-label")
            } else {
                Text(label).font(.system(size: 13, weight: .medium))
            }
            if showsToken {
                SecureField("粘贴 sk-ant-oat01- 开头的 Token", text: $token)
                    .accessibilityIdentifier("subscription-token")
                Text("Token 仅保存在本机账号记录中。更新授权会替换此账号的旧 Token，不影响其他账号。")
                    .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error { WorkbenchErrorLine(text: error) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { token = ""; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canManage || (showsLabel && label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (showsToken && token.isEmpty))
                    .accessibilityIdentifier("save-subscription-account")
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24).frame(width: 440)
        .onDisappear { token = "" }
    }

    private var showsLabel: Bool {
        if case .token = editor { return false }
        return true
    }

    private var showsToken: Bool {
        if case .rename = editor { return false }
        return true
    }

    private func save() {
        let saved: Bool
        switch editor {
        case .add: saved = model.add(label: label, token: token)
        case .rename(let account): saved = model.rename(id: account.id, label: label)
        case .token(let account): saved = model.updateToken(id: account.id, token: token)
        }
        if saved { token = ""; dismiss() }
    }
}

private enum SubscriptionAccountConfirmation {
    case select(SubscriptionAccountViewReference), clear(SubscriptionAccountViewReference), remove(SubscriptionAccountViewReference)
    var title: String {
        switch self {
        case .select(let account): "切换到“\(account.label)”？"
        case .clear(let account): "清除“\(account.label)”的授权？"
        case .remove(let account): "删除“\(account.label)”？"
        }
    }
    var message: String {
        switch self {
        case .select:
            "继续当前会话时，下一次发送会将已有对话历史发给新账号。也可以切换后新建空白会话。"
        case .clear:
            "只清除此账号在本机保存的 Token，账号名称、其他账号、对话历史和项目目录会保留。"
        case .remove:
            "将删除此账号的本机记录和 Token，已有对话历史和项目目录会保留。"
        }
    }
}
