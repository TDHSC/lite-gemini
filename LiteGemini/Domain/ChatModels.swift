import Foundation

// MARK: - ConversationSummary

/// Lightweight summary of a recent Gemini conversation displayed in the Recent Chats popover.
nonisolated struct ConversationSummary: Codable, Equatable, Hashable, Identifiable, Sendable {

    let id: String
    let title: String
    let updatedAt: Date
    let isPinned: Bool

    init(
        id: String,
        title: String,
        updatedAt: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.isPinned = isPinned
    }
}

// MARK: - CitationLink

/// Grounding citation link returned alongside an assistant response.
nonisolated struct CitationLink: Codable, Equatable, Hashable, Identifiable, Sendable {

    let id: String
    let title: String
    let url: URL
    let domain: String?

    /// Display domain preferring the explicit `domain` field and falling back to the URL host.
    var resolvedDomain: String? {
        if let domain, !domain.isEmpty {
            return domain
        }
        return url.host
    }

    init(
        id: String,
        title: String,
        url: URL,
        domain: String? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.domain = domain
    }
}

// MARK: - ImageAttachment

/// Inline or generated image referenced inside an assistant message.
nonisolated struct ImageAttachment: Codable, Equatable, Hashable, Identifiable, Sendable {

    let id: String
    let url: URL
    let altText: String?
    let width: Int?
    let height: Int?
    let suggestedFilename: String

    init(
        id: String,
        url: URL,
        altText: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        suggestedFilename: String
    ) {
        self.id = id
        self.url = url
        self.altText = altText
        self.width = width
        self.height = height
        self.suggestedFilename = suggestedFilename
    }
}

// MARK: - ArtifactKind

/// Category of web-only rich artifact surfaced as a fallback card in Native Mode.
nonisolated enum ArtifactKind: String, Codable, Equatable, Hashable, Sendable {
    case canvas
    case deepResearch
    case gem
    case extensionWidget
    case unknown
}

// MARK: - ArtifactCardInfo

/// Metadata describing an unsupported rich web artifact with an "Open in Web" escape hatch.
nonisolated struct ArtifactCardInfo: Codable, Equatable, Hashable, Identifiable, Sendable {

    let id: String
    let kind: ArtifactKind
    let title: String
    let subtitle: String?

    init(
        id: String,
        kind: ArtifactKind,
        title: String,
        subtitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
    }
}

// MARK: - MessagePart

/// Structured content segment rendered inside an assistant turn.
nonisolated enum MessagePart: Codable, Equatable, Hashable, Sendable {
    case markdown(String)
    case inlineImage(ImageAttachment)
    case unsupportedArtifact(ArtifactCardInfo)
}

// MARK: - TurnResponseMetadata

/// Canonical identifiers and telemetry attached to an assistant turn.
nonisolated struct TurnResponseMetadata: Codable, Equatable, Hashable, Sendable {

    let responseId: String?
    let choiceId: String?
    let modelId: String?
    let thinkingDurationSeconds: Double?

    init(
        responseId: String? = nil,
        choiceId: String? = nil,
        modelId: String? = nil,
        thinkingDurationSeconds: Double? = nil
    ) {
        self.responseId = responseId
        self.choiceId = choiceId
        self.modelId = modelId
        self.thinkingDurationSeconds = thinkingDurationSeconds
    }
}

// MARK: - ChatTurn

