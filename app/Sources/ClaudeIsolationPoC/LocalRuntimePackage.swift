import CryptoKit
import Darwin
import Foundation

/// Only the trusted in-App builder uses this entry point, after candidate payload verification
/// and the real isolated runtime health check. File-picker imports keep publisher trust.
protocol LocalRuntimePackageManaging: RuntimePackageManaging {
    func importLocalBuild(at contents: URL, provenance: LocalRuntimeBuildProvenance,
                          shouldCancel: @Sendable () -> Bool,
                          progress: @Sendable (Double) -> Void,
                          beforeCommit: (@Sendable () throws -> Void)?) throws -> RuntimePackageInfo
}

/// This authorization is constructed inside the App, never decoded from an unsigned package.
/// The candidate path and full inventory bind the health-checked candidate to the store import.
struct LocalRuntimeBuildProvenance: Sendable {
    let candidateContents: URL
    let expectedFiles: [RuntimePackageFile]
    let metadata: LocalRuntimeBuildMetadata

    init(validatedContents: URL, validatedManifest: RuntimePackageManifest,
         sdkArchiveSHA256: String, cliSHA256: String, cliManifestSHA256: String,
         cliSigningKeySHA256: String, builderRecipeSHA256: String) throws {
        try RuntimePackageIO.validateAncestors(validatedContents)
        try validatedManifest.validate()
        let metadata = LocalRuntimeBuildMetadata(cliVersion: validatedManifest.cliVersion,
                                                sdkVersion: validatedManifest.sdkVersion,
                                                nodeVersion: validatedManifest.nodeVersion,
                                                sdkArchiveSHA256: sdkArchiveSHA256,
                                                cliSHA256: cliSHA256, cliManifestSHA256: cliManifestSHA256,
                                                cliSigningKeySHA256: cliSigningKeySHA256,
                                                builderRecipeSHA256: builderRecipeSHA256)
        try metadata.validate()
        candidateContents = validatedContents
        expectedFiles = validatedManifest.files.sorted { $0.path < $1.path }
        self.metadata = metadata
    }
}

struct LocalRuntimeBuildMetadata: Codable, Equatable, Sendable {
    let cliVersion: String
    let sdkVersion: String
    let nodeVersion: String
    let sdkArchiveSHA256: String
    let cliSHA256: String
    let cliManifestSHA256: String
    let cliSigningKeySHA256: String
    let builderRecipeSHA256: String

    func validate() throws {
        guard [cliVersion, sdkVersion, nodeVersion].allSatisfy(RuntimePackageIO.isVersion),
              [sdkArchiveSHA256, cliSHA256, cliManifestSHA256, cliSigningKeySHA256,
               builderRecipeSHA256].allSatisfy(RuntimePackageIO.isDigest) else {
            throw RuntimePackageFailure.invalidPackage
        }
    }
}

private struct LocalRuntimePackageReceipt: Codable, Equatable {
    let schema: String
    let packageID: String
    let manifestSHA256: String
    let provenance: LocalRuntimeBuildMetadata
    static let schemaValue = "claude-local-runtime-receipt/v1"
}

private struct LocalRuntimePackageSignedReceipt: Codable {
    let schema: String
    let keyID: String
    let receipt: String
    let signature: String
    static let schemaValue = "claude-local-runtime-signed-receipt/v1"
}

struct LocalRuntimeSigningIdentity {
    let key: Curve25519.Signing.PrivateKey
    var keyID: String { RuntimePackageIO.digest(key.publicKey.rawRepresentation) }
    var trust: RuntimePackageTrust {
        .init(schema: RuntimePackageTrust.schemaValue,
              publicKeys: [keyID: key.publicKey.rawRepresentation.base64EncodedString()])
    }
}

enum LocalRuntimePackageIO {
    static func validateProvenancePayload(_ contents: URL, provenance: LocalRuntimeBuildMetadata) throws {
        let bytes = try RuntimePackageIO.readSmall(contents.appendingPathComponent("Resources/Runtime/host/text-runtime/images/base.json"),
                                                   limit: 64 * 1024)
        guard let base = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              base["linux_cli_sha256"] as? String == provenance.cliSHA256 else {
            throw RuntimePackageFailure.integrityFailed
        }
        if let cliDigest = base["cli_sha256"] {
            guard cliDigest as? String == provenance.cliSHA256 else { throw RuntimePackageFailure.integrityFailed }
        }
    }

