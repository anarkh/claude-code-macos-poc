import Foundation

struct EvidenceStatus {
    let run: String
    let noNIC: String
    let sourceContract: String
    let gateway: String
    let relay: String
    let finalGate: String
    let details: String

    static let unavailable = EvidenceStatus(run: "未验证", noNIC: "未验证", sourceContract: "未验证", gateway: "未验证", relay: "未验证", finalGate: "完整隔离准入未完成", details: "没有可读取的本地验证证据。")

    static func load(projectRoot: String) -> EvidenceStatus {
        let directory = URL(fileURLWithPath: projectRoot).appendingPathComponent("host/evidence", isDirectory: true)
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let expression = try NSRegularExpression(pattern: "^native-([0-9]+)(?:-relay-chain)?\\.json$")
            let runs = files.compactMap { file -> String? in
                let name = file.lastPathComponent
                guard let match = expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                      let range = Range(match.range(at: 1), in: name) else { return nil }
                let digits = name[range].drop(while: { $0 == "0" })
                return digits.isEmpty ? "0" : String(digits)
            }
            guard let number = runs.max(by: { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }) else { return .unavailable }
            let run = "native-\(number)"
            let main = readJSON(directory.appendingPathComponent("\(run).json"))
            let chain = readJSON(directory.appendingPathComponent("\(run)-relay-chain.json"))
            let assessment = main?["assessment"] as? [String: Any]
            let fixture = main?["native_admission_fixture"] as? [String: Any]
            let postflight = main?["native_postflight"] as? [String: Any]
            let postfiles = postflight?["files"] as? [String: Any]
            let persisted = postfiles?["native-admission-summary.json"] as? [String: Any]
            let persistedEvidence = persisted?["evidence"] as? [String: Any]
            let copiesMatch: Bool
            if let fixture, let persistedEvidence { copiesMatch = NSDictionary(dictionary: fixture).isEqual(to: persistedEvidence) }
            else { copiesMatch = false }
            let primaryValid = main?["schema"] as? String == "claude-code-macos-poc/combined-v1" && main?["run"] as? String == run && copiesMatch
            let hostEvents = main?["host_events"] as? [[String: Any]] ?? []
            let noNICConfiguration = hostEvents.contains { $0["kind"] as? String == "vm_config_validated" && ($0["nic_count"] as? Int) == 0 && ($0["host_directory_shares"] as? Int) == 0 }
            let noNICPassed = primaryValid && noNICConfiguration && assessment?["no_nic_no_shares_boot_and_normal_shutdown"] as? String == "passed"
            let sourcePassed = primaryValid && assessment?["linux_native_source_contract"] as? String == "passed_local_fixture" && fixture?["strict_origin_status"] as? String == "passed_local_fixture"
            let gatewayDirectoryStatus = readJSON(directory.appendingPathComponent("gateway-local-03.json"))
            let gatewayPassed = gatewayDirectoryStatus?["schema"] as? String == "host-gateway-local-tests/v1" && gatewayDirectoryStatus?["status"] as? String == "passed" && gatewayDirectoryStatus?["fixture_only"] as? Bool == true
            let chainValid = chain?["schema"] as? String == "relay-chain-orchestration/v1" && chain?["run"] as? String == run
            let gateway = chain?["gateway"] as? [String: Any]
            let events = gateway?["events"] as? [[String: Any]] ?? []
            let authenticated = events.contains { $0["decision"] as? String == "client_authenticated" }
            let completed = events.contains { $0["decision"] as? String == "response_completed" }
            let relayPassed = primaryValid && chainValid && chain?["vm_exit"] as? Int == 0 && authenticated && completed && chain?["fake_only"] as? Bool == true
            let finalGate = assessment?["native_cli_apparmor_cgroup_admission"] as? String
            let executionEnabled = assessment?["project_execution_enabled"] as? Bool
            let details = primaryValid ? "同轮主证据与独立落盘副本一致。执行开关：\(executionEnabled == true ? "证据声称开启，App 仍拒绝执行" : "关闭")。\(finalGate.map { "准入记录：\($0)。" } ?? "准入记录缺失。")" : "最新轮次证据不完整；未采用旧轮次的通过项补齐。"
            return .init(run: run, noNIC: noNICPassed ? "同轮测试通过" : "未验证 / 未通过", sourceContract: sourcePassed ? "同轮测试通过" : "未验证 / 未通过", gateway: gatewayPassed ? "独立本地 mTLS 测试组通过（假 key）" : "独立本地测试未验证", relay: relayPassed ? "同轮假 API 链路通过" : chainValid ? "同轮链路未完成" : "同轮链路未验证", finalGate: "完整隔离准入未完成", details: details)
        } catch {
            return .init(run: "未验证", noNIC: "未验证", sourceContract: "未验证", gateway: "未验证", relay: "未验证", finalGate: "完整隔离准入未完成", details: "无法读取本地证据目录。")
        }
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 8_388_608 else { return nil }
            return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        } catch { return nil }
    }
}
