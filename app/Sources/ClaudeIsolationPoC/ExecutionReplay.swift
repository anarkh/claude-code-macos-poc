import CoreFoundation
import Darwin
import Foundation

enum ReplayEntryKind { case tool, assistant, status }
enum ReplayEntryState { case completed, failed, information }

struct ReplayEntry: Identifiable {
    let id: String
    let kind: ReplayEntryKind
    let title: String
    let subtitle: String
    let parameters: String?
    let output: String?
    let state: ReplayEntryState
    let approval: String?
}

/// A bounded, read-only projection of one persisted fixture run. It never starts a process.
struct ExecutionReplay {
    let run: String
    let isAvailable: Bool
    let notice: String
    let entries: [ReplayEntry]

    static let unavailable = ExecutionReplay(run: "未验证", isAvailable: false, notice: "没有可读取的执行记录。", entries: [])

    static func load(projectRoot: String) -> ExecutionReplay {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("host/evidence", isDirectory: true)
        guard directory.resolvingSymlinksInPath().path == directory.path else {
            return unavailableRecord(run: "未验证", reason: "证据目录路径无效。")
        }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let expression = try NSRegularExpression(pattern: "^native-([0-9]+)(?:-relay-chain)?\\.json$")
            let numbers = files.compactMap { file -> String? in
                let name = file.lastPathComponent
                guard let match = expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                      let range = Range(match.range(at: 1), in: name) else { return nil }
                let digits = name[range].drop(while: { $0 == "0" })
                return digits.isEmpty ? "0" : String(digits)
            }
            // Decimal comparison avoids overflow and never falls back from an unreadable newer run.
            guard let number = numbers.max(by: { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }) else { return .unavailable }
            let run = "native-\(number)"
            guard let main = readJSON(directory.appendingPathComponent("\(run).json")),
                  main["schema"] as? String == "claude-code-macos-poc/combined-v1",
                  main["run"] as? String == run,
                  let fixture = main["native_admission_fixture"] as? [String: Any],
                  fixture["schema"] as? String == "claude-native-admission/v1",
                  let postflight = main["native_postflight"] as? [String: Any],
                  let postfiles = postflight["files"] as? [String: Any],
                  let persisted = postfiles["native-admission-summary.json"] as? [String: Any],
                  let copy = persisted["evidence"] as? [String: Any],
                  NSDictionary(dictionary: fixture).isEqual(to: copy),
                  let runner = fixture["runner"] as? [String: Any],
                  runner["schema"] as? String == "native-sdk-runner/v1",
                  isJSONTrue(runner["simulation"]), isJSONTrue(runner["fake_key"]),
                  let events = runner["events"] as? [[String: Any]], events.count <= ReplayReader.maximumEvents else {
                return unavailableRecord(run: run, reason: "最新轮次证据未完成或格式无效；没有采用旧轮次补齐。")
            }
            return ReplayReader(run: run, runner: runner, fixture: fixture).build(events: events)
        } catch {
            return unavailableRecord(run: "未验证", reason: "无法读取本地执行记录目录。")
        }
    }

    private static func unavailableRecord(run: String, reason: String) -> ExecutionReplay {
        .init(run: run, isAvailable: false, notice: reason, entries: [])
    }

    private static func isJSONTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        // Open only the fixed basename, reject symlinks, and read a bounded amount from this FD.
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= 8_388_608 else { return nil }
        do {
            let data = try handle.read(upToCount: 8_388_609) ?? Data()
            guard data.count <= 8_388_608 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch { return nil }
    }
}

private struct ReplayReader {
    static let maximumEvents = 4_096
    static let maximumEntries = 160
    static let maximumText = 16_384

    let run: String
    let runner: [String: Any]
    let fixture: [String: Any]

    private var usesFakeService: Bool { exactBoolean(runner["simulation"]) == true }

    private struct ToolRecord {
        let index: Int
        let name: String
        var returned: Bool
    }

