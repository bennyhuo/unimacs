// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import CryptoKit
import IOKit
import Security
import Darwin

extension Notification.Name {
    static let UMAutoUnlockCredentialStateDidChange = Notification.Name("UMAutoUnlockCredentialStateDidChangeNotification")
}

enum UnlockCredentialError: Error, LocalizedError, Equatable {
    case emptyPassword
    case invalidHostIdentifier
    case invalidSecretLength
    case corruptedData
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "Login password cannot be empty."
        case .invalidHostIdentifier:
            return "Remote host identifier cannot be empty."
        case .invalidSecretLength:
            return "Peer secret must be 32 bytes."
        case .corruptedData:
            return "Encrypted auto-unlock data could not be verified or decrypted."
        case .ioFailure(let message):
            return "Failed to read or write auto-unlock storage: \(message)"
        }
    }
}

final class UnlockCredentialStore: @unchecked Sendable {

    static let shared = UnlockCredentialStore()

    private struct EncryptedEnvelope: Codable {
        let version: Int
        let combined: Data
    }

    private struct CredentialPayload: Codable {
        let password: String
        var invalidated: Bool
        let updatedAt: TimeInterval
    }

    private struct PeerSecretsPayload: Codable {
        let version: Int
        var secrets: [String: Data]
    }

    private static let masterKeyByteCount = 32
    private static let envelopeVersion = 1

    private let directoryURL: URL
    private let platformUUIDProvider: () -> String
    private let uidProvider: () -> uid_t
    private let usernameProvider: () -> String
    private let postNotifications: Bool
    private let lock = NSRecursiveLock()

    private var masterKeyURL: URL {
        directoryURL.appendingPathComponent("master.key", isDirectory: false)
    }

    private var credentialFileURL: URL {
        directoryURL.appendingPathComponent("unlock_credential.json", isDirectory: false)
    }

    private var peerSecretsFileURL: URL {
        directoryURL.appendingPathComponent("peer_secrets.json", isDirectory: false)
    }