/// Single prompt-and-response pair within a conversation timeline.
nonisolated struct ChatTurn: Codable, Equatable, Hashable, Identifiable, Sendable {

    let id: String
    var userPrompt: String
    var userAttachments: [StagedAttachmentSummary]
    var assistantParts: [MessagePart]
    var thinkingText: String?
    var isThinkingComplete: Bool
    var citations: [CitationLink]
    var metadata: TurnResponseMetadata
    let createdAt: Date

    init(
        id: String,
        userPrompt: String,
        userAttachments: [StagedAttachmentSummary] = [],
        assistantParts: [MessagePart] = [],
        thinkingText: String? = nil,
        isThinkingComplete: Bool = true,
        citations: [CitationLink] = [],
        metadata: TurnResponseMetadata = TurnResponseMetadata(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userPrompt = userPrompt
        self.userAttachments = userAttachments
        self.assistantParts = assistantParts
        self.thinkingText = thinkingText
        self.isThinkingComplete = isThinkingComplete
        self.citations = citations
        self.metadata = metadata
        self.createdAt = createdAt
    }

    /// Concatenated Markdown prose across all `.markdown` parts of the assistant response.
    var assistantMarkdown: String {
        assistantParts.compactMap { part in
            if case .markdown(let text) = part, !text.isEmpty {
                return text
            }
            return nil
        }.joined(separator: "\n\n")
    }
}

// MARK: - ConversationSnapshot

/// Complete, server-acknowledged conversation snapshot stored atomically per account scope.
nonisolated struct ConversationSnapshot: Codable, Equatable, Sendable {

    let accountScopeId: String
    let conversationId: String
    let title: String
    let modelId: String?
    let updatedAt: Date
    let turns: [ChatTurn]

    init(
        accountScopeId: String,
        conversationId: String,
        title: String,
        modelId: String? = nil,
        updatedAt: Date = Date(),
        turns: [ChatTurn]
    ) {
        self.accountScopeId = accountScopeId
        self.conversationId = conversationId
        self.title = title
        self.modelId = modelId
        self.updatedAt = updatedAt
        self.turns = turns
    }
}

// MARK: - ModelOption

/// Model choice advertised by Gemini for the signed-in account.
nonisolated struct ModelOption: Codable, Equatable, Hashable, Identifiable, Sendable {

    let id: String
    let displayName: String
    let subtitle: String?
    let isThinkingCapable: Bool

    init(
        id: String,
        displayName: String,
        subtitle: String? = nil,
        isThinkingCapable: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.subtitle = subtitle
        self.isThinkingCapable = isThinkingCapable
    }
}

// MARK: - StreamingDelta

/// Cumulative snapshot chunk emitted during an active `StreamGenerate` response.
nonisolated struct StreamingDelta: Equatable, Sendable {

    let conversationId: String?
    let responseId: String?
    let choiceId: String?
    let thinkingText: String?
    let isThinkingComplete: Bool
    let markdownSnapshot: String
    let inlineImages: [ImageAttachment]
    let citations: [CitationLink]
    let artifacts: [ArtifactCardInfo]
    /// Signals that this delta carries the terminal server snapshot and should flush immediately.
    let isFinal: Bool

    init(
        conversationId: String? = nil,
        responseId: String? = nil,
        choiceId: String? = nil,
        thinkingText: String? = nil,
        isThinkingComplete: Bool = false,
        markdownSnapshot: String = "",
        inlineImages: [ImageAttachment] = [],
        citations: [CitationLink] = [],
        artifacts: [ArtifactCardInfo] = [],
        isFinal: Bool = false
    ) {
        self.conversationId = conversationId
        self.responseId = responseId
        self.choiceId = choiceId
        self.thinkingText = thinkingText
        self.isThinkingComplete = isThinkingComplete
        self.markdownSnapshot = markdownSnapshot
        self.inlineImages = inlineImages
        self.citations = citations
        self.artifacts = artifacts
        self.isFinal = isFinal
    }

    /// Builds ordered `MessagePart` elements from the delta's prose, images, and rich artifacts.
    var messageParts: [MessagePart] {
        var parts: [MessagePart] = []
        if !markdownSnapshot.isEmpty {
            parts.append(.markdown(markdownSnapshot))
        }
        for image in inlineImages {
            parts.append(.inlineImage(image))
        }
        for artifact in artifacts {
            parts.append(.unsupportedArtifact(artifact))
        }
        return parts
    }
}
