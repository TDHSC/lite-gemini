import Foundation

// MARK: - CachedConversationSearchMatch

/// Local disk-cache search hit returned synchronously for instant (`0ms`) `⌘K` search results.
nonisolated struct CachedConversationSearchMatch: Identifiable, Equatable, Hashable, Sendable {

    let id: String
    let conversationId: String
    let title: String
    let snippet: String?
    let updatedAt: Date

    init(
        id: String,
        conversationId: String,
        title: String,
        snippet: String? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.conversationId = conversationId
        self.title = title
        self.snippet = snippet
        self.updatedAt = updatedAt
    }

    init(
        conversationId: String,
        title: String,
        snippet: String? = nil,
        updatedAt: Date
    ) {
        self.init(
            id: conversationId,
            conversationId: conversationId,
            title: title,
            snippet: snippet,
            updatedAt: updatedAt
        )
    }
}

// MARK: - SWRConversationCache Local Search

extension SWRConversationCache {

    /// Searches cached conversations and turn payloads for `accountKey` without mutating LRU metadata.
    ///
    /// Matches conversation titles and decoded turn `userPrompt` / `assistantMarkdown` payloads
    /// case-insensitively, extracts a centered ~120-character single-line snippet when turn content
    /// matches, and sorts title matches ahead of body-only matches ordered by `updatedAt` descending.
    func searchConversations(
        accountKey: String,
        query: String,
        limit: Int = 20
    ) -> [CachedConversationSearchMatch] {
        Self.searchCachedConversations(
            in: baseDirectory,
            accountScopeId: accountKey,
            query: query,
            limit: limit
        )
    }

    /// Account-scope convenience overload accepting an optional `accountScopeId`.
    func searchConversations(
        accountScopeId: String?,
        query: String,
        limit: Int = 20
    ) -> [CachedConversationSearchMatch] {
        Self.searchCachedConversations(
            in: baseDirectory,
            accountScopeId: accountScopeId,
            query: query,
            limit: limit
        )
    }

    /// Pure, read-only disk search across `<baseDirectory>/<sanitizedAccountScopeId>/` snapshots and
    /// `recent.json`, safe to execute from any isolation context without touching `index.json`.
    nonisolated static func searchCachedConversations(
        in baseDirectory: URL,
        accountScopeId: String?,
        query: String,
        limit: Int = 20,
        fileManager: FileManager = .default
    ) -> [CachedConversationSearchMatch] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, limit > 0 else {
            return []
        }

        guard let rawScope = accountScopeId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawScope.isEmpty else {
            return []
        }

        let scopeDir = baseDirectory.appendingPathComponent(
            sanitizeFilenameComponent(rawScope),
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: scopeDir.path) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        var recentById: [String: ConversationSummary] = [:]
        let recentURL = scopeDir.appendingPathComponent("recent.json", isDirectory: false)
        if let recentData = try? Data(contentsOf: recentURL),
           let summaries = try? decoder.decode([ConversationSummary].self, from: recentData) {
            for summary in summaries {
                recentById[summary.id] = summary
            }
        }

        struct RankedCandidate {
            let match: CachedConversationSearchMatch
            let isTitleMatch: Bool
        }

        var candidates: [RankedCandidate] = []
        var seenConversationIds: Set<String> = []

        let conversationsDir = scopeDir.appendingPathComponent("conversations", isDirectory: true)
        if let fileURLs = try? fileManager.contentsOfDirectory(
            at: conversationsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for fileURL in fileURLs where fileURL.pathExtension.lowercased() == "json" {
                guard let data = try? Data(contentsOf: fileURL),
                      let snapshot = try? decoder.decode(ConversationSnapshot.self, from: data),
                      !snapshot.conversationId.isEmpty else {
                    continue
                }

                let convId = snapshot.conversationId
                seenConversationIds.insert(convId)

                let recentSummary = recentById[convId]
                let resolvedTitle = resolvedConversationTitle(
                    primary: snapshot.title,
                    fallback: recentSummary?.title
                )
                let resolvedUpdatedAt = max(snapshot.updatedAt, recentSummary?.updatedAt ?? .distantPast)

                let isTitleMatch = resolvedTitle.range(of: trimmedQuery, options: .caseInsensitive) != nil
                let matchedSnippet = extractFirstTurnSnippet(
                    in: snapshot.turns,
                    matching: trimmedQuery
                )

                guard isTitleMatch || matchedSnippet != nil else {
                    continue
                }

                candidates.append(
                    RankedCandidate(
                        match: CachedConversationSearchMatch(
                            id: convId,
                            conversationId: convId,
                            title: resolvedTitle,
                            snippet: matchedSnippet,
                            updatedAt: resolvedUpdatedAt
                        ),
                        isTitleMatch: isTitleMatch
                    )
                )
            }
        }

        for summary in recentById.values where !seenConversationIds.contains(summary.id) {
            let resolvedTitle = resolvedConversationTitle(primary: summary.title, fallback: nil)
            guard resolvedTitle.range(of: trimmedQuery, options: .caseInsensitive) != nil else {
                continue
            }

            candidates.append(
                RankedCandidate(
                    match: CachedConversationSearchMatch(
                        id: summary.id,
                        conversationId: summary.id,
                        title: resolvedTitle,
                        snippet: nil,
                        updatedAt: summary.updatedAt
                    ),
                    isTitleMatch: true
                )
            )
        }

        candidates.sort { lhs, rhs in
            if lhs.isTitleMatch != rhs.isTitleMatch {
                return lhs.isTitleMatch
            }
            if lhs.match.updatedAt != rhs.match.updatedAt {
                return lhs.match.updatedAt > rhs.match.updatedAt
            }
            return lhs.match.conversationId < rhs.match.conversationId
        }

