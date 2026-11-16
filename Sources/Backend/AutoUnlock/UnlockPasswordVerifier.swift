// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import OpenDirectory

enum PasswordVerificationResult: Equatable, Sendable {
    case valid
    case invalidCredentials
    case unavailable(String)
}

protocol UnlockPasswordVerifying: Sendable {
    func verify(password: String, username: String) -> PasswordVerificationResult
}

struct OpenDirectoryPasswordVerifier: UnlockPasswordVerifying {

    func verify(password: String, username: String = NSUserName()) -> PasswordVerificationResult {
        guard !password.isEmpty else {
            return .invalidCredentials
        }

        do {
            guard let session = ODSession.default() else {
                return .unavailable("OpenDirectory default session is unavailable.")
            }
            let record = try userRecord(session: session, username: username)
            try record.verifyPassword(password)
            return .valid
        } catch let nsError as NSError {
            if nsError.domain == ODFrameworkErrorDomain,
               nsError.code == Int(kODErrorCredentialsInvalid.rawValue) {
                return .invalidCredentials
            }
            return .unavailable(nsError.localizedDescription)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private func userRecord(session: ODSession, username: String) throws -> ODRecord {
        let localNode = try ODNode(session: session, type: ODNodeType(kODNodeTypeLocalNodes))
        do {
            return try localNode.record(withRecordType: kODRecordTypeUsers, name: username, attributes: nil)
        } catch {
            let authNode = try ODNode(session: session, type: ODNodeType(kODNodeTypeAuthentication))
            return try authNode.record(withRecordType: kODRecordTypeUsers, name: username, attributes: nil)
        }
    }
}