    static var defaultDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("Unimacs", isDirectory: true)
            .appendingPathComponent("Security", isDirectory: true)
    }

    static func currentHardwarePlatformUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            if let uuid = IORegistryEntryCreateCFProperty(
                service,
                kIOPlatformUUIDKey as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String, !uuid.isEmpty {
                return uuid
            }
        }
        return "unimacs-fallback-platform-uuid"
    }

    init(
        directoryURL: URL = UnlockCredentialStore.defaultDirectoryURL,
        platformUUIDProvider: @escaping () -> String = UnlockCredentialStore.currentHardwarePlatformUUID,
        uidProvider: @escaping () -> uid_t = { getuid() },
        usernameProvider: @escaping () -> String = { NSUserName() },
        postNotifications: Bool = true
    ) {
        self.directoryURL = directoryURL
        self.platformUUIDProvider = platformUUIDProvider
        self.uidProvider = uidProvider
        self.usernameProvider = usernameProvider
        self.postNotifications = postNotifications
    }

    // MARK: - Password Credential

    var hasSavedPassword: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (try? loadCredentialPayloadLocked()) != nil
    }

    var isPasswordInvalid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (try? loadCredentialPayloadLocked())?.invalidated ?? false
    }

    func savePassword(_ password: String) throws {
        guard !password.isEmpty else {
            throw UnlockCredentialError.emptyPassword
        }

        lock.lock()
        defer { lock.unlock() }

        let masterKey = try loadOrCreateMasterKeyForWriteLocked()
        let payload = CredentialPayload(
            password: password,
            invalidated: false,
            updatedAt: Date().timeIntervalSinceReferenceDate
        )
        try writeEncryptedPayloadLocked(
            payload,
            to: credentialFileURL,
            masterKey: masterKey,
            purpose: "credential",
            aadPrefix: "cred:v1"
        )
        postStateChangeNotification()
    }

    func loadPassword() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try loadCredentialPayloadLocked()?.password
    }

    func markPasswordInvalid() {
        setPasswordInvalidatedLocked(true)
    }

    func clearPasswordInvalidFlag() {
        setPasswordInvalidatedLocked(false)
    }

    private func setPasswordInvalidatedLocked(_ invalidated: Bool) {
        lock.lock()
        defer { lock.unlock() }

        guard var payload = try? loadCredentialPayloadLocked(), payload.invalidated != invalidated else {
            return
        }
        guard let masterKey = try? loadExistingMasterKeyLocked() else {
            return
        }
        payload.invalidated = invalidated
        try? writeEncryptedPayloadLocked(
            payload,
            to: credentialFileURL,
            masterKey: masterKey,
            purpose: "credential",
            aadPrefix: "cred:v1"
        )
        postStateChangeNotification()
    }

    func deletePassword() {
        lock.lock()
        defer { lock.unlock() }

        let existed = FileManager.default.fileExists(atPath: credentialFileURL.path)
        try? FileManager.default.removeItem(at: credentialFileURL)
        if existed {
            postStateChangeNotification()
        }
    }

    // MARK: - Per-Peer Shared Secrets

    func savePeerSecret(_ secret: Data, for hostId: String) throws {
        guard !hostId.isEmpty else {
            throw UnlockCredentialError.invalidHostIdentifier
        }
        guard secret.count == AutoUnlockCrypto.expectedKeyLength else {
            throw UnlockCredentialError.invalidSecretLength
        }

        lock.lock()
        defer { lock.unlock() }

        let masterKey = try loadOrCreateMasterKeyForWriteLocked()
        var payload = (try? loadPeerSecretsPayloadLocked(masterKey: masterKey))
            ?? PeerSecretsPayload(version: Self.envelopeVersion, secrets: [:])
        payload.secrets[hostId] = secret

        try writeEncryptedPayloadLocked(
            payload,
            to: peerSecretsFileURL,
            masterKey: masterKey,
            purpose: "peer-secrets",
            aadPrefix: "peers:v1"
        )
        postStateChangeNotification()
    }

    func loadPeerSecret(for hostId: String) -> Data? {
        guard !hostId.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }

        guard let masterKey = try? loadExistingMasterKeyLocked(),
              let payload = try? loadPeerSecretsPayloadLocked(masterKey: masterKey) else {
            return nil
        }
        guard let secret = payload.secrets[hostId], secret.count == AutoUnlockCrypto.expectedKeyLength else {
            return nil
        }
        return secret
    }

    func hasPeerSecret(for hostId: String) -> Bool {
        loadPeerSecret(for: hostId) != nil
    }

    func peerKeyId(for hostId: String) -> String? {
        guard let secret = loadPeerSecret(for: hostId) else { return nil }
        return AutoUnlockCrypto.keyId(for: secret)
    }

    func removePeerSecret(for hostId: String) {
        guard !hostId.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        guard let masterKey = try? loadExistingMasterKeyLocked(),
              var payload = try? loadPeerSecretsPayloadLocked(masterKey: masterKey),
              payload.secrets.removeValue(forKey: hostId) != nil else {
            return
        }

        if payload.secrets.isEmpty {
            try? FileManager.default.removeItem(at: peerSecretsFileURL)
        } else {
            try? writeEncryptedPayloadLocked(
                payload,
                to: peerSecretsFileURL,
                masterKey: masterKey,
                purpose: "peer-secrets",
                aadPrefix: "peers:v1"
            )
        }
        postStateChangeNotification()
    }

    func removeAllPeerSecrets() {
        lock.lock()
        defer { lock.unlock() }

        let existed = FileManager.default.fileExists(atPath: peerSecretsFileURL.path)
        try? FileManager.default.removeItem(at: peerSecretsFileURL)
        if existed {
            postStateChangeNotification()
        }
    }

    // MARK: - Internal Cryptographic & File I/O Helpers

    private func loadCredentialPayloadLocked() throws -> CredentialPayload? {
        guard FileManager.default.fileExists(atPath: credentialFileURL.path) else {
            return nil
        }
        let masterKey = try loadExistingMasterKeyLocked()
        let payload: CredentialPayload = try readEncryptedPayloadLocked(
            from: credentialFileURL,
            masterKey: masterKey,
            purpose: "credential",
            aadPrefix: "cred:v1"
        )
        guard !payload.password.isEmpty else {
            throw UnlockCredentialError.corruptedData
        }
        return payload
    }

    private func loadPeerSecretsPayloadLocked(masterKey: Data) throws -> PeerSecretsPayload? {
        guard FileManager.default.fileExists(atPath: peerSecretsFileURL.path) else {
            return nil
        }
        return try readEncryptedPayloadLocked(
            from: peerSecretsFileURL,
            masterKey: masterKey,
            purpose: "peer-secrets",
            aadPrefix: "peers:v1"
        )
    }

    private func writeEncryptedPayloadLocked<T: Encodable>(
        _ payload: T,
        to fileURL: URL,
        masterKey: Data,
        purpose: String,
        aadPrefix: String
    ) throws {
        try ensureSecureDirectoryLocked()
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(payload)
        } catch {
            throw UnlockCredentialError.ioFailure(error.localizedDescription)
        }

        let key = deriveSymmetricKey(masterKey: masterKey, purpose: purpose)
        let aad = buildAAD(prefix: aadPrefix)
        let nonce = AES.GCM.Nonce()
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        } catch {
            throw UnlockCredentialError.ioFailure(error.localizedDescription)
        }

        guard let combined = sealedBox.combined else {
            throw UnlockCredentialError.ioFailure("Unable to extract sealed box combined bytes.")
        }

        let envelope = EncryptedEnvelope(version: Self.envelopeVersion, combined: combined)
        let encodedEnvelope: Data
        do {
            encodedEnvelope = try JSONEncoder().encode(envelope)
        } catch {
            throw UnlockCredentialError.ioFailure(error.localizedDescription)
        }

        try atomicWriteSecureFileLocked(data: encodedEnvelope, to: fileURL)
    }

    private func readEncryptedPayloadLocked<T: Decodable>(
        from fileURL: URL,
        masterKey: Data,
        purpose: String,
        aadPrefix: String
    ) throws -> T {
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw UnlockCredentialError.ioFailure(error.localizedDescription)
        }

        let envelope: EncryptedEnvelope
        do {
            envelope = try JSONDecoder().decode(EncryptedEnvelope.self, from: fileData)
        } catch {
            throw UnlockCredentialError.corruptedData
        }

        guard envelope.version == Self.envelopeVersion else {
            throw UnlockCredentialError.corruptedData
        }

        let key = deriveSymmetricKey(masterKey: masterKey, purpose: purpose)
        let aad = buildAAD(prefix: aadPrefix)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: envelope.combined)
            let plaintext = try AES.GCM.open(sealedBox, using: key, authenticating: aad)
            return try JSONDecoder().decode(T.self, from: plaintext)
        } catch {
            throw UnlockCredentialError.corruptedData
        }
    }

    private func loadExistingMasterKeyLocked() throws -> Data {
        guard FileManager.default.fileExists(atPath: masterKeyURL.path) else {
            throw UnlockCredentialError.corruptedData
        }
        let data: Data
        do {
            data = try Data(contentsOf: masterKeyURL)
        } catch {
            throw UnlockCredentialError.ioFailure(error.localizedDescription)
        }
        guard data.count == Self.masterKeyByteCount else {
            throw UnlockCredentialError.corruptedData
        }
        return data
    }

    private func loadOrCreateMasterKeyForWriteLocked() throws -> Data {
        try ensureSecureDirectoryLocked()

        if let existing = try? loadExistingMasterKeyLocked() {
            enforceFileSecurityAttributes(at: masterKeyURL)
            return existing
        }

        // If a corrupted master.key existed, clear stale unrecoverable ciphertexts before regenerating.
        if FileManager.default.fileExists(atPath: masterKeyURL.path) {
            try? FileManager.default.removeItem(at: credentialFileURL)
            try? FileManager.default.removeItem(at: peerSecretsFileURL)
        }

        var keyBytes = [UInt8](repeating: 0, count: Self.masterKeyByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, Self.masterKeyByteCount, &keyBytes)
        guard status == errSecSuccess else {
            throw UnlockCredentialError.ioFailure("SecRandomCopyBytes failed with status \(status)")
        }

        let data = Data(keyBytes)
        try atomicWriteSecureFileLocked(data: data, to: masterKeyURL)
        return data
    }

    private func deriveSymmetricKey(masterKey: Data, purpose: String) -> SymmetricKey {
        let uuid = platformUUIDProvider()
        let uid = UInt32(uidProvider())
        let username = usernameProvider()

        var salt = Data()
        appendLengthPrefixedUTF8(uuid, to: &salt)
        var uidBE = uid.bigEndian
        withUnsafeBytes(of: &uidBE) { salt.append(contentsOf: $0) }
        appendLengthPrefixedUTF8(username, to: &salt)

        let info = Data("unimacs-vault-v1:\(purpose)".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey),
            salt: salt,
            info: info,
            outputByteCount: Self.masterKeyByteCount
        )
    }

    private func buildAAD(prefix: String) -> Data {
        let uuid = platformUUIDProvider()
        let uid = uidProvider()
        let username = usernameProvider()
        return Data("\(prefix):\(uuid):\(uid):\(username)".utf8)
    }

    private func appendLengthPrefixedUTF8(_ value: String, to buffer: inout Data) {
        let utf8 = Data(value.utf8)
        var len = UInt32(utf8.count).bigEndian
        withUnsafeBytes(of: &len) { buffer.append(contentsOf: $0) }
        buffer.append(utf8)
    }

    private func ensureSecureDirectoryLocked() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            do {
                try fm.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw UnlockCredentialError.ioFailure(error.localizedDescription)
            }
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        excludeFromBackup(url: directoryURL)
    }

    private func atomicWriteSecureFileLocked(data: Data, to destinationURL: URL) throws {
        let tempURL = directoryURL.appendingPathComponent(".\(destinationURL.lastPathComponent).tmp.\(UUID().uuidString)")
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw UnlockCredentialError.ioFailure(String(cString: strerror(errno)))
        }

        var writeError: String?
        let totalCount = data.count
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < totalCount {
                let written = Darwin.write(fd, base.advanced(by: offset), totalCount - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    writeError = String(cString: strerror(errno))
                    break
                }
                offset += written
            }
        }

        _ = fchmod(fd, S_IRUSR | S_IWUSR)
        _ = fsync(fd)
        close(fd)

        if let writeError = writeError {
            try? FileManager.default.removeItem(at: tempURL)
            throw UnlockCredentialError.ioFailure(writeError)
        }

        if Darwin.rename(tempURL.path, destinationURL.path) != 0 {
            let err = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tempURL)
            throw UnlockCredentialError.ioFailure(err)
        }

        enforceFileSecurityAttributes(at: destinationURL)
    }

    private func enforceFileSecurityAttributes(at url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        excludeFromBackup(url: url)
    }

    private func excludeFromBackup(url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    private func postStateChangeNotification() {
        guard postNotifications else { return }
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .UMAutoUnlockCredentialStateDidChange, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .UMAutoUnlockCredentialStateDidChange, object: self)
            }
        }
    }
}
