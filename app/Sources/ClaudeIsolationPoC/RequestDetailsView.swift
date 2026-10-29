import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

struct RequestDetailsView: View {
    let message: ConversationMessage
    let traces: [ChatRequestTrace]
    var onClearBody: (() -> Void)? = nil
    var diagnosticError: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAttemptID: String?
    @State private var showHeaders = false
    @State private var showingExport = false
    @State private var confirmingClear = false
    @State private var now = Date()
    private let expiryClock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("请求详情").font(.system(size: 18, weight: .semibold))
                    Text("Claude Code 对话").font(.system(size: 12))
                        .foregroundStyle(WorkbenchTheme.secondaryText)
                    Text("默认仅保存摘要。主动开启的正文副本保留 24 小时；已知凭据已脱敏，正文仍可能含敏感信息。")
                        .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("request-details-privacy-note")
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("request-details-close")
            }
            .padding(22)
            Divider()

            if let trace = selectedTrace {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        attemptSelector
                        requestSummary(trace)
                        headersSection(trace)
                        bodySection(trace)
                        if let diagnosticError { WorkbenchErrorLine(text: diagnosticError) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(22)
                }
                .accessibilityIdentifier("request-details-scroll")
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(30)
            }
        }
        .frame(width: 780, height: 640)
        .background(WorkbenchTheme.canvas)
        .accessibilityIdentifier("request-details-sheet")
        .onReceive(expiryClock) { now = $0 }
        .sheet(isPresented: $showingExport) {
            if let trace = selectedTrace { RequestDiagnosticExportView(trace: trace) }
        }
        .alert("清理这条消息的请求正文？", isPresented: $confirmingClear) {
            Button("取消", role: .cancel) {}
            Button("清理正文", role: .destructive) { onClearBody?() }
        } message: {
            Text("这条消息所有请求尝试的诊断正文将被删除，无法恢复。对话消息和请求摘要会保留。")
        }
    }

    private var selectedTrace: ChatRequestTrace? {
        (traces.first(where: { $0.attemptID == selectedAttemptID }) ?? traces.last)?.removingExpiredBody(now: now)
    }

    @ViewBuilder private var attemptSelector: some View {
        if traces.count > 1 {
            Picker("实际请求", selection: Binding(
                get: { selectedTrace?.attemptID ?? "" },
                set: { selectedAttemptID = $0 }
            )) {
                ForEach(traces) { trace in
                    Text("请求 \(trace.attempt)").tag(trace.attemptID)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("request-details-attempt-picker")
        }
    }

    private func requestSummary(_ trace: ChatRequestTrace) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if isWaiting(trace) { ProgressView().controlSize(.mini) }
                else {
                    Image(systemName: trace.outcome == "cancelled" ? "stop.circle" : (isFailure(trace) ? "exclamationmark.circle" : "checkmark.circle"))
                        .foregroundStyle(isFailure(trace) ? .red : WorkbenchTheme.secondaryText)
                        .accessibilityHidden(true)
                }
                Text(phaseDescription(trace)).font(.system(size: 12, weight: .medium))
                    .accessibilityIdentifier("request-details-phase")
                Spacer()
                Text("请求 \(trace.attempt) / \(traces.count)")
                    .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                summaryRow("URL", value: trace.url, identifier: "request-details-url")
                summaryRow("方法", value: trace.method, identifier: "request-details-method")
                summaryRow("模型", value: trace.wireModel, identifier: "request-details-model")
                summaryRow("来源", value: trace.provider.title, identifier: "request-details-provider")
                summaryRow("代理", value: proxyDescription(trace), identifier: "request-details-proxy")
                summaryRow("HTTP 状态", value: trace.status.map(String.init) ?? (isWaiting(trace) ? "等待响应" : "未收到 HTTP 响应"), identifier: "request-details-status")
                summaryRow("耗时", value: trace.durationMS.map { String(format: "%.1f ms", $0) } ?? (isWaiting(trace) ? "进行中" : "未记录"), identifier: "request-details-duration")
            }
            if let error = trace.errorCode {
                WorkbenchErrorLine(text: error)
                    .accessibilityIdentifier("request-details-error")
            } else if trace.phase == .request, let error = message.error {
                WorkbenchErrorLine(text: error)
                    .accessibilityIdentifier("request-details-error")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchTheme.subtleFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private func summaryRow(_ label: String, value: String, identifier: String) -> some View {
        GridRow(alignment: .top) {
            Text(verbatim: label).font(.system(size: 11, weight: .medium))
                .foregroundStyle(WorkbenchTheme.secondaryText)
            Text(verbatim: value).font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier)
        }
    }

    private func headersSection(_ trace: ChatRequestTrace) -> some View {
        DisclosureGroup(isExpanded: $showHeaders) {
            rawTextBlock(headersText(trace), identifier: "request-details-headers")
                .padding(.top, 8)
        } label: {
            Text("请求头（已脱敏）").font(.system(size: 12, weight: .semibold))
        }
        .accessibilityIdentifier("request-details-headers-disclosure")
    }

    private func bodySection(_ trace: ChatRequestTrace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("请求正文副本").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { showingExport = true } label: {
                    Label("预览并导出…", systemImage: "square.and.arrow.up").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("request-details-export")
                if trace.hasBody, onClearBody != nil {
                    Button("清理正文…", role: .destructive) { confirmingClear = true }
                        .buttonStyle(.borderless).font(.system(size: 11))
                        .accessibilityIdentifier("request-details-clear-body")
                }
            }
            HStack(spacing: 12) {
                Text("\(trace.bodyBytes) 字节")
                if trace.hasBody && trace.secretsRedacted { Text("凭据已脱敏") }
            }
            .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
            .accessibilityIdentifier("request-details-body-flags")
            Text(bodyAvailabilityDescription(trace)).font(.system(size: 11))
                .foregroundStyle(WorkbenchTheme.secondaryText)
                .accessibilityIdentifier("request-details-body-availability")
            if trace.hasBody {
                rawTextBlock(trace.body, identifier: "request-details-body", minimumHeight: 200)
            }
        }
    }

    private func bodyAvailabilityDescription(_ trace: ChatRequestTrace) -> String {
        switch trace.bodyAvailability {
        case .legacy: return "旧版本保留的正文，不会自动删除；可手动清理。"
        case .available:
            if let expiresAt = trace.expiresAt {
                return "保留至 \(expiresAt.formatted(date: .abbreviated, time: .standard))，到期后仅保留摘要。"
            }
            return "已保存正文副本。"
        case .notCaptured: return "本次仅保存摘要，未采集诊断正文。"
        case .expired: return "正文已超过 24 小时保留期限，仅保留摘要。"
        case .removed: return "正文已手动清理，仅保留摘要。"
        }
    }

    private func rawTextBlock(_ text: String, identifier: String, minimumHeight: CGFloat = 64) -> some View {
        Text(verbatim: text).font(.system(size: 12, design: .monospaced)).lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
            .padding(12)
            .background(WorkbenchTheme.codeFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkbenchTheme.border, lineWidth: 1))
            .accessibilityIdentifier(identifier)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if [.translating, .running, .streaming].contains(message.state), message.runID != nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 25))
                    .foregroundStyle(WorkbenchTheme.secondaryText)
            }
            Text(message.runID == nil ? "这条旧消息未记录请求详情" : "尚未记录实际请求")
                .font(.system(size: 14, weight: .medium))
            Text(verbatim: emptyDescription).font(.system(size: 12))
                .foregroundStyle(WorkbenchTheme.secondaryText)
                .multilineTextAlignment(.center)
            if let error = message.error { WorkbenchErrorLine(text: error) }
        }
        .accessibilityIdentifier("request-details-empty")
    }

    private var emptyDescription: String {
        guard message.runID != nil else { return "只能查看记录此功能启用后的实际请求。" }
        switch message.state {
        case .translating: return "输入翻译进行中，Claude Code 尚未发出请求。"
        case .running: return "Claude Code 正在启动，请求记录到达后将在此更新。"
        case .streaming: return "等待本次 Claude Code 对话的请求记录。"
        case .failed: return "本次执行失败，未收到实际请求记录。"
        case .cancelled: return "本次执行已停止，未收到实际请求记录。"
        case .complete: return "本次 Claude Code 对话未收到实际请求记录。"
        }
    }

    private func headersText(_ trace: ChatRequestTrace) -> String {
        trace.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private func proxyDescription(_ trace: ChatRequestTrace) -> String {
        if let url = trace.proxy.url { return "\(trace.proxy.mode) · \(url)" }
        return trace.proxy.mode == "unavailable" ? "未记录代理" : trace.proxy.mode
    }

    private func isWaiting(_ trace: ChatRequestTrace) -> Bool {
        trace.phase == .request && ![.complete, .failed, .cancelled].contains(message.state)
    }

    private func isFailure(_ trace: ChatRequestTrace) -> Bool {
        (trace.phase == .error && trace.outcome != "cancelled") || (trace.status.map { $0 >= 400 } ?? false)
            || (trace.phase == .request && message.state == .failed)
    }

    private func phaseDescription(_ trace: ChatRequestTrace) -> String {
        switch trace.phase {
        case .request:
            switch message.state {
            case .cancelled: return "已停止 · 未收到响应记录"
            case .failed: return "执行失败 · 未收到响应记录"
            case .complete: return "请求已发出 · 未收到响应记录"
            case .translating, .running, .streaming: return "请求已发出 · 等待响应"
            }
        case .response: return isFailure(trace) ? "HTTP 请求失败" : "响应已完成"
        case .error: return trace.outcome == "cancelled" ? "请求已停止" : "请求失败"
        }
    }
}

