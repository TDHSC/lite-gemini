import Foundation
import os
import WebKit

/// Drives Gemini's hidden `WKWebView` DOM write controls (prompt submission, file/image
/// attachment staging, stop generating, model selection, turn editing, regeneration, and
/// new-chat reset) using centralized selector groups from `GeminiBridgeSelectors`.
///
/// Every mutating operation enforces a bounded timeout, passes untrusted strings and binary
/// payloads strictly through `WKWebView.callAsyncJavaScript` structured arguments (never
/// interpolating user text or filenames into JS source), and emits typed `ChatTransportError`
/// failures so `ChatSessionStore` can roll back `ComposerDraftState` cleanly.
@MainActor
final class GeminiActionDriver {

    // MARK: - Constants

    /// Default bounded timeout enforced across DOM lookup, upload readiness, and submission steps
    static let defaultTimeout: Duration = .seconds(15)

    /// Wait window after synthetic `paste` before falling back to `<input type="file">`
    static let defaultPasteFallbackDelay: Duration = .milliseconds(600)

    /// Polling cadence for DOM readiness and spinner completion checks
    static let defaultPollInterval: Duration = .milliseconds(50)

    /// Maximum permitted byte size per staged attachment (50 MiB)
    static let defaultMaxAttachmentBytes: Int = 50 * 1024 * 1024