    static func validateCandidateRoot(_ contents: URL) throws {
        try RuntimePackageIO.validateAncestors(contents)
        do {
            guard Set(try RuntimePackageIO.fileManager.contentsOfDirectory(atPath: contents.path)) == Set(["Helpers", "Resources"]),
                  Set(try RuntimePackageIO.fileManager.contentsOfDirectory(atPath: contents.appendingPathComponent("Resources").path)) == Set(["Runtime"]) else {
                throw RuntimePackageFailure.invalidPackage
            }
        } catch { throw RuntimePackageFailure.invalidPackage }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func loadIdentity(at directory: URL, create: Bool = false) throws -> LocalRuntimeSigningIdentity {
        let keyURL = directory.appendingPathComponent("signing-key.raw")
        let trustURL = directory.appendingPathComponent("trust.json")
        var keyMetadata = stat()
        if lstat(keyURL.path, &keyMetadata) != 0 {
            guard errno == ENOENT, create else { throw RuntimePackageFailure.integrityFailed }
            var existingDirectory = stat()
            if lstat(directory.path, &existingDirectory) == 0 {
                guard (existingDirectory.st_mode & S_IFMT) == S_IFDIR,
                      try RuntimePackageIO.fileManager.contentsOfDirectory(atPath: directory.path).isEmpty else {
                    throw RuntimePackageFailure.integrityFailed
                }
            } else if errno != ENOENT { throw RuntimePackageFailure.integrityFailed }
            try RuntimePackageIO.createPrivateDirectory(directory)
            // The operation flock serializes creation. The key belongs solely to this local
            // store and is never added to the immutable publisher trust shipped in the App.
            let identity = LocalRuntimeSigningIdentity(key: Curve25519.Signing.PrivateKey())
            try RuntimePackageIO.atomicWrite(identity.key.rawRepresentation, to: keyURL, mode: 0o600)
            try RuntimePackageIO.atomicWrite(try encode(identity.trust), to: trustURL, mode: 0o600)
        }
        do {
            try RuntimePackageIO.validateAncestors(directory)
            let parent = try RuntimePackageIO.statFile(directory, directory: true)
            let key = try RuntimePackageIO.statFile(keyURL)
            let trust = try RuntimePackageIO.statFile(trustURL)
            guard parent.st_uid == getuid(), parent.st_mode & 0o777 == 0o700,
                  key.st_uid == getuid(), key.st_mode & 0o777 == 0o600, key.st_size == 32,
                  trust.st_uid == getuid(), trust.st_mode & 0o777 == 0o600 else {
                throw RuntimePackageFailure.integrityFailed
            }
            let identity = LocalRuntimeSigningIdentity(key: try .init(rawRepresentation:
                RuntimePackageIO.readSmall(keyURL, limit: 32)))
            let storedTrust = try RuntimePackageIO.loadTrust(trustURL)
            guard storedTrust.schema == identity.trust.schema,
                  storedTrust.publicKeys == identity.trust.publicKeys else {
                throw RuntimePackageFailure.integrityFailed
            }
            return identity
        } catch { throw RuntimePackageFailure.integrityFailed }
    }

    static func signManifest(_ manifest: RuntimePackageManifest,
                             identity: LocalRuntimeSigningIdentity) throws -> RuntimePackageVerified {
        let bytes = try encode(manifest)
        let signature = RuntimePackageSignature(schema: RuntimePackageSignature.schemaValue,
                                                keyID: identity.keyID,
                                                signature: try identity.key.signature(for: bytes).base64EncodedString())
        return .init(manifest: manifest, bytes: bytes, signatureBytes: try encode(signature),
                     id: "local-" + RuntimePackageIO.digest(bytes))
    }

    static func signedManifest(at directory: URL, identity: LocalRuntimeSigningIdentity) throws -> RuntimePackageVerified {
        let package = try RuntimePackageIO.signedManifest(at: directory, trust: identity.trust)
        return .init(manifest: package.manifest, bytes: package.bytes,
                     signatureBytes: package.signatureBytes, id: "local-" + RuntimePackageIO.digest(package.bytes))
    }

    static func signedReceipt(for package: RuntimePackageVerified, provenance: LocalRuntimeBuildMetadata,
                              identity: LocalRuntimeSigningIdentity) throws -> Data {
        let receipt = LocalRuntimePackageReceipt(schema: LocalRuntimePackageReceipt.schemaValue,
                                                 packageID: package.id,
                                                 manifestSHA256: RuntimePackageIO.digest(package.bytes),
                                                 provenance: provenance)
        let bytes = try encode(receipt)
        return try encode(LocalRuntimePackageSignedReceipt(schema: LocalRuntimePackageSignedReceipt.schemaValue,
                            keyID: identity.keyID, receipt: bytes.base64EncodedString(),
                            signature: try identity.key.signature(for: bytes).base64EncodedString()))
    }

    @discardableResult
    static func verifyReceipt(at url: URL, package: RuntimePackageVerified,
                              identity: LocalRuntimeSigningIdentity) throws -> LocalRuntimeBuildMetadata {
        do {
            try RuntimePackageIO.validateAncestors(url.deletingLastPathComponent())
            let metadata = try RuntimePackageIO.statFile(url)
            let parent = try RuntimePackageIO.statFile(url.deletingLastPathComponent(), directory: true)
            guard metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o400,
                  parent.st_uid == getuid(), parent.st_mode & 0o777 == 0o700 else {
                throw RuntimePackageFailure.integrityFailed
            }
            let envelope = try JSONDecoder().decode(LocalRuntimePackageSignedReceipt.self,
                from: RuntimePackageIO.readSmall(url, limit: 16 * 1024))
            guard envelope.schema == LocalRuntimePackageSignedReceipt.schemaValue,
                  envelope.keyID == identity.keyID, let bytes = Data(base64Encoded: envelope.receipt),
                  let signature = Data(base64Encoded: envelope.signature), signature.count == 64,
                  identity.key.publicKey.isValidSignature(signature, for: bytes) else {
                throw RuntimePackageFailure.integrityFailed
            }
            let receipt = try JSONDecoder().decode(LocalRuntimePackageReceipt.self, from: bytes)
            try receipt.provenance.validate()
            guard receipt.schema == LocalRuntimePackageReceipt.schemaValue,
                  receipt.packageID == package.id,
                  receipt.manifestSHA256 == RuntimePackageIO.digest(package.bytes),
                  receipt.provenance.cliVersion == package.manifest.cliVersion,
                  receipt.provenance.sdkVersion == package.manifest.sdkVersion,
                  receipt.provenance.nodeVersion == package.manifest.nodeVersion,
                  package.manifest.version == package.manifest.cliVersion else {
                throw RuntimePackageFailure.integrityFailed
            }
            return receipt.provenance
        } catch { throw RuntimePackageFailure.integrityFailed }
    }
}