enum RequestDiagnosticExportFailure: Error {
    case unavailable, expired, saveFailed, cleanupFailed
}

/// Keep the saved diagnostic private from its initial creation, including during replacement.
func saveRequestDiagnosticPreview(_ preview: String, to destination: URL) throws {
    guard destination.isFileURL else { throw RequestDiagnosticExportFailure.saveFailed }
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".diagnostic-\(UUID().uuidString).tmp")
    let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw RequestDiagnosticExportFailure.saveFailed }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var closed = false
    do {
        try handle.write(contentsOf: Data(preview.utf8))
        try handle.synchronize()
        try handle.close()
        closed = true
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw RequestDiagnosticExportFailure.saveFailed }
        guard try String(contentsOf: destination, encoding: .utf8) == preview else { throw RequestDiagnosticExportFailure.saveFailed }
    } catch {
        var cleanupFailed = false
        if !closed {
            do { try handle.close() } catch { cleanupFailed = true }
        }
        if Darwin.unlink(temporary.path) != 0 && errno != ENOENT { cleanupFailed = true }
        throw cleanupFailed ? RequestDiagnosticExportFailure.cleanupFailed : RequestDiagnosticExportFailure.saveFailed
    }
}

/// Copy and save consume this exact preview, never a separately generated export.
@MainActor
final class RequestDiagnosticExportModel: ObservableObject {
    @Published private(set) var preview = ""
    @Published private(set) var includeBody = false
    @Published private(set) var canIncludeBody = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private var trace: ChatRequestTrace

