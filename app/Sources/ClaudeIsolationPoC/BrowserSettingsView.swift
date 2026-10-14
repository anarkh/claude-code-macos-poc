import SwiftUI

struct BrowserSettingsView: View {
    @ObservedObject var browser: BrowserVMController
    @State private var confirmingClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("浏览器").font(.system(size: 21, weight: .semibold))
                Text("独立 Firefox 与持久浏览器资料。")
                    .font(.system(size: 13)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("浏览器 HTTP 代理").font(.system(size: 12, weight: .medium))
                TextField("http://127.0.0.1:17897", text: $browser.proxyDraft)
                    .textFieldStyle(.roundedBorder).disabled(!browser.canConfigure)
                    .accessibilityIdentifier("browser-proxy-url")
                Button("保存浏览器设置", action: browser.saveSettings).disabled(!browser.canConfigure)
                    .accessibilityIdentifier("browser-save-settings")
                Text(browser.settingsStatus).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                Text("仅支持本机 127.0.0.1 的 HTTP 代理。默认端口 17897 对应本机配置的专用日本出口；实际地区取决于代理配置。浏览器无法连通代理时，网页请求会失败。")
                    .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            Divider()
            Toggle("完整 Resist Fingerprinting", isOn: $browser.resistFingerprintingDraft)
                .disabled(!browser.canConfigure).accessibilityIdentifier("browser-resist-fingerprinting")
            Text("开启后网站看到 UTC+0（Atlantic/Reykjavik）与英语 en-US，部分网站或登录流程可能受影响；guest 界面仍为日语。修改后点击保存，并在下次启动生效。")
                .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            VStack(alignment: .leading, spacing: 9) {
                Text("浏览环境").font(.system(size: 13, weight: .medium))
                Text("Firefox \(browser.firefoxVersion) · 日语 ja · Asia/Tokyo · 1280 × 800")
                Text(browser.resistFingerprinting ? "已保存完整 Resist Fingerprinting：网站时区 UTC+0、语言 en-US。" : "已保存常规指纹保护：网站语言 ja、时区 Asia/Tokyo。")
                Text("网站仍可识别代理出口、浏览器特征、屏幕大小及你的登录身份。")
            }.font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("浏览器资料").font(.system(size: 13, weight: .medium))
                Text("登录、Cookie 和书签保存在 App 专用浏览器资料盘。停止和退出时正常关机并保留资料；返回会话后浏览器继续运行。")
                Text("点击“从 Mac 粘贴文本”或在 Firefox 中按 ⌘V 时，仅传入当次纯文本（最多 64 KiB）。平时不读取或同步 Mac 剪贴板，也不把浏览器剪贴板传回 Mac。")
                Text("上传、下载暂留 guest 内；宿主文件、音频和摄像头未开放。App 不读取网页内容；主动粘贴的文本经内存临时传送。")
                Button("清除浏览器资料…", role: .destructive) { confirmingClear = true }
                    .disabled(!browser.canConfigure).accessibilityIdentifier("browser-clear-profile")
                if !browser.canConfigure { Text("请先停止浏览器，再修改代理或清除资料。") }
            }.font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            if let error = browser.error { WorkbenchErrorLine(text: error) }
        }.fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("browser-settings")
            .alert("清除浏览器资料？", isPresented: $confirmingClear) {
                Button("取消", role: .cancel) {}
                Button("清除资料", role: .destructive, action: browser.clearProfile)
            } message: {
                Text("此操作会删除 Firefox 登录状态、Cookie、书签与 guest 下载文件，并退出所有网页登录。下次启动使用新的资料盘。")
            }
    }
}
