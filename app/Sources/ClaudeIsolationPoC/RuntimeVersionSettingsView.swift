import SwiftUI

struct RuntimeVersionSettingsView: View {
    @ObservedObject var model: RuntimeVersionViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("版本与更新").font(.system(size: 16, weight: .semibold))
            if let snapshot = model.snapshot {
                HStack(alignment: .top, spacing: 30) {
                    version("Claude Code", snapshot.current.cliVersion, id: "runtime-cli-version")
                    version("Agent SDK", snapshot.current.sdkVersion, id: "runtime-sdk-version")
                    version("运行包", snapshot.current.version, id: "runtime-package-version")
                }
                Text(snapshot.current.id == snapshot.bundled.id ? "正在使用 App 内置运行包" :
                    (snapshot.current.id.hasPrefix("local-") ? "正在使用由官方制品在本机生成的隔离运行包" : "正在使用已验证的导入运行包"))
                    .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                    .accessibilityIdentifier("runtime-package-origin")
                if let pending = snapshot.pending {
                    Text("待启用：\(pending.version) · Claude Code \(pending.cliVersion)")
                        .font(.system(size: 12)).accessibilityIdentifier("runtime-package-pending")
                }
                if let previous = snapshot.previous {
                    Text("可回退：\(previous.version) · Claude Code \(previous.cliVersion)")
                        .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                        .accessibilityIdentifier("runtime-package-previous")
                }
            }
            Text("更新来源：Anthropic 官方 · 配套 CLI / SDK")
                .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                .accessibilityIdentifier("official-runtime-update-source")
            HStack {
                Button("检查更新") { Task { await model.checkForUpdates() } }
                    .disabled(!model.canCheckUpdates).accessibilityIdentifier("check-runtime-update")
                Button("一键升级") { Task { await model.installUpdate() } }
                    .buttonStyle(.borderedProminent).disabled(!model.canInstallUpdate)
                    .accessibilityIdentifier("install-runtime-update")
            }
            if let release = model.availableUpdate {
                Text("可升级至 \(release.info.version) · 下载 \(ByteCountFormatter.string(fromByteCount: release.totalBytes, countStyle: .file))\nClaude Code \(release.info.cliVersion) · Agent SDK \(release.info.sdkVersion)")
                    .font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("available-runtime-update")
            }
            if let release = model.availableOfficialUpdate {
                Text("可升级：Claude Code \(release.cliVersion) · Agent SDK \(release.sdkVersion)\n下载官方制品后，在本机自动生成隔离运行包。")
                    .font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("available-official-runtime-update")
            }
            Text(model.updateStatus).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("online-update-status")
            HStack {
                Button("导入运行包…", action: model.choosePackage).disabled(!model.canImport)
                    .accessibilityIdentifier("import-runtime-package")
                Button("回退到上一版本", action: model.requestRollback).disabled(!model.canRollback)
                    .accessibilityIdentifier("rollback-runtime-package")
                if model.snapshot?.pending != nil {
                    Button("取消待启用", action: model.cancelPending).disabled(model.isBusy)
                        .accessibilityIdentifier("cancel-pending-runtime-package")
                }
            }.controlSize(.small)
            if model.isBusy {
                HStack {
                    ProgressView(value: model.progress).accessibilityIdentifier("runtime-import-progress")
                    Button(model.onlineOperation ? "取消更新" : "取消导入", action: model.cancelImport).controlSize(.small)
                        .accessibilityIdentifier("cancel-runtime-import")
                }
            }
            Text(model.status).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                .accessibilityIdentifier("runtime-package-status")
            if let error = model.error { WorkbenchErrorLine(text: error) }
            if let diagnostic = model.snapshot?.diagnostic { WorkbenchErrorLine(text: diagnostic) }
            Text("官方更新无需填写更新源。App 通过统一代理下载并验证配套 CLI / SDK，在本机离线封装，检查 DeepSeek、Sonnet、Opus、Haiku 与 VM 启动；全部通过后在当前任务结束时启用。不兼容或更新失败时继续使用当前版本，可回退到上一版本。离线导入仍校验发布者签名。")
                .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(WorkbenchTheme.border))
        .accessibilityIdentifier("runtime-version-settings")
        .onAppear { model.refresh() }
    }
    private func version(_ title: String, _ value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            Text(value).font(.system(size: 14, weight: .medium)).textSelection(.enabled).accessibilityIdentifier(id)
        }
    }
}
