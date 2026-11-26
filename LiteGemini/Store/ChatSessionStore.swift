import AppKit
import Combine
import Foundation
import os

// MARK: - StreamingState

/// Live streaming lifecycle state of a `ChatSessionStore`.
nonisolated enum StreamingState: Equatable, Sendable {
    /// No response is currently being generated.
    case idle
    /// Request has been dispatched to the transport and is waiting for the first `StreamingDelta`.
    case awaitingFirstDelta(turnId: String)
    /// Actively receiving streaming deltas for the trailing turn.
    case streaming(
        turnId: String,
        thinkingText: String?,
        isThinkingComplete: Bool,
        markdownSnapshot: String,
        inlineImages: [ImageAttachment],
        citations: [CitationLink],
        artifacts: [ArtifactCardInfo]
    )

    /// Whether a generation request is currently in flight.
    var isActive: Bool {
        switch self {
        case .idle:
            return false
        case .awaitingFirstDelta, .streaming:
            return true
        }
    }

    /// Identifier of the turn currently awaiting or receiving streaming deltas, if any.
    var activeTurnId: String? {
        switch self {
        case .idle:
            return nil
        case .awaitingFirstDelta(let turnId):
            return turnId
        case .streaming(let turnId, _, _, _, _, _, _):
            return turnId
        }
    }
}

// MARK: - ChatSessionStore

/// Reusable `@MainActor` single-conversation engine shared identically by both Main Window
/// (`MainWorkspaceStore`) and Quick Mode (`QuickWorkspaceController`).
///
/// Owns turns, 60fps streaming delta coalescing, `ComposerDraftState`, 15-second stream-start
/// timeout with automatic draft rollback, and privacy-preserving SWR cache writes.
@MainActor
final class ChatSessionStore: ObservableObject {

    // MARK: - Types

    private enum StreamOperation {
        case send(rollback: DraftRollbackSnapshot)
        case edit(originalTurn: ChatTurn, rollback: DraftRollbackSnapshot)
        case regenerate(originalTurn: ChatTurn, previousModelId: String?)
        case deepResearchConfirm
    }

    private struct ActiveStreamContext {
        let generation: UInt64
        let turnIndex: Int
        let optimisticTurnId: String
        let operation: StreamOperation
        var thinkingStartedAt: ContinuousClock.Instant?
        var thinkingDurationSeconds: Double?
        var receivedFirstDelta: Bool = false
        var lastFlushedDelta: StreamingDelta?
        var pendingDelta: StreamingDelta?
        var didTimeout: Bool = false
        var wasExplicitlyStopped: Bool = false
    }

    // MARK: - Constants

