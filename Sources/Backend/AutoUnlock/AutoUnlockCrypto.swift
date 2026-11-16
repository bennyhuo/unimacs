// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import CryptoKit
import Security

enum AutoUnlockCryptoError: Error, LocalizedError, Equatable {
    case invalidPublicKey
    case invalidSecretLength
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidPublicKey:
            return "Invalid Curve25519 peer public key."
        case .invalidSecretLength:
            return "Auto-unlock shared secret must be 32 bytes."
        case .randomGenerationFailed(let status):
            return "Failed to generate cryptographically secure random bytes (OSStatus \(status))."
        }
    }
}

enum AutoUnlockCrypto {

    private static let peerSecretInfo = Data("unimacs-autounlock-peer-secret-v1".utf8)
    private static let challengeDomainTag = Data("unimacs-autounlock-v1".utf8)
    static let expectedKeyLength = 32

    static func generateKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    static func derivePeerSecret(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKeyBytes: Data,
        localHostId: String,
        remoteHostId: String
    ) throws -> Data {
        guard peerPublicKeyBytes.count == expectedKeyLength else {
            throw AutoUnlockCryptoError.invalidPublicKey
        }

        let peerPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyBytes)
        } catch {
            throw AutoUnlockCryptoError.invalidPublicKey
        }

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        } catch {
            throw AutoUnlockCryptoError.invalidPublicKey
        }

        let sortedIds = [localHostId, remoteHostId].sorted()
        var salt = Data()
        appendLengthPrefixed(Data(sortedIds[0].utf8), to: &salt)
        appendLengthPrefixed(Data(sortedIds[1].utf8), to: &salt)

        let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: peerSecretInfo,
            outputByteCount: expectedKeyLength
        )

        return derivedKey.withUnsafeBytes { Data($0) }
    }

    static func keyId(for secret: Data) -> String {
        let digest = SHA256.hash(data: secret)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func generateNonce(byteCount: Int = 32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw AutoUnlockCryptoError.randomGenerationFailed(status)
        }
        return Data(bytes)
    }

    static func challengeTranscript(
        requestId: String,
        nonce: Data,
        requesterHostId: String,
        targetHostId: String
    ) -> Data {
        var data = Data()
        appendLengthPrefixed(challengeDomainTag, to: &data)
        appendLengthPrefixed(Data(requestId.utf8), to: &data)
        appendLengthPrefixed(nonce, to: &data)
        appendLengthPrefixed(Data(requesterHostId.utf8), to: &data)
        appendLengthPrefixed(Data(targetHostId.utf8), to: &data)
        return data
    }

    static func computeChallengeHMAC(
        secret: Data,
        requestId: String,
        nonce: Data,
        requesterHostId: String,
        targetHostId: String
    ) throws -> Data {
        guard secret.count == expectedKeyLength else {
            throw AutoUnlockCryptoError.invalidSecretLength
        }
        let key = SymmetricKey(data: secret)
        let transcript = challengeTranscript(
            requestId: requestId,
            nonce: nonce,
            requesterHostId: requesterHostId,
            targetHostId: targetHostId
        )
        let mac = HMAC<SHA256>.authenticationCode(for: transcript, using: key)
        return Data(mac)
    }

    static func verifyChallengeHMAC(
        _ hmac: Data,
        secret: Data,
        requestId: String,
        nonce: Data,
        requesterHostId: String,
        targetHostId: String
    ) -> Bool {
        guard secret.count == expectedKeyLength, hmac.count == expectedKeyLength else {
            return false
        }
        let key = SymmetricKey(data: secret)
        let transcript = challengeTranscript(
            requestId: requestId,
            nonce: nonce,
            requesterHostId: requesterHostId,
            targetHostId: targetHostId
        )
        return HMAC<SHA256>.isValidAuthenticationCode(hmac, authenticating: transcript, using: key)
    }

    private static func appendLengthPrefixed(_ chunk: Data, to buffer: inout Data) {
        var length = UInt32(chunk.count).bigEndian
        withUnsafeBytes(of: &length) { buffer.append(contentsOf: $0) }
        buffer.append(chunk)
    }
}
