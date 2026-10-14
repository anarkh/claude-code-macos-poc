import SwiftUI

struct RuntimeTimeZonePicker: View {
    @Binding var selection: String
    @State private var isPresented = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var options: [RuntimeTimeZoneOption] {
        RuntimeTimeZoneCatalog.filtered(query: query)
    }

    var body: some View {
        Button {
            query = ""
            isPresented = true
        } label: {
            HStack(spacing: 8) {
                Text(selection.isEmpty ? "请选择时区" : selection)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WorkbenchTheme.secondaryText)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(WorkbenchTheme.editor, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(WorkbenchTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("runtime-time-zone")
        .accessibilityLabel("进程时区")
        .accessibilityValue(selection.isEmpty ? "未选择" : selection)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(WorkbenchTheme.secondaryText)
                    TextField("搜索时区，例如东京、Tokyo 或 UTC", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityIdentifier("runtime-time-zone-search")
                        .accessibilityLabel("搜索时区")
                }
                .padding(10)
                .background(WorkbenchTheme.editor, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(WorkbenchTheme.border, lineWidth: 1))

                if options.isEmpty {
                    Text("未找到匹配时区，请换个关键词。")
                        .font(.system(size: 13))
                        .foregroundStyle(WorkbenchTheme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(options) { option in
                                Button { choose(option) } label: {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(option.id).font(.system(size: 13, weight: .medium))
                                            Text(option.label).font(.system(size: 11))
                                                .foregroundStyle(WorkbenchTheme.secondaryText)
                                        }
                                        .lineLimit(1)
                                        Spacer(minLength: 6)
                                        if selection == option.id {
                                            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                                        }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .background(selection == option.id ? WorkbenchTheme.selection : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .keyboardShortcut(options.count == 1 ? .defaultAction : nil)
                                .accessibilityLabel(option.id + "，" + option.label)
                                .accessibilityValue(selection == option.id ? "已选择" : "未选择")
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 430, height: 340)
            .background(WorkbenchTheme.canvas)
            .onAppear { searchFocused = true }
            .onExitCommand { isPresented = false }
        }
    }

    private func choose(_ option: RuntimeTimeZoneOption) {
        if selection != option.id { selection = option.id }
        isPresented = false
    }
}
