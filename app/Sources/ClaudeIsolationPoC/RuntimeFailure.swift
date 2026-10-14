import Foundation

/// Only the fixed runtime profile errors are shared with the user interface.
func appRuntimeFailureMessage(_ code: String) -> String? {
    switch code {
    case "RUNTIME_PROFILE_REQUIRED", "RUNTIME_PROFILE_INVALID", "RUNTIME_PROFILE_SAVE_FAILED":
        return "运行环境配置无效，请在设置的“运行环境”中保存时区和进程语言。"
    default:
        return nil
    }
}
