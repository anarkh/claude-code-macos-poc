import Darwin
import Foundation

struct ExternalClaudeLocation: Identifiable {
    enum Status { case present, absent, link, unavailable, manual }
    let id: String
    let title: String
    let pathLabel: String
    let status: Status
    let guidance: String
    let revealURL: URL?
    var statusText: String {
        switch status {
        case .present: "存在 · 未修改"
        case .absent: "未发现此位置"
        case .link: "符号链接 · 未跟随"
        case .unavailable: "无法检查 · 未修改"
        case .manual: "未访问 · 手动处理"
        }
    }
}

/// Reads only metadata of fixed candidates. No directory contents, credentials,
/// browser databases or Keychain APIs are read, and no external files are deleted.
struct ExternalClaudeLocationScanner {
    let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    func scan() -> [ExternalClaudeLocation] {
        let candidates: [(String, String, String)] = [
            ("CLI 全局配置", ".claude.json", "混合了账号、项目和 MCP 配置；请在外部 CLI 中正常退出，不整文件删除。"),
            ("CLI 用户目录", ".claude", "包含 Skills、配置和历史；请在外部 CLI 中正常退出，不整目录删除。"),
            ("Claude Desktop", "Library/Application Support/Claude", "在 Claude Desktop 中正常退出账号；此处不直接修改登录数据库。"),
            ("Claude 第三方推理", "Library/Application Support/Claude-3p", "先在 Desktop 中确认推理来源，保留第三方 Key、设置和会话。"),
            ("Desktop 缓存", "Library/Caches/com.anthropic.claudefordesktop", "未确认缓存与登录身份的关系，保留。"),
            ("Desktop HTTP 存储", "Library/HTTPStorages/com.anthropic.claudefordesktop", "可能混合登录与其他状态，保留；使用应用内退出。"),
            ("Claude 日志", "Library/Logs/Claude", "日志不属于本次登录重置的删除范围。"),
            ("第三方推理日志", "Library/Logs/Claude-3p", "日志不属于本次登录重置的删除范围。")
        ]
        var result = candidates.map { title, path, guidance in
            let url = home.appendingPathComponent(path)
            var info = stat()
            let status: ExternalClaudeLocation.Status
            if lstat(url.path, &info) == 0 {
                status = (info.st_mode & S_IFMT) == S_IFLNK ? .link : .present
            } else { status = errno == ENOENT ? .absent : .unavailable }
            return ExternalClaudeLocation(id: path, title: title, pathLabel: "~/" + path, status: status,
                                         guidance: guidance, revealURL: status == .present ? url : nil)
        }
        result.append(.init(id: "keychain", title: "系统钥匙串", pathLabel: "未自动访问", status: .manual,
                            guidance: "通过对应 Claude 客户端正常退出。此功能不会查询、读取或删除钥匙串条目。", revealURL: nil))
        result.append(.init(id: "browser", title: "浏览器登录 / 自定义 CLI 目录", pathLabel: "未自动扫描", status: .manual,
                            guidance: "请在浏览器中退出 Claude；设置了 CLAUDE_CONFIG_DIR 的外部 CLI，请在该 CLI 内退出。", revealURL: nil))
        return result
    }
}

