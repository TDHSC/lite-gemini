import Foundation

// MARK: - ChatTransportError

/// Structured failures emitted by `ChatTransport` implementations.
nonisolated enum ChatTransportError: Error, Equatable, LocalizedError, Sendable {
    case notSignedIn
    case conversationNotFound(id: String)
    case streamStartTimeout
    case challengeRequired(ChallengeBannerState)
    case actionDriverFailed(reason: String)
    case modelUnavailable(id: String)
    case attachmentRejected(reason: String)
    case cancelled
    case networkError(message: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to Gemini to continue."
        case .conversationNotFound:
            return "This conversation could not be found."
        case .streamStartTimeout:
            return "Gemini did not respond in time. Your message has been restored."
        case .challengeRequired(let banner):
            return banner.message
        case .actionDriverFailed(let reason):
            return reason
        case .modelUnavailable(let id):
            return "Model \(id) is currently unavailable."
        case .attachmentRejected(let reason):
            return reason
        case .cancelled:
            return "Generation cancelled."
        case .networkError(let message):
            return message
        }
    }
}

// MARK: - HomeLoadResult

/// Initial session payload returned when loading Gemini's `/app` home surface or switching accounts.
nonisolated struct HomeLoadResult: Equatable, Sendable {

    let authState: AuthState
    let recentConversations: [ConversationSummary]
    let availableModels: [ModelOption]
    let selectedModelId: String?
    let isTemporaryChat: Bool

    init(
        authState: AuthState,
        recentConversations: [ConversationSummary] = [],
        availableModels: [ModelOption] = [],
        selectedModelId: String? = nil,
        isTemporaryChat: Bool = false
    ) {
        self.authState = authState
        self.recentConversations = recentConversations
        self.availableModels = availableModels
        self.selectedModelId = selectedModelId
        self.isTemporaryChat = isTemporaryChat
    }
}

// MARK: - ChatTransportEvent

/// Out-of-band events pushed by a `ChatTransport` as the underlying session observes page or network changes.
nonisolated enum ChatTransportEvent: Equatable, Sendable {
    case authStateChanged(AuthState)
    case recentConversationsUpdated([ConversationSummary])
    case conversationSynced(ConversationSnapshot)
    case conversationNotFound(conversationId: String)
    case modelsUpdated(available: [ModelOption], selectedId: String?)
    case temporaryChatStateChanged(Bool)
    case challengeEncountered(ChallengeBannerState)
    case challengeCleared
}

// MARK: - ChatTransport

/// Abstraction decoupling observable stores from the hidden `WKWebView` Session Bridge so stores are
/// 100% testable with headless mock transports.
@MainActor
protocol ChatTransport: AnyObject {

    /// Event callback invoked on `@MainActor` for asynchronous bridge updates.
    var onEvent: (@MainActor (ChatTransportEvent) -> Void)? { get set }

    /// Loads `/app` for the specified account index and desired temporary-chat mode.
    func loadHome(authUser: Int?, temporaryChat: Bool) async throws -> HomeLoadResult

    /// Loads and returns the authoritative server snapshot for a conversation.
    func loadConversation(id: String, authUser: Int?) async throws -> ConversationSnapshot

    /// Refreshes the recent conversations list for the active account.
    func refreshRecentConversations() async throws -> [ConversationSummary]

    /// Submits a prompt and optional attachments, returning a stream of cumulative response deltas.
    func sendPrompt(
        text: String,
        attachments: [StagedAttachment],
        modelId: String?,
        isTemporaryChat: Bool
    ) -> AsyncThrowingStream<StreamingDelta, Error>

    /// Stops any active response generation in the underlying session.
    func stopStreaming() async

    /// Replaces the most recent user prompt and streams the regenerated assistant response.
    func editLastTurn(newText: String) -> AsyncThrowingStream<StreamingDelta, Error>

    /// Regenerates the most recent assistant response and streams the replacement.
    func regenerateLastTurn() -> AsyncThrowingStream<StreamingDelta, Error>

    /// Selects a model option on the underlying session.
    func selectModel(id: String) async throws

    /// Synchronizes the temporary-chat toggle state on the underlying session.
    func setTemporaryChat(_ enabled: Bool) async throws

    /// Switches the active Google account to the given `?authuser=N` index.
    func switchAccount(authUserIndex: Int) async throws -> HomeLoadResult

    /// Synchronizes an optional composer tool mode (`Canvas` or `Deep Research`) on the underlying session.
    func setComposerTool(_ tool: ComposerToolMode?) async throws

