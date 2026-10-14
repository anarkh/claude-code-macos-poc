import AppKit
import Foundation

enum ApplicationTerminationFailure: Error, LocalizedError, Equatable {
    case workAdmissionClosed
    case drainTimedOut([String])
    case persistenceFailed
    case coordinatorUnavailable
    case browserSaveUnconfirmed(String)

    var errorDescription: String? {
        switch self {
        case .workAdmissionClosed: "App 正在退出，已停止接收新的模型任务。"
        case .drainTimedOut(let pending):
            "等待任务退出超时（\(pending.joined(separator: "、"))）。App 已保持打开，凭据与会话仍保留。\(pending.contains("浏览器保存与关机") ? "请在浏览器页面等待关机完成，或确认后手动强制停止，再重试退出。" : "请稍后重试退出。")"
        case .persistenceFailed:
            "会话保存或回读验证失败。App 已保持打开，凭据与已有会话文件仍保留。请检查磁盘空间和数据目录权限后重试退出。"
        case .coordinatorUnavailable: "退出协调器尚未准备好，App 已保持打开。请稍后重试退出。"
        case .browserSaveUnconfirmed(let message): message
        }
    }
}

@MainActor
protocol BrowserTerminationManaging: AnyObject {
    var isTerminationWorkSettled: Bool { get }
    var terminationSaveFailure: String? { get }
    func beginTermination()
    func endTermination()
    func acknowledgeTerminationSaveFailure() throws
}

/// One admission barrier and one deadline cover UI tasks and dispatch workers.
/// A cancelled stream may finish before its worker; registry settlement is also
/// required before AppKit receives permission to end the application.
@MainActor
final class ApplicationTerminationCoordinator {
    private let chat: ConversationViewModel
    private let execution: ExecutionViewModel
    private let translation: TranslationViewModel
    private let loginReset: ClaudeLoginResetModel?
    private let runtimeVersions: RuntimeVersionViewModel?
    private let browser: (any BrowserTerminationManaging)?
    private let registry: OwnedProcessRegistry
    private let timeoutSeconds: Double
    private var drainTask: Task<Void, Error>?
    private(set) var isReadyToTerminate = false

    init(chat: ConversationViewModel, execution: ExecutionViewModel, translation: TranslationViewModel,
         loginReset: ClaudeLoginResetModel? = nil, runtimeVersions: RuntimeVersionViewModel? = nil,
         browser: (any BrowserTerminationManaging)? = nil, registry: OwnedProcessRegistry = .shared,
         timeoutSeconds: Double = 12) {
        self.chat = chat; self.execution = execution; self.translation = translation
        self.loginReset = loginReset; self.registry = registry; self.timeoutSeconds = timeoutSeconds
        self.runtimeVersions = runtimeVersions
        self.browser = browser
    }