        return candidates.prefix(limit).map(\.match)
    }

    /// Extracts a clean single-line snippet (~120 characters) centered around the first case-insensitive
    /// occurrence of `query` in `source`, returning `nil` if `source` does not contain `query`.
    nonisolated static func extractCenteredSnippet(
        from source: String,
        matching query: String,
        maxLength: Int = 120
    ) -> String? {
        let collapsed = collapseWhitespaceToSingleLine(source)
        guard !collapsed.isEmpty else {
            return nil
        }

        let normalizedQuery = collapseWhitespaceToSingleLine(query)
        guard !normalizedQuery.isEmpty else {
            return nil
        }

        let matchRange = collapsed.range(of: query, options: .caseInsensitive)
            ?? collapsed.range(of: normalizedQuery, options: .caseInsensitive)
        guard let matchRange else {
            return nil
        }

        let budget = max(24, maxLength)
        let totalCount = collapsed.count
        if totalCount <= budget {
            return collapsed
        }

        let matchLength = collapsed.distance(from: matchRange.lowerBound, to: matchRange.upperBound)
        if matchLength >= budget {
            let endIdx = collapsed.index(
                matchRange.lowerBound,
                offsetBy: budget,
                limitedBy: collapsed.endIndex
            ) ?? collapsed.endIndex
            let prefixEllipsis = matchRange.lowerBound > collapsed.startIndex ? "…" : ""
            let suffixEllipsis = endIdx < collapsed.endIndex ? "…" : ""
            let slice = collapsed[matchRange.lowerBound..<endIdx].trimmingCharacters(in: .whitespaces)
            return "\(prefixEllipsis)\(slice)\(suffixEllipsis)"
        }

        let contextBudget = budget - matchLength
        let initialLeading = contextBudget / 2
        let initialTrailing = contextBudget - initialLeading

        var startIndex = collapsed.index(
            matchRange.lowerBound,
            offsetBy: -initialLeading,
            limitedBy: collapsed.startIndex
        ) ?? collapsed.startIndex
        let actualLeading = collapsed.distance(from: startIndex, to: matchRange.lowerBound)
        let unusedLeading = initialLeading - actualLeading

        var endIndex = collapsed.index(
            matchRange.upperBound,
            offsetBy: initialTrailing + unusedLeading,
            limitedBy: collapsed.endIndex
        ) ?? collapsed.endIndex
        let actualTrailing = collapsed.distance(from: matchRange.upperBound, to: endIndex)
        let unusedTrailing = (initialTrailing + unusedLeading) - actualTrailing

        if unusedTrailing > 0, startIndex > collapsed.startIndex {
            startIndex = collapsed.index(
                startIndex,
                offsetBy: -unusedTrailing,
                limitedBy: collapsed.startIndex
            ) ?? collapsed.startIndex
        }

        // Trim partial leading/trailing ASCII words without trimming into the match range.
        if startIndex > collapsed.startIndex {
            let maxSnap = collapsed.index(startIndex, offsetBy: 10, limitedBy: matchRange.lowerBound) ?? matchRange.lowerBound
            if let spaceIdx = collapsed[startIndex..<maxSnap].firstIndex(of: " ") {
                let candidateStart = collapsed.index(after: spaceIdx)
                if candidateStart <= matchRange.lowerBound {
                    startIndex = candidateStart
                }
            }
        }

        if endIndex < collapsed.endIndex {
            let minSnap = collapsed.index(endIndex, offsetBy: -10, limitedBy: matchRange.upperBound) ?? matchRange.upperBound
            if let spaceIdx = collapsed[minSnap..<endIndex].lastIndex(of: " "),
               spaceIdx >= matchRange.upperBound {
                endIndex = spaceIdx
            }
        }

        let prefixEllipsis = startIndex > collapsed.startIndex ? "…" : ""
        let suffixEllipsis = endIndex < collapsed.endIndex ? "…" : ""
        let snippetBody = collapsed[startIndex..<endIndex].trimmingCharacters(in: .whitespaces)
        return "\(prefixEllipsis)\(snippetBody)\(suffixEllipsis)"
    }

    // MARK: - Private Helpers

    private nonisolated static func resolvedConversationTitle(primary: String, fallback: String?) -> String {
        let trimmedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrimary.isEmpty {
            return trimmedPrimary
        }
        if let fallback {
            let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedFallback.isEmpty {
                return trimmedFallback
            }
        }
        return "Untitled"
    }

    private nonisolated static func extractFirstTurnSnippet(
        in turns: [ChatTurn],
        matching query: String
    ) -> String? {
        for turn in turns.reversed() {
            if let promptSnippet = extractCenteredSnippet(from: turn.userPrompt, matching: query) {
                return promptSnippet
            }
            let markdown = turn.assistantMarkdown
            if !markdown.isEmpty,
               let assistantSnippet = extractCenteredSnippet(from: markdown, matching: query) {
                return assistantSnippet
            }
            for part in turn.assistantParts {
                if case .unsupportedArtifact(let card) = part {
                    if let titleSnippet = extractCenteredSnippet(from: card.title, matching: query) {
                        return titleSnippet
                    }
                    if let content = card.content,
                       let contentSnippet = extractCenteredSnippet(from: content, matching: query) {
                        return contentSnippet
                    }
                }
            }
        }
        return nil
    }

    private nonisolated static func collapseWhitespaceToSingleLine(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(min(text.count, 1024))
        var previousWasWhitespace = true

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !previousWasWhitespace {
                    result.append(" ")
                    previousWasWhitespace = true
                }
            } else {
                result.unicodeScalars.append(scalar)
                previousWasWhitespace = false
            }
        }

        if result.last == " " {
            result.removeLast()
        }
        return result
    }
}