@MainActor
final class ClaudeLoginResetModel: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var progress = ""
    @Published private(set) var result: String?
    @Published private(set) var error: String?
    @Published private(set) var runtimeSummary = "尚未检查"
    @Published private(set) var externalLocations: [ExternalClaudeLocation] = []
    @Published var inspectExternal = false {
        didSet { if !inspectExternal { externalLocations = [] } }
    }
    private let chat: ConversationViewModel
    private let execution: ExecutionViewModel
    private let translation: TranslationViewModel
    private let runtime: OwnedRuntimeCleanupService
    private let externalScanner: ExternalClaudeLocationScanner
    private let timeoutSeconds: Double

    init(chat: ConversationViewModel, execution: ExecutionViewModel, translation: TranslationViewModel,
         runtime: OwnedRuntimeCleanupService = .init(), externalScanner: ExternalClaudeLocationScanner = .init(),
         timeoutSeconds: Double = 8) {
        self.chat = chat; self.execution = execution; self.translation = translation
        self.runtime = runtime; self.externalScanner = externalScanner; self.timeoutSeconds = timeoutSeconds
    }

    func prepare() {
        guard !isBusy else { return }
        result = nil; error = nil; progress = ""; inspectExternal = false; externalLocations = []
        do {
            let snapshot = try runtime.scan()
            runtimeSummary = "可清理 \(snapshot.eligibleCount) 项；需手动检查 \(snapshot.manualCount) 项。" +
                (snapshot.hasBlockingRuns ? "检测到仍在运行或退出状态不明的任务，执行时会再次检查。" : "")
        } catch { runtimeSummary = "暂时无法检查运行目录；重置前会重新检查，失败时保留 Token。" }
    }

    func scanExternal() {
        guard inspectExternal, !isBusy else { return }
        externalLocations = externalScanner.scan()
    }

    func reset() async {
        guard !isBusy, !OwnedProcessRegistry.shared.isTerminationInProgress else { return }
        isBusy = true; result = nil; error = nil
        var credentialStageStarted = false
        var credentialVerified = false
        OwnedProcessRegistry.shared.beginLoginReset()
        chat.beginLoginReset(); execution.beginLoginReset(); translation.beginLoginReset()
        defer {
            chat.endLoginReset(); execution.endLoginReset(); translation.endLoginReset()
            OwnedProcessRegistry.shared.endLoginReset(); isBusy = false
        }
        do {
            progress = "正在停止聊天、翻译和连接测试…"
            try await chat.drainForLoginReset(timeoutSeconds: timeoutSeconds)
            try await execution.drainForLoginReset(timeoutSeconds: timeoutSeconds)
            try await translation.drainForLoginReset(timeoutSeconds: timeoutSeconds)
            try await OwnedProcessRegistry.shared.drainForLoginReset(timeoutSeconds: timeoutSeconds)
            progress = "正在核对运行目录与进程状态…"
            let snapshot = try runtime.scan()
            guard !snapshot.hasBlockingRuns else { throw LoginResetLifecycleFailure.workStillRunning }
            guard !snapshot.items.contains(where: { $0.status == .failed }) else { throw OwnedRuntimeCleanupFailure.scanUnavailable }
            progress = "正在清除并验证当前账号的订阅授权…"
            credentialStageStarted = true
            try execution.clearSubscriptionForLoginReset()
            credentialVerified = true
            try chat.completeLoginReset()
            progress = "正在清理已确认归属的运行残留…"
            let cleaned = runtime.cleanup(snapshot)
            runtimeSummary = "已删除 \(cleaned.deletedCount) 项；保留待检查 \(cleaned.manualCount) 项；失败或变化 \(cleaned.failedCount) 项。"
            if cleaned.failedCount > 0 || cleaned.hasBlockingRuns {
                result = "当前账号授权已清除并验证，已打开空白会话，其他账号已保留。部分运行残留未清理，请重新检查。"
            } else {
                result = "当前账号授权已清除并验证，已打开空白会话，其他账号已保留。" +
                    (cleaned.manualCount > 0 ? "无法确认归属的残留已保留。" : "已确认归属的运行残留已处理。")
            }
            progress = "完成"
        } catch {
            let prefix = credentialVerified ? "Token 已清除，但后续步骤未完成。" :
                (credentialStageStarted ? "Token 删除或读回验证未完成，请检查后重试。" : "尚未删除 Token。")
            let detail: String
            switch error {
            case let failure as LoginResetLifecycleFailure: detail = failure.localizedDescription
            case let failure as OwnedRuntimeCleanupFailure: detail = failure.localizedDescription
            default: detail = "无法完成本地状态操作；请检查 App 数据目录权限后重试。"
            }
            self.error = prefix + detail
            progress = "未完成"
        }
    }
}
