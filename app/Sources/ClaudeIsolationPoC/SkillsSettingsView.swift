import AppKit
import SwiftUI

struct SkillsSettingsView: View {
    @ObservedObject var model: SkillsViewModel
    @State private var selectedID: UUID?
    @State private var removalCandidate: TextSkill?

    private var selectedSkill: TextSkill? {
        model.skills.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Skills 管理").font(.system(size: 21, weight: .semibold))
                Text("只加载文本指令，脚本和工具不会执行。")
                    .font(.system(size: 13)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Button("导入 SKILL.md…", action: importSkill)
                        .accessibilityIdentifier("import-text-skill")
                    Text("导入后先预览再启用")
                        .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                }
                if let error = model.error { WorkbenchErrorLine(text: error) }
                else if let status = model.status {
                    Text(status).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.skills.isEmpty {
                emptyState
            } else {
                skillList
                if let skill = selectedSkill { preview(skill) }
            }
            Text("启用后，指令会随每次发送请求发送给执行模型。原文件变更不会自动同步；更新时先移除副本，再重新导入。")
                .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("skills-settings")
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: model.skills.map(\.id)) { selectFirstIfNeeded() }
        .alert("移除 Skill 副本？", isPresented: Binding(
            get: { removalCandidate != nil },
            set: { if !$0 { removalCandidate = nil } }
        )) {
            Button("取消", role: .cancel) { removalCandidate = nil }
            Button("移除副本", role: .destructive) {
                if let skill = removalCandidate { model.remove(skill.id) }
                removalCandidate = nil
            }
        } message: {
            Text("只移除 App 中保存的副本，不会改动原文件。")
        }
    }

    private var skillList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(model.skills) { skill in
                    HStack(spacing: 12) {
                        Button {
                            selectedID = skill.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skill.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                if !skill.summary.isEmpty {
                                    Text(skill.summary).font(.system(size: 12))
                                        .foregroundStyle(WorkbenchTheme.secondaryText).lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("skill-select-\(skill.id.uuidString)")
                        .accessibilityLabel("预览 \(skill.name)")
                        Toggle("启用", isOn: Binding(
                            get: { skill.isEnabled },
                            set: { model.setEnabled(skill.id, enabled: $0) }
                        ))
                        .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
                        .accessibilityIdentifier("skill-enabled-\(skill.id.uuidString)")
                        .accessibilityLabel("启用 \(skill.name)")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(selectedID == skill.id ? WorkbenchTheme.selection : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(4)
        }
        .frame(height: 130)
        .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(WorkbenchTheme.border, lineWidth: 1))
    }

    private func preview(_ skill: TextSkill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("原始指令 · \(skill.name)").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Button("移除副本…", role: .destructive) { removalCandidate = skill }
                    .controlSize(.small).accessibilityIdentifier("remove-text-skill")
            }
            ScrollView {
                Text(verbatim: skill.content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .accessibilityIdentifier("skill-preview")
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .background(WorkbenchTheme.editor, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(WorkbenchTheme.border, lineWidth: 1))
        }.frame(maxHeight: .infinity).layoutPriority(1)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text").font(.system(size: 25)).foregroundStyle(WorkbenchTheme.secondaryText)
            Text("尚未导入 Skills").font(.system(size: 14, weight: .medium))
            Text("选择一个 SKILL.md 文件或直接包含它的目录。\nApp 只保存文本副本，导入后默认关闭。")
                .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkbenchTheme.subtleFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private func selectFirstIfNeeded() {
        if selectedSkill == nil { selectedID = model.skills.first?.id }
    }

    private func importSkill() {
        let settingsWindow = NSApp.keyWindow
        let panel = NSOpenPanel()
        panel.title = "导入文本 Skill"
        panel.message = "选择 SKILL.md 文件或直接包含 SKILL.md 的目录；只导入文本指令。"
        panel.prompt = "导入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let delegate = TextSkillImportPanelDelegate()
        panel.delegate = delegate
        let response = withExtendedLifetime(delegate) { panel.runModal() }
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
        }
        guard response == .OK, let url = panel.url else { return }
        let previousIDs = Set(model.skills.map(\.id))
        model.importSkill(at: url)
        if let imported = model.skills.first(where: { !previousIDs.contains($0.id) }) {
            selectedID = imported.id
        } else {
            selectFirstIfNeeded()
        }
    }
}

private final class TextSkillImportPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return true
        }
        return url.lastPathComponent == "SKILL.md"
    }

}
