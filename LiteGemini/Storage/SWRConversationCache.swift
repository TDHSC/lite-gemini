import CryptoKit
import Foundation
import os

// MARK: - LastActiveConversationRecord

/// Tracks the last non-temporary active conversation for cold-start restoration.
nonisolated struct LastActiveConversationRecord: Codable, Equatable, Sendable {
    let conversationId: String
    let updatedAt: Date
}

// MARK: - SWRConversationCache

/// Account-scoped, read-only stale-while-revalidate disk snapshot cache enforcing all six
/// Lite Gemini v2 data, sync, and privacy invariants.
///
/// Storage layout:
/// ```
/// <baseDirectory>/
/// └── <sanitizedAccountScopeId>/
///     ├── recent.json
///     ├── index.json
///     └── conversations/
///         └── <sanitizedConversationId>.json
/// ```
@MainActor
final class SWRConversationCache {

    // MARK: - Types

    private nonisolated struct ConversationIndexEntry: Codable, Equatable, Sendable {
        let conversationId: String
        let filename: String
        var lastAccessedAt: Date
        var accessSequence: UInt64
    }

    private nonisolated struct AccountCacheIndex: Codable, Equatable, Sendable {
        var lastActiveConversation: LastActiveConversationRecord?
        var nextAccessSequence: UInt64 = 1
        var entries: [String: ConversationIndexEntry] = [:]
    }

    // MARK: - Constants

