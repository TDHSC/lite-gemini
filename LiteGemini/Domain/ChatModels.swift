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

// MARK: - DeepResearchPlanStep

/// Single step in a Gemini Deep Research plan presented before multi-source execution begins.
nonisolated struct DeepResearchPlanStep: Codable, Equatable, Hashable, Identifiable, Sendable {

    let id: String
    let title: String
    let detail: String?

    init(
        id: String,
        title: String,
        detail: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

// MARK: - DeepResearchPlan

/// Structured research plan requiring user confirmation (`Start Research` / `Edit Plan`).
nonisolated struct DeepResearchPlan: Codable, Equatable, Hashable, Sendable {

    let steps: [DeepResearchPlanStep]
    let estimatedTimeText: String?
    var isConfirmed: Bool

    init(
        steps: [DeepResearchPlanStep],
        estimatedTimeText: String? = nil,
        isConfirmed: Bool = false
    ) {
        self.steps = steps
        self.estimatedTimeText = estimatedTimeText
        self.isConfirmed = isConfirmed
    }
}

// MARK: - DeepResearchProgress

/// Live execution status emitted while Gemini Deep Research browses sources and synthesizes a report.
nonisolated struct DeepResearchProgress: Codable, Equatable, Hashable, Sendable {

    let statusText: String
    let isRunning: Bool
    let browsedSourceCount: Int?

    init(
        statusText: String,
        isRunning: Bool,
        browsedSourceCount: Int? = nil
    ) {
        self.statusText = statusText
        self.isRunning = isRunning
        self.browsedSourceCount = browsedSourceCount
    }
}

// MARK: - ArtifactKind

/// Category of rich Gemini artifact surfaced as a native interactive card or fallback card.
nonisolated enum ArtifactKind: String, Codable, Equatable, Hashable, Sendable {
    case canvas
    case deepResearch
    case gem
    case extensionWidget
    case unknown
}

// MARK: - ArtifactCardInfo

/// Metadata and optional rich payload describing a Gemini Canvas document/code workspace,
/// Deep Research plan/report, or web-only fallback artifact.
///
/// All `v2.1` payload properties are optional so `v2.0` JSON snapshots on disk decode seamlessly.
nonisolated struct ArtifactCardInfo: Codable, Equatable, Hashable, Identifiable, Sendable {

    let id: String
    let kind: ArtifactKind
    let title: String
    let subtitle: String?
    let content: String?
    let language: String?
    let htmlPreviewContent: String?
    var plan: DeepResearchPlan?
    var progress: DeepResearchProgress?

    init(
        id: String,
        kind: ArtifactKind,
        title: String,
        subtitle: String? = nil,
        content: String? = nil,
        language: String? = nil,
        htmlPreviewContent: String? = nil,
        plan: DeepResearchPlan? = nil,
        progress: DeepResearchProgress? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.language = language
        self.htmlPreviewContent = htmlPreviewContent
        self.plan = plan
        self.progress = progress
    }

    /// `true` when this artifact carries native text or HTML content openable in the Split Pane.
    var hasNativeContent: Bool {
        if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let htmlPreviewContent, !htmlPreviewContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    /// `true` when this card represents a pre-execution Deep Research plan awaiting user confirmation.
    var isDeepResearchPlanCard: Bool {
        kind == .deepResearch && plan != nil && !hasNativeContent
    }

    /// Normalized lowercase language tag inferred from `language` or content prefix.
    var normalizedLanguage: String? {
        if let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !raw.isEmpty {
            return raw
        }
        guard let trimmed = content?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") {
            return "html"
        }
        if trimmed.hasPrefix("<svg") {
            return "svg"
        }
        return nil
    }

    /// `true` when this Canvas/Report artifact can render inside the sandboxed live `Preview` tab.
    var supportsLiveWebPreview: Bool {
        if let htmlPreviewContent, !htmlPreviewContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let lang = normalizedLanguage else {
            return false
        }
        if lang == "html" || lang == "htm" || lang == "svg" {
            return true
        }
        if lang == "xml",
           let trimmed = content?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           trimmed.contains("<svg") {
            return true
        }
        return false
    }

    /// `true` when this artifact represents a source code workspace rather than prose Markdown.
    var isCodeWorkspace: Bool {
        guard let lang = normalizedLanguage else {
            return false
        }
        return lang != "markdown" && lang != "md" && lang != "text" && lang != "plaintext"
    }

    ///Suggested file extension when exporting or saving this artifact to disk.
    var suggestedFileExtension: String {
        switch normalizedLanguage {
        case "html", "htm": return "html"
        case "svg": return "svg"
        case "swift": return "swift"
        case "python", "py": return "py"
        case "javascript", "js": return "js"
        case "typescript", "ts": return "ts"
        case "tsx": return "tsx"
        case "jsx": return "jsx"
        case "css": return "css"
        case "json": return "json"
        case "rust", "rs": return "rs"
        case "go": return "go"
        case "java": return "java"
        case "c": return "c"
        case "cpp", "c++", "cxx": return "cpp"
        case "sh", "bash", "zsh": return "sh"
        case "yaml", "yml": return "yaml"
        case "sql": return "sql"
        default: return isCodeWorkspace ? (normalizedLanguage ?? "txt") : "md"
        }
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
    var quotedPassages: [QuotedPassage]?
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
        quotedPassages: [QuotedPassage]? = nil,
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
        self.quotedPassages = quotedPassages
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

    /// `true` when this turn contains at least one rich artifact (Canvas, Deep Research, Gem, or extension).
    var hasArtifacts: Bool {
        assistantParts.contains { part in
            if case .unsupportedArtifact = part {
                return true
            }
            return false
        }
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
