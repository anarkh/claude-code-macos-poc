import Foundation

/// Metadata and stdio fixtures only; these checks never start an official runtime
/// or use a runtime store, network connection, or credential provider.
enum OfficialRuntimeUpdateChecks {
    static func run() throws -> [String: Bool] {
        var results: [String: Bool] = [:]
        func check(_ name: String, _ condition: Bool) { results["official_runtime_update_" + name] = condition }
        func reject(_ name: String, expected: OfficialRuntimeUpdateFailure = .invalidResponse,
                    _ operation: () throws -> Void) {
            do { try operation(); check(name, false) }
            catch let failure as OfficialRuntimeUpdateFailure { check(name, failure == expected) }
            catch { check(name, false) }
        }
        func encode(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        func metadata(sdk: String = "0.3.295", cli: String = "2.1.295", node: String = "20.0.0") -> [String: Any] {
            let integrity = "sha512-" + Data(repeating: 0x4a, count: 64).base64EncodedString()
            return [
                "schema": "official-paired-release/v1", "sdkVersion": sdk, "cliVersion": cli,
                "nodeMinimum": node, "officialStableCLI": cli, "stableChannelStatus": "verified",
                "signingKeyFingerprint": "31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE",
                "metadataSHA256": ["sdk": String(repeating: "a", count: 64),
                                   "nativeCLI": String(repeating: "b", count: 64),
                                   "manifest": String(repeating: "c", count: 64)],
                "artifacts": [
                    "sdk": ["name": "@anthropic-ai/claude-agent-sdk", "version": sdk,
                            "integrity": integrity, "unpackedSize": 1024],
                    "nativeCLI": ["name": "@anthropic-ai/claude-agent-sdk-linux-arm64", "version": sdk,
                                  "integrity": integrity, "unpackedSize": 2048],
                    "cli": ["platform": "linux-arm64", "size": 4096, "sha256": String(repeating: "d", count: 64)]
                ]
            ]
        }
        func modifiedMetadata(_ mutation: (inout [String: Any]) -> Void) throws -> Data {
            var value = metadata(); mutation(&value); return try encode(value)
        }
        func modifiedArtifact(_ kind: String, _ mutation: (inout [String: Any]) -> Void) throws -> Data {
            var value = metadata()
            var artifacts = value["artifacts"] as! [String: Any]
            var artifact = artifacts[kind] as! [String: Any]
            mutation(&artifact); artifacts[kind] = artifact; value["artifacts"] = artifacts
            return try encode(value)
        }
        func checked(_ release: [String: Any], available: Any) throws -> Data {
            try encode(["type": "checked", "release": release, "updateAvailable": available])
        }
        let current = RuntimePackageInfo(id: "bundled", version: "1.0.0", cliVersion: "2.1.295",
                                         sdkVersion: "0.3.295", nodeVersion: "26.7.0")
        let validMetadata = try encode(metadata())
        let release = try OfficialRuntimeWire.release(validMetadata)
        check("release_accepts_official_pair", release.sdkVersion == current.sdkVersion &&
              release.cliVersion == current.cliVersion && release.nodeMinimum == "20.0.0")
        check("release_canonical_metadata_roundtrip", try OfficialRuntimeWire.release(release.metadataBytes).metadataBytes == release.metadataBytes)
        var stableUnavailable = metadata()
        stableUnavailable["stableChannelStatus"] = "unavailable"; stableUnavailable["officialStableCLI"] = NSNull()
        check("release_accepts_explicit_unavailable_stable_channel", try OfficialRuntimeWire.release(encode(stableUnavailable)).cliVersion == current.cliVersion)
        check("release_stable_cli_is_informational", try OfficialRuntimeWire.release(modifiedMetadata { $0["officialStableCLI"] = "2.1.296" }).cliVersion == current.cliVersion)

        for (name, data) in [
            ("empty", Data()), ("malformed", Data("{\"schema\":".utf8)),
            ("array", Data("[]".utf8)), ("scalar", Data("true".utf8)),
            ("trailing_json", validMetadata + Data(" {}".utf8)),
            ("invalid_utf8", Data([0xff, 0xfe, 0xfd])),
            ("oversized", Data(repeating: 32, count: OfficialRuntimeWire.maximumMetadataBytes + 1))
        ] {
            reject("release_rejects_" + name) { _ = try OfficialRuntimeWire.release(data) }
        }
        for (name, field, value) in [
            ("schema", "schema", "official-paired-release/v2"),
            ("sdk_version", "sdkVersion", "0.3.295-beta"),
            ("cli_version", "cliVersion", "2.1"),
            ("node_version", "nodeMinimum", "26.7.0;run"),
            ("signer", "signingKeyFingerprint", String(repeating: "A", count: 40)),
            ("stable_status", "stableChannelStatus", "unknown"),
            ("stable_version", "officialStableCLI", "2.1.296-beta")
        ] {
            reject("release_rejects_" + name) {
                _ = try OfficialRuntimeWire.release(modifiedMetadata { $0[field] = value })
            }
        }
        reject("release_rejects_unknown_top_level_key") {
            _ = try OfficialRuntimeWire.release(modifiedMetadata { $0["downloadURL"] = "https://fixture.invalid/package" })
        }
        reject("release_rejects_missing_top_level_key") {
            _ = try OfficialRuntimeWire.release(modifiedMetadata { $0.removeValue(forKey: "metadataSHA256") })
        }
        reject("release_rejects_nonstring_version") {
            _ = try OfficialRuntimeWire.release(modifiedMetadata { $0["sdkVersion"] = 295 })
        }
        reject("release_rejects_unavailable_stable_value") {
            _ = try OfficialRuntimeWire.release(modifiedMetadata { $0["stableChannelStatus"] = "unavailable" })
        }
        reject("release_rejects_verified_stable_null") {
            _ = try OfficialRuntimeWire.release(modifiedMetadata { $0["officialStableCLI"] = NSNull() })
        }
        for (name, digests) in [
            ("missing_digest", ["sdk": String(repeating: "a", count: 64), "manifest": String(repeating: "b", count: 64)]),
            ("extra_digest", ["sdk": String(repeating: "a", count: 64), "nativeCLI": String(repeating: "b", count: 64),
                              "manifest": String(repeating: "c", count: 64), "extra": String(repeating: "d", count: 64)]),
            ("invalid_digest", ["sdk": "not-a-digest", "nativeCLI": String(repeating: "b", count: 64), "manifest": String(repeating: "c", count: 64)])
        ] {
            reject("release_rejects_" + name) { _ = try OfficialRuntimeWire.release(modifiedMetadata { $0["metadataSHA256"] = digests }) }
        }
        reject("release_rejects_unknown_artifact_kind") {
            _ = try OfficialRuntimeWire.release(modifiedMetadata {
                var artifacts = $0["artifacts"] as! [String: Any]; artifacts["extension"] = [:]; $0["artifacts"] = artifacts
            })
        }
        for kind in ["sdk", "nativeCLI"] {
            for (name, field, value) in [
                ("wrong_name", "name", "fixture-other-package"), ("wrong_version", "version", "0.3.296"),
                ("wrong_integrity_algorithm", "integrity", "sha256-" + Data(repeating: 0, count: 32).base64EncodedString()),
                ("invalid_integrity_base64", "integrity", "sha512-%%"),
                ("short_integrity", "integrity", "sha512-" + Data(repeating: 0, count: 63).base64EncodedString())
            ] {
                reject("release_rejects_" + kind + "_" + name) {
                    _ = try OfficialRuntimeWire.release(modifiedArtifact(kind) { $0[field] = value })
                }
            }
            reject("release_rejects_" + kind + "_unknown_field") {
                _ = try OfficialRuntimeWire.release(modifiedArtifact(kind) { $0["url"] = "https://fixture.invalid/" })
            }
            for (name, size) in [("zero", 0 as Any), ("negative", -1 as Any), ("fractional", 1.5 as Any),
                                 ("boolean", true as Any), ("string", "1024" as Any),
                                 ("oversized", (320 * 1024 * 1024 + 1) as Any)] {
                reject("release_rejects_" + kind + "_" + name + "_size") {
                    _ = try OfficialRuntimeWire.release(modifiedArtifact(kind) { $0["unpackedSize"] = size })
                }
            }
        }
        reject("release_rejects_combined_unpacked_size_over_limit") {
            _ = try OfficialRuntimeWire.release(modifiedMetadata {
                var artifacts = $0["artifacts"] as! [String: Any]
                for kind in ["sdk", "nativeCLI"] {
                    var artifact = artifacts[kind] as! [String: Any]; artifact["unpackedSize"] = 160 * 1024 * 1024 + 1
                    artifacts[kind] = artifact
                }
                $0["artifacts"] = artifacts
            })
        }
        for (name, field, value) in [("platform", "platform", "darwin-arm64"), ("digest", "sha256", "not-a-digest")] {
            reject("release_rejects_cli_" + name) { _ = try OfficialRuntimeWire.release(modifiedArtifact("cli") { $0[field] = value }) }
        }
        for (name, size) in [("boolean", true as Any), ("fractional", 1.5 as Any), ("zero", 0 as Any),
                             ("oversized", (320 * 1024 * 1024 + 1) as Any)] {
            reject("release_rejects_cli_" + name + "_size") {
                _ = try OfficialRuntimeWire.release(modifiedArtifact("cli") { $0["size"] = size })
            }
        }

        check("check_same_pair_is_current", try OfficialRuntimeWire.checked(checked(metadata(), available: false), current: current) == nil)
        check("check_older_pair_is_current", try OfficialRuntimeWire.checked(checked(metadata(sdk: "0.3.294", cli: "2.1.294"), available: false), current: current) == nil)
        for (name, candidate) in [("both", metadata(sdk: "0.3.296", cli: "2.1.296")),
                                  ("sdk_only", metadata(sdk: "0.3.296")), ("cli_only", metadata(cli: "2.1.296"))] {
            check("check_offers_" + name + "_upgrade", try OfficialRuntimeWire.checked(checked(candidate, available: true), current: current) != nil)
        }
        for (name, candidate, available) in [("same_pair", metadata(), true),
                                             ("newer_pair", metadata(sdk: "0.3.296", cli: "2.1.296"), false),
                                             ("older_pair", metadata(sdk: "0.3.294", cli: "2.1.294"), true)] {
            reject("check_rejects_false_availability_" + name) {
                _ = try OfficialRuntimeWire.checked(checked(candidate, available: available), current: current)
            }
        }
        for (name, candidate) in [("sdk_downgrade", metadata(sdk: "0.3.294", cli: "2.1.296")),
                                  ("cli_downgrade", metadata(sdk: "0.3.296", cli: "2.1.294")),
                                  ("node_requirement", metadata(sdk: "0.3.296", cli: "2.1.296", node: "26.7.1"))] {
            reject("check_rejects_" + name, expected: .incompatible) {
                _ = try OfficialRuntimeWire.checked(checked(candidate, available: true), current: current)
            }
        }
        check("check_accepts_exact_node_requirement", try OfficialRuntimeWire.checked(checked(metadata(sdk: "0.3.296", node: "26.7.0"), available: true), current: current) != nil)
        reject("check_rejects_numeric_boolean") {
            _ = try OfficialRuntimeWire.checked(checked(metadata(), available: 0), current: current)
        }
        reject("check_rejects_invalid_current_version") {
            let invalid = RuntimePackageInfo(id: "fixture", version: "1.0.0", cliVersion: "invalid", sdkVersion: current.sdkVersion, nodeVersion: current.nodeVersion)
            _ = try OfficialRuntimeWire.checked(checked(metadata(), available: false), current: invalid)
        }

        let integrity = "sha512-" + Data(repeating: 0x4a, count: 64).base64EncodedString()
        let receipt: [String: Any] = [
            "schema": "official-runtime-receipt/v1", "sdkVersion": release.sdkVersion,
            "cliVersion": release.cliVersion, "nodeMinimum": release.nodeMinimum,
            "sdkArchiveSHA256": String(repeating: "e", count: 64), "nativeArchiveSHA256": String(repeating: "f", count: 64),
            "cliSHA256": String(repeating: "d", count: 64), "cliManifestSHA256": String(repeating: "c", count: 64),
            "cliSigningKeySHA256": "bd70a5e4a268002704024ceba7f8446024114e94f3f0bdd11c23a9e592be81c6",
            "cliSigningKeyFingerprint": "31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE",
            "sdkMetadataSHA256": String(repeating: "a", count: 64), "nativeMetadataSHA256": String(repeating: "b", count: 64),
            "sdkIntegrity": integrity, "nativeIntegrity": integrity, "cliBytes": 4096,
            "sdkArchiveBytes": 512, "nativeArchiveBytes": 1024,
            "installationScriptsExecuted": false, "cliExecuted": false, "binaryMatchesSignedManifest": true,
            "provenance": "official-npm-and-anthropic-signature"
        ]
        func modifiedReceipt(_ mutation: (inout [String: Any]) -> Void) throws -> Data {
            var value = receipt; mutation(&value); return try encode(["type": "downloaded", "receipt": value])
        }
        let receiptBytes = try OfficialRuntimeWire.receipt(modifiedReceipt { _ in }, release: release)
        check("receipt_accepts_verified_download", try OfficialRuntimeWire.object(receiptBytes)["schema"] as? String == "official-runtime-receipt/v1")
        reject("receipt_rejects_unknown_field") {
            _ = try OfficialRuntimeWire.receipt(modifiedReceipt { $0["url"] = "https://fixture.invalid/archive" }, release: release)
        }
        reject("receipt_rejects_missing_field") {
            _ = try OfficialRuntimeWire.receipt(modifiedReceipt { $0.removeValue(forKey: "provenance") }, release: release)
        }
        for (name, field, value) in [
            ("sdk_pair", "sdkVersion", "0.3.296"), ("cli_pair", "cliVersion", "2.1.296"),
            ("node_requirement", "nodeMinimum", "26.7.0"),
            ("cli_digest", "cliSHA256", String(repeating: "a", count: 64)),
            ("manifest_digest", "cliManifestSHA256", String(repeating: "d", count: 64)),
            ("signing_key_digest", "cliSigningKeySHA256", String(repeating: "a", count: 64)),
            ("signing_key_fingerprint", "cliSigningKeyFingerprint", String(repeating: "A", count: 40)),
            ("sdk_metadata_digest", "sdkMetadataSHA256", String(repeating: "c", count: 64)),
            ("native_metadata_digest", "nativeMetadataSHA256", String(repeating: "c", count: 64)),
            ("sdk_integrity", "sdkIntegrity", "sha512-" + Data(repeating: 1, count: 64).base64EncodedString()),
            ("native_integrity", "nativeIntegrity", "sha512-" + Data(repeating: 1, count: 64).base64EncodedString()),
            ("provenance", "provenance", "fixture-unverified-source")
        ] {
            reject("receipt_rejects_" + name, expected: .integrityFailed) {
                _ = try OfficialRuntimeWire.receipt(modifiedReceipt { $0[field] = value }, release: release)
            }
        }
        for (name, field, value) in [("scripts_executed", "installationScriptsExecuted", true),
                                      ("cli_executed", "cliExecuted", true),
                                      ("unsigned_binary", "binaryMatchesSignedManifest", false)] {
            reject("receipt_rejects_" + name, expected: .integrityFailed) {
                _ = try OfficialRuntimeWire.receipt(modifiedReceipt { $0[field] = value }, release: release)
            }
        }
        reject("receipt_rejects_numeric_boolean") {
            _ = try OfficialRuntimeWire.receipt(modifiedReceipt { $0["installationScriptsExecuted"] = 0 }, release: release)
        }
        reject("receipt_rejects_cli_size_mismatch", expected: .integrityFailed) {
            _ = try OfficialRuntimeWire.receipt(modifiedReceipt { $0["cliBytes"] = 4095 }, release: release)
        }
        for key in ["sdkArchiveSHA256", "nativeArchiveSHA256"] {
            reject("receipt_rejects_invalid_" + key) {
                _ = try OfficialRuntimeWire.receipt(modifiedReceipt { $0[key] = "not-a-digest" }, release: release)
            }
        }
        for key in ["sdkArchiveBytes", "nativeArchiveBytes"] {
            reject("receipt_rejects_boolean_" + key) {
                _ = try OfficialRuntimeWire.receipt(modifiedReceipt { $0[key] = true }, release: release)
            }
            reject("receipt_rejects_oversized_" + key) {
                _ = try OfficialRuntimeWire.receipt(modifiedReceipt { $0[key] = 160 * 1024 * 1024 + 1 }, release: release)
            }
        }

        let checkLine = try checked(metadata(), available: false)
        let downloadLine = try encode(["type": "downloaded", "receipt": [:]])
        let buildLine = try encode(["type": "built", "result": [:]])
        let healthLine = try encode(["type": "healthy"])
        for (name, operation, line) in [("check", OfficialRuntimeOperation.check, checkLine),
                                        ("download", .download, downloadLine), ("build", .build, buildLine), ("health", .health, healthLine)] {
            var parser = OfficialRuntimeResponseParser(operation: operation)
            check("parser_accepts_" + name + "_terminal", try parser.consume(line) == nil && parser.finish(processSucceeded: true) == line)
            reject("parser_rejects_duplicate_" + name + "_terminal") { _ = try parser.consume(line) }
            reject("parser_" + name + "_terminal_requires_process_success", expected: operation.unsuccessful) {
                _ = try parser.finish(processSucceeded: false)
            }
        }
        for (name, operation, line) in [("check_download", OfficialRuntimeOperation.check, downloadLine),
                                        ("download_build", .download, buildLine), ("build_health", .build, healthLine), ("health_check", .health, checkLine)] {
            reject("parser_rejects_wrong_terminal_" + name) {
                var parser = OfficialRuntimeResponseParser(operation: operation); _ = try parser.consume(line)
            }
        }
        reject("parser_missing_terminal_rejected") {
            _ = try OfficialRuntimeResponseParser(operation: .check).finish(processSucceeded: true)
        }
        reject("parser_unknown_event_rejected") {
            var parser = OfficialRuntimeResponseParser(operation: .check); _ = try parser.consume(encode(["type": "trace"]))
        }
        reject("parser_unknown_terminal_field_rejected") {
            var parser = OfficialRuntimeResponseParser(operation: .health); _ = try parser.consume(encode(["type": "healthy", "debug": true]))
        }
        reject("parser_invalid_receipt_type_rejected") {
            var parser = OfficialRuntimeResponseParser(operation: .download); _ = try parser.consume(encode(["type": "downloaded", "receipt": []]))
        }
        reject("parser_line_size_bounded") {
            var parser = OfficialRuntimeResponseParser(operation: .health)
            _ = try parser.consume(Data(repeating: 32, count: OfficialRuntimeOperation.health.maximumLineBytes + 1))
        }

        func progress(_ fraction: Any, phase: String = "download") throws -> Data {
            try encode(["type": "progress", "fraction": fraction, "phase": phase])
        }
        var downloadParser = OfficialRuntimeResponseParser(operation: .download)
        let zeroProgress = try downloadParser.consume(progress(0.0, phase: "metadata"))
        let sameProgress = try downloadParser.consume(progress(0.0))
        let finalProgress = try downloadParser.consume(progress(1.0, phase: "verify"))
        check("parser_progress_accepts_bounds_and_equal_fraction", zeroProgress?.0 == 0 && sameProgress?.0 == 0 && finalProgress?.0 == 1 && finalProgress?.1 == "verify")
        reject("parser_progress_rejects_regression") { _ = try downloadParser.consume(progress(0.5)) }
        for (name, fraction) in [("boolean", true as Any), ("negative", -0.1 as Any), ("above_one", 1.1 as Any), ("string", "0.5" as Any)] {
            reject("parser_progress_rejects_" + name) {
                var parser = OfficialRuntimeResponseParser(operation: .download); _ = try parser.consume(progress(fraction))
            }
        }
        reject("parser_progress_rejects_operation_wrong_phase") {
            var parser = OfficialRuntimeResponseParser(operation: .build); _ = try parser.consume(progress(0.5))
        }
        reject("parser_progress_rejects_unknown_phase") {
            var parser = OfficialRuntimeResponseParser(operation: .download); _ = try parser.consume(progress(0.5, phase: "exec"))
        }
        reject("parser_health_rejects_progress") {
            var parser = OfficialRuntimeResponseParser(operation: .health); _ = try parser.consume(progress(0.5))
        }
        var buildParser = OfficialRuntimeResponseParser(operation: .build)
        check("parser_build_progress_accepts_prepare", try buildParser.consume(progress(0.5, phase: "prepare"))?.1 == "prepare")
        var boundedParser = OfficialRuntimeResponseParser(operation: .download)
        let unchangedProgress = try progress(0.0)
        for _ in 0..<4096 { _ = try boundedParser.consume(unchangedProgress) }
        reject("parser_progress_event_count_bounded") { _ = try boundedParser.consume(unchangedProgress) }
        _ = try downloadParser.consume(downloadLine)
        reject("parser_progress_after_terminal_rejected") { _ = try downloadParser.consume(progress(1.0)) }

        for (name, operation, code, expected) in [
            ("cancelled", OfficialRuntimeOperation.check, "OFFICIAL_CANCELLED", OfficialRuntimeUpdateFailure.cancelled),
            ("timeout", .check, "OFFICIAL_INPUT_TIMEOUT", .timeout),
            ("network", .download, "OFFICIAL_NETWORK_FAILED", .networkUnavailable),
            ("signature", .check, "OFFICIAL_SIGNATURE_INVALID", .integrityFailed),
            ("artifact", .download, "OFFICIAL_ARTIFACT_INVALID", .integrityFailed),
            ("unsupported_node", .build, "UPDATE_BUILD_NODE_UNSUPPORTED", .incompatible),
            ("build_archive", .build, "UPDATE_BUILD_ARCHIVE_INVALID", .integrityFailed),
            ("build", .build, "UPDATE_BUILD_FAILED", .buildFailed),
            ("health", .health, "UPDATE_HEALTH_FAILED", .healthFailed),
            ("http_check", .check, "OFFICIAL_HTTP_FAILED", .sourceUnavailable),
            ("http_download", .download, "OFFICIAL_HTTP_FAILED", .downloadFailed),
            ("metadata", .check, "OFFICIAL_METADATA_INVALID", .invalidResponse)
        ] {
            var parser = OfficialRuntimeResponseParser(operation: operation)
            _ = try parser.consume(encode(["type": "error", "code": code]))
            reject("parser_maps_error_" + name, expected: expected) { _ = try parser.finish(processSucceeded: false) }
            reject("parser_rejects_process_success_with_error_" + name) { _ = try parser.finish(processSucceeded: true) }
            reject("parser_rejects_terminal_after_error_" + name) { _ = try parser.consume(healthLine) }
        }
        reject("parser_rejects_unknown_error_code") {
            var parser = OfficialRuntimeResponseParser(operation: .check)
            _ = try parser.consume(encode(["type": "error", "code": "OFFICIAL_FUTURE_ERROR"]))
        }
        reject("parser_rejects_error_extra_field") {
            var parser = OfficialRuntimeResponseParser(operation: .check)
            _ = try parser.consume(encode(["type": "error", "code": "OFFICIAL_CANCELLED", "message": "fixture"]))
        }
        return results
    }
}
