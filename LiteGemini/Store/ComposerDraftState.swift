import Combine
import Foundation

// MARK: - DraftRollbackSnapshot

/// Immutable snapshot of composer state captured immediately before an optimistic send or edit,
/// allowing exact restoration if a write driver fails, times out, or is aborted prior to first token.
nonisolated struct DraftRollbackSnapshot: Equatable, Sendable {

    let text: String
    let stagedAttachments: [StagedAttachment]
    let quotes: [QuotedPassage]
    let editingTurnId: String?
    let activeToolMode: ComposerToolMode?

    init(
        text: String,
        stagedAttachments: [StagedAttachment] = [],
        quotes: [QuotedPassage] = [],
        editingTurnId: String? = nil,
        activeToolMode: ComposerToolMode? = nil
    ) {
        self.text = text
        self.stagedAttachments = stagedAttachments
        self.quotes = quotes
        self.editingTurnId = editingTurnId
        self.activeToolMode = activeToolMode
    }
}

// MARK: - ComposerDraftState

/// Shared `@MainActor` composer draft state reused by both Main Window and Quick Mode.
///
/// Lives in the store layer so hiding the Quick Mode floating bar prior to sending preserves
/// unsent text and staged attachments in memory with zero disk serialization.
@MainActor
final class ComposerDraftState: ObservableObject {

    // MARK: - Constants

    static let maxStagedQuotes: Int = QuotedPassage.maxStagedCount
    static let quoteUndoRetentionDuration: Duration = .seconds(5)

    // MARK: - Published State

    /// Current text inside the native composer.
    @Published var text: String
    /// Files and images staged for the next prompt submission.
    @Published var stagedAttachments: [StagedAttachment]
    /// Highlighted passages staged as structured quotes above the composer (hard cap: 5).
    @Published var quotes: [QuotedPassage]
    /// Whether the max-5 staged quotes info banner is currently visible.
    @Published var isQuoteCapAlertVisible: Bool
    /// Most recently removed quote retained briefly for single-step undo restore.
    @Published private(set) var lastRemovedQuote: QuotedPassage?
    /// Identifier of the latest user turn currently being edited, or `nil` for a normal send.
    @Published var editingTurnId: String?
    /// Whether the folder-upload web-mode fallback banner is currently visible.
    @Published var showsFolderWebFallbackBanner: Bool
    /// Optional composer tool mode (`Canvas` or `Deep Research`) active for the next prompt.
    @Published var activeToolMode: ComposerToolMode?

    private var lastRemovedQuoteIndex: Int?
    private var quoteUndoExpiryTask: Task<Void, Never>?

    // MARK: - Computed Properties

    /// Draft text trimmed of leading and trailing whitespace and newlines.
    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the composer has enough content (non-empty text or at least one attachment) to submit.
    var canSubmit: Bool {
        !trimmedText.isEmpty || !stagedAttachments.isEmpty
    }

    /// Whether the composer is currently editing the latest user turn.
    var isEditing: Bool {
        editingTurnId != nil
    }

    /// Whether the composer holds any unsent draft text, attachments, quotes, or edit state.
    var hasUnsentContent: Bool {
        canSubmit || isEditing || !quotes.isEmpty
    }

    /// Lightweight metadata summaries for all currently staged attachments.
    var attachmentSummaries: [StagedAttachmentSummary] {
        stagedAttachments.map(\.summary)
    }

    /// Banner display items corresponding to `quotes`.
    var quoteBannerItems: [ComposerQuoteBannerItem] {
        quotes.map { ComposerQuoteBannerItem(id: $0.id, quotedText: $0.quotedText, turnId: $0.turnId) }
    }

    // MARK: - Initialization

    init(
        text: String = "",
        stagedAttachments: [StagedAttachment] = [],
        quotes: [QuotedPassage] = [],
        editingTurnId: String? = nil,
        showsFolderWebFallbackBanner: Bool = false,
        activeToolMode: ComposerToolMode? = nil
    ) {
        self.text = text
        self.stagedAttachments = stagedAttachments
        self.quotes = Array(quotes.prefix(Self.maxStagedQuotes))
        self.isQuoteCapAlertVisible = false
        self.lastRemovedQuote = nil
        self.editingTurnId = editingTurnId
        self.showsFolderWebFallbackBanner = showsFolderWebFallbackBanner
        self.activeToolMode = activeToolMode
    }

    isolated deinit {
        quoteUndoExpiryTask?.cancel()
    }

    // MARK: - Quote Mutations

    /// Stages a quoted passage above the composer, deduplicating identical `(turnId, quotedText)`
    /// entries and enforcing the 5-quote cap. Returns `false` and shows the cap banner when full.
    @discardableResult
    func addQuote(_ passage: QuotedPassage) -> Bool {
        guard !passage.quotedText.isEmpty else {
            return false
        }
        if quotes.contains(where: { $0.turnId == passage.turnId && $0.quotedText == passage.quotedText }) {
            isQuoteCapAlertVisible = false
            return true
        }
        guard quotes.count < Self.maxStagedQuotes else {
            isQuoteCapAlertVisible = true
            return false
        }
        isQuoteCapAlertVisible = false
        quotes.append(passage)
        return true
    }

