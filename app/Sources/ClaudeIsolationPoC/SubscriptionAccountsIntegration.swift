import Foundation
import SwiftUI

@MainActor
func configureAccountLifecycle(_ accounts: SubscriptionAccountsModel, chat: ConversationViewModel,
                               execution: ExecutionViewModel, loginReset: ClaudeLoginResetModel,
                               runtimeVersion: RuntimeVersionViewModel) {
    accounts.canMutate = { [weak chat, weak execution, weak loginReset, weak runtimeVersion] in
        guard let chat, let execution, let loginReset, let runtimeVersion else { return false }
        return chat.isTerminationWorkSettled && !chat.isTerminationInProgress && !chat.isLoginResetInProgress
            && !execution.testBusy && !execution.isTerminationInProgress && !execution.isLoginResetInProgress
            && !loginReset.isBusy && !runtimeVersion.isBusy
    }
    accounts.canRefresh = { [weak execution, weak loginReset] in
        guard let execution, let loginReset else { return false }
        return !execution.isTerminationInProgress && !execution.isLoginResetInProgress && !loginReset.isBusy
    }
}

/// Only injected by the existing explicit offline UI fixture mode.
struct FixtureSubscriptionQuotaService: SubscriptionQuotaFetching {
    func fetch(token: String) async throws -> SubscriptionQuotaSnapshot {
        try Task.checkCancellation()
        guard token.hasPrefix("sk-ant-oat01-fake-") else { throw SubscriptionQuotaFailure(code: "QUOTA_FORBIDDEN") }
        let now = Date()
        return .init(windows: [
            .init(id: "five_hour", usedPercentage: 35, resetsAt: now.addingTimeInterval(7_200)),
            .init(id: "seven_day", usedPercentage: 64, resetsAt: now.addingTimeInterval(172_800))
        ], queriedAt: now)
    }
}

struct SubscriptionAccountMenu: View {
    @ObservedObject var model: SubscriptionAccountsModel
    let canManage: Bool
    let openSettings: () -> Void
    let onSelect: (UUID, Bool) -> Void
    @State private var pendingAccountID: UUID?

    var body: some View {
        Menu {
            ForEach(model.accounts) { account in
                Button {
                    pendingAccountID = account.id
                } label: {
                    if account.id == model.currentAccountID {
                        Label(account.label, systemImage: "checkmark")
                    } else { Text(account.label) }
                }
                .disabled(!canManage || account.id == model.currentAccountID || account.token == nil)
            }
            Divider()
            Button("管理账号与额度…", action: openSettings)
        } label: {
            Label(model.currentAccount?.label ?? "选择账号", systemImage: "person.crop.circle")
                .font(.system(size: 12)).lineLimit(1).frame(maxWidth: 160)
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("conversation-subscription-account")
        .help("当前账号只影响下一次发送；请求执行和停止清理期间不能切换。")
        .confirmationDialog("切换订阅账号", isPresented: Binding(
            get: { pendingAccountID != nil }, set: { if !$0 { pendingAccountID = nil } }
        ), titleVisibility: .visible) {
            Button("继续当前会话") { select(startNew: false) }
            Button("切换并新建会话") { select(startNew: true) }
            Button("取消", role: .cancel) { pendingAccountID = nil }
        } message: {
            Text("继续当前会话时，下一次发送会把已有对话历史发送给新账号。新建会话不会携带这些历史。")
        }
    }

    private func select(startNew: Bool) {
        guard let id = pendingAccountID else { return }
        pendingAccountID = nil
        onSelect(id, startNew)
    }
}