    init(trace: ChatRequestTrace, now: Date = Date()) {
        self.trace = trace
        rebuild(includeBody: false, now: now)
    }

    func setIncludeBody(_ value: Bool, now: Date = Date()) {
        notice = nil
        rebuild(includeBody: value, now: now)
    }

    func updateTrace(_ trace: ChatRequestTrace, now: Date = Date()) {
        self.trace = trace
        rebuild(includeBody: includeBody && trace.removingExpiredBody(now: now).hasBody, now: now)
    }

    func refreshIfExpired(now: Date = Date()) {
        let available = trace.removingExpiredBody(now: now).hasBody
        canIncludeBody = available
        if includeBody && !available {
            rebuild(includeBody: false, now: now)
            notice = "正文已过期，预览已更新为摘要。"
        }
    }

    func contentForExport(now: Date = Date()) throws -> String {
        if includeBody && !trace.removingExpiredBody(now: now).hasBody {
            refreshIfExpired(now: now)
            throw RequestDiagnosticExportFailure.expired
        }
        guard error == nil, !preview.isEmpty else { throw RequestDiagnosticExportFailure.unavailable }
        return preview
    }

    private func rebuild(includeBody: Bool, now: Date) {
        let available = trace.removingExpiredBody(now: now).hasBody
        canIncludeBody = available
        self.includeBody = includeBody && available
        do {
            preview = try trace.diagnosticExport(includeBody: self.includeBody, now: now)
            error = nil
        } catch {
            preview = ""
            self.error = "诊断预览生成失败，请关闭后重试；未复制或保存任何内容。"
        }
    }
}

