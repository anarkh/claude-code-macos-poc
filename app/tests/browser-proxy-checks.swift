import Darwin
import Foundation

@main
struct BrowserProxyChecksMain {
    private struct Check: Encodable {
        let name: String
        let passed: Bool
    }

    private struct Report: Encodable {
        let schema = "browser-proxy-checks/v1"
        let ok: Bool
        let count: Int
        let checks: [Check]
        let failures: [String]
    }

    static func main() {
        let checks = browserProxyGatewayChecks().map { Check(name: $0.0, passed: $0.1) }
        let failures = checks.isEmpty ? ["no_checks_returned"] : checks.filter { !$0.passed }.map(\.name)
        let report = Report(ok: failures.isEmpty, count: checks.count, checks: checks, failures: failures)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("FAIL browser_proxy_checks_output_failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
        exit(report.ok ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
