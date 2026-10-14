import Foundation

/// Shared messages for the execution, translation and connection-test bridges.
/// Only finite transport codes reach the UI; diagnostics and credentials do not.
func appNetworkFailureMessage(_ code: String) -> String? {
    switch code {
    case "NETWORK_POLICY_REQUIRED", "NETWORK_POLICY_INVALID", "NETWORK_POLICY_SAVE_FAILED":
        return "网络配置无效，请在设置的“网络”中保存 HTTP 代理地址。"
    case "PROXY_CONNECT_FAILED":
        return "无法连接本机代理，请启动 Clash Verge 并检查代理端口；本次请求未回退直连。"
    case "PROXY_CONNECT_REJECTED":
        return "本机代理拒绝了连接，请检查 Clash 规则和节点；本次请求未回退直连。"
    case "PROXY_TIMEOUT":
        return "代理连接或响应超时，请检查 Clash 节点后重试；本次请求未回退直连。"
    case "PROXY_TLS_FAILED":
        return "代理隧道中的 TLS 证书验证失败，已停止请求；请检查节点或证书配置。"
    case "NETWORK_CANCELLED":
        return "已停止本次网络请求。"
    case "PROXY_REQUEST_FAILED":
        return "代理连接中断，请检查节点后重试；本次请求未回退直连。"
    case "PROXY_RESPONSE_TOO_LARGE":
        return "代理返回的模型响应超过限制，已停止处理。"
    case "NETWORK_REQUEST_INVALID", "NETWORK_TEST_DEPENDENCIES_INVALID":
        return "网络请求格式无效，请检查 App 安装文件后重试。"
    default:
        return nil
    }
}