    static let defaultMaxCachedConversations = 20
    static let defaultClearDataNotificationName = Notification.Name("BrowsingDataCleared")

    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "SWRConversationCache")

    // MARK: - Properties

    /// Root directory containing per-account cache folders (`.../LiteGemini/Cache/v2/` by default).
    let baseDirectory: URL
    /// Maximum number of cached conversation snapshots retained per `accountScopeId`.
    let maxCachedConversations: Int
    /// Notification name that triggers a synchronous full wipe of `baseDirectory`.
    let clearDataNotificationName: Notification.Name

    private let fileManager: FileManager
    private let notificationCenter: NotificationCenter
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var clearDataObserver: (any NSObjectProtocol)?

    // MARK: - Initialization

    /// Returns the default on-disk cache root: `~/Library/Application Support/LiteGemini/Cache/v2/`.
    nonisolated static func defaultBaseDirectory(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("LiteGemini", isDirectory: true)
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
    }

    init(
        baseDirectory: URL = SWRConversationCache.defaultBaseDirectory(),
        maxCachedConversations: Int = SWRConversationCache.defaultMaxCachedConversations,
        clearDataNotificationName: Notification.Name = SWRConversationCache.defaultClearDataNotificationName,
        notificationCenter: NotificationCenter = .default,
        fileManager: FileManager = .default
    ) {
        self.baseDirectory = baseDirectory
        self.maxCachedConversations = max(1, maxCachedConversations)
        self.clearDataNotificationName = clearDataNotificationName
        self.notificationCenter = notificationCenter
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder

        self.clearDataObserver = notificationCenter.addObserver(
            forName: clearDataNotificationName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.clearAll()
                }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        self?.clearAll()
                    }
                }
            }
        }
    }

    isolated deinit {
        if let clearDataObserver {
            notificationCenter.removeObserver(clearDataObserver)
        }
    }

    // MARK: - Recent Conversations

    /// Loads cached recent conversation summaries for `accountScopeId`, or `[]` if absent or unscoped.
    func loadRecentConversations(accountScopeId: String?) -> [ConversationSummary] {
        guard let scopeDir = accountDirectory(for: accountScopeId) else {
            return []
        }
        let recentURL = scopeDir.appendingPathComponent("recent.json", isDirectory: false)
        guard let data = try? Data(contentsOf: recentURL) else {
            return []
        }
        return (try? decoder.decode([ConversationSummary].self, from: data)) ?? []
    }

    /// Atomically replaces `recent.json` for `accountScopeId` (Server-Always-Wins).
    func saveRecentConversations(_ summaries: [ConversationSummary], accountScopeId: String?) {
        guard let scopeDir = accountDirectory(for: accountScopeId) else {
            return
        }
        do {
            try fileManager.createDirectory(at: scopeDir, withIntermediateDirectories: true)
            let data = try encoder.encode(summaries)
            let recentURL = scopeDir.appendingPathComponent("recent.json", isDirectory: false)
            try data.write(to: recentURL, options: [.atomic])
        } catch {
            Self.logger.error("Failed to write recent.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Conversation Snapshots

    /// Loads a cached conversation snapshot and updates its LRU recency when present.
    func loadConversation(
        accountScopeId: String?,
        conversationId: String,
        accessedAt: Date = Date()
    ) -> ConversationSnapshot? {
        guard let scopeDir = accountDirectory(for: accountScopeId),
              let sanitizedConvId = Self.validatedIdentifier(conversationId) else {
            return nil
        }

        let filename = Self.conversationFilename(for: sanitizedConvId)
        let fileURL = conversationsDirectory(in: scopeDir).appendingPathComponent(filename, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? decoder.decode(ConversationSnapshot.self, from: data) else {
            return nil
        }

        // Update LRU metadata on a cache hit without failing the read if index persistence fails.
        var index = loadIndex(in: scopeDir)
        let sequence = index.nextAccessSequence
        index.nextAccessSequence += 1
        index.entries[sanitizedConvId] = ConversationIndexEntry(
            conversationId: sanitizedConvId,
            filename: filename,
            lastAccessedAt: accessedAt,
            accessSequence: sequence
        )
        saveIndex(index, in: scopeDir)

        return snapshot
    }

    /// Atomically writes a complete, server-acknowledged conversation snapshot (Server-Always-Wins)
    /// and enforces the per-account LRU cap.
    ///
    /// Performs zero disk I/O when `isTemporaryChat == true` or `snapshot.accountScopeId` is empty.
    func saveConversation(
        _ snapshot: ConversationSnapshot,
        isTemporaryChat: Bool = false,
        accessedAt: Date = Date()
    ) {
        guard !isTemporaryChat else {
            return
        }
        guard let scopeDir = accountDirectory(for: snapshot.accountScopeId),
              let sanitizedConvId = Self.validatedIdentifier(snapshot.conversationId) else {
            return
        }

        let convDir = conversationsDirectory(in: scopeDir)
        let filename = Self.conversationFilename(for: sanitizedConvId)
        let targetURL = convDir.appendingPathComponent(filename, isDirectory: false)

        do {
            try fileManager.createDirectory(at: convDir, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: targetURL, options: [.atomic])
        } catch {
            Self.logger.error("Failed to write conversation snapshot: \(error.localizedDescription, privacy: .public)")
            return
        }

        var index = loadIndex(in: scopeDir)
        let sequence = index.nextAccessSequence
        index.nextAccessSequence += 1
        index.entries[sanitizedConvId] = ConversationIndexEntry(
            conversationId: sanitizedConvId,
            filename: filename,
            lastAccessedAt: accessedAt,
            accessSequence: sequence
        )

        evictOverflowEntriesIfNeeded(in: &index, conversationsDir: convDir)
        saveIndex(index, in: scopeDir)
    }

    /// Returns all currently cached conversation IDs for `accountScopeId`, ordered most-recently-used first.
    func cachedConversationIds(accountScopeId: String?) -> [String] {
        guard let scopeDir = accountDirectory(for: accountScopeId) else {
            return []
        }
        let index = loadIndex(in: scopeDir)
        return index.entries.values
            .sorted { lhs, rhs in
                if lhs.accessSequence != rhs.accessSequence {
                    return lhs.accessSequence > rhs.accessSequence
                }
                return lhs.lastAccessedAt > rhs.lastAccessedAt
            }
            .map(\.conversationId)
    }

    // MARK: - Last Active Conversation Metadata

    /// Loads the last non-temporary active conversation record for cold-start restoration.
    func loadLastActiveConversation(accountScopeId: String?) -> LastActiveConversationRecord? {
        guard let scopeDir = accountDirectory(for: accountScopeId) else {
            return nil
        }
        return loadIndex(in: scopeDir).lastActiveConversation
    }

    /// Records or clears the last non-temporary active conversation for cold-start restoration.
    ///
    /// Performs zero disk I/O when `isTemporaryChat == true` or `accountScopeId` is nil/empty.
    func saveLastActiveConversationId(
        _ conversationId: String?,
        updatedAt: Date = Date(),
        accountScopeId: String?,
        isTemporaryChat: Bool = false
    ) {
        guard !isTemporaryChat else {
            return
        }
        guard let scopeDir = accountDirectory(for: accountScopeId) else {
            return
        }

        if conversationId == nil, !fileManager.fileExists(atPath: scopeDir.path) {
            return
        }

        var index = loadIndex(in: scopeDir)
        if let conversationId, let validId = Self.validatedIdentifier(conversationId) {
            index.lastActiveConversation = LastActiveConversationRecord(
                conversationId: validId,
                updatedAt: updatedAt
            )
        } else {
            index.lastActiveConversation = nil
        }
        saveIndex(index, in: scopeDir)
    }

    // MARK: - Eviction & Wipe

    /// Immediately removes a conversation snapshot, LRU index entry, and matching recent entry.
    func evictConversation(accountScopeId: String?, conversationId: String) {
        guard let scopeDir = accountDirectory(for: accountScopeId),
              let validId = Self.validatedIdentifier(conversationId),
              fileManager.fileExists(atPath: scopeDir.path) else {
            return
        }

        let convDir = conversationsDirectory(in: scopeDir)
        let filename = Self.conversationFilename(for: validId)
        let targetURL = convDir.appendingPathComponent(filename, isDirectory: false)
        removeItemIfExists(at: targetURL)

        var index = loadIndex(in: scopeDir)
        let removedEntry = index.entries.removeValue(forKey: validId)
        if let removedEntry, removedEntry.filename != filename {
            removeItemIfExists(at: convDir.appendingPathComponent(removedEntry.filename, isDirectory: false))
        }
        if index.lastActiveConversation?.conversationId == validId {
            index.lastActiveConversation = nil
        }
        saveIndex(index, in: scopeDir)

        let recentURL = scopeDir.appendingPathComponent("recent.json", isDirectory: false)
        if let data = try? Data(contentsOf: recentURL),
           let summaries = try? decoder.decode([ConversationSummary].self, from: data) {
            let filtered = summaries.filter { $0.id != validId }
            if filtered.count != summaries.count {
                saveRecentConversations(filtered, accountScopeId: accountScopeId)
            }
        }
    }

    /// Synchronously wipes the entire cache root directory across all account scopes.
    func clearAll() {
        removeItemIfExists(at: baseDirectory)
    }

    // MARK: - Filename Sanitization

    /// Sanitizes an arbitrary identifier into a safe single path component with no path traversal.
    nonisolated static func sanitizeFilenameComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "empty"
        }

        let isSafeASCII = trimmed.count <= 120
            && trimmed != "."
            && trimmed != ".."
            && trimmed.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57)   // 0-9
                || (byte >= 65 && byte <= 90) // A-Z
                || (byte >= 97 && byte <= 122) // a-z
                || byte == 45                 // -
                || byte == 95                 // _
            }

        if isSafeASCII {
            return trimmed
        }

        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let hexAlphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for byte in digest.prefix(16) {
            bytes.append(hexAlphabet[Int(byte >> 4)])
            bytes.append(hexAlphabet[Int(byte & 0x0F)])
        }
        return "h_" + String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Private Helpers

    private nonisolated static func validatedIdentifier(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func conversationFilename(for conversationId: String) -> String {
        "\(sanitizeFilenameComponent(conversationId)).json"
    }

    private func accountDirectory(for accountScopeId: String?) -> URL? {
        guard let validScopeId = Self.validatedIdentifier(accountScopeId) else {
            return nil
        }
        let sanitized = Self.sanitizeFilenameComponent(validScopeId)
        return baseDirectory.appendingPathComponent(sanitized, isDirectory: true)
    }

    private func conversationsDirectory(in scopeDirectory: URL) -> URL {
        scopeDirectory.appendingPathComponent("conversations", isDirectory: true)
    }

    private func indexURL(in scopeDirectory: URL) -> URL {
        scopeDirectory.appendingPathComponent("index.json", isDirectory: false)
    }

    private func loadIndex(in scopeDirectory: URL) -> AccountCacheIndex {
        let url = indexURL(in: scopeDirectory)
        guard let data = try? Data(contentsOf: url),
              let index = try? decoder.decode(AccountCacheIndex.self, from: data) else {
            return AccountCacheIndex()
        }
        return index
    }

    private func saveIndex(_ index: AccountCacheIndex, in scopeDirectory: URL) {
        do {
            try fileManager.createDirectory(at: scopeDirectory, withIntermediateDirectories: true)
            let data = try encoder.encode(index)
            try data.write(to: indexURL(in: scopeDirectory), options: [.atomic])
        } catch {
            Self.logger.error("Failed to write index.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func evictOverflowEntriesIfNeeded(in index: inout AccountCacheIndex, conversationsDir: URL) {
        let overflowCount = index.entries.count - maxCachedConversations
        guard overflowCount > 0 else {
            return
        }

        let sortedOldestFirst = index.entries.values.sorted { lhs, rhs in
            if lhs.accessSequence != rhs.accessSequence {
                return lhs.accessSequence < rhs.accessSequence
            }
            if lhs.lastAccessedAt != rhs.lastAccessedAt {
                return lhs.lastAccessedAt < rhs.lastAccessedAt
            }
            return lhs.conversationId < rhs.conversationId
        }

        for evicted in sortedOldestFirst.prefix(overflowCount) {
            index.entries.removeValue(forKey: evicted.conversationId)
            removeItemIfExists(at: conversationsDir.appendingPathComponent(evicted.filename, isDirectory: false))
            if index.lastActiveConversation?.conversationId == evicted.conversationId {
                index.lastActiveConversation = nil
            }
        }
    }

    private func removeItemIfExists(at url: URL) {
        do {
            try fileManager.removeItem(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        } catch {
            Self.logger.error("Failed to remove cache item \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