    func build(events: [[String: Any]]) -> ExecutionReplay {
        var entries: [ReplayEntry] = []
        var tools: [String: ToolRecord] = [:]
        var duplicateToolIDs: Set<String> = []
        var truncated = false
        let permissions = runner["permissions"] as? [[String: Any]] ?? []

        func append(_ entry: ReplayEntry) -> Int? {
            guard entries.count < Self.maximumEntries - 3 else { truncated = true; return nil }
            entries.append(entry)
            return entries.count - 1
        }

        for (eventIndex, event) in events.enumerated() {
            switch event["type"] as? String {
            case "command_lifecycle":
                if let state = event["state"] as? String, state == "queued" || state == "started" {
                    _ = append(.init(id: "\(run)-event-\(eventIndex)", kind: .status,
                                     title: state == "queued" ? "请求已入队" : "Claude Code 开始执行",
                                     subtitle: "已保存的生命周期事件", parameters: nil, output: nil,
                                     state: .information, approval: nil))
                }
            case "system":
                if event["subtype"] as? String == "init" {
                    _ = append(.init(id: "\(run)-event-\(eventIndex)", kind: .status, title: "Claude Code 已初始化",
                                     subtitle: "已保存的初始化事件", parameters: nil, output: nil, state: .information, approval: nil))
                }
            case "assistant":
                guard let message = event["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for (blockIndex, block) in content.enumerated() {
                    let entryID = "\(run)-event-\(eventIndex)-block-\(blockIndex)"
                    if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                        _ = append(.init(id: entryID, kind: .assistant, title: "Claude", subtitle: usesFakeService ? "模型回复 · 本地模拟服务" : "模型回复 · 来源未验证",
                                         parameters: nil, output: boundedText(text), state: .information, approval: nil))
                    } else if block["type"] as? String == "tool_use", let identifier = block["id"] as? String,
                              !identifier.isEmpty, identifier.count <= 256, let name = block["name"] as? String, name.count <= 128 {
                        if duplicateToolIDs.contains(identifier) { continue }
                        if let old = tools[identifier] {
                            let prior = entries[old.index]
                            entries[old.index] = .init(id: prior.id, kind: prior.kind, title: prior.title, subtitle: "工具 ID 重复，执行状态无法确认",
                                                       parameters: prior.parameters, output: prior.output, state: .information, approval: prior.approval)
                            tools[identifier] = nil
                            duplicateToolIDs.insert(identifier)
                            continue
                        }
                        let input = block["input"] as? [String: Any]
                        let known = Self.inputFields[name] != nil
                        let permission = approval(for: identifier, name: name, input: input, permissions: permissions)
                        let index = append(.init(id: entryID, kind: .tool, title: known ? toolTitle(name) : "未支持的工具",
                                                 subtitle: "未记录完整工具返回", parameters: known ? parameters(name: name, input: input) : nil,
                                                 output: nil, state: .information, approval: permission))
                        if let index { tools[identifier] = .init(index: index, name: name, returned: false) }
                    }
                }
            case "user":
                // Only tool_result blocks are projected. The original prompt and receipt are never shown.
                guard let message = event["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for block in content where block["type"] as? String == "tool_result" {
                    guard let identifier = block["tool_use_id"] as? String, var tool = tools[identifier] else { continue }
                    let old = entries[tool.index]
                    let result = toolOutput(block)
                    let known = Self.inputFields[tool.name] != nil
                    let state: ReplayEntryState = tool.returned || !known ? .information : result.state
                    let subtitle = !known ? "未支持的工具，返回内容未展开" : tool.returned ? "工具返回重复，执行状态无法确认" : result.subtitle
                    entries[tool.index] = .init(id: old.id, kind: .tool, title: old.title, subtitle: subtitle,
                                               parameters: old.parameters, output: known ? result.text : nil, state: state, approval: old.approval)
                    tool.returned = true
                    tools[identifier] = tool
                }
            default:
                // Stream deltas duplicate completed messages; unknown events are never serialized into the UI.
                continue
            }
        }