    /// Approves the pending Deep Research plan (`Start Research`) and streams the execution progress & final report.
    func confirmDeepResearchPlan() -> AsyncThrowingStream<StreamingDelta, Error>

    // MARK: - v2.2 Conversational Power Tools

    /// Submits a prompt with optional staged `QuotedPassage` entries and attachments, returning response deltas.
    func sendPrompt(
        text: String,
        quotes: [QuotedPassage],
        attachments: [StagedAttachment],
        modelId: String?,
        isTemporaryChat: Bool
    ) -> AsyncThrowingStream<StreamingDelta, Error>

    /// Submits a prompt with staged quotes and attachments, awaiting completion of the active stream.
    func sendPrompt(
        _ text: String,
        quotes: [QuotedPassage],
        attachments: [StagedAttachment]
    ) async

    /// Regenerates the latest assistant response with a specific variant and optional model switch, streaming deltas.
    func regenerateLastTurn(
        variant: RegenerateVariant,
        modelId: String?
    ) -> AsyncThrowingStream<StreamingDelta, Error>

    /// Regenerates the latest assistant response with a specific variant and optional model switch.
    func regenerateLatestResponse(variant: RegenerateVariant, modelId: String?) async

    /// Branches a conversation from the specified turn into a new chat, returning the new `conversationId`.
    func branchConversation(
        conversationId: String,
        requestId: String?,
        responseId: String?
    ) async -> String?

    /// Creates a public `gemini.google.com/share/<id>` link for the entire chat or a single turn.
    func createPublicShareLink(
        conversationId: String,
        scope: ShareLinkScope,
        selectedDraftId: String?
    ) async throws -> ShareLinkResult

    /// Exports a Markdown message to Google Docs, Gmail Drafts, Colab, or Sheets, returning the artifact URL.
    func exportToCloudService(
        service: CloudExportService,
        title: String,
        markdownText: String
    ) async throws -> URL

    /// Searches remote Gemini chat history semantically via `SearchChatsPageQuery`.
    func searchRemoteConversations(query: String, limit: Int) async -> [ConversationSearchHit]

    /// Synthesizes a spoken MP3 audio chunk for `text` in `locale` via `useResponseTtsQuery`.
    func synthesizeSpeechChunk(text: String, locale: String) async -> Data?
}

extension ChatTransport {

    func setComposerTool(_ tool: ComposerToolMode?) async throws {}

    func confirmDeepResearchPlan() -> AsyncThrowingStream<StreamingDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func sendPrompt(
        text: String,
        quotes: [QuotedPassage],
        attachments: [StagedAttachment],
        modelId: String?,
        isTemporaryChat: Bool
    ) -> AsyncThrowingStream<StreamingDelta, Error> {
        let combined = QuotedPassage.formatPrompt(text, with: quotes)
        return sendPrompt(
            text: combined,
            attachments: attachments,
            modelId: modelId,
            isTemporaryChat: isTemporaryChat
        )
    }

    func sendPrompt(
        _ text: String,
        quotes: [QuotedPassage],
        attachments: [StagedAttachment]
    ) async {
        let stream = sendPrompt(
            text: text,
            quotes: quotes,
            attachments: attachments,
            modelId: nil,
            isTemporaryChat: false
        )
        do {
            for try await _ in stream {}
        } catch {}
    }

    func regenerateLastTurn(
        variant: RegenerateVariant,
        modelId: String?
    ) -> AsyncThrowingStream<StreamingDelta, Error> {
        regenerateLastTurn()
    }

    func regenerateLatestResponse(variant: RegenerateVariant, modelId: String?) async {
        let stream = regenerateLastTurn(variant: variant, modelId: modelId)
        do {
            for try await _ in stream {}
        } catch {}
    }

    func branchConversation(
        conversationId: String,
        requestId: String?,
        responseId: String?
    ) async -> String? {
        nil
    }

    func createPublicShareLink(
        conversationId: String,
        scope: ShareLinkScope,
        selectedDraftId: String?
    ) async throws -> ShareLinkResult {
        throw GeminiTransportActionError.unsupported
    }

    func exportToCloudService(
        service: CloudExportService,
        title: String,
        markdownText: String
    ) async throws -> URL {
        throw GeminiTransportActionError.unsupported
    }

    func searchRemoteConversations(query: String, limit: Int) async -> [ConversationSearchHit] {
        []
    }

    func synthesizeSpeechChunk(text: String, locale: String) async -> Data? {
        nil
    }
}
