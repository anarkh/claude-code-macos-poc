import CryptoKit
import Darwin
import Foundation

/// Uses disposable sparse disks and synthetic profile bytes; it never launches a VM or reads real login data.
func browserRuntimeStorageChecks() async -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("browser_storage_" + name, passed)) }
    func rejects(_ expected: BrowserRuntimeStorageFailure, _ body: () throws -> Void) -> Bool {
        do { try body(); return false }
        catch let failure as BrowserRuntimeStorageFailure { return failure == expected }
        catch { return false }
    }
    func anyStorageFailure(_ body: () throws -> Void) -> Bool {
        do { try body(); return false }
        catch is BrowserRuntimeStorageFailure { return true }
        catch { return false }
    }
    let zeroDigest = String(repeating: "0", count: 64)
    let validManifest = BrowserRuntimeManifest(firefoxVersion: "157.0.1",
                                             sha256: ["kernel": zeroDigest, "initrd": zeroDigest, "guest.raw": zeroDigest], diskBytes: 65_536)
    do {
        try validManifest.validate()
        var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(validManifest)) as! [String: Any]
        fields["build_metadata"] = ["purpose": "synthetic"]
        check("required_manifest_fields_allow_metadata", try JSONDecoder().decode(BrowserRuntimeManifest.self,
              from: JSONSerialization.data(withJSONObject: fields)) == validManifest)
        for (name, key, value) in [
            ("schema", "schema", "browser-vm-base/v2"),
            ("version_controls", "firefox_version", "157.0.1\n"),
            ("version_empty", "firefox_version", "")
        ] {
            var invalid = fields; invalid[key] = value
            check("reject_" + name, rejects(.invalidManifest) {
                _ = try JSONDecoder().decode(BrowserRuntimeManifest.self, from: JSONSerialization.data(withJSONObject: invalid))
            })
        }
        var missing = fields; missing.removeValue(forKey: "disk_bytes")
        check("reject_missing_disk_size", rejects(.invalidManifest) {
            _ = try JSONDecoder().decode(BrowserRuntimeManifest.self, from: JSONSerialization.data(withJSONObject: missing))
        })
        for (name, hashes) in [
            ("missing_hash", ["kernel": zeroDigest, "initrd": zeroDigest]),
            ("extra_hash", ["kernel": zeroDigest, "initrd": zeroDigest, "guest.raw": zeroDigest, "cli.raw": zeroDigest]),
            ("uppercase_hash", ["kernel": String(repeating: "A", count: 64), "initrd": zeroDigest, "guest.raw": zeroDigest]),
            ("short_hash", ["kernel": "abc", "initrd": zeroDigest, "guest.raw": zeroDigest]),
            ("non_hex_hash", ["kernel": String(repeating: "z", count: 64), "initrd": zeroDigest, "guest.raw": zeroDigest])
        ] {
            check("reject_" + name, rejects(.invalidManifest) {
                try BrowserRuntimeManifest(firefoxVersion: "157.0.1", sha256: hashes, diskBytes: 65_536).validate()
            })
        }
        check("reject_zero_disk_size", rejects(.invalidManifest) {
            try BrowserRuntimeManifest(firefoxVersion: "157.0.1", sha256: validManifest.sha256, diskBytes: 0).validate()
        })
    } catch { check("manifest_setup", false) }

    do {
        let fixture = try BrowserStorageFixture(); defer { fixture.remove() }
        let storage = fixture.storage()
        let prepared = try storage.prepare()
        defer { do { try prepared.lease.release() } catch { check("roundtrip_deferred_release", false) } }
        check("verified_manifest_and_distinct_vm_disks", prepared.manifest == fixture.manifest &&
              prepared.diskURL != prepared.profileDiskURL && prepared.diskURL != fixture.images.appendingPathComponent("guest.raw"))
        check("profile_directory_private", fixture.mode(fixture.profile) == 0o700)
        check("persistent_profile_private_two_gib_sparse", fixture.mode(prepared.profileDiskURL) == 0o600 &&
              fixture.size(prepared.profileDiskURL) == 2_147_483_648 && fixture.allocatedSize(prepared.profileDiskURL) < 1_048_576)
        check("root_and_iso_private", fixture.mode(prepared.diskURL) == 0o600 && fixture.mode(prepared.configDiskURL) == 0o600)
        let seed = prepared.configDiskURL.deletingLastPathComponent().appendingPathComponent("seed/browser-config.json")
        let seedData = try Data(contentsOf: seed)
        let payload = try JSONSerialization.jsonObject(with: seedData) as? [String: Any]
        check("default_session_config_exact_public_fields", payload.map { Set($0.keys) == ["schema", "resist_fingerprinting", "boot_epoch_seconds"] } == true &&
              payload?["schema"] as? String == "browser-session-config/v1" && payload?["resist_fingerprinting"] as? Bool == false &&
              abs((payload?["boot_epoch_seconds"] as? Double ?? 0) - Date().timeIntervalSince1970) < 30)
        let iso = try Data(contentsOf: prepared.configDiskURL)
        check("real_iso_contains_exact_config_payload", iso.count > 32_768 && iso.range(of: seedData) != nil &&
              String(decoding: iso[32_769..<32_774], as: UTF8.self) == "CD001")
        let profileJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.profile.appendingPathComponent("profile.json"))) as? [String: Any]
        check("profile_metadata_has_no_baseline_or_login", profileJSON.map { Set($0.keys) == ["schema", "disk_bytes"] } == true &&
              profileJSON?["schema"] as? String == "browser-profile/v1")
        check("second_instance_blocked_through_running_lease", rejects(.profileBusy) { _ = try fixture.storage().prepare() })
        check("clear_blocked_through_running_lease", rejects(.profileBusy) { try fixture.storage().clearProfile() })
        let loginMarker = Data("synthetic-login-state".utf8)
        try fixture.write(loginMarker, to: prepared.profileDiskURL, offset: 1_048_576)
        try fixture.write(Data("changed-root".utf8), to: prepared.diskURL, offset: 0)
        check("cow_root_write_preserves_baseline", try BrowserBaselineFile(fixture.images.appendingPathComponent("guest.raw")).digest() == fixture.manifest.sha256["guest.raw"])
        let oldSession = prepared.diskURL.deletingLastPathComponent()
        try prepared.lease.release()
        try prepared.lease.release()
        check("release_deletes_only_session_and_is_idempotent", !FileManager.default.fileExists(atPath: oldSession.path) &&
              FileManager.default.fileExists(atPath: prepared.profileDiskURL.path))
        try fixture.replaceBaselineDisk(Data(repeating: 5, count: 65_536), firefoxVersion: "158.0.2")
        let next = try storage.prepare(resistFingerprinting: true)
        defer { do { try next.lease.release() } catch { check("next_deferred_release", false) } }
        check("baseline_update_preserves_login_profile", try fixture.read(next.profileDiskURL, offset: 1_048_576, count: loginMarker.count) == loginMarker &&
              next.manifest.firefoxVersion == "158.0.2")
        let nextPayload = try JSONSerialization.jsonObject(with: Data(contentsOf: next.configDiskURL.deletingLastPathComponent()
            .appendingPathComponent("seed/browser-config.json"))) as? [String: Any]
        check("rfp_choice_written_to_next_session", nextPayload?["resist_fingerprinting"] as? Bool == true)
        try next.lease.release()
        let unrelated = fixture.profile.appendingPathComponent("unrelated-file")
        try fixture.savePrivate(Data("preserve-me".utf8), at: unrelated)
        try storage.clearProfile()
        let unrelatedData = try Data(contentsOf: unrelated)
        check("clear_only_owned_profile_files", !FileManager.default.fileExists(atPath: fixture.profile.appendingPathComponent("profile.raw").path) &&
              !FileManager.default.fileExists(atPath: fixture.profile.appendingPathComponent("profile.json").path) &&
              unrelatedData == Data("preserve-me".utf8) &&
              FileManager.default.fileExists(atPath: fixture.profile.appendingPathComponent("profile.lock").path))
        check("clear_keeps_readonly_baseline", try BrowserBaselineFile(fixture.images.appendingPathComponent("guest.raw")).digest() == fixture.manifest.sha256["guest.raw"])
    } catch { check("profile_roundtrip_setup", false) }

    do {
        let fixture = try BrowserStorageFixture(); defer { fixture.remove() }
        let kernel = fixture.images.appendingPathComponent("kernel")
        try fixture.saveBaseline(Data("tampered-kernel".utf8), at: kernel)
        check("hash_mismatch_blocks_clone", rejects(.integrityMismatch("kernel")) { _ = try fixture.storage().prepare() })
        check("hash_failure_does_not_create_profile", !FileManager.default.fileExists(atPath: fixture.profile.appendingPathComponent("profile.raw").path))
        guard Darwin.chmod(kernel.path, 0o600) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("fixture") }
        check("writable_baseline_rejected", rejects(.unsafeBaseline) { _ = try fixture.storage().prepare() })
        try FileManager.default.removeItem(at: kernel)
        let outside = fixture.root.appendingPathComponent("outside-kernel")
        try fixture.saveBaseline(Data("outside".utf8), at: outside)
        try FileManager.default.createSymbolicLink(at: kernel, withDestinationURL: outside)
        check("symlink_baseline_rejected", rejects(.unsafeBaseline) { _ = try fixture.storage().prepare() })
        check("symlink_baseline_target_preserved", try Data(contentsOf: outside) == Data("outside".utf8))
        let imagesLink = fixture.root.appendingPathComponent("linked-resources")
        try FileManager.default.createSymbolicLink(at: imagesLink, withDestinationURL: fixture.resources)
        check("symlink_baseline_ancestor_rejected", rejects(.unsafeBaseline) {
            _ = try BrowserRuntimeStorage(bundleResourcesURL: imagesLink, profileDirectoryURL: fixture.profile).prepare()
        })
    } catch { check("baseline_boundary_setup", false) }

    do {
        let fixture = try BrowserStorageFixture(); defer { fixture.remove() }
        let file = fixture.images.appendingPathComponent("kernel")
        let opened = try BrowserBaselineFile(file)
        var mutated = false
        check("write_during_hash_detected_by_fstat_snapshot", rejects(.unsafeBaseline) {
            _ = try opened.digest {
                if !mutated {
                    mutated = true
                    try fixture.saveBaseline(Data("kernel-fixture".utf8), at: file)
                }
            }
        })
        let old = try BrowserBaselineFile(file)
        let replacement = fixture.images.appendingPathComponent("replacement")
        try fixture.saveBaseline(Data("kernel-fixture".utf8), at: replacement)
        guard Darwin.rename(replacement.path, file.path) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("fixture") }
        check("path_replacement_after_open_detected", rejects(.unsafeBaseline) { _ = try old.digest() })
    } catch { check("toctou_setup", false) }

    do {
        let fixture = try BrowserStorageFixture(); defer { fixture.remove() }
        let fakeCLIImages = fixture.root.appendingPathComponent("host/vm/images", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeCLIImages, withIntermediateDirectories: true)
        check("does_not_fall_back_to_cli_vm", rejects(.baselineMissing) {
            _ = try BrowserRuntimeStorage(bundleResourcesURL: nil, developmentProjectRoot: fixture.root.path,
                                         profileDirectoryURL: fixture.profile).prepare()
        })
        if Bundle.main.bundleURL.pathExtension != "app" {
            let devImages = fixture.root.appendingPathComponent("host/browser-runtime/images", isDirectory: true)
            try FileManager.default.createDirectory(at: devImages.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: fixture.images, to: devImages)
            let development = BrowserRuntimeStorage(bundleResourcesURL: nil, developmentProjectRoot: fixture.root.path,
                                                    profileDirectoryURL: fixture.profile)
            let prepared = try development.prepare(); try prepared.lease.release()
            check("dev_browser_fallback_is_separate_and_validated", prepared.kernelURL.deletingLastPathComponent() == devImages)
        }
    } catch { check("baseline_resolution_setup", false) }

    do {
        let fixture = try BrowserStorageFixture(); defer { fixture.remove() }
        let prepared = try fixture.storage().prepare(); try prepared.lease.release()
        let profileJSON = fixture.profile.appendingPathComponent("profile.json")
        let badJSON = Data("{\"schema\":\"browser-profile/v2\",\"disk_bytes\":2147483648}".utf8)
        try fixture.savePrivate(badJSON, at: profileJSON)
        let badProfileRejected = rejects(.incompatibleProfile) { _ = try fixture.storage().prepare() }
        let preservedJSON = try Data(contentsOf: profileJSON)
        check("incompatible_profile_is_preserved", badProfileRejected &&
              preservedJSON == badJSON && fixture.size(prepared.profileDiskURL) == 2_147_483_648)
        check("incompatible_profile_message_offers_explicit_clear", BrowserRuntimeStorageFailure.incompatibleProfile.message.contains("清除"))
        try FileManager.default.removeItem(at: profileJSON)
        check("partial_profile_not_automatically_reset", rejects(.incompatibleProfile) { _ = try fixture.storage().prepare() } &&
              FileManager.default.fileExists(atPath: prepared.profileDiskURL.path))
        try fixture.storage().clearProfile()
        let recreated = try fixture.storage().prepare(); try recreated.lease.release()
        check("explicit_clear_allows_new_profile", fixture.size(recreated.profileDiskURL) == 2_147_483_648)
        let alias = fixture.root.appendingPathComponent("profile-hardlink")
        guard Darwin.link(recreated.profileDiskURL.path, alias.path) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("fixture") }
        check("profile_hardlink_rejected", rejects(.unsafeProfile) { _ = try fixture.storage().prepare() })
        check("clear_refuses_profile_hardlink", rejects(.unsafeProfile) { try fixture.storage().clearProfile() })
        check("hardlink_data_preserved", FileManager.default.fileExists(atPath: alias.path) && FileManager.default.fileExists(atPath: recreated.profileDiskURL.path))
    } catch { check("profile_compatibility_setup", false) }

    do {
        let fixture = try BrowserStorageFixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        check("permissive_directory_rejected", rejects(.unsafeProfile) { _ = try fixture.storage().prepare() })
        check("unsafe_directory_not_implicitly_modified", fixture.mode(fixture.profile) == 0o755)
        guard Darwin.chmod(fixture.profile.path, 0o700) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("fixture") }
        let external = fixture.root.appendingPathComponent("external-private-file")
        try fixture.savePrivate(Data("preserve-outside".utf8), at: external)
        try FileManager.default.createSymbolicLink(at: fixture.profile.appendingPathComponent("profile.lock"), withDestinationURL: external)
        check("symlink_lock_rejected", rejects(.unsafeProfile) { _ = try fixture.storage().prepare() })
        try FileManager.default.removeItem(at: fixture.profile.appendingPathComponent("profile.lock"))
        try FileManager.default.createSymbolicLink(at: fixture.profile.appendingPathComponent("profile.raw"), withDestinationURL: external)
        check("clear_refuses_symlink_profile", rejects(.unsafeProfile) { try fixture.storage().clearProfile() })
        check("clear_preserves_symlink_target", try Data(contentsOf: external) == Data("preserve-outside".utf8))
    } catch { check("profile_permission_setup", false) }

    do {
        let fixture = try BrowserStorageFixture(); defer { fixture.remove() }
        let attempts = BrowserStorageCheckCounter()
        let storage = fixture.storage(cloneOperation: { _, destination, name in
            attempts.increment()
            let descriptor = Darwin.openat(destination, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw BrowserRuntimeStorageFailure.storageIO("fixture") }
            Darwin.close(descriptor)
            throw BrowserRuntimeStorageFailure.apfsCloneRequired
        })
        check("clone_failure_has_no_copy_fallback", rejects(.apfsCloneRequired) { _ = try storage.prepare() } && attempts.value == 1)
        check("failed_clone_leaves_no_session", try fixture.sessions().isEmpty)
        let recovered = try fixture.storage().prepare(); try recovered.lease.release()
        check("clone_failure_releases_lock", fixture.size(recovered.profileDiskURL) == 2_147_483_648)
    } catch { check("clone_failure_setup", false) }

    do {
        let fixture = try BrowserStorageFixture(); defer { fixture.remove() }
        let entered = DispatchSemaphore(value: 0); let resume = DispatchSemaphore(value: 0)
        let storage = fixture.storage(cloneOperation: { _, _, _ in
            entered.signal(); resume.wait()
            try Task.checkCancellation()
        })
        let task = Task.detached { try storage.prepare() }
        let started = await Task.detached { browserStorageWait(entered) }.value
        check("preparation_holds_lock_before_clone", started && rejects(.profileBusy) { try fixture.storage().clearProfile() })
        task.cancel(); resume.signal()
        do { _ = try await task.value; check("cancelled_prepare_settles", false) }
        catch is CancellationError { check("cancelled_prepare_settles", true) }
        catch { check("cancelled_prepare_settles", false) }
        check("cancelled_prepare_removes_session", try fixture.sessions().isEmpty)
        try fixture.storage().clearProfile()
        check("cancelled_prepare_releases_lock", !FileManager.default.fileExists(atPath: fixture.profile.appendingPathComponent("profile.raw").path))
    } catch { check("cancellation_setup", false) }

    do {
        let fixture = try BrowserStorageFixture(); defer { fixture.remove() }
        let prepared = try fixture.storage().prepare()
        let unknown = prepared.diskURL.deletingLastPathComponent().appendingPathComponent("unrelated-file")
        try fixture.savePrivate(Data("preserve-unknown".utf8), at: unknown)
        check("cleanup_refuses_unknown_session_files", rejects(.cleanupFailed) { try prepared.lease.release() })
        check("cleanup_failure_preserves_unknown_file", try Data(contentsOf: unknown) == Data("preserve-unknown".utf8))
        check("orphan_cleanup_fails_explicitly", anyStorageFailure { _ = try fixture.storage().prepare() })
        try fixture.storage().clearProfile()
        check("cleanup_failure_unlocks_without_deleting_unknown", FileManager.default.fileExists(atPath: unknown.path))
        try FileManager.default.removeItem(at: unknown)
        let recovered = try fixture.storage().prepare(); try recovered.lease.release()
        check("empty_orphan_session_recovered_under_lock", try fixture.sessions().isEmpty)
    } catch { check("cleanup_failure_setup", false) }

    return results
}

