import Foundation
import Observation
import os

// MARK: - BtwSessionStore

/// Isolated `@MainActor` state machine for the `Btw` ephemeral side-question panel.
///
/// Lazily spins up a dedicated temporary-chat `ChatTransport` on first question so main-window
/// conversations and in-flight streams are never navigated or mutated.
@MainActor
@Observable
final class BtwSessionStore {

    // MARK: - Nested Types

    /// Single user-question + assistant-response exchange inside the `Btw` side thread.
    nonisolated struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        let userQuestion: String
        let quotes: [BtwQuoteItem]
        var assistantMarkdown: String
        var isStreaming: Bool
        var errorMessage: String?

        init(
            id: UUID = UUID(),
            userQuestion: String,
            quotes: [BtwQuoteItem] = [],
            assistantMarkdown: String = "",
            isStreaming: Bool = false,
            errorMessage: String? = nil
        ) {
            self.id = id
            self.userQuestion = userQuestion
            self.quotes = quotes
            self.assistantMarkdown = assistantMarkdown
            self.isStreaming = isStreaming
            self.errorMessage = errorMessage
        }
    }

    // MARK: - Constants

    static let maxStagedQuotes: Int = 5
    static let defaultIdleTeardownInterval: Duration = .seconds(300)
    static let defaultStreamStartTimeout: Duration = .seconds(25)

    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "BtwSessionStore")

    // MARK: - Observable State

    var isPresented: Bool = false
    var entries: [Entry] = []
    var stagedQuotes: [BtwQuoteItem] = []
    var inputText: String = ""
    var isGenerating: Bool = false
    var isSummarizing: Bool = false
    var lastErrorMessage: String? = nil
    var focusTrigger: Int = 0

    // MARK: - Computed Properties

    var hasEntries: Bool {
        !entries.isEmpty
    }

    var canSubmitInput: Bool {
        !isGenerating
            && !isSummarizing
            && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSendToMainChat: Bool {
        !isGenerating
            && !isSummarizing
            && entries.contains {
                !$0.assistantMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    // MARK: - Transport & Lifecycle Dependencies

    @ObservationIgnored private let makeEphemeralTransport: () -> any ChatTransport
    @ObservationIgnored private let onTearDownTransport: ((any ChatTransport) -> Void)?
    @ObservationIgnored private let authUserIndexProvider: (() -> Int?)?
    @ObservationIgnored private let modelIdProvider: (() -> String?)?
    @ObservationIgnored private let idleTeardownInterval: Duration
    @ObservationIgnored private let streamStartTimeout: Duration

    @ObservationIgnored private var ephemeralTransport: (any ChatTransport)?
    @ObservationIgnored private var isTransportBootstrapped: Bool = false
    @ObservationIgnored private var hasPackedContextOnCurrentTransport: Bool = false
    @ObservationIgnored private var activeGeneration: UInt64 = 0
    @ObservationIgnored private var activeStreamTask: Task<Void, Never>?
    @ObservationIgnored private var activeTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var idleTeardownTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        makeEphemeralTransport: @escaping () -> any ChatTransport,
        onTearDownTransport: ((any ChatTransport) -> Void)? = nil,
        authUserIndexProvider: (() -> Int?)? = nil,
        modelIdProvider: (() -> String?)? = nil,
        idleTeardownInterval: Duration = BtwSessionStore.defaultIdleTeardownInterval,
        streamStartTimeout: Duration = BtwSessionStore.defaultStreamStartTimeout
    ) {
        self.makeEphemeralTransport = makeEphemeralTransport
        self.onTearDownTransport = onTearDownTransport
        self.authUserIndexProvider = authUserIndexProvider
        self.modelIdProvider = modelIdProvider
        self.idleTeardownInterval = idleTeardownInterval
        self.streamStartTimeout = streamStartTimeout
    }

    isolated deinit {
        activeStreamTask?.cancel()
        activeTimeoutTask?.cancel()
        idleTeardownTask?.cancel()
        if let transport = ephemeralTransport {
            ephemeralTransport = nil
            onTearDownTransport?(transport)
        }
    }

    // MARK: - Public Actions

    /// Presents the `Btw` panel, optionally staging a highlighted quote and/or immediately
    /// dispatching an initial side question (e.g. from `/btw <question>`).
    func open(
        with quote: BtwQuoteItem? = nil,
        initialQuestion: String? = nil,
        mainTurns: [ChatTurn]
    ) {
        idleTeardownTask?.cancel()
        idleTeardownTask = nil

        isPresented = true
        focusTrigger &+= 1
        lastErrorMessage = nil

        if let quote {
            stageQuote(quote)
        }

        if let initialQuestion {
            let trimmed = initialQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                inputText = trimmed
                if !isGenerating && !isSummarizing {
                    sendCurrentInput(mainTurns: mainTurns)
                }
            }
        }
    }

    /// Stages a quoted passage for the next `Btw` turn, deduplicating identical `(turnId, quotedText)`
    /// entries and enforcing the 5-quote cap.
    @discardableResult
    func stageQuote(_ quote: BtwQuoteItem) -> Bool {
        guard !quote.quotedText.isEmpty else {
            return false
        }
        if stagedQuotes.contains(where: { $0.turnId == quote.turnId && $0.quotedText == quote.quotedText }) {
            return true
        }
        guard stagedQuotes.count < Self.maxStagedQuotes else {
            return false
        }
        stagedQuotes.append(quote)
        return true
    }

    /// Removes a staged quote chip by identifier.
    func removeStagedQuote(id: UUID) {
        stagedQuotes.removeAll { $0.id == id }
    }

    /// Dispatches `inputText` (and any `stagedQuotes`) on the isolated temporary-chat transport,
    /// packing up to 10 turns / 16,000 chars of read-only main chat context on the first turn.
    func sendCurrentInput(mainTurns: [ChatTurn]) {
        guard !isGenerating, !isSummarizing else {
            return
        }

        let trimmedQuestion = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            return
        }

        idleTeardownTask?.cancel()
        idleTeardownTask = nil
        activeStreamTask?.cancel()
        activeTimeoutTask?.cancel()

        let quotesForTurn = stagedQuotes
        stagedQuotes = []
        inputText = ""
        lastErrorMessage = nil

        let entryId = UUID()
        let entry = Entry(
            id: entryId,
            userQuestion: trimmedQuestion,
            quotes: quotesForTurn,
            assistantMarkdown: "",
            isStreaming: true,
            errorMessage: nil
        )
        entries.append(entry)
        isGenerating = true

        activeGeneration &+= 1
        let generation = activeGeneration
        let isFirstTurn = !hasPackedContextOnCurrentTransport

        activeStreamTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.performSendTurn(
                entryId: entryId,
                question: trimmedQuestion,
                quotes: quotesForTurn,
                isFirstTurn: isFirstTurn,
                mainTurns: mainTurns,
                generation: generation
            )
        }
    }

    /// Stops any active `Btw` stream without clearing prior turns.
    func stopGenerating() {
        guard isGenerating else {
            return
        }

        activeGeneration &+= 1
        activeStreamTask?.cancel()
        activeStreamTask = nil
        activeTimeoutTask?.cancel()
        activeTimeoutTask = nil
        isGenerating = false

        for idx in entries.indices where entries[idx].isStreaming {
            entries[idx].isStreaming = false
        }

        if let transport = ephemeralTransport {
            Task { @MainActor in
                await transport.stopStreaming()
            }
        }
    }

    /// Requests a 2–5 bullet summary of the `Btw` side thread from the isolated ephemeral session
    /// and returns `"Notes from Btw:\n..."` ready to insert into the main composer.
    func summarizeForMainChat() async -> String? {
        guard !isGenerating, !isSummarizing, canSendToMainChat else {
            return nil
        }

        isSummarizing = true
        lastErrorMessage = nil
        let generation = activeGeneration
        defer {
            isSummarizing = false
        }

        do {
            let transport = try await ensureEphemeralTransportReady(generation: generation)
            guard activeGeneration == generation, !Task.isCancelled else {
                return nil
            }

            let prompt = BtwPromptBuilder.buildSummarizePrompt()
            let stream = transport.sendPrompt(
                text: prompt,
                attachments: [],
                modelId: modelIdProvider?(),
                isTemporaryChat: true
            )

            var latestMarkdown = ""
            for try await delta in stream {
                guard activeGeneration == generation, !Task.isCancelled else {
                    await transport.stopStreaming()
                    return nil
                }
                if !delta.markdownSnapshot.isEmpty {
                    latestMarkdown = delta.markdownSnapshot
                }
            }

            guard activeGeneration == generation, !Task.isCancelled else {
                return nil
            }

            let formatted = BtwPromptBuilder.formatNotesForMainChat(latestMarkdown)
            if formatted.isEmpty {
                lastErrorMessage = String(localized: "Unable to summarize this side thread.")
                return nil
            }
            return formatted
        } catch is CancellationError {
            return nil
        } catch let error as ChatTransportError {
            if case .cancelled = error {
                return nil
            }
            lastErrorMessage = error.errorDescription
            return nil
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Resets all `Btw` conversation entries, staged quotes, input text, and tears down the
    /// ephemeral transport so subsequent questions begin with a clean temporary session.
    func clear() {
        let wasActive = isGenerating || isSummarizing
        activeGeneration &+= 1
        activeStreamTask?.cancel()
        activeStreamTask = nil
        activeTimeoutTask?.cancel()
        activeTimeoutTask = nil
        idleTeardownTask?.cancel()
        idleTeardownTask = nil

        entries = []
        stagedQuotes = []
        inputText = ""
        isGenerating = false
        isSummarizing = false
        lastErrorMessage = nil

        tearDownEphemeralTransport(stopStreamingFirst: wasActive)
    }

    /// Hides the `Btw` panel, stops any in-flight stream, and schedules ephemeral transport teardown
    /// (immediately if no thread exists, or after the idle timeout otherwise).
    func close() {
        isPresented = false

        if isGenerating || isSummarizing {
            activeGeneration &+= 1
            activeStreamTask?.cancel()
            activeStreamTask = nil
            activeTimeoutTask?.cancel()
            activeTimeoutTask = nil
            isGenerating = false
            isSummarizing = false
            for idx in entries.indices where entries[idx].isStreaming {
                entries[idx].isStreaming = false
            }
            if let transport = ephemeralTransport {
                Task { @MainActor in
                    await transport.stopStreaming()
                }
            }
        }

        if entries.isEmpty {
            tearDownEphemeralTransport()
            return
        }

        idleTeardownTask?.cancel()
        let interval = idleTeardownInterval
        idleTeardownTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard let self, !self.isPresented, !self.isGenerating, !self.isSummarizing else {
                return
            }
            self.tearDownEphemeralTransport()
        }
    }

    // MARK: - Private Execution Helpers

    private func performSendTurn(
        entryId: UUID,
        question: String,
        quotes: [BtwQuoteItem],
        isFirstTurn: Bool,
        mainTurns: [ChatTurn],
        generation: UInt64
    ) async {
        do {
            let transport = try await ensureEphemeralTransportReady(generation: generation)
            guard activeGeneration == generation, !Task.isCancelled else {
                return
            }

            let focusedTurnId = quotes.first(where: { $0.turnId != nil })?.turnId
            let background = isFirstTurn
                ? BtwPromptBuilder.packMainChatBackground(turns: mainTurns, focusedTurnId: focusedTurnId)
                : ""
            let payload = BtwPromptBuilder.buildPromptPayload(
                userQuestion: question,
                quotes: quotes,
                isFirstTurn: isFirstTurn,
                mainChatBackground: background
            )

            let stream = transport.sendPrompt(
                text: payload,
                attachments: [],
                modelId: modelIdProvider?(),
                isTemporaryChat: true
            )

            var receivedFirstDelta = false
            scheduleStreamStartTimeout(
                entryId: entryId,
                generation: generation,
                transport: transport
            )

            for try await delta in stream {
                guard activeGeneration == generation, !Task.isCancelled else {
                    await transport.stopStreaming()
                    return
                }

                if !receivedFirstDelta {
                    receivedFirstDelta = true
                    activeTimeoutTask?.cancel()
                    activeTimeoutTask = nil
                }

                if !delta.markdownSnapshot.isEmpty {
                    updateEntry(id: entryId) { entry in
                        entry.assistantMarkdown = delta.markdownSnapshot
                    }
                }
            }

            activeTimeoutTask?.cancel()
            activeTimeoutTask = nil

            guard activeGeneration == generation, !Task.isCancelled else {
                return
            }

            let finalMarkdown = entries.first(where: { $0.id == entryId })?.assistantMarkdown ?? ""
            if receivedFirstDelta || !finalMarkdown.isEmpty {
                hasPackedContextOnCurrentTransport = true
            }

            updateEntry(id: entryId) { entry in
                entry.isStreaming = false
                if entry.assistantMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let message = String(localized: "Gemini returned an empty response.")
                    entry.errorMessage = message
                    self.lastErrorMessage = message
                }
            }
            isGenerating = false
            activeStreamTask = nil
        } catch is CancellationError {
            if activeGeneration == generation {
                activeTimeoutTask?.cancel()
                activeTimeoutTask = nil
                updateEntry(id: entryId) { entry in
                    entry.isStreaming = false
                }
                isGenerating = false
                activeStreamTask = nil
            }
        } catch let error as ChatTransportError {
            guard activeGeneration == generation else {
                return
            }
            activeTimeoutTask?.cancel()
            activeTimeoutTask = nil
            let message: String? = (error == .cancelled) ? nil : error.errorDescription
            updateEntry(id: entryId) { entry in
                entry.isStreaming = false
                entry.errorMessage = message
            }
            if let message {
                lastErrorMessage = message
            }
            isGenerating = false
            activeStreamTask = nil
        } catch {
            guard activeGeneration == generation else {
                return
            }
            activeTimeoutTask?.cancel()
            activeTimeoutTask = nil
            let message = error.localizedDescription
            updateEntry(id: entryId) { entry in
                entry.isStreaming = false
                entry.errorMessage = message
            }
            lastErrorMessage = message
            isGenerating = false
            activeStreamTask = nil
        }
    }

    private func ensureEphemeralTransportReady(generation: UInt64) async throws -> any ChatTransport {
        if let existing = ephemeralTransport, isTransportBootstrapped {
            return existing
        }

        let transport: any ChatTransport
        if let existing = ephemeralTransport {
            transport = existing
        } else {
            let created = makeEphemeralTransport()
            ephemeralTransport = created
            transport = created
        }

        do {
            let homeResult = try await transport.loadHome(
                authUser: authUserIndexProvider?(),
                temporaryChat: true
            )
            guard activeGeneration == generation, !Task.isCancelled else {
                throw ChatTransportError.cancelled
            }

            if homeResult.isTemporaryChat {
                try? await transport.setTemporaryChat(true)
            } else {
                try await transport.setTemporaryChat(true)
            }

            guard activeGeneration == generation, !Task.isCancelled else {
                throw ChatTransportError.cancelled
            }

            isTransportBootstrapped = true
            return transport
        } catch {
            Self.logger.error("Failed to bootstrap Btw ephemeral transport: \(error.localizedDescription, privacy: .public)")
            if ephemeralTransport === transport {
                tearDownEphemeralTransport()
            }
            throw error
        }
    }

    private func scheduleStreamStartTimeout(
        entryId: UUID,
        generation: UInt64,
        transport: any ChatTransport
    ) {
        activeTimeoutTask?.cancel()
        let timeout = streamStartTimeout
        activeTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self, self.activeGeneration == generation, self.isGenerating else {
                return
            }
            Self.logger.error("Btw stream start timed out before first delta")
            self.activeGeneration &+= 1
            self.activeStreamTask?.cancel()
            self.activeStreamTask = nil
            self.activeTimeoutTask = nil

            let message = ChatTransportError.streamStartTimeout.errorDescription
                ?? String(localized: "Gemini did not respond in time.")
            self.updateEntry(id: entryId) { entry in
                entry.isStreaming = false
                entry.errorMessage = message
            }
            self.lastErrorMessage = message
            self.isGenerating = false

            await transport.stopStreaming()
        }
    }

    private func tearDownEphemeralTransport(stopStreamingFirst: Bool = false) {
        isTransportBootstrapped = false
        hasPackedContextOnCurrentTransport = false
        guard let transport = ephemeralTransport else {
            return
        }
        ephemeralTransport = nil
        let teardown = onTearDownTransport
        if stopStreamingFirst {
            Task { @MainActor in
                await transport.stopStreaming()
                teardown?(transport)
            }
        } else {
            teardown?(transport)
        }
    }

    private func updateEntry(id: UUID, mutate: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&entries[index])
    }
}
