import Combine
import Foundation

// MARK: - DraftRollbackSnapshot

/// Immutable snapshot of composer state captured immediately before an optimistic send or edit,
/// allowing exact restoration if a write driver fails, times out, or is aborted prior to first token.
nonisolated struct DraftRollbackSnapshot: Equatable, Sendable {

    let text: String
    let stagedAttachments: [StagedAttachment]
    let editingTurnId: String?

    init(
        text: String,
        stagedAttachments: [StagedAttachment] = [],
        editingTurnId: String? = nil
    ) {
        self.text = text
        self.stagedAttachments = stagedAttachments
        self.editingTurnId = editingTurnId
    }
}

// MARK: - ComposerDraftState

/// Shared `@MainActor` composer draft state reused by both Main Window and Quick Mode.
///
/// Lives in the store layer so hiding the Quick Mode floating bar prior to sending preserves
/// unsent text and staged attachments in memory with zero disk serialization.
@MainActor
final class ComposerDraftState: ObservableObject {

    // MARK: - Published State

    /// Current text inside the native composer.
    @Published var text: String
    /// Files and images staged for the next prompt submission.
    @Published var stagedAttachments: [StagedAttachment]
    /// Identifier of the latest user turn currently being edited, or `nil` for a normal send.
    @Published var editingTurnId: String?
    /// Whether the folder-upload web-mode fallback banner is currently visible.
    @Published var showsFolderWebFallbackBanner: Bool

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

    /// Whether the composer holds any unsent draft text, attachments, or edit state.
    var hasUnsentContent: Bool {
        canSubmit || isEditing
    }

    /// Lightweight metadata summaries for all currently staged attachments.
    var attachmentSummaries: [StagedAttachmentSummary] {
        stagedAttachments.map(\.summary)
    }

    // MARK: - Initialization

    init(
        text: String = "",
        stagedAttachments: [StagedAttachment] = [],
        editingTurnId: String? = nil,
        showsFolderWebFallbackBanner: Bool = false
    ) {
        self.text = text
        self.stagedAttachments = stagedAttachments
        self.editingTurnId = editingTurnId
        self.showsFolderWebFallbackBanner = showsFolderWebFallbackBanner
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

    /// Enters edit mode for the given user turn, loading its original prompt into the composer.
    func beginEditing(turnId: String, prompt: String) {
        editingTurnId = turnId
        text = prompt
        stagedAttachments.removeAll()
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
            editingTurnId: editingTurnId
        )
        text = ""
        stagedAttachments.removeAll()
        editingTurnId = nil
        showsFolderWebFallbackBanner = false
        return snapshot
    }

    /// Restores a previously captured rollback snapshot back into the composer after a failed,
    /// timed-out, or pre-token aborted submission.
    func restoreRollbackSnapshot(_ snapshot: DraftRollbackSnapshot) {
        text = snapshot.text
        stagedAttachments = snapshot.stagedAttachments
        editingTurnId = snapshot.editingTurnId
    }

    /// Clears all draft text, attachments, edit state, and banners.
    func reset() {
        text = ""
        stagedAttachments.removeAll()
        editingTurnId = nil
        showsFolderWebFallbackBanner = false
    }
}