private final class BrowserStorageCheckCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private func browserStorageWait(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 10) == .success
}

private final class BrowserStorageFixture {
    let root: URL
    let resources: URL
    let images: URL
    let profile: URL
    private(set) var manifest: BrowserRuntimeManifest

    init() throws {
        var canonical = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(FileManager.default.temporaryDirectory.path, &canonical) != nil else {
            throw BrowserRuntimeStorageFailure.storageIO("fixture")
        }
        root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("browser-storage-check-\(UUID().uuidString)", isDirectory: true)
        resources = root.appendingPathComponent("Resources", isDirectory: true)
        images = resources.appendingPathComponent("BrowserRuntime/images", isDirectory: true)
        profile = root.appendingPathComponent("Browser", isDirectory: true)
        let contents = ["kernel": Data("kernel-fixture".utf8), "initrd": Data("initrd-fixture".utf8), "guest.raw": Data(repeating: 7, count: 65_536)]
        manifest = BrowserRuntimeManifest(firefoxVersion: "157.0.1", sha256: contents.mapValues(Self.hash), diskBytes: 65_536)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, data) in contents { try saveBaseline(data, at: images.appendingPathComponent(name)) }
        try saveBaseline(JSONEncoder().encode(manifest), at: images.appendingPathComponent("browser.json"))
    }

    func storage(cloneOperation: BrowserRuntimeStorage.CloneOperation? = nil) -> BrowserRuntimeStorage {
        BrowserRuntimeStorage(bundleResourcesURL: resources, profileDirectoryURL: profile, cloneOperation: cloneOperation)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func replaceBaselineDisk(_ data: Data, firefoxVersion: String) throws {
        try saveBaseline(data, at: images.appendingPathComponent("guest.raw"))
        var hashes = manifest.sha256; hashes["guest.raw"] = Self.hash(data)
        manifest = BrowserRuntimeManifest(firefoxVersion: firefoxVersion, sha256: hashes, diskBytes: Int64(data.count))
        try saveBaseline(JSONEncoder().encode(manifest), at: images.appendingPathComponent("browser.json"))
    }
    func saveBaseline(_ data: Data, at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard Darwin.chmod(url.path, 0o600) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("fixture") }
        }
        try data.write(to: url)
        guard Darwin.chmod(url.path, 0o400) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("fixture") }
    }
    func savePrivate(_ data: Data, at url: URL) throws {
        try data.write(to: url)
        guard Darwin.chmod(url.path, 0o600) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("fixture") }
    }
    func write(_ data: Data, to url: URL, offset: Int64) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BrowserRuntimeStorageFailure.storageIO("fixture") }
        defer { Darwin.close(descriptor) }
        let count = data.withUnsafeBytes { Darwin.pwrite(descriptor, $0.baseAddress!, $0.count, offset) }
        guard count == data.count else { throw BrowserRuntimeStorageFailure.storageIO("fixture") }
    }
    func read(_ url: URL, offset: Int64, count: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BrowserRuntimeStorageFailure.storageIO("fixture") }
        defer { Darwin.close(descriptor) }
        var data = Data(count: count)
        let actual = data.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress!, $0.count, offset) }
        guard actual == count else { throw BrowserRuntimeStorageFailure.storageIO("fixture") }
        return data
    }
    func mode(_ url: URL) -> mode_t {
        var value = stat(); return Darwin.lstat(url.path, &value) == 0 ? value.st_mode & 0o777 : 0
    }
    func size(_ url: URL) -> Int64 {
        var value = stat(); return Darwin.lstat(url.path, &value) == 0 ? value.st_size : -1
    }
    func allocatedSize(_ url: URL) -> Int64 {
        var value = stat(); return Darwin.lstat(url.path, &value) == 0 ? Int64(value.st_blocks) * 512 : -1
    }
    func sessions() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: profile.path).filter { $0.hasPrefix(".browser-session-") }
    }
    func remove() {
        do { try FileManager.default.removeItem(at: root) }
        catch { fputs("BROWSER_STORAGE_CHECK_FIXTURE_CLEANUP_FAILED\n", stderr) }
    }
}
