import Foundation

let appVMFailureCodes: Set<String> = [
    "RUNTIME_PACKAGE_INVALID",
    "VM_RUNTIME_UNAVAILABLE", "VM_RUNTIME_INVALID", "VM_START_FAILED", "VM_ISOLATION_REJECTED",
    "VM_PROTOCOL_REJECTED", "VM_REQUEST_REJECTED", "VM_CHANNEL_CLOSED", "VM_FRAME_LIMIT",
    "VM_DIAGNOSTIC_LIMIT", "VM_GUEST_FAILED", "VM_CLEANUP_FAILED", "VM_FAILED", "VM_TIMEOUT",
]

func appVMFailureMessage(_ code: String) -> String? {
    guard appVMFailureCodes.contains(code) else { return nil }
    switch code {
    case "RUNTIME_PACKAGE_INVALID":
        return "Claude Code 运行包未通过校验，请在设置的更新标签页中重新导入或回退。"
    case "VM_RUNTIME_UNAVAILABLE", "VM_RUNTIME_INVALID":
        return "隔离运行环境缺失或校验失败，请重新安装完整 App。"
    case "VM_TIMEOUT":
        return "隔离环境启动或回复超时，请稍后重试。"
    case "VM_CLEANUP_FAILED":
        return "隔离环境未确认完全退出，本次回复未记为完成。请退出 App 后重试。"
    default:
        return "隔离环境未通过运行校验，本次请求已停止。请重试或检查 App 安装。"
    }
}