    func requestTermination() async throws {
        if isReadyToTerminate { return }
        if let drainTask { try await drainTask.value; return }

        // Close process admission before any task cancellation can race a launch.
        registry.beginTermination()
        browser?.beginTermination()
        chat.beginTermination(); execution.beginTermination(); translation.beginTermination()
        runtimeVersions?.beginTermination()
        let task = Task { @MainActor in
            do {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(max(0, self.timeoutSeconds)))
                while !self.pendingWork.isEmpty {
                    try Task.checkCancellation()
                    guard clock.now < deadline else {
                        throw ApplicationTerminationFailure.drainTimedOut(self.pendingWork)
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                if let failure = self.browser?.terminationSaveFailure {
                    throw ApplicationTerminationFailure.browserSaveUnconfirmed(failure)
                }
                try self.chat.persistForTermination()
                self.isReadyToTerminate = true
            } catch {
                // A failed quit leaves the app usable, while keeping a concurrent
                // login reset's independent admission barrier intact.
                self.chat.endTermination(); self.execution.endTermination(); self.translation.endTermination()
                self.registry.endTermination()
                self.runtimeVersions?.endTermination()
                self.browser?.endTermination()
                throw error
            }
        }
        drainTask = task
        do {
            try await task.value
            drainTask = nil
        } catch {
            drainTask = nil
            throw error
        }
    }

    func acknowledgeBrowserSaveFailure() throws {
        try browser?.acknowledgeTerminationSaveFailure()
    }

    private var pendingWork: [String] {
        var pending: [String] = []
        if !chat.isTerminationWorkSettled { pending.append("聊天与消息翻译") }
        if !translation.isTerminationWorkSettled { pending.append("设置翻译") }
        if !execution.isTerminationWorkSettled { pending.append("连接测试") }
        if registry.activeCount != 0 { pending.append("模型与虚拟机进程") }
        if loginReset?.isBusy == true { pending.append("已开始的登录清理") }
        if runtimeVersions?.isTerminationWorkSettled == false { pending.append("运行包导入") }
        if browser?.isTerminationWorkSettled == false { pending.append("浏览器保存与关机") }
        return pending
    }
}

@MainActor
final class ClaudeIsolationApplicationDelegate: NSObject, NSApplicationDelegate {
    var terminationCoordinator: ApplicationTerminationCoordinator?
    private var terminationTask: Task<Void, Never>?
    // Tests observe completion without terminating their runner. Production
    // retries AppKit termination after async work finishes in the normal run loop.
    var terminationReply: ((Bool) -> Void)?
    var terminationFailure: ((String) -> Void)?
    // Tests decide without presenting a modal alert; production only accepts
    // acknowledgement from the dedicated alert's explicit "still quit" button.
    var browserSaveFailureDecision: ((String) -> Bool)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let terminationCoordinator else {
            reportFailure(ApplicationTerminationFailure.coordinatorUnavailable.localizedDescription)
            return .terminateCancel
        }
        if terminationCoordinator.isReadyToTerminate { return .terminateNow }
        if terminationTask != nil { return .terminateCancel }
        terminationTask = Task { @MainActor in
            do {
                try await terminationCoordinator.requestTermination()
                self.terminationTask = nil
                self.reply(true, to: sender)
            } catch {
                if case ApplicationTerminationFailure.browserSaveUnconfirmed(let message) = error {
                    if self.confirmQuitWithUnconfirmedBrowserSave(message) {
                        do {
                            try terminationCoordinator.acknowledgeBrowserSaveFailure()
                            try await terminationCoordinator.requestTermination()
                            self.terminationTask = nil
                            self.reply(true, to: sender)
                        } catch {
                            self.terminationTask = nil
                            self.reply(false, to: sender)
                            self.reportFailure((error as? ApplicationTerminationFailure)?.localizedDescription ??
                                "浏览器尚未停稳，App 已保持打开。请稍后重试退出。")
                        }
                    } else {
                        self.terminationTask = nil
                        self.reply(false, to: sender)
                    }
                    return
                }
                self.terminationTask = nil
                self.reply(false, to: sender)
                let message = (error as? ApplicationTerminationFailure)?.localizedDescription ??
                    "停止任务时发生错误，App 已保持打开。请稍后重试退出。"
                self.reportFailure(message)
            }
        }
        // terminateLater enters AppKit's nested modal run loop. If Quit was
        // requested by a MainActor task, that loop can strand the async drain.
        // Intercept this attempt; retry once ready, when terminateNow is safe.
        return .terminateCancel
    }

    private func confirmQuitWithUnconfirmedBrowserSave(_ message: String) -> Bool {
        if let browserSaveFailureDecision { return browserSaveFailureDecision(message) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "浏览器保存尚未确认"
        alert.informativeText = message + "\n仍然退出将接受本次未确认保存的风险，资料盘继续保留。"
        alert.addButton(withTitle: "继续使用 App")
        alert.addButton(withTitle: "仍然退出")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func reply(_ shouldTerminate: Bool, to application: NSApplication) {
        if let terminationReply { terminationReply(shouldTerminate) }
        else if shouldTerminate { application.terminate(nil) }
    }

    private func reportFailure(_ message: String) {
        if let terminationFailure { terminationFailure(message); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出尚未完成"
        alert.informativeText = message
        alert.addButton(withTitle: "继续使用 App")
        alert.runModal()
    }
}