    /// Removes a staged quote by identifier and retains it in the single-step undo buffer for 5 seconds.
    func removeQuote(id: UUID) {
        guard let index = quotes.firstIndex(where: { $0.id == id }) else {
            return
        }
        let removed = quotes.remove(at: index)
        isQuoteCapAlertVisible = false
        lastRemovedQuote = removed
        lastRemovedQuoteIndex = index

        quoteUndoExpiryTask?.cancel()
        quoteUndoExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.quoteUndoRetentionDuration)
            } catch {
                return
            }
            guard let self, self.lastRemovedQuote?.id == removed.id else {
                return
            }
            self.lastRemovedQuote = nil
            self.lastRemovedQuoteIndex = nil
            self.quoteUndoExpiryTask = nil
        }
    }

    /// Restores the most recently removed quote if still within the undo window and under the 5-quote cap.
    @discardableResult
    func undoRemoveQuote() -> Bool {
        guard let restored = lastRemovedQuote else {
            return false
        }
        guard quotes.count < Self.maxStagedQuotes else {
            isQuoteCapAlertVisible = true
            return false
        }
        let targetIndex = min(lastRemovedQuoteIndex ?? quotes.count, quotes.count)
        quotes.insert(restored, at: targetIndex)
        clearQuoteUndoBuffer()
        isQuoteCapAlertVisible = false
        return true
    }

    /// Dismisses the max-5 staged quotes info banner.
    func dismissQuoteCapAlert() {
        isQuoteCapAlertVisible = false
    }

    /// Clears all staged quotes, cap alerts, and single-step undo state.
    func clearQuotes() {
        quotes.removeAll()
        isQuoteCapAlertVisible = false
        clearQuoteUndoBuffer()
    }

    private func clearQuoteUndoBuffer() {
        quoteUndoExpiryTask?.cancel()
        quoteUndoExpiryTask = nil
        lastRemovedQuote = nil
        lastRemovedQuoteIndex = nil
    }

    // MARK: - Attachment Mutations

    /// Appends a single staged attachment to the draft.
    func addAttachment(_ attachment: StagedAttachment) {
        stagedAttachments.append(attachment)
    }

    /// Appends multiple staged attachments to the draft.
    func addAttachments(_ attachments: [StagedAttachment]) {
        guard !attachments.isEmpty else {
            return
        }
        stagedAttachments.append(contentsOf: attachments)
    }

    /// Removes a staged attachment by its identifier.
    func removeAttachment(id: UUID) {
        stagedAttachments.removeAll { $0.id == id }
    }

    /// Removes all staged attachments.
    func clearAttachments() {
        stagedAttachments.removeAll()
    }

    // MARK: - Edit Lifecycle

    /// Enters edit mode for the given user turn, loading its original prompt and quotes into the composer.
    func beginEditing(turnId: String, prompt: String, quotes: [QuotedPassage] = []) {
        editingTurnId = turnId
        text = prompt
        stagedAttachments.removeAll()
        clearQuotes()
        self.quotes = Array(quotes.prefix(Self.maxStagedQuotes))
        showsFolderWebFallbackBanner = false
    }

    /// Exits edit mode and clears the draft text.
    func cancelEditing() {
        editingTurnId = nil
        text = ""
    }

    // MARK: - Optimistic Send & Rollback

    /// Captures the current draft state into an immutable rollback snapshot and clears the composer
    /// immediately for optimistic submission.
    func takeSnapshotForOptimisticSend() -> DraftRollbackSnapshot {
        let snapshot = DraftRollbackSnapshot(
            text: text,
            stagedAttachments: stagedAttachments,
            quotes: quotes,
            editingTurnId: editingTurnId,
            activeToolMode: activeToolMode
        )
        text = ""
        stagedAttachments.removeAll()
        clearQuotes()
        editingTurnId = nil
        showsFolderWebFallbackBanner = false
        if activeToolMode == .deepResearch {
            activeToolMode = nil
        }
        return snapshot
    }

    /// Restores a previously captured rollback snapshot back into the composer after a failed,
    /// timed-out, or pre-token aborted submission.
    func restoreRollbackSnapshot(_ snapshot: DraftRollbackSnapshot) {
        text = snapshot.text
        stagedAttachments = snapshot.stagedAttachments
        quotes = Array(snapshot.quotes.prefix(Self.maxStagedQuotes))
        isQuoteCapAlertVisible = false
        clearQuoteUndoBuffer()
        editingTurnId = snapshot.editingTurnId
        activeToolMode = snapshot.activeToolMode
    }

    /// Clears all draft text, attachments, quotes, edit state, and banners.
    func reset() {
        text = ""
        stagedAttachments.removeAll()
        clearQuotes()
        editingTurnId = nil
        showsFolderWebFallbackBanner = false
        activeToolMode = nil
    }
}
