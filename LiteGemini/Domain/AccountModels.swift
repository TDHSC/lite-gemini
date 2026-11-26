import CryptoKit
import Foundation

// MARK: - AccountScope

/// Identifies a signed-in Google account with a deterministic, filesystem-safe scope ID.
nonisolated struct AccountScope: Codable, Equatable, Hashable, Identifiable, Sendable {

    /// First 16 lowercase hexadecimal characters of the SHA-256 hash of the normalized account identifier.
    let scopeId: String
    /// Signed-in Google account email address.
    let email: String
    /// Optional human-readable account name.
    let displayName: String?
    /// Optional profile avatar URL.
    let avatarURL: URL?
    /// Google multi-account `?authuser=N` index.
    let authUserIndex: Int

    var id: String { scopeId }

    /// Single-character fallback monogram for circular avatar rendering when no avatar image is available.
    var initials: String {
        let source = (displayName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? email.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let first = source.first else {
            return "?"
        }
        return String(first).uppercased()
    }

    /// Creates an account scope from an email (and optional Gaia ID), deriving a deterministic `scopeId`.
    init(
        email: String,
        gaiaId: String? = nil,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        authUserIndex: Int = 0
    ) {
        let preferredIdentifier: String
        if let gaiaId, !gaiaId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preferredIdentifier = gaiaId
        } else {
            preferredIdentifier = email
        }
        self.scopeId = Self.computeScopeId(for: preferredIdentifier)
        self.email = email
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.authUserIndex = authUserIndex
    }

    /// Creates an account scope with an explicit precomputed `scopeId`.
    init(
        scopeId: String,
        email: String,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        authUserIndex: Int = 0
    ) {
        self.scopeId = scopeId
        self.email = email
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.authUserIndex = authUserIndex
    }

    /// Computes a deterministic 16-character lowercase hex SHA-256 prefix safe for directory names.
    static func computeScopeId(for identifier: String) -> String {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hexAlphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for byte in digest.prefix(8) {
            bytes.append(hexAlphabet[Int(byte >> 4)])
            bytes.append(hexAlphabet[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - AuthState

/// Authentication status of the hidden Gemini web session.
nonisolated enum AuthState: Equatable, Sendable {
    /// Initial state before auth probes have completed.
    case unknown
    /// No signed-in Google account is active.
    case signedOut
    /// One or more Google accounts are signed in, with `active` currently selected.
    case signedIn(active: AccountScope, available: [AccountScope])

    /// Currently active signed-in account, if any.
    var activeAccount: AccountScope? {
        guard case .signedIn(let active, _) = self else {
            return nil
        }
        return active
    }

    /// All discovered signed-in accounts, or an empty array when signed out or unknown.
    var availableAccounts: [AccountScope] {
        guard case .signedIn(_, let available) = self else {
            return []
        }
        return available
    }

    /// Whether an authenticated Google account is active.
    var isSignedIn: Bool {
        activeAccount != nil
    }
}

// MARK: - ChallengeBannerState

/// Actionable banner displayed when a mid-session auth challenge, redirect, or bridge fallback occurs.
nonisolated struct ChallengeBannerState: Equatable, Sendable {

    /// Category of interruption encountered by the session bridge.
    nonisolated enum Kind: String, Codable, Equatable, Hashable, Sendable {
        case reauthRequired
        case captchaOrPolicy
        case unexpectedRedirect
        case bridgeFallback
    }

    /// Interruption category controlling the offered recovery actions.
    let kind: Kind
    /// Human-readable description of the challenge or fallback condition.
    let message: String
    /// Optional URL to open in a verification popup or Classic Web Mode.
    let challengeURL: URL?

    init(kind: Kind, message: String, challengeURL: URL? = nil) {
        self.kind = kind
        self.message = message
        self.challengeURL = challengeURL
    }
}