private struct RequestDiagnosticExportView: View {
    let trace: ChatRequestTrace
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: RequestDiagnosticExportModel
    @State private var outputStatus: String?
    @State private var outputError: String?
    private let expiryClock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(trace: ChatRequestTrace) {
        self.trace = trace
        _model = StateObject(wrappedValue: RequestDiagnosticExportModel(trace: trace))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("诊断导出预览").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("复制或保存的内容与下方预览一致。正文会去除已知凭据，仍可能包含对话、代码及其他敏感信息。")
                .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            Toggle("包含已脱敏正文", isOn: Binding(
                get: { model.includeBody }, set: { model.setIncludeBody($0); outputStatus = nil; outputError = nil }
            ))
            .disabled(!model.canIncludeBody)
            .accessibilityIdentifier("request-export-include-body")
            if !model.canIncludeBody {
                Text("正文未采集、已过期或已清理，仅可导出摘要。")
                    .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            ScrollView {
                Text(verbatim: model.preview).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                    .accessibilityIdentifier("request-export-preview")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkbenchTheme.codeFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkbenchTheme.border, lineWidth: 1))
            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            if let error = model.error ?? outputError { WorkbenchErrorLine(text: error) }
            HStack {
                if let outputStatus {
                    Text(outputStatus).font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
                        .accessibilityIdentifier("request-export-status")
                }
                Spacer()
                Button("复制预览", action: copyPreview)
                    .accessibilityIdentifier("request-export-copy")
                Button("保存预览…", action: savePreview)
                    .accessibilityIdentifier("request-export-save")
            }
            .disabled(model.error != nil || model.preview.isEmpty)
        }
        .padding(22).frame(width: 740, height: 600).background(WorkbenchTheme.canvas)
        .accessibilityIdentifier("request-export-sheet")
        .onReceive(expiryClock) { model.refreshIfExpired(now: $0) }
        .onChange(of: trace) { _, trace in model.updateTrace(trace) }
    }

    private func copyPreview() {
        do {
            let preview = try model.contentForExport()
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(preview, forType: .string) else {
                outputError = "复制失败，请重试。"; outputStatus = nil; return
            }
            outputStatus = "已复制预览内容。"; outputError = nil
        } catch {
            outputError = "预览内容已失效，请检查更新后的预览再复制。"; outputStatus = nil
        }
    }

    private func savePreview() {
        let preview: String
        do { preview = try model.contentForExport() }
        catch { outputError = "预览内容已失效，请检查更新后的预览再保存。"; outputStatus = nil; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "request-diagnostic.txt"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                guard try model.contentForExport() == preview else { throw RequestDiagnosticExportFailure.expired }
                try saveRequestDiagnosticPreview(preview, to: destination)
                outputStatus = "已保存预览内容。"; outputError = nil
            } catch is RequestDiagnosticExportFailure {
                outputError = "预览已变化或保存校验失败，请检查当前预览后重新保存。"; outputStatus = nil
            } catch {
                outputError = "未能确认诊断文件已保存，请检查目标位置后重试。"; outputStatus = nil
            }
        }
    }
}
