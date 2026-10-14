import SwiftUI

@MainActor
final class RuntimeSettingsViewModel: ObservableObject {
    @Published var timeZone = ""
    @Published var language = ""
    @Published private(set) var status = "运行环境配置不可用"
    @Published private(set) var error: String?
    private let store: any RuntimeProfilePersisting

    init(store: any RuntimeProfilePersisting = RuntimeProfileStore()) {
        self.store = store
        do {
            let profile = try store.load()
            timeZone = profile.timeZone
            language = profile.language
            status = "每次启动 App 内进程时自动应用此配置。"
        } catch {
            self.error = (error as? RuntimeProfileFailure ?? .invalid).message
        }
    }

    func save() { persist(AppRuntimeProfile(timeZone: timeZone, language: language)) }
    func useJapanPreset() { persist(.japan) }

    func chooseTimeZone(_ identifier: String) {
        guard AppRuntimeProfile.availableTimeZones.contains(identifier) else {
            status = "选择未完成 · 请从时区列表中选择。"
            error = RuntimeProfileFailure.invalid.message
            return
        }
        timeZone = identifier
        status = "已选择 · 点击保存运行环境后生效。"
        error = nil
    }

    private func persist(_ profile: AppRuntimeProfile) {
        do {
            try profile.validate()
            try store.save(profile)
            guard try store.load() == profile else { throw RuntimeProfileFailure.persistenceFailed }
            timeZone = profile.timeZone
            language = profile.language
            status = "已保存 · 下一次请求自动使用此时区和语言。"
            error = nil
        } catch {
            status = "保存未完成 · 请检查配置后重试。"
            self.error = (error as? RuntimeProfileFailure ?? .persistenceFailed).message
        }
    }
}

struct RuntimeSettingsView: View {
    @ObservedObject var model: RuntimeSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("进程时区和语言").font(.system(size: 21, weight: .semibold))
                Text("Claude Code、翻译和连接测试启动时自动应用保存的运行环境。")
                    .font(.system(size: 13)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("时区").font(.system(size: 12, weight: .medium))
                    RuntimeTimeZonePicker(selection: Binding(get: { model.timeZone }, set: model.chooseTimeZone))
                    Text("搜索并选择时区，支持东京、Tokyo、UTC 等关键词；选择后点击保存。")
                        .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("进程语言").font(.system(size: 12, weight: .medium))
                    Picker("进程语言", selection: $model.language) {
                        if model.language.isEmpty { Text("请选择语言").tag("") }
                        Text("日语").tag("ja")
                        Text("英语").tag("en")
                        Text("中文").tag("zh")
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .accessibilityIdentifier("runtime-language").accessibilityLabel("进程语言")
                }
                HStack(spacing: 10) {
                    Button("保存运行环境", action: model.save).accessibilityIdentifier("save-runtime-profile")
                    Button("应用日本预设", action: model.useJapanPreset).accessibilityIdentifier("apply-japan-runtime-preset")
                }
                Text(model.status).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                    .accessibilityIdentifier("runtime-profile-status")
                if let error = model.error { WorkbenchErrorLine(text: error) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("日本预设：Asia/Tokyo · 日语", systemImage: "globe.asia.australia")
                Text("“应用日本预设”会直接保存。你也可以独立修改时区和语言，再点击保存运行环境。正在执行的请求使用启动时的配置。")
                Text("此设置控制 App 内进程的 TZ 和语言环境，不修改整台 Mac 的时区、系统语言或 App 的中文界面。")
                Text("输入翻译的目标语言仍在会话输入框中选择；运行环境语言不决定模型回复的语言。")
                Text("时区和语言预设不验证代理地区，也不能保证所有机器信息符合某个地区。")
            }
            .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("runtime-settings")
    }
}