    static let defaultStreamStartTimeout: Duration = .seconds(15)
    static let defaultStreamCoalesceInterval: Duration = .milliseconds(16)

    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "ChatSessionStore")

    // MARK: - Published State

    /// Canonical Gemini conversation ID, or `nil` for a fresh unsent chat or temporary session.
    @Published private(set) var conversationId: String?
    /// Display title of the active conversation.
    @Published private(set) var title: String = ""
    /// Ordered conversation turns currently shown in the timeline.
    @Published private(set) var turns: [ChatTurn] = []
    /// Live streaming state for the trailing turn.
    @Published private(set) var streamingState: StreamingState = .idle
    /// Models advertised by Gemini for the signed-in account.
    @Published private(set) var availableModels: [ModelOption] = []
    /// Currently selected model identifier.
    @Published var selectedModelId: String?
    /// Whether this session is ephemeral (zero disk writes, omitted from Recent Chats).
    @Published private(set) var isTemporaryChat: Bool
    /// Actionable mid-session auth challenge or bridge fallback banner.
    @Published var challengeBanner: ChallengeBannerState?
    /// Whether a background server sync/revalidation is in progress.
    @Published private(set) var isSyncing: Bool = false
    /// Most recent user-facing error message, cleared on the next action.
    @Published var lastErrorMessage: String?
    /// Currently inspected Canvas or Deep Research Report artifact in the Main Window Split Pane.
    @Published var selectedArtifact: ArtifactCardInfo?
    /// Whether `selectedArtifact` should auto-open once a new Canvas/Report artifact arrives in this session.
    var autoOpenNativeArtifacts: Bool = false

    // MARK: - v2.2 Share, Export, Branch & Speech State

    /// Active public share link confirmation banner payload, or `nil` when hidden.
    @Published var activeShareLinkResult: ShareLinkResult? = nil
    /// Whether a `useCreatePublicShareLinkMutation` request is currently in flight.
    @Published private(set) var isCreatingShareLink: Bool = false
    /// Whether a PDF or Google Cloud export is currently in flight.
    @Published private(set) var isExportingDocument: Bool = false
    /// Identifier of the turn currently being branched, or `nil` when idle.
    @Published private(set) var branchingTurnId: String? = nil
    /// Transient confirmation pill message (e.g. `"Branched into a new chat"`).
    @Published var transientStatusMessage: String? = nil

    /// Workspace-scoped neural TTS playback controller for assistant turns.
    let speechController = TurnSpeechController()

    /// Shared composer draft state (survives Quick Mode pre-send hide/show cycles).
    let draft: ComposerDraftState

    /// Active account scope identifier used to partition SWR disk cache writes.
    private(set) var accountScopeId: String?

    /// Number of coalesced UI delta flushes applied (exposed for deterministic coalescing tests).
    private(set) var coalescedFlushCount: Int = 0

    // MARK: - Parent Hooks

    /// Invoked after a non-temporary stream completes with a server-acknowledged snapshot.
    var onConversationCompleted: (@MainActor (ConversationSnapshot) -> Void)?
    /// Invoked synchronously when the user initiates a prompt send (e.g., to expand Quick Mode).
    var onFirstSendAttempted: (@MainActor () -> Void)?
    /// Invoked when the user submits a `/btw <question>` slash command from the composer.
    var onTriggerBtwSlashCommand: (@MainActor (String, [QuotedPassage]) -> Void)?
    /// Invoked when a conversation branch succeeds with the newly created `conversationId`.
    var onBranchedConversationCreated: (@MainActor (String) async -> Void)?

    // MARK: - Computed Properties

    /// Whether a prompt, edit, or regeneration stream is currently in flight.
    var isStreaming: Bool {
        streamingState.isActive
    }

    /// Whether the session contains at least one turn.
    var hasTurns: Bool {
        !turns.isEmpty
    }

    /// Whether the latest user turn can be edited.
    var canEditLastTurn: Bool {
        !isStreaming && !turns.isEmpty
    }

    /// Whether the latest assistant turn can be regenerated.
    var canRegenerateLastTurn: Bool {
        !isStreaming && !turns.isEmpty
    }

    // MARK: - Dependencies

    let transport: any ChatTransport
    let cache: SWRConversationCache?
    let streamStartTimeout: Duration
    let streamCoalesceInterval: Duration

    private var streamGeneration: UInt64 = 0
    private var activeStreamContext: ActiveStreamContext?
    private var streamTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var coalesceTask: Task<Void, Never>?
    private var transientStatusTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        transport: any ChatTransport,
        cache: SWRConversationCache? = nil,
        draft: ComposerDraftState = ComposerDraftState(),
        initialTemporaryChat: Bool = false,
        accountScopeId: String? = nil,
        streamStartTimeout: Duration = ChatSessionStore.defaultStreamStartTimeout,
        streamCoalesceInterval: Duration = ChatSessionStore.defaultStreamCoalesceInterval,
        attachToTransportEvents: Bool = true
    ) {
        self.transport = transport
        self.cache = cache
        self.draft = draft
        self.isTemporaryChat = initialTemporaryChat
        self.accountScopeId = accountScopeId
        self.streamStartTimeout = streamStartTimeout
        self.streamCoalesceInterval = streamCoalesceInterval

        if attachToTransportEvents {
            transport.onEvent = { [weak self] event in
                self?.handleTransportEvent(event)
            }
        }
    }

    isolated deinit {
        cancelStreamTasks()
        transientStatusTask?.cancel()
        speechController.stop()
    }

    // MARK: - Public Actions

    /// Alias for `send()` submitting the current composer draft.
    func sendCurrentDraft() async {
        await send()
    }

    /// Submits the current draft as a new turn, intercepts `/btw` side commands,
    /// or commits an in-progress edit of the latest turn.
    func send() async {
        if !draft.isEditing {
            let slash = BtwPromptBuilder.parseSlashCommand(draft.text)
            if slash.matched, let onTriggerBtwSlashCommand {
                let stagedQuotes = draft.quotes
                draft.text = ""
                draft.clearQuotes()
                onTriggerBtwSlashCommand(slash.question, stagedQuotes)
                return
            }
        }

        guard !isStreaming, draft.canSubmit else {
            return
        }

        if draft.isEditing {
            await commitEditLastTurn()
            return
        }

        let wasEmpty = turns.isEmpty
        let rollback = draft.takeSnapshotForOptimisticSend()
        lastErrorMessage = nil
        challengeBanner = nil

        let optimisticId = "optimistic-\(UUID().uuidString)"
        let optimisticTurn = ChatTurn(
            id: optimisticId,
            userPrompt: rollback.text,
            userAttachments: rollback.stagedAttachments.map(\.summary),
            quotedPassages: rollback.quotes.isEmpty ? nil : rollback.quotes,
            assistantParts: [],
            thinkingText: nil,
            isThinkingComplete: false,
            citations: [],
            metadata: TurnResponseMetadata(modelId: selectedModelId),
            createdAt: Date()
        )
        turns.append(optimisticTurn)
        let turnIndex = turns.count - 1

        if wasEmpty {
            onFirstSendAttempted?()
        }

        if let toolMode = rollback.activeToolMode {
            try? await transport.setComposerTool(toolMode)
        }

        let stream = transport.sendPrompt(
            text: rollback.text,
            quotes: rollback.quotes,
            attachments: rollback.stagedAttachments,
            modelId: selectedModelId,
            isTemporaryChat: isTemporaryChat
        )

        let customTimeout: Duration? = rollback.activeToolMode == .deepResearch ? .seconds(120) : nil
        await executeStream(
            stream: stream,
            turnIndex: turnIndex,
            optimisticTurnId: optimisticId,
            operation: .send(rollback: rollback),
            customStartTimeout: customTimeout
        )
    }

    /// Sets or clears the active composer tool mode (`Canvas` or `Deep Research`) and syncs the transport.
    func setToolMode(_ mode: ComposerToolMode?) async {
        draft.activeToolMode = mode
        try? await transport.setComposerTool(mode)
    }

    /// Approves a pending Deep Research plan card (`Start Research`) and streams live search progress & final report.
    func confirmDeepResearchPlan(for planArtifact: ArtifactCardInfo) async {
        guard !isStreaming else {
            return
        }
        lastErrorMessage = nil
        challengeBanner = nil

        for tIdx in turns.indices {
            for pIdx in turns[tIdx].assistantParts.indices {
                if case .unsupportedArtifact(var card) = turns[tIdx].assistantParts[pIdx],
                   card.id == planArtifact.id,
                   var existingPlan = card.plan {
                    existingPlan.isConfirmed = true
                    card.plan = existingPlan
                    turns[tIdx].assistantParts[pIdx] = .unsupportedArtifact(card)
                }
            }
        }

        let optimisticId = "optimistic-research-\(UUID().uuidString)"
        let researchTurn = ChatTurn(
            id: optimisticId,
            userPrompt: String(localized: "Start Research"),
            userAttachments: [],
            assistantParts: [
                .unsupportedArtifact(
                    ArtifactCardInfo(
                        id: "deep-research-progress",
                        kind: .deepResearch,
                        title: planArtifact.title,
                        subtitle: String(localized: "Starting Deep Research…"),
                        progress: DeepResearchProgress(
                            statusText: String(localized: "Starting Deep Research…"),
                            isRunning: true
                        )
                    )
                )
            ],
            thinkingText: nil,
            isThinkingComplete: false,
            citations: [],
            metadata: TurnResponseMetadata(modelId: selectedModelId),
            createdAt: Date()
        )
        turns.append(researchTurn)
        let turnIndex = turns.count - 1

        let stream = transport.confirmDeepResearchPlan()
        await executeStream(
            stream: stream,
            turnIndex: turnIndex,
            optimisticTurnId: optimisticId,
            operation: .deepResearchConfirm,
            customStartTimeout: .seconds(300)
        )
    }

    /// Stops an active generation immediately, preserving any already-received tokens in memory
    /// without writing partial state to disk (or rolling back the draft if no token arrived yet).
    func stop() async {
        guard let context = activeStreamContext else {
            return
        }

        activeStreamContext?.wasExplicitlyStopped = true
        streamGeneration &+= 1
        cancelStreamTasks()

        if !context.receivedFirstDelta {
            rollbackOperation(context.operation, turnIndex: context.turnIndex)
        } else {
            flushPendingDelta(in: context.turnIndex)
            finalizePartialTurnInMemory(at: context.turnIndex)
        }

        streamingState = .idle
        activeStreamContext = nil
        await transport.stopStreaming()
    }

    /// Loads the latest user turn's prompt into the composer for editing.
    func beginEditingLastTurn() {
        guard canEditLastTurn, let lastTurn = turns.last else {
            return
        }
        draft.beginEditing(
            turnId: lastTurn.id,
            prompt: lastTurn.userPrompt,
            quotes: lastTurn.quotedPassages ?? []
        )
    }

    /// Cancels an active turn edit and clears the composer draft.
    func cancelEditing() {
        draft.cancelEditing()
    }

    /// Regenerates the assistant response for the latest turn using `.tryAgain`, restoring on failure.
    func regenerateLastTurn() async {
        await regenerateLatestTurn(variant: .tryAgain, modelId: nil)
    }

    /// Regenerates the assistant response for the latest turn with a specific length/tone/no-tool
    /// variant and optional model switch, restoring the original turn on pre-delta failure.
    func regenerateLatestTurn(
        variant: RegenerateVariant = .tryAgain,
        modelId: String? = nil
    ) async {
        guard canRegenerateLastTurn else {
            return
        }

        speechController.stop()

        let turnIndex = turns.count - 1
        let originalTurn = turns[turnIndex]
        let previousModelId = selectedModelId
        if let modelId = modelId?.trimmingCharacters(in: .whitespacesAndNewlines), !modelId.isEmpty {
            selectedModelId = modelId
        }

        lastErrorMessage = nil
        challengeBanner = nil

        turns[turnIndex].assistantParts = []
        turns[turnIndex].thinkingText = nil
        turns[turnIndex].isThinkingComplete = false
        turns[turnIndex].citations = []
        turns[turnIndex].metadata = TurnResponseMetadata(modelId: selectedModelId)

        let stream: AsyncThrowingStream<StreamingDelta, Error>
        if variant == .tryAgain && (modelId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            stream = transport.regenerateLastTurn()
        } else {
            stream = transport.regenerateLastTurn(variant: variant, modelId: modelId)
        }

        await executeStream(
            stream: stream,
            turnIndex: turnIndex,
            optimisticTurnId: originalTurn.id,
            operation: .regenerate(originalTurn: originalTurn, previousModelId: previousModelId)
        )
    }

    /// Branches a new conversation starting from `turn`, seeding the local cache for 0ms visual
    /// continuity, navigating to the new conversation, and refreshing Recent Chats.
    func branchFromTurn(_ turn: ChatTurn) async {
        guard !isStreaming, !isTemporaryChat, branchingTurnId == nil else {
            return
        }
        guard let sourceConversationId = conversationId, !sourceConversationId.isEmpty else {
            lastErrorMessage = String(localized: "Finish sending this conversation before branching.")
            return
        }
        guard let turnIndex = turns.firstIndex(where: { $0.id == turn.id }) else {
            return
        }

        branchingTurnId = turn.id
        defer { branchingTurnId = nil }
        lastErrorMessage = nil

        let resolvedRequestId = Self.serverRequestId(for: turn)
        let resolvedResponseId = Self.serverDraftResponseId(for: turn)

        guard let newConversationId = await transport.branchConversation(
            conversationId: sourceConversationId,
            requestId: resolvedRequestId,
            responseId: resolvedResponseId
        ), !newConversationId.isEmpty else {
            lastErrorMessage = String(localized: "Unable to branch this conversation right now.")
            return
        }

        let seededTurns = Array(turns[...turnIndex])
        let seededSnapshot = ConversationSnapshot(
            accountScopeId: accountScopeId ?? "",
            conversationId: newConversationId,
            title: title,
            modelId: selectedModelId,
            updatedAt: Date(),
            turns: seededTurns
        )

        if let scopeId = accountScopeId, !scopeId.isEmpty {
            cache?.saveConversation(seededSnapshot, isTemporaryChat: false)
        }

        speechController.stop()

        if let onBranchedConversationCreated {
            await onBranchedConversationCreated(newConversationId)
        } else {
            applySnapshot(seededSnapshot, persistToCache: false)
        }

        showTransientStatus(String(localized: "Branched into a new chat"))
    }

    // MARK: - Share, Export & Speech Actions

    /// Creates a public `gemini.google.com/share/<id>` link for either a single turn or the entire
    /// chat, copies the URL to `NSPasteboard.general`, and surfaces `activeShareLinkResult`.
    func createPublicShareLink(for turn: ChatTurn? = nil) async {
        guard !isTemporaryChat, !isCreatingShareLink else {
            return
        }
        guard let convId = conversationId, !convId.isEmpty else {
            lastErrorMessage = String(localized: "Finish sending this conversation before sharing.")
            return
        }

        let scope: ShareLinkScope
        let selectedDraftId: String?
        if let turn {
            guard let reqId = Self.serverRequestId(for: turn) else {
                lastErrorMessage = String(localized: "Finish sending this conversation before sharing.")
                return
            }
            scope = .singleTurn(requestId: reqId, responseId: Self.serverDraftResponseId(for: turn))
            selectedDraftId = Self.serverDraftResponseId(for: turn) ?? turns.last.flatMap(Self.serverDraftResponseId(for:))
        } else {
            scope = .entireConversation
            selectedDraftId = turns.last.flatMap(Self.serverDraftResponseId(for:))
        }

        isCreatingShareLink = true
        defer { isCreatingShareLink = false }
        lastErrorMessage = nil

        do {
            let result = try await transport.createPublicShareLink(
                conversationId: convId,
                scope: scope,
                selectedDraftId: selectedDraftId
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.url.absoluteString, forType: .string)
            activeShareLinkResult = result
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Dismisses the floating share-link confirmation banner pill.
    func dismissShareLinkBanner() {
        activeShareLinkResult = nil
    }

    /// Exports either a single turn or the full conversation as a local `.md` file via `NSSavePanel`.
    func exportMarkdown(turn: ChatTurn? = nil) {
        let exportTitle = resolvedExportTitle
        let markdown: String
        if let turn {
            markdown = ConversationDocumentExporter.formatTurnMarkdown(title: exportTitle, turn: turn)
        } else {
            markdown = ConversationDocumentExporter.formatConversationMarkdown(
                title: exportTitle,
                conversationId: conversationId,
                turns: turns
            )
        }
        ConversationDocumentExporter.saveMarkdownPanel(defaultFilename: exportTitle, markdown: markdown)
    }

    /// Renders either a single turn or the full conversation as a paginated `.pdf` file via `NSSavePanel`.
    func exportPDF(turn: ChatTurn? = nil) async {
        guard !isExportingDocument else {
            return
        }
        isExportingDocument = true
        defer { isExportingDocument = false }

        let exportTitle = resolvedExportTitle
        if let turn {
            await ConversationDocumentExporter.exportTurnPDFPanel(title: exportTitle, turn: turn)
        } else {
            await ConversationDocumentExporter.exportPDFPanel(
                title: exportTitle,
                conversationId: conversationId,
                turns: turns
            )
        }
    }

    /// Exports either a single turn's Markdown or the full conversation to Google Docs, Gmail Draft,
    /// Colab, or Sheets, opening the resulting artifact URL in the default browser.
    func exportToCloud(service: CloudExportService, turn: ChatTurn? = nil) async {
        guard !isExportingDocument else {
            return
        }

        let exportTitle = resolvedExportTitle
        let markdownText: String
        if let turn {
            markdownText = turn.assistantMarkdown
        } else {
            markdownText = ConversationDocumentExporter.formatConversationMarkdown(
                title: exportTitle,
                conversationId: conversationId,
                turns: turns
            )
        }

        guard !markdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        isExportingDocument = true
        defer { isExportingDocument = false }
        lastErrorMessage = nil

        do {
            let artifactURL = try await transport.exportToCloudService(
                service: service,
                title: exportTitle,
                markdownText: markdownText
            )
            NSWorkspace.shared.open(artifactURL)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Starts, pauses, or resumes neural TTS playback for `turn` via `transport.synthesizeSpeechChunk`.
    func toggleSpeech(for turn: ChatTurn) {
        let turnUUID = TurnSpeechController.stableTurnUUID(for: turn.id)
        speechController.togglePlayback(
            turnId: turnUUID,
            markdown: turn.assistantMarkdown,
            localeHint: nil
        ) { [weak self] chunkText, locale in
            guard let self else {
                return nil
            }
            return await self.transport.synthesizeSpeechChunk(text: chunkText, locale: locale)
        }
    }

    /// Synthesizes a single TTS audio chunk through the active transport.
    func synthesizeSpeechChunk(text: String, locale: String) async -> Data? {
        await transport.synthesizeSpeechChunk(text: text, locale: locale)
    }

    /// Displays a transient floating status pill for `duration` seconds.
    func showTransientStatus(_ message: String, duration: Duration = .seconds(3.5)) {
        transientStatusTask?.cancel()
        transientStatusMessage = message
        transientStatusTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self, self.transientStatusMessage == message else {
                return
            }
            self.transientStatusMessage = nil
            self.transientStatusTask = nil
        }
    }

    /// Dismisses any visible transient status pill immediately.
    func dismissTransientStatus() {
        transientStatusTask?.cancel()
        transientStatusTask = nil
        transientStatusMessage = nil
    }

    private var resolvedExportTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if let firstPrompt = turns.first?.userPrompt {
            let derived = Self.derivedTitle(from: firstPrompt)
            if !derived.isEmpty {
                return derived
            }
        }
        return "Gemini Chat"
    }

    private nonisolated static func serverRequestId(for turn: ChatTurn) -> String? {
        if let responseId = turn.metadata.responseId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !responseId.isEmpty {
            return responseId
        }
        let trimmedId = turn.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, !trimmedId.hasPrefix("optimistic-") else {
            return nil
        }
        return trimmedId
    }

    private nonisolated static func serverDraftResponseId(for turn: ChatTurn) -> String? {
        if let choiceId = turn.metadata.choiceId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !choiceId.isEmpty {
            return choiceId
        }
        return nil
    }

    /// Resets the session to a fresh conversation and reloads `/app` on the transport.
    func startNewChat(temporary: Bool? = nil, authUser: Int? = nil) async {
        speechController.stop()
        if isStreaming {
            await stop()
        }

        resetToEmptyState(temporary: temporary)
        isSyncing = true
        defer { isSyncing = false }

        do {
            let result = try await transport.loadHome(authUser: authUser, temporaryChat: isTemporaryChat)
            applyHomeMetadata(result)
        } catch let error as ChatTransportError {
            handleActionError(error)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Switches the active model on the transport, rolling back on failure.
    func selectModel(id: String) async {
        let previousModelId = selectedModelId
        selectedModelId = id
        lastErrorMessage = nil

        do {
            try await transport.selectModel(id: id)
        } catch let error as ChatTransportError {
            selectedModelId = previousModelId
            handleActionError(error)
        } catch {
            selectedModelId = previousModelId
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Synchronizes the temporary-chat toggle state with the underlying transport.
    func setTemporaryChat(_ enabled: Bool) async {
        guard isTemporaryChat != enabled else {
            return
        }

        let previous = isTemporaryChat
        isTemporaryChat = enabled
        lastErrorMessage = nil

        do {
            try await transport.setTemporaryChat(enabled)
        } catch let error as ChatTransportError {
            isTemporaryChat = previous
            handleActionError(error)
        } catch {
            isTemporaryChat = previous
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Store Coordination Helpers

    /// Synchronously clears all conversation state without invoking network I/O.
    func resetToEmptyState(temporary: Bool? = nil, preserveDraft: Bool = false) {
        abortActiveStreamWithoutTransportCall()
        speechController.stop()
        conversationId = nil
        title = ""
        turns = []
        streamingState = .idle
        challengeBanner = nil
        lastErrorMessage = nil
        selectedArtifact = nil
        activeShareLinkResult = nil
        isSyncing = false

        if let temporary {
            isTemporaryChat = temporary
        }
        if !preserveDraft {
            draft.reset()
        }
    }

    /// Updates the account scope identifier used when persisting server-acknowledged snapshots.
    func updateAccountScope(_ scopeId: String?) {
        accountScopeId = scopeId
    }

    /// Updates the background sync indicator (coordinated by `MainWorkspaceStore`).
    func setSyncing(_ syncing: Bool) {
        isSyncing = syncing
    }

    /// Replaces the entire in-memory session with an authoritative snapshot (Server-Always-Wins).
    func applySnapshot(_ snapshot: ConversationSnapshot, persistToCache: Bool) {
        abortActiveStreamWithoutTransportCall()
        if conversationId != snapshot.conversationId {
            speechController.stop()
            activeShareLinkResult = nil
        }
        accountScopeId = snapshot.accountScopeId
        conversationId = snapshot.conversationId
        title = snapshot.title
        turns = snapshot.turns
        if let modelId = snapshot.modelId {
            selectedModelId = modelId
        }
        isTemporaryChat = false
        streamingState = .idle
        challengeBanner = nil
        lastErrorMessage = nil

        if persistToCache {
            cache?.saveConversation(snapshot, isTemporaryChat: false)
        }
    }

    /// Prepares the store while fetching an uncached conversation from the transport.
    func prepareForConversationLoad(id: String) {
        abortActiveStreamWithoutTransportCall()
        speechController.stop()
        conversationId = id
        title = ""
        turns = []
        isTemporaryChat = false
        streamingState = .idle
        challengeBanner = nil
        lastErrorMessage = nil
        activeShareLinkResult = nil
        isSyncing = true
    }

    /// Applies model list and temporary-chat metadata returned by `loadHome` or `switchAccount`.
    func applyHomeMetadata(_ result: HomeLoadResult) {
        if !result.availableModels.isEmpty {
            availableModels = result.availableModels
        }
        if let selectedId = result.selectedModelId {
            selectedModelId = selectedId
        } else if selectedModelId == nil, let firstModel = availableModels.first {
            selectedModelId = firstModel.id
        }
        isTemporaryChat = result.isTemporaryChat
    }

    /// Handles out-of-band events pushed by the underlying `ChatTransport`.
    func handleTransportEvent(_ event: ChatTransportEvent) {
        switch event {
        case .conversationSynced(let snapshot):
            guard !isTemporaryChat else {
                return
            }
            if conversationId == nil || conversationId == snapshot.conversationId {
                applySnapshot(snapshot, persistToCache: true)
            }

        case .conversationNotFound(let missingId):
            cache?.evictConversation(accountScopeId: accountScopeId, conversationId: missingId)
            if conversationId == missingId {
                resetToEmptyState()
            }

        case .modelsUpdated(let available, let selectedId):
            availableModels = available
            if let selectedId {
                selectedModelId = selectedId
            } else if selectedModelId == nil {
                selectedModelId = available.first?.id
            }

        case .temporaryChatStateChanged(let enabled):
            isTemporaryChat = enabled

        case .challengeEncountered(let banner):
            haltActiveStreamForChallenge(banner)

        case .challengeCleared:
            challengeBanner = nil

        case .authStateChanged, .recentConversationsUpdated:
            break
        }
    }

    // MARK: - Private Edit Flow

    private func commitEditLastTurn() async {
        guard !turns.isEmpty, !draft.trimmedText.isEmpty else {
            return
        }

        let turnIndex = turns.count - 1
        let originalTurn = turns[turnIndex]
        let rollback = draft.takeSnapshotForOptimisticSend()
        lastErrorMessage = nil
        challengeBanner = nil

        turns[turnIndex].userPrompt = rollback.text
        turns[turnIndex].quotedPassages = rollback.quotes.isEmpty ? nil : rollback.quotes
        turns[turnIndex].assistantParts = []
        turns[turnIndex].thinkingText = nil
        turns[turnIndex].isThinkingComplete = false
        turns[turnIndex].citations = []
        turns[turnIndex].metadata = TurnResponseMetadata(modelId: selectedModelId)

        let formattedPrompt = QuotedPassage.formatPrompt(rollback.text, with: rollback.quotes)
        let stream = transport.editLastTurn(newText: formattedPrompt)
        await executeStream(
            stream: stream,
            turnIndex: turnIndex,
            optimisticTurnId: originalTurn.id,
            operation: .edit(originalTurn: originalTurn, rollback: rollback)
        )
    }

    // MARK: - Private Streaming Engine

    private func executeStream(
        stream: AsyncThrowingStream<StreamingDelta, Error>,
        turnIndex: Int,
        optimisticTurnId: String,
        operation: StreamOperation,
        customStartTimeout: Duration? = nil
    ) async {
        cancelStreamTasks()
        streamGeneration &+= 1
        let generation = streamGeneration

        activeStreamContext = ActiveStreamContext(
            generation: generation,
            turnIndex: turnIndex,
            optimisticTurnId: optimisticTurnId,
            operation: operation
        )
        streamingState = .awaitingFirstDelta(turnId: optimisticTurnId)
        scheduleStreamStartTimeout(for: generation, overrideTimeout: customStartTimeout)

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                for try await delta in stream {
                    guard self.streamGeneration == generation else {
                        return
                    }
                    self.receiveStreamingDelta(delta, generation: generation)
                }

                guard self.streamGeneration == generation else {
                    return
                }
                self.completeActiveStream(generation: generation)
            } catch {
                guard self.streamGeneration == generation else {
                    return
                }
                self.failActiveStream(error: error, generation: generation)
            }
        }

        streamTask = task
        await task.value
    }

    private func scheduleStreamStartTimeout(for generation: UInt64, overrideTimeout: Duration? = nil) {
        timeoutTask?.cancel()
        let timeout = overrideTimeout ?? streamStartTimeout
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }

            guard let self,
                  self.streamGeneration == generation,
                  let context = self.activeStreamContext,
                  !context.receivedFirstDelta else {
                return
            }

            Self.logger.error("Stream start timed out before first delta; rolling back optimistic state")
            self.activeStreamContext?.didTimeout = true
            self.streamTask?.cancel()
            Task { @MainActor [weak self] in
                await self?.transport.stopStreaming()
            }
            self.failActiveStream(error: ChatTransportError.streamStartTimeout, generation: generation)
        }
    }

    private func receiveStreamingDelta(_ delta: StreamingDelta, generation: UInt64) {
        guard var context = activeStreamContext, context.generation == generation else {
            return
        }

        if let deltaConversationId = delta.conversationId, !deltaConversationId.isEmpty, !isTemporaryChat {
            conversationId = deltaConversationId
        }

        let isFirstDelta = !context.receivedFirstDelta
        if isFirstDelta {
            context.receivedFirstDelta = true
            timeoutTask?.cancel()
            timeoutTask = nil
        }

        if let thinking = delta.thinkingText, !thinking.isEmpty {
            if context.thinkingStartedAt == nil {
                context.thinkingStartedAt = .now
            }
            if delta.isThinkingComplete, context.thinkingDurationSeconds == nil, let startedAt = context.thinkingStartedAt {
                let elapsed = ContinuousClock.now - startedAt
                context.thinkingDurationSeconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000.0
            }
        }

        context.pendingDelta = delta
        activeStreamContext = context

        // Apply the very first token and any terminal delta immediately; coalesce intermediate rapid chunks.
        if isFirstDelta || delta.isFinal || streamCoalesceInterval == .zero {
            coalesceTask?.cancel()
            coalesceTask = nil
            flushPendingDelta(in: context.turnIndex)
        } else if coalesceTask == nil {
            let interval = streamCoalesceInterval
            coalesceTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self,
                      self.streamGeneration == generation,
                      let current = self.activeStreamContext else {
                    return
                }
                self.coalesceTask = nil
                self.flushPendingDelta(in: current.turnIndex)
            }
        }
    }

    private func flushPendingDelta(in turnIndex: Int) {
        guard var context = activeStreamContext,
              let delta = context.pendingDelta,
              turns.indices.contains(turnIndex) else {
            return
        }

        context.pendingDelta = nil
        context.lastFlushedDelta = delta
        activeStreamContext = context

        let parts = delta.messageParts
        let effectiveTurnId = delta.responseId ?? turns[turnIndex].id

        turns[turnIndex].assistantParts = parts
        turns[turnIndex].thinkingText = delta.thinkingText
        turns[turnIndex].isThinkingComplete = delta.isThinkingComplete
        turns[turnIndex].citations = delta.citations
        turns[turnIndex].metadata = TurnResponseMetadata(
            responseId: delta.responseId ?? turns[turnIndex].metadata.responseId,
            choiceId: delta.choiceId ?? turns[turnIndex].metadata.choiceId,
            modelId: selectedModelId ?? turns[turnIndex].metadata.modelId,
            thinkingDurationSeconds: context.thinkingDurationSeconds ?? turns[turnIndex].metadata.thinkingDurationSeconds
        )

        streamingState = .streaming(
            turnId: effectiveTurnId,
            thinkingText: delta.thinkingText,
            isThinkingComplete: delta.isThinkingComplete,
            markdownSnapshot: delta.markdownSnapshot,
            inlineImages: delta.inlineImages,
            citations: delta.citations,
            artifacts: delta.artifacts
        )

        // Live-update or auto-open the Split Pane when a Canvas or Deep Research Report streams in.
        if let activeSelected = selectedArtifact,
           let updatedMatch = delta.artifacts.first(where: { $0.id == activeSelected.id && $0.hasNativeContent }) {
            selectedArtifact = updatedMatch
        } else if autoOpenNativeArtifacts,
                  selectedArtifact == nil,
                  let firstRich = delta.artifacts.first(where: { ($0.kind == .canvas || $0.kind == .deepResearch) && $0.hasNativeContent }) {
            selectedArtifact = firstRich
        }

        coalescedFlushCount += 1
    }

    private func completeActiveStream(generation: UInt64) {
        guard let context = activeStreamContext, context.generation == generation else {
            return
        }

        cancelStreamTasks()
        flushPendingDelta(in: context.turnIndex)

        guard let finalContext = activeStreamContext else {
            return
        }

        // Treat a 0-delta completion as a failed empty response and roll back cleanly.
        guard finalContext.receivedFirstDelta else {
            rollbackOperation(finalContext.operation, turnIndex: finalContext.turnIndex)
            streamingState = .idle
            activeStreamContext = nil
            lastErrorMessage = ChatTransportError.actionDriverFailed(reason: "Gemini returned an empty response.").errorDescription
            return
        }

        if turns.indices.contains(finalContext.turnIndex) {
            let finalDelta = finalContext.lastFlushedDelta
            let currentTurn = turns[finalContext.turnIndex]
            let canonicalTurnId = finalDelta?.responseId ?? currentTurn.id

            var resolvedThinkingDuration = finalContext.thinkingDurationSeconds
            if resolvedThinkingDuration == nil,
               let startedAt = finalContext.thinkingStartedAt,
               let thinking = currentTurn.thinkingText,
               !thinking.isEmpty {
                let elapsed = ContinuousClock.now - startedAt
                resolvedThinkingDuration = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000.0
            }

            let finalizedTurn = ChatTurn(
                id: canonicalTurnId,
                userPrompt: currentTurn.userPrompt,
                userAttachments: currentTurn.userAttachments,
                quotedPassages: currentTurn.quotedPassages,
                assistantParts: currentTurn.assistantParts,
                thinkingText: currentTurn.thinkingText,
                isThinkingComplete: true,
                citations: currentTurn.citations,
                metadata: TurnResponseMetadata(
                    responseId: finalDelta?.responseId ?? currentTurn.metadata.responseId,
                    choiceId: finalDelta?.choiceId ?? currentTurn.metadata.choiceId,
                    modelId: selectedModelId ?? currentTurn.metadata.modelId,
                    thinkingDurationSeconds: resolvedThinkingDuration ?? currentTurn.metadata.thinkingDurationSeconds
                ),
                createdAt: currentTurn.createdAt
            )
            turns[finalContext.turnIndex] = finalizedTurn

            if let finalConvId = finalDelta?.conversationId, !finalConvId.isEmpty, !isTemporaryChat {
                conversationId = finalConvId
            }
            if title.isEmpty, let firstTurn = turns.first {
                title = Self.derivedTitle(from: firstTurn.userPrompt)
            }
        }

        streamingState = .idle
        activeStreamContext = nil

        // Persist strictly when non-temporary, scoped to a signed-in account, and carrying a canonical ID.
        if !isTemporaryChat,
           let scopeId = accountScopeId,
           let convId = conversationId,
           !convId.isEmpty {
            let snapshot = ConversationSnapshot(
                accountScopeId: scopeId,
                conversationId: convId,
                title: title,
                modelId: selectedModelId,
                updatedAt: Date(),
                turns: turns
            )
            cache?.saveConversation(snapshot, isTemporaryChat: false)
            onConversationCompleted?(snapshot)
        }
    }

    private func failActiveStream(error: Error, generation: UInt64) {
        guard let context = activeStreamContext, context.generation == generation else {
            return
        }

        streamGeneration &+= 1
        cancelStreamTasks()

        if !context.receivedFirstDelta {
            rollbackOperation(context.operation, turnIndex: context.turnIndex)
        } else {
            flushPendingDelta(in: context.turnIndex)
            finalizePartialTurnInMemory(at: context.turnIndex)
        }

        streamingState = .idle
        activeStreamContext = nil

        if let transportError = error as? ChatTransportError {
            handleActionError(transportError)
        } else if !(error is CancellationError) {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func haltActiveStreamForChallenge(_ banner: ChallengeBannerState) {
        if let context = activeStreamContext {
            streamGeneration &+= 1
            cancelStreamTasks()

            if !context.receivedFirstDelta {
                rollbackOperation(context.operation, turnIndex: context.turnIndex)
            } else {
                flushPendingDelta(in: context.turnIndex)
                finalizePartialTurnInMemory(at: context.turnIndex)
            }
            activeStreamContext = nil
        }

        streamingState = .idle
        challengeBanner = banner
        lastErrorMessage = banner.message
    }

    private func handleActionError(_ error: ChatTransportError) {
        switch error {
        case .challengeRequired(let banner):
            challengeBanner = banner
            lastErrorMessage = banner.message
        case .streamStartTimeout:
            let message = error.errorDescription ?? "Gemini did not respond in time."
            challengeBanner = ChallengeBannerState(kind: .bridgeFallback, message: message)
            lastErrorMessage = message
        case .actionDriverFailed(let reason):
            challengeBanner = ChallengeBannerState(kind: .bridgeFallback, message: reason)
            lastErrorMessage = reason
        case .cancelled:
            break
        default:
            lastErrorMessage = error.errorDescription
        }
    }

    /// Replaces in-memory turns when handing off a Quick Mode session into Main Window.
    func adoptExternalSession(
        conversationId: String?,
        title: String,
        turns: [ChatTurn],
        isTemporary: Bool,
        selectedArtifact: ArtifactCardInfo?
    ) {
        abortActiveStreamWithoutTransportCall()
        speechController.stop()
        self.conversationId = conversationId
        self.title = title
        self.turns = turns
        self.isTemporaryChat = isTemporary
        self.streamingState = .idle
        self.selectedArtifact = selectedArtifact
        self.activeShareLinkResult = nil
    }

    private func rollbackOperation(_ operation: StreamOperation, turnIndex: Int) {
        switch operation {
        case .send(let rollback):
            if turns.indices.contains(turnIndex) {
                turns.remove(at: turnIndex)
            }
            draft.restoreRollbackSnapshot(rollback)

        case .edit(let originalTurn, let rollback):
            if turns.indices.contains(turnIndex) {
                turns[turnIndex] = originalTurn
            }
            draft.restoreRollbackSnapshot(rollback)

        case .regenerate(let originalTurn, let previousModelId):
            if turns.indices.contains(turnIndex) {
                turns[turnIndex] = originalTurn
            }
            selectedModelId = previousModelId

        case .deepResearchConfirm:
            if turns.indices.contains(turnIndex) {
                turns.remove(at: turnIndex)
            }
            for tIdx in turns.indices {
                for pIdx in turns[tIdx].assistantParts.indices {
                    if case .unsupportedArtifact(var card) = turns[tIdx].assistantParts[pIdx],
                       var plan = card.plan,
                       plan.isConfirmed {
                        plan.isConfirmed = false
                        card.plan = plan
                        turns[tIdx].assistantParts[pIdx] = .unsupportedArtifact(card)
                    }
                }
            }
        }
    }

    private func finalizePartialTurnInMemory(at turnIndex: Int) {
        guard turns.indices.contains(turnIndex) else {
            return
        }
        turns[turnIndex].isThinkingComplete = true
    }

    private func abortActiveStreamWithoutTransportCall() {
        streamGeneration &+= 1
        cancelStreamTasks()
        activeStreamContext = nil
    }

    private func cancelStreamTasks() {
        timeoutTask?.cancel()
        timeoutTask = nil
        coalesceTask?.cancel()
        coalesceTask = nil
        streamTask?.cancel()
        streamTask = nil
    }

    private nonisolated static func derivedTitle(from prompt: String) -> String {
        let singleLine = prompt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        if singleLine.count <= 80 {
            return singleLine
        }
        return String(singleLine.prefix(80))
    }
}
