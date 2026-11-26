import Foundation

// MARK: - QuotedPassage

/// A passage selected from an assistant turn and staged as a structured quote for follow-up or `Btw`.
nonisolated struct QuotedPassage: Identifiable, Codable, Equatable, Hashable, Sendable {

    static let maxCharacterCount = 2000
    static let maxStagedCount = 5

    let id: UUID
    let quotedText: String
    let conversationId: String?
    let turnId: String?

    init(
        id: UUID = UUID(),
        quotedText: String,
        conversationId: String? = nil,
        turnId: String? = nil
    ) {
        self.id = id
        let trimmed = quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > Self.maxCharacterCount {
            self.quotedText = String(trimmed.prefix(Self.maxCharacterCount))
        } else {
            self.quotedText = trimmed
        }
        self.conversationId = conversationId
        self.turnId = turnId
    }

    /// Formats non-empty staged quotes as Markdown blockquotes prepended above `prompt`.
    static func formatPrompt(_ prompt: String, with quotes: [QuotedPassage]) -> String {
        let blocks: [String] = quotes.compactMap { passage in
            let trimmed = passage.quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            let normalized = trimmed
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            return normalized
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
        }

        guard !blocks.isEmpty else {
            return prompt
        }

        let quotedHeader = blocks.joined(separator: "\n\n")
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return quotedHeader
        }
        return "\(quotedHeader)\n\n\(prompt)"
    }
}

// MARK: - RegenerateVariant

/// Supported response regeneration variants for the latest assistant turn.
nonisolated enum RegenerateVariant: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case tryAgain
    case shorter
    case longer
    case simpler
    case casual
    case professional
    case retryWithoutTools

    var id: String { rawValue }

    /// Verified Gemini follow-up regenerate option code when exposed on `StreamGenerateResponse`.
    var geminiOptionCode: Int? {
        switch self {
        case .tryAgain:
            return 1001
        case .shorter:
            return 1005
        case .longer:
            return 1004
        case .simpler, .casual, .professional, .retryWithoutTools:
            return nil
        }
    }
}

// MARK: - ShareLinkScope

/// Scope targeted when creating a public `gemini.google.com/share/<id>` link.
nonisolated enum ShareLinkScope: Equatable, Hashable, Codable, Sendable {
    case entireConversation
    case singleTurn(requestId: String, responseId: String?)
}

// MARK: - ShareLinkResult

/// Public share URL and opaque server tokens returned by `useCreatePublicShareLinkMutation`.
nonisolated struct ShareLinkResult: Equatable, Hashable, Codable, Sendable {

    let url: URL
    let externalUrlId: String?
    let shareToken: String?

    init(
        url: URL,
        externalUrlId: String? = nil,
        shareToken: String? = nil
    ) {
        self.url = url
        self.externalUrlId = externalUrlId
        self.shareToken = shareToken
    }
}

// MARK: - CloudExportService

/// Target Google cloud destination for `useExportMessageMutation`.
nonisolated enum CloudExportService: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case docs = "EXPORT_SERVICE_DOCS"
    case gmail = "EXPORT_SERVICE_GMAIL"
    case colab = "EXPORT_SERVICE_COLAB"
    case sheets = "EXPORT_SERVICE_SHEETS"

    var id: String { rawValue }
}

// MARK: - SearchHitSource

/// Origin tier that produced a `ConversationSearchHit` in hybrid `⌘K` search.
nonisolated enum SearchHitSource: String, Codable, Equatable, Hashable, Sendable {
    case localCache
    case cloudSemantic
    case merged
}

// MARK: - ConversationSearchHit

/// Single search result surfaced in the global `⌘K` hybrid conversation search palette.
nonisolated struct ConversationSearchHit: Identifiable, Codable, Equatable, Hashable, Sendable {

    let id: String
    let conversationId: String
    let title: String
    let snippet: String?
    let updatedAt: Date?
    let source: SearchHitSource

    init(
        id: String? = nil,
        conversationId: String,
        title: String,
        snippet: String? = nil,
        updatedAt: Date? = nil,
        source: SearchHitSource
    ) {
        self.id = id ?? conversationId
        self.conversationId = conversationId
        self.title = title
        self.snippet = snippet
        self.updatedAt = updatedAt
        self.source = source
    }
}

// MARK: - GeminiTransportActionError

/// Typed failures emitted by `v2.2` transport actions (Omakase GraphQL & DOM fallbacks).
nonisolated enum GeminiTransportActionError: Error, Equatable, LocalizedError, Sendable {
    case unsupported
    case invalidArguments(String)
    case graphQLError(code: Int?, message: String)
    case targetNotPersisted
    case malformedResponse(String)
    case authenticationUnavailable
    case invalidArtifactURL(String)
    case fallbackUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return String(localized: "This action is not supported by the active transport.")
        case .invalidArguments(let detail):
            return detail
        case .graphQLError(let code, let message):
            if let code {
                return "\(message) (code \(code))"
            }
            return message
        case .targetNotPersisted:
            return String(localized: "Gemini has not finished saving this conversation yet. Please try again in a moment.")
        case .malformedResponse(let detail):
            return detail
        case .authenticationUnavailable:
            return String(localized: "Sign in to Gemini to perform this action.")
        case .invalidArtifactURL(let detail):
            return detail
        case .fallbackUnavailable(let detail):
            return detail
        }
    }
}