    /// Brief wait window after clicking Regenerate to detect an optional `.cdk-overlay-container` menu
    static let defaultRegenerateMenuWait: Duration = .milliseconds(250)

    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "GeminiBridge")

    // MARK: - Configuration

    let timeout: Duration
    let pasteFallbackDelay: Duration
    let pollInterval: Duration
    let maxAttachmentBytes: Int
    let regenerateMenuWait: Duration

    // MARK: - Initialization

    init(
        timeout: Duration = GeminiActionDriver.defaultTimeout,
        pasteFallbackDelay: Duration = GeminiActionDriver.defaultPasteFallbackDelay,
        pollInterval: Duration = GeminiActionDriver.defaultPollInterval,
        maxAttachmentBytes: Int = GeminiActionDriver.defaultMaxAttachmentBytes,
        regenerateMenuWait: Duration = GeminiActionDriver.defaultRegenerateMenuWait
    ) {
        self.timeout = timeout
        self.pasteFallbackDelay = pasteFallbackDelay
        self.pollInterval = pollInterval
        self.maxAttachmentBytes = maxAttachmentBytes
        self.regenerateMenuWait = regenerateMenuWait
    }

    // MARK: - Attachments

    /// Stages one or more files or images into Gemini's hidden composer and waits until previews
    /// appear and all upload progress spinners clear within the configured timeout.
    ///
    /// Attempts synthetic `ClipboardEvent('paste')` first; if the preview count fails to increment
    /// within `pasteFallbackDelay`, falls back to clicking the upload menu trigger and assigning
    /// `DataTransfer.files` to the hidden `<input type="file">`.
    func stageAttachments(_ attachments: [StagedAttachment], in webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + timeout
        try await stageAttachments(attachments, in: webView, deadline: deadline)
    }

    // MARK: - Prompt Submission & Stop

    /// Stages optional attachments, injects `text` into Gemini's composer editor, waits for
    /// Luminous/Angular to enable the Send control, and clicks Send.
    func submitPrompt(
        text: String,
        attachments: [StagedAttachment],
        in webView: WKWebView
    ) async throws {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || !attachments.isEmpty else {
            throw ChatTransportError.actionDriverFailed(
                reason: "Cannot submit an empty prompt without attachments."
            )
        }

        let startedAt = ContinuousClock.now
        let deadline = startedAt + timeout

        if !attachments.isEmpty {
            try await stageAttachments(attachments, in: webView, deadline: deadline)
        }

        // Inject prompt text once the composer editor is mounted in the DOM.
        var textInjected = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let result = try await invokeJS(
                Self.injectComposerTextScript,
                arguments: [
                    "editorSelectors": GeminiBridgeSelectors.ComposerDOM.editor.all,
                    "text": text
                ],
                in: webView,
                action: "submitPrompt.injectText"
            )
            if boolValue(result["ok"]) {
                textInjected = true
                break
            }
            try await sleepStep(until: deadline)
        }

        guard textInjected else {
            Self.logger.error("submitPrompt: composer editor not found within timeout")
            throw ChatTransportError.actionDriverFailed(
                reason: "Composer input editor was not found within timeout."
            )
        }

        // Poll until Angular/Luminous swaps the mic button to an enabled Send button and click it.
        var lastReason = "missing"
        while true {
            try Task.checkCancellation()
            let result = try await invokeJS(
                Self.clickEnabledControlScript,
                arguments: [
                    "selectors": GeminiBridgeSelectors.ComposerDOM.sendButton.all
                ],
                in: webView,
                action: "submitPrompt.clickSend"
            )
            if boolValue(result["clicked"]) {
                let selectorIndex = intValue(result["selectorIndex"]) ?? -1
                let elapsedMs = elapsedMilliseconds(since: startedAt)
                Self.logger.notice(
                    "submitPrompt: clicked send selectorIndex=\(selectorIndex, privacy: .public) attachments=\(attachments.count, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
                )
                return
            }

            if let reason = result["reason"] as? String {
                lastReason = reason
            }

            if ContinuousClock.now >= deadline {
                break
            }
            try await sleepStep(until: deadline)
        }

        Self.logger.error("submitPrompt: send button unavailable reason=\(lastReason, privacy: .public)")
        if lastReason == "disabled" {
            throw ChatTransportError.actionDriverFailed(
                reason: "Composer send button remained disabled within timeout."
            )
        }
        throw ChatTransportError.actionDriverFailed(
            reason: "Composer send button was not found within timeout."
        )
    }

    /// Locates and clicks Gemini's active Stop Generating button, returning `true` if clicked.
    func stopGenerating(in webView: WKWebView) async -> Bool {
        do {
            let result = try await invokeJS(
                Self.clickEnabledControlScript,
                arguments: [
                    "selectors": GeminiBridgeSelectors.ComposerDOM.stopButton.all
                ],
                in: webView,
                action: "stopGenerating"
            )
            let clicked = boolValue(result["clicked"])
            if clicked {
                let selectorIndex = intValue(result["selectorIndex"]) ?? -1
                Self.logger.notice("stopGenerating: clicked selectorIndex=\(selectorIndex, privacy: .public)")
            } else {
                let reason = (result["reason"] as? String) ?? "missing"
                Self.logger.notice("stopGenerating: not clicked reason=\(reason, privacy: .public)")
            }
            return clicked
        } catch {
            Self.logger.error("stopGenerating: failed code=\((error as NSError).code, privacy: .public)")
            return false
        }
    }

    // MARK: - Model Selection

    /// Opens Gemini's model switcher menu, selects the option matching `id` by `data-mode-id`
    /// (with label fallback), and closes the overlay cleanly if still open.
    ///
    /// Throws `ChatTransportError.modelUnavailable(id:)` if the requested option is missing or
    /// marked disabled (`aria-disabled="true"`).
    func selectModel(id: String, in webView: WKWebView) async throws {
        let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw ChatTransportError.modelUnavailable(id: id)
        }

        let startedAt = ContinuousClock.now
        let deadline = startedAt + timeout

        // Open the model switcher menu if it is not already rendered in the overlay.
        var menuOpened = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let openResult = try await invokeJS(
                Self.ensureModelMenuOpenScript,
                arguments: [
                    "switcherSelectors": GeminiBridgeSelectors.ComposerDOM.modelSwitcherButton.all,
                    "menuSelectors": GeminiBridgeSelectors.ComposerDOM.modelMenuContainer.all
                ],
                in: webView,
                action: "selectModel.openMenu"
            )
            let status = (openResult["status"] as? String) ?? "missing"
            if status == "open" || status == "clicked" {
                menuOpened = true
                break
            }
            try await sleepStep(until: deadline)
        }

        guard menuOpened else {
            Self.logger.error("selectModel: model switcher button unavailable")
            throw ChatTransportError.actionDriverFailed(
                reason: "Model switcher button was not found or remained disabled."
            )
        }

        // Wait for the menu container and its option items to mount.
        var sawContainer = false
        var sawItems = false
        var emptyItemsGraceDeadline: ContinuousClock.Instant?

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let probe = try await invokeJS(
                Self.probeModelMenuScript,
                arguments: [
                    "menuSelectors": GeminiBridgeSelectors.ComposerDOM.modelMenuContainer.all,
                    "itemSelectors": GeminiBridgeSelectors.ComposerDOM.modelMenuItem.all
                ],
                in: webView,
                action: "selectModel.probeMenu"
            )
            let hasMenu = boolValue(probe["hasMenu"])
            let itemCount = intValue(probe["itemCount"]) ?? 0

            if hasMenu {
                sawContainer = true
                if itemCount > 0 {
                    sawItems = true
                    break
                }
                if emptyItemsGraceDeadline == nil {
                    emptyItemsGraceDeadline = min(deadline, ContinuousClock.now + .milliseconds(250))
                }
                if let grace = emptyItemsGraceDeadline, ContinuousClock.now >= grace {
                    break
                }
            }
            try await sleepStep(until: deadline)
        }

        guard sawContainer else {
            Self.logger.error("selectModel: model menu container did not appear within timeout")
            throw ChatTransportError.actionDriverFailed(
                reason: "Model picker menu did not open within timeout."
            )
        }

        guard sawItems else {
            await closeModelMenuIfNeeded(in: webView)
            Self.logger.error("selectModel: menu opened with zero items for id=\(trimmedId, privacy: .public)")
            throw ChatTransportError.modelUnavailable(id: id)
        }

        let pickResult = try await invokeJS(
            Self.selectModelOptionScript,
            arguments: [
                "itemSelectors": GeminiBridgeSelectors.ComposerDOM.modelMenuItem.all,
                "menuSelectors": GeminiBridgeSelectors.ComposerDOM.modelMenuContainer.all,
                "switcherSelectors": GeminiBridgeSelectors.ComposerDOM.modelSwitcherButton.all,
                "modeIdAttr": GeminiBridgeSelectors.ComposerDOM.modelModeIdAttribute,
                "labelClass": GeminiBridgeSelectors.ComposerDOM.modelItemLabelClass,
                "targetId": trimmedId
            ],
            in: webView,
            action: "selectModel.pickOption"
        )

        let status = (pickResult["status"] as? String) ?? "missing"
        switch status {
        case "selected":
            let elapsedMs = elapsedMilliseconds(since: startedAt)
            Self.logger.notice(
                "selectModel: selected id=\(trimmedId, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
            )
            return
        case "disabled":
            Self.logger.error("selectModel: option disabled id=\(trimmedId, privacy: .public)")
            throw ChatTransportError.modelUnavailable(id: id)
        case "missing":
            Self.logger.error("selectModel: option missing id=\(trimmedId, privacy: .public)")
            throw ChatTransportError.modelUnavailable(id: id)
        default:
            Self.logger.error("selectModel: unexpected status=\(status, privacy: .public)")
            throw ChatTransportError.actionDriverFailed(
                reason: "Failed to select model option."
            )
        }
    }

    // MARK: - Turn Actions (Edit & Regenerate)

    /// Opens edit mode on the latest `user-query`, replaces its text with `newText`, and clicks
    /// the Update button.
    func editLatestTurn(newText: String, in webView: WKWebView) async throws {
        guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatTransportError.actionDriverFailed(
                reason: "Edited prompt text cannot be empty."
            )
        }

        let startedAt = ContinuousClock.now
        let deadline = startedAt + timeout

        // Step 1: Locate the latest user query and open its inline editor (unless already open).
        var editTriggered = false
        var lastTriggerReason = "missing-query"

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let triggerResult = try await invokeJS(
                Self.openLatestTurnEditScript,
                arguments: [
                    "userQuerySelectors": GeminiBridgeSelectors.ConversationDOM.userQuery.all,
                    "editButtonSelectors": GeminiBridgeSelectors.ConversationDOM.editLatestPromptButton.all,
                    "editFieldSelectors": GeminiBridgeSelectors.ConversationDOM.editPromptField.all,
                    "scopePrefix": GeminiBridgeSelectors.ConversationDOM.userQuery.primary + " "
                ],
                in: webView,
                action: "editLatestTurn.openEdit"
            )
            let status = (triggerResult["status"] as? String) ?? "missing-query"
            if status == "clicked" || status == "already-open" {
                editTriggered = true
                break
            }
            lastTriggerReason = status
            try await sleepStep(until: deadline)
        }

        guard editTriggered else {
            Self.logger.error("editLatestTurn: failed to open editor reason=\(lastTriggerReason, privacy: .public)")
            throw ChatTransportError.actionDriverFailed(
                reason: "Edit button was not available on the latest user turn (\(lastTriggerReason))."
            )
        }

        // Step 2: Wait for the edit field inside the latest user query and inject `newText`.
        var fieldUpdated = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let injectResult = try await invokeJS(
                Self.injectLatestTurnEditTextScript,
                arguments: [
                    "userQuerySelectors": GeminiBridgeSelectors.ConversationDOM.userQuery.all,
                    "editFieldSelectors": GeminiBridgeSelectors.ConversationDOM.editPromptField.all,
                    "scopePrefix": GeminiBridgeSelectors.ConversationDOM.userQuery.primary + " ",
                    "newText": newText
                ],
                in: webView,
                action: "editLatestTurn.injectText"
            )
            if boolValue(injectResult["ok"]) {
                fieldUpdated = true
                break
            }
            try await sleepStep(until: deadline)
        }

        guard fieldUpdated else {
            Self.logger.error("editLatestTurn: edit prompt field did not appear within timeout")
            throw ChatTransportError.actionDriverFailed(
                reason: "Edit prompt field did not appear within timeout."
            )
        }

        // Step 3: Wait for the Update button inside the latest user query to be enabled and click it.
        var lastUpdateReason = "missing"
        while true {
            try Task.checkCancellation()
            let updateResult = try await invokeJS(
                Self.clickLatestTurnScopedButtonScript,
                arguments: [
                    "containerSelectors": GeminiBridgeSelectors.ConversationDOM.userQuery.all,
                    "buttonSelectors": GeminiBridgeSelectors.ConversationDOM.editPromptUpdateButton.all,
                    "scopePrefix": GeminiBridgeSelectors.ConversationDOM.userQuery.primary + " "
                ],
                in: webView,
                action: "editLatestTurn.clickUpdate"
            )
            if boolValue(updateResult["clicked"]) {
                let elapsedMs = elapsedMilliseconds(since: startedAt)
                Self.logger.notice("editLatestTurn: submitted elapsedMs=\(elapsedMs, privacy: .public)")
                return
            }
            if let reason = updateResult["reason"] as? String {
                lastUpdateReason = reason
            }
            if ContinuousClock.now >= deadline {
                break
            }
            try await sleepStep(until: deadline)
        }

        Self.logger.error("editLatestTurn: update button unavailable reason=\(lastUpdateReason, privacy: .public)")
        throw ChatTransportError.actionDriverFailed(
            reason: "Edit update button was unavailable within timeout (\(lastUpdateReason))."
        )
    }

    /// Clicks Regenerate on the latest `model-response` and, if an overlay regenerate menu opens
    /// in `.cdk-overlay-container`, clicks its primary regenerate option.
    func regenerateLatestTurn(in webView: WKWebView) async throws {
        let startedAt = ContinuousClock.now
        let deadline = startedAt + timeout

        var clickedTrigger = false
        var lastReason = "missing-container"

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let result = try await invokeJS(
                Self.clickLatestTurnScopedButtonScript,
                arguments: [
                    "containerSelectors": GeminiBridgeSelectors.ConversationDOM.modelResponse.all,
                    "buttonSelectors": GeminiBridgeSelectors.ConversationDOM.regenerateButton.all,
                    "scopePrefix": GeminiBridgeSelectors.ConversationDOM.modelResponse.primary + " "
                ],
                in: webView,
                action: "regenerateLatestTurn.clickTrigger"
            )
            if boolValue(result["clicked"]) {
                clickedTrigger = true
                break
            }
            if let reason = result["reason"] as? String {
                lastReason = reason
            }
            try await sleepStep(until: deadline)
        }

        guard clickedTrigger else {
            Self.logger.error("regenerateLatestTurn: regenerate button unavailable reason=\(lastReason, privacy: .public)")
            throw ChatTransportError.actionDriverFailed(
                reason: "Regenerate button was not found on the latest model response (\(lastReason))."
            )
        }

        // Wait one frame, then briefly watch for an optional overlay menu option.
        let menuDeadline = min(deadline, ContinuousClock.now + regenerateMenuWait)
        var sawDisabledOption = false

        while true {
            try Task.checkCancellation()
            let menuResult = try await invokeJS(
                Self.clickEnabledControlScript,
                arguments: [
                    "selectors": GeminiBridgeSelectors.ConversationDOM.regenerateMenuOption.all
                ],
                in: webView,
                action: "regenerateLatestTurn.clickMenuOption"
            )
            if boolValue(menuResult["clicked"]) {
                let elapsedMs = elapsedMilliseconds(since: startedAt)
                Self.logger.notice("regenerateLatestTurn: clicked overlay option elapsedMs=\(elapsedMs, privacy: .public)")
                return
            }

            let reason = (menuResult["reason"] as? String) ?? "missing"
            if reason == "disabled" {
                sawDisabledOption = true
            }

            if ContinuousClock.now >= menuDeadline {
                break
            }
            try await sleepStep(until: menuDeadline)
        }

        if sawDisabledOption {
            Self.logger.error("regenerateLatestTurn: overlay menu option remained disabled")
            throw ChatTransportError.actionDriverFailed(
                reason: "Regenerate menu option remained disabled."
            )
        }

        let elapsedMs = elapsedMilliseconds(since: startedAt)
        Self.logger.notice("regenerateLatestTurn: direct regenerate triggered elapsedMs=\(elapsedMs, privacy: .public)")
    }

    // MARK: - New Chat

    /// Clicks Gemini's in-page New Chat trigger if present and enabled.
    ///
    /// Returns `false` when no enabled control is found so the caller can fall back to loading `/app`.
    func triggerNewChat(in webView: WKWebView) async -> Bool {
        do {
            let result = try await invokeJS(
                Self.clickEnabledControlScript,
                arguments: [
                    "selectors": GeminiBridgeSelectors.ComposerDOM.newChatTrigger.all
                ],
                in: webView,
                action: "triggerNewChat"
            )
            let clicked = boolValue(result["clicked"])
            if clicked {
                let selectorIndex = intValue(result["selectorIndex"]) ?? -1
                Self.logger.notice("triggerNewChat: clicked selectorIndex=\(selectorIndex, privacy: .public)")
            } else {
                let reason = (result["reason"] as? String) ?? "missing"
                Self.logger.notice("triggerNewChat: unavailable reason=\(reason, privacy: .public)")
            }
            return clicked
        } catch {
            Self.logger.error("triggerNewChat: failed code=\((error as NSError).code, privacy: .public)")
            return false
        }
    }

    // MARK: - Private Attachment Pipeline

    private func stageAttachments(
        _ attachments: [StagedAttachment],
        in webView: WKWebView,
        deadline: ContinuousClock.Instant
    ) async throws {
        guard !attachments.isEmpty else { return }

        var totalBytes = 0
        for attachment in attachments {
            if attachment.data.isEmpty {
                Self.logger.error("stageAttachments: rejected empty attachment")
                throw ChatTransportError.attachmentRejected(
                    reason: "Attachment cannot be empty."
                )
            }
            if attachment.data.count > maxAttachmentBytes {
                let limitMB = max(1, maxAttachmentBytes / (1024 * 1024))
                Self.logger.error(
                    "stageAttachments: rejected oversized attachment bytes=\(attachment.data.count, privacy: .public) limit=\(self.maxAttachmentBytes, privacy: .public)"
                )
                throw ChatTransportError.attachmentRejected(
                    reason: "Attachment exceeds the \(limitMB) MB per-file size limit."
                )
            }
            totalBytes += attachment.data.count
        }

        let startedAt = ContinuousClock.now
        let encodedFiles: [[String: Any]] = attachments.map { item in
            let safeName = item.filename.isEmpty ? "attachment" : item.filename
            let trimmedMime = item.mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeMime = trimmedMime.isEmpty ? "application/octet-stream" : trimmedMime
            return [
                "name": safeName,
                "type": safeMime,
                "base64": item.data.base64EncodedString()
            ]
        }

        // Primary path: construct DataTransfer in page context and dispatch ClipboardEvent('paste').
        var initialPreviewCount = 0
        var pasted = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let pasteResult = try await invokeJS(
                Self.pasteAttachmentsScript,
                arguments: [
                    "editorSelectors": GeminiBridgeSelectors.ComposerDOM.editor.all,
                    "previewSelectors": GeminiBridgeSelectors.ComposerDOM.attachmentPreview.all,
                    "files": encodedFiles
                ],
                in: webView,
                action: "stageAttachments.paste"
            )
            if boolValue(pasteResult["ok"]) {
                initialPreviewCount = intValue(pasteResult["initialPreviewCount"]) ?? 0
                pasted = true
                break
            }
            try await sleepStep(until: deadline)
        }

        guard pasted else {
            Self.logger.error("stageAttachments: composer editor not found for paste injection")
            throw ChatTransportError.actionDriverFailed(
                reason: "Composer input editor was not found while staging attachments."
            )
        }

        let expectedPreviewCount = initialPreviewCount + attachments.count
        let pasteFallbackDeadline = min(deadline, ContinuousClock.now + pasteFallbackDelay)
        var pasteIncrementedPreviews = false

        while true {
            try Task.checkCancellation()
            let status = try await readAttachmentStatus(in: webView)
            if status.previewCount >= expectedPreviewCount && status.spinnerCount == 0 {
                let elapsedMs = elapsedMilliseconds(since: startedAt)
                Self.logger.notice(
                    "stageAttachments: ready via paste count=\(attachments.count, privacy: .public) bytes=\(totalBytes, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
                )
                return
            }
            if status.previewCount > initialPreviewCount {
                pasteIncrementedPreviews = true
                break
            }
            if ContinuousClock.now >= pasteFallbackDeadline {
                break
            }
            try await sleepStep(until: pasteFallbackDeadline)
        }

        // Fallback path: click upload menu trigger, locate <input type="file">, assign files, dispatch change.
        if !pasteIncrementedPreviews && ContinuousClock.now < deadline {
            Self.logger.notice(
                "stageAttachments: paste did not increment previews within fallback delay; trying file input fallback"
            )
            _ = try await invokeJS(
                Self.triggerUploadMenuScript,
                arguments: [
                    "triggerSelectors": GeminiBridgeSelectors.ComposerDOM.uploadMenuTrigger.all
                ],
                in: webView,
                action: "stageAttachments.openUploadMenu"
            )

            var assignedFileInput = false
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let assignResult = try await invokeJS(
                    Self.assignFileInputScript,
                    arguments: [
                        "fileInputSelectors": GeminiBridgeSelectors.ComposerDOM.fileInput.all,
                        "files": encodedFiles
                    ],
                    in: webView,
                    action: "stageAttachments.assignFileInput"
                )
                if boolValue(assignResult["ok"]) {
                    assignedFileInput = true
                    break
                }
                try await sleepStep(until: deadline)
            }

            guard assignedFileInput else {
                Self.logger.error("stageAttachments: fallback file input not found within timeout")
                throw ChatTransportError.actionDriverFailed(
                    reason: "Attachment file input was not found after triggering upload fallback."
                )
            }
        }

        // Wait until all staged attachment previews are present and every upload spinner has cleared.
        var lastStatus = AttachmentStatus(previewCount: initialPreviewCount, spinnerCount: 0)
        while true {
            try Task.checkCancellation()
            lastStatus = try await readAttachmentStatus(in: webView)
            if lastStatus.previewCount >= expectedPreviewCount && lastStatus.spinnerCount == 0 {
                let elapsedMs = elapsedMilliseconds(since: startedAt)
                let path = pasteIncrementedPreviews ? "paste" : "fileInput"
                Self.logger.notice(
                    "stageAttachments: ready via \(path, privacy: .public) count=\(attachments.count, privacy: .public) bytes=\(totalBytes, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
                )
                return
            }
            if ContinuousClock.now >= deadline {
                break
            }
            try await sleepStep(until: deadline)
        }

        Self.logger.error(
            "stageAttachments: timeout expectedPreviews=\(expectedPreviewCount, privacy: .public) observedPreviews=\(lastStatus.previewCount, privacy: .public) spinners=\(lastStatus.spinnerCount, privacy: .public)"
        )
        if lastStatus.previewCount < expectedPreviewCount {
            let observedNew = max(0, lastStatus.previewCount - initialPreviewCount)
            throw ChatTransportError.actionDriverFailed(
                reason: "Timed out waiting for \(attachments.count) attachment preview(s) to appear (detected \(observedNew))."
            )
        }
        throw ChatTransportError.actionDriverFailed(
            reason: "Timed out waiting for attachment upload to finish (\(lastStatus.spinnerCount) spinner(s) still active)."
        )
    }

    private struct AttachmentStatus {
        let previewCount: Int
        let spinnerCount: Int
    }

    private func readAttachmentStatus(in webView: WKWebView) async throws -> AttachmentStatus {
        let result = try await invokeJS(
            Self.attachmentStatusScript,
            arguments: [
                "previewSelectors": GeminiBridgeSelectors.ComposerDOM.attachmentPreview.all,
                "spinnerSelectors": GeminiBridgeSelectors.ComposerDOM.attachmentUploadingSpinner.all
            ],
            in: webView,
            action: "stageAttachments.status"
        )
        return AttachmentStatus(
            previewCount: intValue(result["previewCount"]) ?? 0,
            spinnerCount: intValue(result["spinnerCount"]) ?? 0
        )
    }

    private func closeModelMenuIfNeeded(in webView: WKWebView) async {
        _ = try? await invokeJS(
            Self.closeModelMenuScript,
            arguments: [
                "menuSelectors": GeminiBridgeSelectors.ComposerDOM.modelMenuContainer.all,
                "switcherSelectors": GeminiBridgeSelectors.ComposerDOM.modelSwitcherButton.all
            ],
            in: webView,
            action: "selectModel.closeMenu"
        )
    }

    // MARK: - Private Execution Helpers

    private func invokeJS(
        _ functionBody: String,
        arguments: [String: Any],
        in webView: WKWebView,
        action: String
    ) async throws -> [String: Any] {
        try Task.checkCancellation()
        do {
            let raw = try await webView.callAsyncJavaScript(
                functionBody,
                arguments: arguments,
                in: nil,
                contentWorld: .page
            )
            if let dict = raw as? [String: Any] {
                return dict
            }
            return [:]
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            let nsError = error as NSError
            Self.logger.error(
                "invokeJS [\(action, privacy: .public)] failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
            throw ChatTransportError.actionDriverFailed(
                reason: "Page action '\(action)' failed during JavaScript execution (code \(nsError.code))."
            )
        }
    }

    private func sleepStep(until deadline: ContinuousClock.Instant) async throws {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return }
        let duration = remaining < pollInterval ? remaining : pollInterval
        try await Task.sleep(for: duration)
    }

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        let secondsMs = Double(elapsed.components.seconds) * 1000.0
        let attosecondsMs = Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
        return max(0, Int((secondsMs + attosecondsMs).rounded()))
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let flag = value as? Bool {
            return flag
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    private func intValue(_ value: Any?) -> Int? {
        if let integer = value as? Int {
            return integer
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    // MARK: - JavaScript Helpers & Action Bodies

    /// Shared pure-JS DOM helper definitions prepended to action bodies.
    private nonisolated static let jsCommonHelpers = """
    const isElementDisabled = (el) => {
        if (!el) return true;
        if (el.disabled === true) return true;
        if (el.hasAttribute && el.hasAttribute('disabled')) return true;
        const aria = el.getAttribute ? el.getAttribute('aria-disabled') : null;
        return typeof aria === 'string' && aria.toLowerCase() === 'true';
    };

    const isClipboardBridgeElement = (el) => {
        if (!el) return false;
        if (el.classList && el.classList.contains('ql-clipboard')) return true;
        return Boolean(el.closest && el.closest('.ql-clipboard'));
    };

    const queryFirstMatching = (selectors, excludeClipboard) => {
        for (let i = 0; i < selectors.length; i += 1) {
            try {
                const list = document.querySelectorAll(selectors[i]);
                for (let j = 0; j < list.length; j += 1) {
                    const candidate = list[j];
                    if (excludeClipboard && isClipboardBridgeElement(candidate)) continue;
                    return { element: candidate, selectorIndex: i };
                }
            } catch (_) {}
        }
        return null;
    };

    const queryAllFirstGroup = (selectors) => {
        for (let i = 0; i < selectors.length; i += 1) {
            try {
                const list = document.querySelectorAll(selectors[i]);
                if (list.length > 0) {
                    return { elements: Array.from(list), selectorIndex: i };
                }
            } catch (_) {}
        }
        return { elements: [], selectorIndex: -1 };
    };

    const findInsideScope = (scopeEl, selectors, scopePrefix, excludeClipboard) => {
        for (let i = 0; i < selectors.length; i += 1) {
            const sel = selectors[i];
            try {
                const matches = document.querySelectorAll(sel);
                for (let j = matches.length - 1; j >= 0; j -= 1) {
                    const candidate = matches[j];
                    if (scopeEl && !scopeEl.contains(candidate)) continue;
                    if (excludeClipboard && isClipboardBridgeElement(candidate)) continue;
                    return { element: candidate, selectorIndex: i };
                }
            } catch (_) {}

            if (scopeEl && scopePrefix && sel.startsWith(scopePrefix)) {
                const relativeSel = sel.slice(scopePrefix.length);
                try {
                    const relMatches = scopeEl.querySelectorAll(relativeSel);
                    for (let j = relMatches.length - 1; j >= 0; j -= 1) {
                        const candidate = relMatches[j];
                        if (excludeClipboard && isClipboardBridgeElement(candidate)) continue;
                        return { element: candidate, selectorIndex: i };
                    }
                } catch (_) {}
            }
        }
        return null;
    };

    const resolveClickTarget = (el) => {
        if (!el) return null;
        const tag = el.tagName ? el.tagName.toUpperCase() : '';
        if (tag === 'BUTTON' || tag === 'A') return el;
        const inner = el.querySelector ? el.querySelector('button, a') : null;
        if (inner) return inner;
        const outer = el.closest ? el.closest('button, a') : null;
        return outer || el;
    };

    // Race requestAnimationFrame against a short timer so offscreen/headless WKWebViews
    // (where display-link rAF may be paused) never hang while live views still yield a frame.
    const nextFrameAndMicrotask = () => new Promise((resolve) => {
        let settled = false;
        const finish = () => {
            if (settled) return;
            settled = true;
            Promise.resolve().then(resolve);
        };
        const timer = setTimeout(finish, 32);
        if (typeof requestAnimationFrame === 'function') {
            requestAnimationFrame(() => {
                clearTimeout(timer);
                finish();
            });
        }
    });

    const base64ToUint8Array = (b64) => {
        const binary = atob(b64);
        const len = binary.length;
        const bytes = new Uint8Array(len);
        for (let i = 0; i < len; i += 1) {
            bytes[i] = binary.charCodeAt(i);
        }
        return bytes;
    };

    const buildDataTransfer = (fileSpecs) => {
        const dt = new DataTransfer();
        for (let i = 0; i < fileSpecs.length; i += 1) {
            const spec = fileSpecs[i];
            const bytes = base64ToUint8Array(spec.base64);
            const file = new File([bytes], spec.name, {
                type: spec.type,
                lastModified: Date.now()
            });
            dt.items.add(file);
        }
        return dt;
    };

    const setEditableText = (el, text) => {
        el.focus();
        const tag = el.tagName ? el.tagName.toUpperCase() : '';
        const isFormField = (tag === 'TEXTAREA' || tag === 'INPUT');

        if (text.length === 0) {
            const existing = isFormField
                ? String(el.value || '')
                : String(el.innerText || el.textContent || '');
            if (existing.trim().length === 0) {
                return;
            }
        }

        let inputFired = false;
        const trackInput = () => { inputFired = true; };
        el.addEventListener('input', trackInput, true);

        let inserted = false;
        if (isFormField) {
            if (typeof el.select === 'function') {
                el.select();
            }
            try {
                inserted = text.length === 0
                    ? document.execCommand('delete', false, null)
                    : document.execCommand('insertText', false, text);
            } catch (_) {
                inserted = false;
            }
            el.removeEventListener('input', trackInput, true);

            if (!inserted || el.value !== text) {
                const proto = tag === 'TEXTAREA'
                    ? HTMLTextAreaElement.prototype
                    : HTMLInputElement.prototype;
                const descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
                if (descriptor && descriptor.set) {
                    descriptor.set.call(el, text);
                } else {
                    el.value = text;
                }
                inputFired = false;
            }
        } else {
            const selection = window.getSelection ? window.getSelection() : null;
            if (selection) {
                const range = document.createRange();
                range.selectNodeContents(el);
                selection.removeAllRanges();
                selection.addRange(range);
            }
            // Only invoke selectAll when focus actually landed inside `el` to avoid selecting document body.
            if (document.activeElement === el || el.contains(document.activeElement)) {
                try {
                    document.execCommand('selectAll', false, null);
                } catch (_) {}
            }
            try {
                inserted = text.length === 0
                    ? document.execCommand('delete', false, null)
                    : document.execCommand('insertText', false, text);
            } catch (_) {
                inserted = false;
            }
            el.removeEventListener('input', trackInput, true);

            const normalize = (s) => String(s || '').replace(/\\r\\n/g, '\\n').replace(/\\n+$/, '');
            const expected = normalize(text);
            const innerNorm = normalize(el.innerText);
            const contentNorm = normalize(el.textContent);
            const matches = expected.length === 0
                ? (innerNorm.trim().length === 0 && contentNorm.trim().length === 0)
                : (innerNorm === expected || contentNorm === expected);

            if (!inserted || !matches) {
                el.textContent = text;
                inputFired = false;
            }
        }

        if (!inputFired) {
            el.dispatchEvent(new InputEvent('input', {
                bubbles: true,
                inputType: text.length === 0 ? 'deleteContentBackward' : 'insertText',
                data: text.length === 0 ? null : text
            }));
        }
    };

    const closeMenuOverlayIfOpen = async (menuSelectors, switcherSelectors) => {
        if (!queryFirstMatching(menuSelectors, false)) return;
        const esc = new KeyboardEvent('keydown', {
            key: 'Escape',
            code: 'Escape',
            keyCode: 27,
            bubbles: true,
            cancelable: true
        });
        document.dispatchEvent(esc);
        if (document.activeElement && document.activeElement !== document) {
            document.activeElement.dispatchEvent(esc);
        }
        await nextFrameAndMicrotask();
        if (!queryFirstMatching(menuSelectors, false)) return;
        const switcher = queryFirstMatching(switcherSelectors, false);
        if (switcher && !isElementDisabled(switcher.element)) {
            switcher.element.click();
            await nextFrameAndMicrotask();
        }
    };
    """

    private nonisolated static let pasteAttachmentsScript = jsCommonHelpers + """
    const foundEditor = queryFirstMatching(editorSelectors, true);
    if (!foundEditor) {
        return { ok: false, reason: 'missing-editor' };
    }

    const initialPreviewCount = queryAllFirstGroup(previewSelectors).elements.length;
    const dt = buildDataTransfer(files);

    const pasteEvent = new ClipboardEvent('paste', {
        clipboardData: dt,
        bubbles: true,
        cancelable: true
    });
    if (!pasteEvent.clipboardData || !pasteEvent.clipboardData.files || pasteEvent.clipboardData.files.length === 0) {
        try {
            Object.defineProperty(pasteEvent, 'clipboardData', {
                value: dt,
                configurable: true
            });
        } catch (_) {}
    }

    foundEditor.element.focus();
    foundEditor.element.dispatchEvent(pasteEvent);
    await nextFrameAndMicrotask();
    return { ok: true, initialPreviewCount: initialPreviewCount };
    """

    private nonisolated static let triggerUploadMenuScript = jsCommonHelpers + """
    const found = queryFirstMatching(triggerSelectors, false);
    if (!found) {
        return { clicked: false, reason: 'missing' };
    }
    const target = resolveClickTarget(found.element);
    if (isElementDisabled(found.element) || isElementDisabled(target)) {
        return { clicked: false, reason: 'disabled' };
    }
    target.click();
    await nextFrameAndMicrotask();
    return { clicked: true, selectorIndex: found.selectorIndex };
    """

    private nonisolated static let assignFileInputScript = jsCommonHelpers + """
    const found = queryFirstMatching(fileInputSelectors, false);
    if (!found) {
        return { ok: false, reason: 'missing-file-input' };
    }
    const input = found.element;
    const dt = buildDataTransfer(files);
    input.files = dt.files;
    input.dispatchEvent(new Event('change', { bubbles: true }));
    await nextFrameAndMicrotask();
    return { ok: true, selectorIndex: found.selectorIndex };
    """

    private nonisolated static let attachmentStatusScript = jsCommonHelpers + """
    const previews = queryAllFirstGroup(previewSelectors).elements.length;
    const spinners = queryAllFirstGroup(spinnerSelectors).elements.length;
    return { previewCount: previews, spinnerCount: spinners };
    """

    private nonisolated static let injectComposerTextScript = jsCommonHelpers + """
    const found = queryFirstMatching(editorSelectors, true);
    if (!found) {
        return { ok: false, reason: 'missing-editor' };
    }
    setEditableText(found.element, text);
    await nextFrameAndMicrotask();
    return { ok: true, selectorIndex: found.selectorIndex };
    """

    private nonisolated static let clickEnabledControlScript = jsCommonHelpers + """
    let sawDisabled = false;
    for (let i = 0; i < selectors.length; i += 1) {
        try {
            const matches = document.querySelectorAll(selectors[i]);
            for (let j = 0; j < matches.length; j += 1) {
                const candidate = matches[j];
                const target = resolveClickTarget(candidate);
                if (isElementDisabled(candidate) || isElementDisabled(target)) {
                    sawDisabled = true;
                    continue;
                }
                target.click();
                return { clicked: true, selectorIndex: i };
            }
        } catch (_) {}
    }
    return { clicked: false, reason: sawDisabled ? 'disabled' : 'missing' };
    """

    private nonisolated static let ensureModelMenuOpenScript = jsCommonHelpers + """
    if (queryFirstMatching(menuSelectors, false)) {
        return { status: 'open' };
    }
    const found = queryFirstMatching(switcherSelectors, false);
    if (!found) {
        return { status: 'missing' };
    }
    const target = resolveClickTarget(found.element);
    if (isElementDisabled(found.element) || isElementDisabled(target)) {
        return { status: 'disabled' };
    }
    target.click();
    await nextFrameAndMicrotask();
    return { status: 'clicked', selectorIndex: found.selectorIndex };
    """

    private nonisolated static let probeModelMenuScript = jsCommonHelpers + """
    const menu = queryFirstMatching(menuSelectors, false);
    if (!menu) {
        return { hasMenu: false, itemCount: 0 };
    }
    const items = queryAllFirstGroup(itemSelectors).elements;
    return { hasMenu: true, itemCount: items.length };
    """

    private nonisolated static let selectModelOptionScript = jsCommonHelpers + """
    const items = queryAllFirstGroup(itemSelectors).elements;
    let matched = null;

    for (let i = 0; i < items.length; i += 1) {
        const modeId = items[i].getAttribute ? items[i].getAttribute(modeIdAttr) : null;
        if (modeId === targetId) {
            matched = items[i];
            break;
        }
    }

    if (!matched) {
        const targetLower = targetId.toLowerCase();
        for (let i = 0; i < items.length; i += 1) {
            const labelEl = items[i].querySelector ? items[i].querySelector(labelClass) : null;
            const rawLabel = labelEl ? labelEl.textContent : items[i].textContent;
            const normalized = String(rawLabel || '').trim().toLowerCase();
            if (normalized === targetLower) {
                matched = items[i];
                break;
            }
        }
    }

    if (!matched) {
        await closeMenuOverlayIfOpen(menuSelectors, switcherSelectors);
        return { status: 'missing' };
    }

    const clickTarget = resolveClickTarget(matched);
    if (isElementDisabled(matched) || isElementDisabled(clickTarget)) {
        await closeMenuOverlayIfOpen(menuSelectors, switcherSelectors);
        return { status: 'disabled' };
    }

    clickTarget.click();
    await nextFrameAndMicrotask();
    await closeMenuOverlayIfOpen(menuSelectors, switcherSelectors);
    return { status: 'selected' };
    """

    private nonisolated static let closeModelMenuScript = jsCommonHelpers + """
    await closeMenuOverlayIfOpen(menuSelectors, switcherSelectors);
    return { ok: true };
    """

    private nonisolated static let openLatestTurnEditScript = jsCommonHelpers + """
    const queries = queryAllFirstGroup(userQuerySelectors).elements;
    if (queries.length === 0) {
        return { status: 'missing-query' };
    }
    const lastQuery = queries[queries.length - 1];
    if (findInsideScope(lastQuery, editFieldSelectors, scopePrefix, true)) {
        return { status: 'already-open' };
    }
    const foundBtn = findInsideScope(lastQuery, editButtonSelectors, scopePrefix, false);
    if (!foundBtn) {
        return { status: 'missing-button' };
    }
    const target = resolveClickTarget(foundBtn.element);
    if (isElementDisabled(foundBtn.element) || isElementDisabled(target)) {
        return { status: 'disabled' };
    }
    target.click();
    await nextFrameAndMicrotask();
    return { status: 'clicked', selectorIndex: foundBtn.selectorIndex };
    """

    private nonisolated static let injectLatestTurnEditTextScript = jsCommonHelpers + """
    const queries = queryAllFirstGroup(userQuerySelectors).elements;
    if (queries.length === 0) {
        return { ok: false, reason: 'missing-query' };
    }
    const lastQuery = queries[queries.length - 1];
    const foundField = findInsideScope(lastQuery, editFieldSelectors, scopePrefix, true);
    if (!foundField) {
        return { ok: false, reason: 'missing-field' };
    }
    setEditableText(foundField.element, newText);
    await nextFrameAndMicrotask();
    return { ok: true, selectorIndex: foundField.selectorIndex };
    """

    private nonisolated static let clickLatestTurnScopedButtonScript = jsCommonHelpers + """
    const containers = queryAllFirstGroup(containerSelectors).elements;
    if (containers.length === 0) {
        return { clicked: false, reason: 'missing-container' };
    }
    const lastContainer = containers[containers.length - 1];
    const foundBtn = findInsideScope(lastContainer, buttonSelectors, scopePrefix, false);
    if (!foundBtn) {
        return { clicked: false, reason: 'missing' };
    }
    const target = resolveClickTarget(foundBtn.element);
    if (isElementDisabled(foundBtn.element) || isElementDisabled(target)) {
        return { clicked: false, reason: 'disabled' };
    }
    target.click();
    await nextFrameAndMicrotask();
    return { clicked: true, selectorIndex: foundBtn.selectorIndex };
    """
}

// MARK: - GeminiWriteDriving Conformance Adapter

/// Bridges `GeminiActionDriver` and `TemporaryChatController` to `GeminiSessionEngine`'s
/// `GeminiWriteDriving` protocol.
@MainActor
final class DefaultGeminiWriteDriver: GeminiWriteDriving {

    let actionDriver: GeminiActionDriver
    private weak var temporaryChatController: TemporaryChatController?

    init(
        actionDriver: GeminiActionDriver = GeminiActionDriver(),
        temporaryChatController: TemporaryChatController? = nil
    ) {
        self.actionDriver = actionDriver
        self.temporaryChatController = temporaryChatController
    }

    func submitPrompt(
        in webView: WKWebView,
        text: String,
        attachments: [StagedAttachment],
        modelId: String?,
        isTemporaryChat: Bool
    ) async throws {
        if let temporaryChatController,
           let currentTemp = await temporaryChatController.readState(),
           currentTemp != isTemporaryChat {
            try await temporaryChatController.setTemporaryChat(
                isTemporaryChat,
                reason: "submitPrompt",
                timeout: actionDriver.timeout
            )
        }
        if let modelId, !modelId.isEmpty {
            try? await actionDriver.selectModel(id: modelId, in: webView)
        }
        try await actionDriver.submitPrompt(text: text, attachments: attachments, in: webView)
    }

    func stopStreaming(in webView: WKWebView) async {
        _ = await actionDriver.stopGenerating(in: webView)
    }

    func editLastTurn(in webView: WKWebView, newText: String) async throws {
        try await actionDriver.editLatestTurn(newText: newText, in: webView)
    }

    func regenerateLastTurn(in webView: WKWebView) async throws {
        try await actionDriver.regenerateLatestTurn(in: webView)
    }

    func selectModel(in webView: WKWebView, id: String) async throws {
        try await actionDriver.selectModel(id: id, in: webView)
    }

    func setTemporaryChat(in webView: WKWebView, enabled: Bool) async throws {
        if let temporaryChatController {
            try await temporaryChatController.setTemporaryChat(
                enabled,
                reason: "nativeToggle",
                timeout: actionDriver.timeout
            )
        } else {
            let tempController = TemporaryChatController(webView: webView)
            try await tempController.setTemporaryChat(
                enabled,
                reason: "nativeToggle",
                timeout: actionDriver.timeout
            )
        }
    }
}