        entries.append(resultEntry())
        entries.append(stopEntry())
        if truncated {
            entries.append(.init(id: "\(run)-bounded", kind: .status, title: "显示条数已达上限",
                                 subtitle: "仅显示前 \(Self.maximumEntries - 3) 条过程记录及结束状态。", parameters: nil, output: nil,
                                 state: .information, approval: nil))
        }
        let notice = usesFakeService
            ? "本地测试回放 · 官方 CLI 的已保存事件，模型响应来自模拟服务；不是实时任务。完整隔离准入未完成。"
            : "本地执行回放 · 模型来源未验证；不是实时任务。完整隔离准入未完成。"
        return .init(run: run, isAvailable: true, notice: notice,
                     entries: entries)
    }

    private static let inputFields: [String: [String]] = [
        "Write": ["file_path", "content"], "Read": ["file_path", "offset", "limit", "pages"],
        "Edit": ["file_path", "old_string", "new_string", "replace_all"],
        "Bash": ["command", "description", "timeout", "run_in_background"]
    ]

    private func toolTitle(_ name: String) -> String {
        switch name {
        case "Write": return "Write · 写入文件"
        case "Read": return "Read · 读取文件"
        case "Edit": return "Edit · 修改文件"
        case "Bash": return "Bash · 执行命令"
        default: return "工具调用"
        }
    }

    private func parameters(name: String, input: [String: Any]?) -> String? {
        guard let input, let fields = Self.inputFields[name] else { return nil }
        let selected = fields.reduce(into: [String: Any]()) { result, key in
            if let value = input[key] { result[key] = sanitizedJSON(value, depth: 0) }
        }
        guard !selected.isEmpty, JSONSerialization.isValidJSONObject(selected),
              let data = try? JSONSerialization.data(withJSONObject: selected, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return boundedText(String(decoding: data, as: UTF8.self))
    }

    private func approval(for identifier: String, name: String, input: [String: Any]?, permissions: [[String: Any]]) -> String {
        let matches = permissions.filter { $0["tool_use_id"] as? String == identifier }
        guard matches.count == 1, let permission = matches.first,
              permission["name"] as? String == name, let recordedInput = permission["input"] as? [String: Any],
              let input, NSDictionary(dictionary: recordedInput).isEqual(to: input),
              exactBoolean(permission["fixture_only"]) == true,
              let output = permission["output"] as? [String: Any], let behavior = output["behavior"] as? String else {
            return "未记录测试许可"
        }
        if let recordedID = output["toolUseID"], recordedID as? String != identifier { return "未记录测试许可" }
        switch behavior {
        case "allow": return "测试许可：允许（非人工确认）"
        case "deny": return "测试许可：拒绝（非人工确认）"
        case "ask": return "测试许可：要求确认（未记录人工确认）"
        default: return "测试许可类型未识别"
        }
    }

    private func toolOutput(_ block: [String: Any]) -> (text: String?, state: ReplayEntryState, subtitle: String) {
        var text: String?
        var payloadKnown = false
        if let value = block["content"] as? String { text = boundedText(value); payloadKnown = true }
        else if let blocks = block["content"] as? [[String: Any]] {
            let supported = blocks.filter { $0["type"] as? String == "text" && $0["text"] is String }
            if !supported.isEmpty || blocks.isEmpty { text = boundedText(supported.compactMap { $0["text"] as? String }.joined(separator: "\n")) }
            payloadKnown = supported.count == blocks.count
        }
        if exactBoolean(block["is_error"]) == true { return (text, .failed, "工具返回错误") }
        guard payloadKnown else { return (text, .information, "工具返回缺失或包含未识别内容") }
        if block["is_error"] != nil && exactBoolean(block["is_error"]) == nil {
            return (text, .information, "工具错误标记格式无效")
        }
        // Warnings in successful Bash stdout are preserved verbatim; text is not used to guess an exit status.
        return (text, .completed, "工具返回已记录")
    }

    private func resultEntry() -> ReplayEntry {
        guard let result = runner["result"] as? [String: Any], result["type"] as? String == "result" else {
            return .init(id: "\(run)-result", kind: .status, title: "执行结果未记录", subtitle: "无法确认 SDK 是否结束。",
                         parameters: nil, output: nil, state: .information, approval: nil)
        }
        let success = result["subtype"] as? String == "success" && exactBoolean(result["is_error"]) == false
        let failed = exactBoolean(result["is_error"]) == true
        return .init(id: "\(run)-result", kind: .status, title: success ? "SDK 执行记录结束" : failed ? "SDK 返回错误" : "SDK 结束状态未确认",
                     subtitle: success ? "\(usesFakeService ? "模拟服务" : "SDK 记录")返回 success；工具错误仍按各自返回显示。" : "结束状态来自当前轮次证据。",
                     parameters: nil, output: nil, state: success ? .completed : failed ? .failed : .information, approval: nil)
    }

    private func stopEntry() -> ReplayEntry {
        guard let stop = fixture["root_stop"] as? [String: Any], let events = stop["events"] as? [String: Any],
              let elapsed = finiteNumber(stop["cgroup_kill_elapsed_ms"]), elapsed >= 0,
              let seconds = finiteNumber(stop["observation_seconds"]), seconds >= 0 else {
            return .init(id: "\(run)-stop", kind: .status, title: "独立停止未确认", subtitle: "停止证据缺失或格式无效。",
                         parameters: nil, output: nil, state: .information, approval: nil)
        }
        let complete = events["populated"] as? String == "0" && exactBoolean(stop["writes_stable_for_3_seconds"]) == true && seconds >= 3
        let detail = "记录的停止耗时：\(String(format: "%.0f", elapsed)) ms；观察窗口：\(String(format: "%.3f", seconds)) 秒。"
        return .init(id: "\(run)-stop", kind: .status, title: complete ? "独立停止已验证" : "独立停止未确认",
                     subtitle: detail, parameters: nil, output: complete ? "执行作用域已清空，观察窗口内文件保持稳定。" : nil,
                     state: complete ? .completed : .information, approval: nil)
    }

    private func exactBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private func sanitizedJSON(_ value: Any, depth: Int) -> Any {
        guard depth < 6 else { return "[嵌套内容未展开]" }
        if let text = value as? String { return boundedText(text) }
        if let dictionary = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.keys.sorted().prefix(40).map { key in
                let lower = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
                let sensitive = ["token", "sessiontoken", "clienttoken", "receipt", "receiptid", "apikey", "authorization", "secret", "credential"].contains(lower)
                return (key, sensitive ? "[已隐藏]" : sanitizedJSON(dictionary[key]!, depth: depth + 1))
            })
        }
        if let array = value as? [Any] { return array.prefix(16).map { sanitizedJSON($0, depth: depth + 1) } }
        return value
    }

    private func boundedText(_ text: String) -> String {
        let suffix = "\n[内容已截断]"
        var value = String(text.prefix(Self.maximumText))
        if value.count == Self.maximumText && text.count > Self.maximumText {
            value = String(value.prefix(Self.maximumText - suffix.count)) + suffix
        }
        let expressions = [
            #"(?i)\bBearer\s+[^\s\"']+"#,
            #"(?i)\b(?:api[_-]?key|client[_-]?token|session[_-]?token|authorization|receipt(?:[_-]?id)?)\b[\"']?\s*[:=]\s*[\"']?[^\s\"',;}]+"#
        ]
        for pattern in expressions {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            value = expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "[已隐藏凭据]")
        }
        return String(value.prefix(Self.maximumText))
    }
}
