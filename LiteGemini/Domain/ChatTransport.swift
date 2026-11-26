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
}
