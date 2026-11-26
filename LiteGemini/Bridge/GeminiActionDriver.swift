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

    /// Automatic retry delay when `useCreatePublicShareLinkMutation` returns transient error `1218`
    static let defaultShareRetryDelay: Duration = .milliseconds(2000)

    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "GeminiBridge")

    // MARK: - Configuration

    let timeout: Duration
    let pasteFallbackDelay: Duration
    let pollInterval: Duration
    let maxAttachmentBytes: Int
    let regenerateMenuWait: Duration
    let shareRetryDelay: Duration
    let graphQLClient: GeminiGraphQLClient

    // MARK: - Initialization

    init(
        timeout: Duration = GeminiActionDriver.defaultTimeout,
        pasteFallbackDelay: Duration = GeminiActionDriver.defaultPasteFallbackDelay,
        pollInterval: Duration = GeminiActionDriver.defaultPollInterval,
        maxAttachmentBytes: Int = GeminiActionDriver.defaultMaxAttachmentBytes,
        regenerateMenuWait: Duration = GeminiActionDriver.defaultRegenerateMenuWait,
        shareRetryDelay: Duration = GeminiActionDriver.defaultShareRetryDelay,
        graphQLClient: GeminiGraphQLClient? = nil
    ) {
        self.timeout = timeout
        self.pasteFallbackDelay = pasteFallbackDelay
        self.pollInterval = pollInterval
        self.maxAttachmentBytes = maxAttachmentBytes
        self.regenerateMenuWait = regenerateMenuWait
        self.shareRetryDelay = shareRetryDelay
        self.graphQLClient = graphQLClient ?? GeminiGraphQLClient(timeout: timeout)
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

    // MARK: - v2.2 Conversational Power Tools (Dual-Path GraphQL + DOM)

    /// Formats optional staged `quotes` as Markdown blockquotes above `text` and submits the prompt.
    func submitPrompt(
        text: String,
        quotes: [QuotedPassage],
        attachments: [StagedAttachment],
        in webView: WKWebView
    ) async throws {
        let combinedText = QuotedPassage.formatPrompt(text, with: quotes)
        try await submitPrompt(text: combinedText, attachments: attachments, in: webView)
    }

    /// Regenerates the latest assistant response with the requested `variant` and optional `modelId` switch.
    func regenerateLatestResponse(
        variant: RegenerateVariant,
        modelId: String?,
        in webView: WKWebView
    ) async throws {
        let trimmedModelId = modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedModelId, !trimmedModelId.isEmpty {
            try? await selectModel(id: trimmedModelId, in: webView)
        }

        if variant == .tryAgain {
            try await regenerateLatestTurn(in: webView)
            return
        }

        let startedAt = ContinuousClock.now
        let deadline = startedAt + timeout

        if variant == .retryWithoutTools {
            let direct = try await invokeJS(
                Self.clickLatestTurnScopedButtonScript,
                arguments: [
                    "containerSelectors": GeminiBridgeSelectors.ConversationDOM.modelResponse.all,
                    "buttonSelectors": GeminiBridgeSelectors.ConversationDOM.retryWithoutToolButton.all,
                    "scopePrefix": GeminiBridgeSelectors.ConversationDOM.modelResponse.primary + " "
                ],
                in: webView,
                action: "regenerateVariant.retryWithoutTools.direct"
            )
            if boolValue(direct["clicked"]) {
                Self.logger.notice("regenerateLatestResponse: clicked direct retry-without-tools")
                return
            }

            let triggers: [[String]] = [
                GeminiBridgeSelectors.ConversationDOM.regenerateButton.all,
                GeminiBridgeSelectors.ConversationDOM.moreActionsButton.all
            ]
            for triggerSelectors in triggers {
                if try await openOverlayAndPickVariant(
                    triggerSelectors: triggerSelectors,
                    variant: .retryWithoutTools,
                    in: webView,
                    deadline: deadline
                ) {
                    let elapsedMs = elapsedMilliseconds(since: startedAt)
                    Self.logger.notice(
                        "regenerateLatestResponse: triggered retryWithoutTools elapsedMs=\(elapsedMs, privacy: .public)"
                    )
                    return
                }
            }

            throw ChatTransportError.actionDriverFailed(
                reason: "Retry without tools is unavailable for the latest response."
            )
        }

        // Tone/length modifiers: try Modify Response menu first, then Regenerate menu (`1004`/`1005`).
        let triggerGroups: [[String]] = [
            GeminiBridgeSelectors.ConversationDOM.modifyResponseButton.all,
            GeminiBridgeSelectors.ConversationDOM.regenerateButton.all
        ]

        for triggerSelectors in triggerGroups {
            if try await openOverlayAndPickVariant(
                triggerSelectors: triggerSelectors,
                variant: variant,
                in: webView,
                deadline: deadline
            ) {
                let elapsedMs = elapsedMilliseconds(since: startedAt)
                Self.logger.notice(
                    "regenerateLatestResponse: triggered variant=\(variant.rawValue, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
                )
                return
            }
        }

        throw ChatTransportError.actionDriverFailed(
            reason: "Regenerate variant '\(variant.rawValue)' is unavailable for the current model response."
        )
    }

    /// Branches a conversation from the given turn into a new chat, returning the new `conversationId`.
    ///
    /// Path A executes `ChatResponseActionBarBranchMutation` via Omakase GraphQL (with dynamic
    /// `persistedQueryId` discovery). Path B falls back to clicking `[data-test-id="branch-button"]`
    /// inside `<model-response>` and observing the SPA `/app/<newConversationId>` navigation.
    func branchConversation(
        conversationId: String,
        requestId: String?,
        responseId: String?,
        in webView: WKWebView
    ) async -> String? {
        let trimmedConversationId = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)

        // Path A: Omakase GraphQL primary (verified token with dynamic rotation fallback).
        if !trimmedConversationId.isEmpty {
            var requestPayload: [String: Any] = [
                "conversationId": GeminiGraphQLClient.canonicalConversationId(trimmedConversationId)
            ]
            if let req = requestId?.trimmingCharacters(in: .whitespacesAndNewlines), !req.isEmpty {
                requestPayload["requestId"] = req
            }
            if let resp = responseId?.trimmingCharacters(in: .whitespacesAndNewlines), !resp.isEmpty {
                requestPayload["responseId"] = resp
            }

            typealias Gateway = GeminiBridgeSelectors.GraphQLGateway
            let primaryPersistedId = Gateway.PersistedQuery.branchConversation
            let operationName = Gateway.OperationName.branchConversation

            do {
                let response = try await graphQLClient.execute(
                    operationName: operationName,
                    persistedQueryId: primaryPersistedId,
                    variables: ["request": requestPayload],
                    in: webView
                )
                if let newId = GeminiGraphQLClient.decodeBranchConversationId(from: response) {
                    Self.logger.notice("branchConversation: succeeded via GraphQL")
                    return newId
                }
            } catch {
                Self.logger.notice(
                    "branchConversation: primary GraphQL token failed (\(error.localizedDescription, privacy: .public)); checking dynamic persistedQueryId lookup"
                )
            }

            if let discoveredId = await graphQLClient.resolvePersistedQueryId(for: operationName, in: webView),
               discoveredId != primaryPersistedId {
                do {
                    let retryResponse = try await graphQLClient.execute(
                        operationName: operationName,
                        persistedQueryId: discoveredId,
                        variables: ["request": requestPayload],
                        in: webView
                    )
                    if let newId = GeminiGraphQLClient.decodeBranchConversationId(from: retryResponse) {
                        Self.logger.notice("branchConversation: succeeded via dynamic GraphQL lookup")
                        return newId
                    }
                } catch {
                    Self.logger.notice(
                        "branchConversation: dynamic GraphQL lookup failed (\(error.localizedDescription, privacy: .public)); attempting DOM fallback"
                    )
                }
            }
        }

        // Path B: DOM fallback — click branch button and observe SPA URL transition to `/app/<id>`.
        let initialRouteId = webView.url.flatMap(GeminiURLRoute.parse)?.conversationId
        let normalizedSource = trimmedConversationId.hasPrefix("c_")
            ? String(trimmedConversationId.dropFirst(2))
            : trimmedConversationId

        do {
            let clickResult = try await invokeJS(
                Self.clickTurnBranchButtonScript,
                arguments: [
                    "containerSelectors": GeminiBridgeSelectors.ConversationDOM.modelResponse.all,
                    "branchSelectors": GeminiBridgeSelectors.ConversationDOM.branchButton.all,
                    "moreSelectors": GeminiBridgeSelectors.ConversationDOM.moreActionsButton.all,
                    "overlayItemSelectors": GeminiBridgeSelectors.ConversationDOM.overlayMenuItems.all,
                    "scopePrefix": GeminiBridgeSelectors.ConversationDOM.modelResponse.primary + " ",
                    "requestId": requestId ?? "",
                    "responseId": responseId ?? ""
                ],
                in: webView,
                action: "branchConversation.domClick"
            )
            guard boolValue(clickResult["clicked"]) else {
                Self.logger.notice("branchConversation: DOM branch button not found")
                return nil
            }
        } catch {
            Self.logger.error("branchConversation: DOM fallback failed (\(error.localizedDescription, privacy: .public))")
            return nil
        }

        let navWait = timeout < .seconds(6) ? timeout : .seconds(6)
        let deadline = ContinuousClock.now + navWait
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return nil }
            if let observed = webView.url.flatMap(GeminiURLRoute.parse)?.conversationId,
               !observed.isEmpty,
               observed != initialRouteId,
               observed != trimmedConversationId,
               observed != normalizedSource {
                Self.logger.notice("branchConversation: succeeded via DOM SPA navigation")
                if trimmedConversationId.hasPrefix("c_"), !observed.hasPrefix("c_") {
                    return "c_\(observed)"
                }
                return observed
            }
            do {
                try await sleepStep(until: deadline)
            } catch {
                return nil
            }
        }

        return nil
    }

    /// Creates a public `gemini.google.com/share/<id>` link via `useCreatePublicShareLinkMutation`.
    ///
    /// Automatically retries once after `shareRetryDelay` (`2000ms`) on transient `BardErrorInfo`
    /// error `1218` (`SHARE_ERROR_TARGET_NOT_PERSISTED`), and falls back to the DOM share dialog
    /// if the GraphQL transport itself is unreachable.
    func createPublicShareLink(
        conversationId: String,
        scope: ShareLinkScope,
        selectedDraftId: String?,
        in webView: WKWebView
    ) async throws -> ShareLinkResult {
        let trimmedConversationId = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationId.isEmpty else {
            throw GeminiTransportActionError.invalidArguments("Cannot share a conversation without an ID.")
        }

        let target: Any
        let fallbackDraftId: String?
        switch scope {
        case .entireConversation:
            target = NSNull()
            fallbackDraftId = nil
        case .singleTurn(let requestId, let responseId):
            let trimmedRequest = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRequest.isEmpty else {
                throw GeminiTransportActionError.invalidArguments("Single-turn share requires a request ID.")
            }
            target = ["requestId": trimmedRequest]
            fallbackDraftId = responseId
        }

        let resolvedDraftId = [selectedDraftId, fallbackDraftId]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })

        let variables: [String: Any] = [
            "conversationId": GeminiGraphQLClient.canonicalConversationId(trimmedConversationId),
            "target": target,
            "lastTurnSelectedDraftId": resolvedDraftId ?? NSNull(),
            "shareDestination": NSNull(),
            "landingPageMetadata": NSNull()
        ]

        typealias Gateway = GeminiBridgeSelectors.GraphQLGateway

        func runMutation() async throws -> ShareLinkResult {
            let response = try await graphQLClient.execute(
                operationName: Gateway.OperationName.createPublicShareLink,
                persistedQueryId: Gateway.PersistedQuery.createPublicShareLink,
                variables: variables,
                in: webView
            )
            return try GeminiGraphQLClient.decodeShareLinkResult(from: response)
        }

        do {
            return try await runMutation()
        } catch GeminiTransportActionError.targetNotPersisted {
            Self.logger.notice("createPublicShareLink: received error 1218 (target not persisted); retrying once after 2000ms")
            try await Task.sleep(for: shareRetryDelay)
            return try await runMutation()
        } catch let error as GeminiTransportActionError {
            if case .fallbackUnavailable = error,
               scope == .entireConversation,
               let fallback = await attemptDOMShareLinkFallback(in: webView) {
                Self.logger.notice("createPublicShareLink: succeeded via DOM share dialog fallback")
                return fallback
            }
            throw error
        }
    }

    /// Exports a Markdown message to Google Docs, Gmail Drafts, Colab, or Sheets via `useExportMessageMutation`.
    func exportToCloudService(
        service: CloudExportService,
        title: String,
        markdownText: String,
        in webView: WKWebView
    ) async throws -> URL {
        guard !markdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiTransportActionError.invalidArguments("Cannot export an empty message.")
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmedTitle.isEmpty ? "Gemini Export" : trimmedTitle

        let variables: [String: Any] = [
            "request": [
                "exportServiceType": service.rawValue,
                "title": resolvedTitle,
                "textMessage": markdownText
            ]
        ]

        typealias Gateway = GeminiBridgeSelectors.GraphQLGateway
        let response = try await graphQLClient.execute(
            operationName: Gateway.OperationName.exportMessage,
            persistedQueryId: Gateway.PersistedQuery.exportMessage,
            variables: variables,
            in: webView
        )
        return try GeminiGraphQLClient.decodeExportArtifactURL(from: response, service: service)
    }

    /// Queries Gemini's remote semantic history search via `SearchChatsPageQuery`.
    func searchRemoteConversations(
        query: String,
        limit: Int,
        in webView: WKWebView
    ) async -> [ConversationSearchHit] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, limit > 0 else {
            return []
        }

        let variables: [String: Any] = [
            "query": trimmedQuery,
            "queryEmpty": false,
            "excludeMonothreadTaskConversations": true,
            "includeEnterpriseStatus": false,
            "pageSize": limit
        ]

        typealias Gateway = GeminiBridgeSelectors.GraphQLGateway
        do {
            let response = try await graphQLClient.execute(
                operationName: Gateway.OperationName.searchChats,
                persistedQueryId: Gateway.PersistedQuery.searchChats,
                variables: variables,
                in: webView
            )
            return GeminiGraphQLClient.decodeSearchHits(from: response, limit: limit)
        } catch {
            Self.logger.notice(
                "searchRemoteConversations: GraphQL query failed (\(error.localizedDescription, privacy: .public))"
            )
            return []
        }
    }

    /// Synthesizes neural MP3 audio for `text` in `locale` via `useResponseTtsQuery`, decoding `base64url` into `Data`.
    func synthesizeSpeechChunk(
        text: String,
        locale: String,
        in webView: WKWebView
    ) async -> Data? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return nil
        }

        let trimmedLocale = locale.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLocale = trimmedLocale.isEmpty ? "en-US" : trimmedLocale

        let variables: [String: Any] = [
            "request": [
                "appId": "TTS_APP_ID_BARD",
                "text": trimmedText,
                "locale": resolvedLocale,
                "audioEncoding": "TTS_ENCODING_MP3"
            ]
        ]

        typealias Gateway = GeminiBridgeSelectors.GraphQLGateway
        do {
            let response = try await graphQLClient.execute(
                operationName: Gateway.OperationName.responseTts,
                persistedQueryId: Gateway.PersistedQuery.responseTts,
                variables: variables,
                in: webView
            )
            return GeminiGraphQLClient.decodeAudioData(from: response)
        } catch {
            Self.logger.notice(
                "synthesizeSpeechChunk: GraphQL TTS failed (\(error.localizedDescription, privacy: .public))"
            )
            return nil
        }
    }

    /// DOM fallback that clicks Gemini's `<tts-control-v2>` listen button on the latest `model-response`.
    func triggerDOMSpeechPlayback(in webView: WKWebView) async -> Bool {
        do {
            let result = try await invokeJS(
                Self.clickLatestTurnScopedButtonScript,
                arguments: [
                    "containerSelectors": GeminiBridgeSelectors.ConversationDOM.modelResponse.all,
                    "buttonSelectors": GeminiBridgeSelectors.ConversationDOM.ttsControl.all,
                    "scopePrefix": GeminiBridgeSelectors.ConversationDOM.modelResponse.primary + " "
                ],
                in: webView,
                action: "triggerDOMSpeechPlayback"
            )
            return boolValue(result["clicked"])
        } catch {
            return false
        }
    }

    // MARK: - Private v2.2 Helpers

    private func openOverlayAndPickVariant(
        triggerSelectors: [String],
        variant: RegenerateVariant,
        in webView: WKWebView,
        deadline: ContinuousClock.Instant
    ) async throws -> Bool {
        let triggerResult = try await invokeJS(
            Self.clickLatestTurnScopedButtonScript,
            arguments: [
                "containerSelectors": GeminiBridgeSelectors.ConversationDOM.modelResponse.all,
                "buttonSelectors": triggerSelectors,
                "scopePrefix": GeminiBridgeSelectors.ConversationDOM.modelResponse.primary + " "
            ],
            in: webView,
            action: "regenerateVariant.openTrigger"
        )
        guard boolValue(triggerResult["clicked"]) else {
            return false
        }

        let menuWait = regenerateMenuWait > .milliseconds(450) ? regenerateMenuWait : .milliseconds(450)
        let menuDeadline = min(deadline, ContinuousClock.now + menuWait)
        let (testIdHints, keywords) = Self.variantMatchingHints(for: variant)
        let optionCodeString = variant.geminiOptionCode.map(String.init) ?? ""

        while true {
            try Task.checkCancellation()
            let pickResult = try await invokeJS(
                Self.clickOverlayVariantOptionScript,
                arguments: [
                    "itemSelectors": GeminiBridgeSelectors.ConversationDOM.overlayMenuItems.all,
                    "explicitSelectors": variant == .retryWithoutTools
                        ? GeminiBridgeSelectors.ConversationDOM.retryWithoutToolButton.all
                        : [],
                    "optionCode": optionCodeString,
                    "testIdHints": testIdHints,
                    "keywords": keywords
                ],
                in: webView,
                action: "regenerateVariant.pickOption"
            )
            if boolValue(pickResult["clicked"]) {
                return true
            }
            if ContinuousClock.now >= menuDeadline {
                break
            }
            try await sleepStep(until: menuDeadline)
        }

        _ = try? await invokeJS(
            Self.dismissOverlayScript,
            arguments: [:],
            in: webView,
            action: "regenerateVariant.dismissOverlay"
        )
        return false
    }

    private func attemptDOMShareLinkFallback(in webView: WKWebView) async -> ShareLinkResult? {
        do {
            let result = try await invokeJS(
                Self.domCreateShareLinkScript,
                arguments: [
                    "shareSelectors": GeminiBridgeSelectors.ConversationDOM.shareButton.all,
                    "overlayItemSelectors": GeminiBridgeSelectors.ConversationDOM.overlayMenuItems.all
                ],
                in: webView,
                action: "createPublicShareLink.domFallback"
            )
            if boolValue(result["ok"]),
               let rawURL = (result["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: rawURL),
               url.scheme?.lowercased() == "https" {
                let externalId = url.lastPathComponent.isEmpty ? nil : url.lastPathComponent
                return ShareLinkResult(url: url, externalUrlId: externalId, shareToken: nil)
            }
        } catch {
            Self.logger.notice("createPublicShareLink: DOM fallback failed (\(error.localizedDescription, privacy: .public))")
        }
        return nil
    }

    private nonisolated static func variantMatchingHints(for variant: RegenerateVariant) -> (testIds: [String], keywords: [String]) {
        switch variant {
        case .tryAgain:
            return (["regenerate-option", "try-again", "redo"], ["try again", "redo", "regenerate", "重试", "重新生成"])
        case .shorter:
            return (["shorter", "modify-shorter"], ["shorter", "更精简", "更短", "简短"])
        case .longer:
            return (["longer", "modify-longer"], ["longer", "更详细", "更长", "详细"])
        case .simpler:
            return (["simpler", "modify-simpler"], ["simpler", "更通俗", "更简单", "通俗"])
        case .casual:
            return (["casual", "modify-casual"], ["more casual", "casual", "更口语", "更随意", "口语"])
        case .professional:
            return (["professional", "modify-professional"], ["more professional", "professional", "更正式", "更专业", "正式"])
        case .retryWithoutTools:
            return (["retry-without-tool-button", "without-tool"], ["retry without tools", "without tools", "不使用工具"])
        }
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

        let folderAttachments = attachments.filter(\.isFolder)
        var regularAttachments = attachments.filter { !$0.isFolder }

        for folder in folderAttachments {
            let stagedNatively = try await stageFolderAttachment(folder, in: webView, deadline: deadline)
            if !stagedNatively, let entries = folder.folderEntries, !entries.isEmpty {
                let consolidated = FolderAttachmentScanner.buildConsolidatedTextBundle(
                    folderName: folder.filename,
                    entries: entries
                )
                regularAttachments.append(
                    StagedAttachment(
                        filename: consolidated.filename,
                        mimeType: consolidated.mimeType,
                        data: consolidated.data,
                        isImage: false
                    )
                )
            }
        }

        guard !regularAttachments.isEmpty else { return }

        var totalBytes = 0
        for attachment in regularAttachments {
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
        let encodedFiles: [[String: Any]] = regularAttachments.map { item in
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

        let expectedPreviewCount = initialPreviewCount + regularAttachments.count
        let pasteFallbackDeadline = min(deadline, ContinuousClock.now + pasteFallbackDelay)
        var pasteIncrementedPreviews = false

        while true {
            try Task.checkCancellation()
            let status = try await readAttachmentStatus(in: webView)
            if status.previewCount >= expectedPreviewCount && status.spinnerCount == 0 {
                let elapsedMs = elapsedMilliseconds(since: startedAt)
                Self.logger.notice(
                    "stageAttachments: ready via paste count=\(regularAttachments.count, privacy: .public) bytes=\(totalBytes, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
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
                    "stageAttachments: ready via \(path, privacy: .public) count=\(regularAttachments.count, privacy: .public) bytes=\(totalBytes, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
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
                reason: "Timed out waiting for \(regularAttachments.count) attachment preview(s) to appear (detected \(observedNew))."
            )
        }
        throw ChatTransportError.actionDriverFailed(
            reason: "Timed out waiting for attachment upload to finish (\(lastStatus.spinnerCount) spinner(s) still active)."
        )
    }

    /// Attempts to stage a directory bundle via Gemini's `<code-folder-uploader>` (`webkitRelativePath`).
    /// Returns `true` when the native folder uploader accepted the directory and cleared its upload spinners;
    /// returns `false` when the account lacks `Import code` so callers can fall back to a consolidated bundle.
    private func stageFolderAttachment(
        _ folder: StagedAttachment,
        in webView: WKWebView,
        deadline: ContinuousClock.Instant
    ) async throws -> Bool {
        guard let entries = folder.folderEntries, !entries.isEmpty else {
            return false
        }

        let initialStatus = try await readAttachmentStatus(in: webView)
        let encodedEntries: [[String: Any]] = entries.map { entry in
            [
                "name": entry.filename,
                "relativePath": entry.relativePath,
                "type": entry.mimeType.isEmpty ? "text/plain" : entry.mimeType,
                "base64": entry.data.base64EncodedString()
            ]
        }

        let injectResult = try await invokeJS(
            Self.stageCodeFolderScript,
            arguments: [
                "uploadTriggerSelectors": GeminiBridgeSelectors.ComposerDOM.uploadMenuTrigger.all,
                "codeImportSelectors": GeminiBridgeSelectors.ComposerDOM.codeImportTrigger.all,
                "folderItemSelectors": GeminiBridgeSelectors.ComposerDOM.codeFolderUploadItem.all,
                "dirInputSelectors": GeminiBridgeSelectors.ComposerDOM.directoryFileInput.all,
                "files": encodedEntries
            ],
            in: webView,
            action: "stageFolderAttachment.inject"
        )

        guard boolValue(injectResult["ok"]) else {
            let reason = (injectResult["reason"] as? String) ?? "unavailable"
            Self.logger.notice("stageFolderAttachment: code-folder-uploader unavailable (\(reason, privacy: .public)); using consolidated codebase fallback")
            return false
        }

        let previewDetectDeadline = min(deadline, ContinuousClock.now + .milliseconds(1200))
        var sawFolderPreview = false
        while ContinuousClock.now < previewDetectDeadline {
            try Task.checkCancellation()
            let status = try await readAttachmentStatus(in: webView)
            if status.previewCount > initialStatus.previewCount {
                sawFolderPreview = true
                if status.spinnerCount == 0 {
                    return true
                }
                break
            }
            try await sleepStep(until: previewDetectDeadline)
        }

        guard sawFolderPreview else {
            return false
        }

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let status = try await readAttachmentStatus(in: webView)
            if status.previewCount > initialStatus.previewCount && status.spinnerCount == 0 {
                Self.logger.notice("stageFolderAttachment: folder '\(folder.filename, privacy: .public)' uploaded natively (\(entries.count, privacy: .public) files)")
                return true
            }
            try await sleepStep(until: deadline)
        }

        throw ChatTransportError.actionDriverFailed(
            reason: "Timed out waiting for folder '\(folder.filename)' upload to finish."
        )
    }

    // MARK: - Composer Tool Mode & Deep Research Actions

    /// Synchronizes Gemini's `toolbox-drawer` tool mode (`Canvas` or `Deep Research`), or clears any
    /// active tool chip when `tool == nil`. Best-effort if the signed-in account hides `toolbox-drawer`.
    func setComposerTool(_ tool: ComposerToolMode?, in webView: WKWebView) async throws {
        let targetKeywords: [String]
        let targetIcons: [String]
        switch tool {
        case .none:
            targetKeywords = []
            targetIcons = []
        case .canvas:
            targetKeywords = ["canvas", "画布"]
            targetIcons = ["select_window_2", "edit_note", "note_stack", "draft"]
        case .deepResearch:
            targetKeywords = ["deep research", "深度研究"]
            targetIcons = ["travel_explore", "manage_search", "Troubleshoot", "globe_book"]
        }

        _ = try await invokeJS(
            Self.syncComposerToolScript,
            arguments: [
                "deselectSelectors": GeminiBridgeSelectors.ComposerDOM.toolboxDeselectButton.all,
                "drawerTriggerSelectors": GeminiBridgeSelectors.ComposerDOM.toolboxDrawerTrigger.all,
                "drawerItemSelectors": GeminiBridgeSelectors.ComposerDOM.toolboxDrawerItem.all,
                "targetKeywords": targetKeywords,
                "targetIcons": targetIcons
            ],
            in: webView,
            action: "setComposerTool"
        )
    }

    /// Clicks the `Start Research` (`[data-test-id="confirm-button"]`) button on the latest
    /// `deep-research-confirmation-widget` in the conversation timeline.
    func confirmDeepResearchPlan(in webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + timeout
        var lastReason = "missing"
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let result = try await invokeJS(
                Self.clickEnabledControlScript,
                arguments: [
                    "selectors": GeminiBridgeSelectors.ConversationDOM.deepResearchConfirmButton.all
                ],
                in: webView,
                action: "confirmDeepResearchPlan"
            )
            if boolValue(result["clicked"]) {
                Self.logger.notice("confirmDeepResearchPlan: clicked Start Research")
                return
            }
            if let reason = result["reason"] as? String {
                lastReason = reason
            }
            try await sleepStep(until: deadline)
        }

        throw ChatTransportError.actionDriverFailed(
            reason: "Deep Research confirmation button was unavailable (\(lastReason))."
        )
    }

    /// Probes the hidden page DOM for Deep Research confirmation plans, live processing status,
    /// or active Canvas immersive text to supplement wire-parsed `ArtifactCardInfo` items.
    func probeLatestTurnDOMArtifacts(in webView: WKWebView) async -> (
        planArtifact: ArtifactCardInfo?,
        progress: DeepResearchProgress?,
        canvasText: String?,
        canvasTitle: String?
    ) {
        guard let result = try? await invokeJS(
            Self.probeRichWidgetsScript,
            arguments: [
                "widgetSelectors": GeminiBridgeSelectors.ConversationDOM.deepResearchConfirmationWidget.all,
                "statusSelectors": GeminiBridgeSelectors.ConversationDOM.deepResearchProcessingStatus.all
            ],
            in: webView,
            action: "probeLatestTurnDOMArtifacts"
        ) else {
            return (nil, nil, nil, nil)
        }

        var planCard: ArtifactCardInfo?
        if let rawSteps = result["planSteps"] as? [[String: Any]], !rawSteps.isEmpty {
            let steps: [DeepResearchPlanStep] = rawSteps.enumerated().compactMap { idx, dict in
                guard let title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else {
                    return nil
                }
                let detail = (dict["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return DeepResearchPlanStep(
                    id: "dom-step-\(idx)",
                    title: title,
                    detail: (detail?.isEmpty == false) ? detail : nil
                )
            }
            if !steps.isEmpty {
                let planTitle = ((result["planTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? String(localized: "Research Plan")
                let estimate = ((result["timeEstimate"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                let isConfirmed = boolValue(result["isPlanConfirmed"])
                planCard = ArtifactCardInfo(
                    id: "deep-research-plan-dom",
                    kind: .deepResearch,
                    title: planTitle,
                    subtitle: estimate,
                    plan: DeepResearchPlan(steps: steps, estimatedTimeText: estimate, isConfirmed: isConfirmed)
                )
            }
        }

        var progress: DeepResearchProgress?
        if let statusText = (result["processingStatus"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !statusText.isEmpty {
            progress = DeepResearchProgress(
                statusText: statusText,
                isRunning: boolValue(result["isProcessingRunning"]),
                browsedSourceCount: intValue(result["sourceCount"])
            )
        }

        let canvasText = ((result["canvasText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let canvasTitle = ((result["canvasTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }

        return (planCard, progress, canvasText, canvasTitle)
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
            if (spec.relativePath) {
                try {
                    Object.defineProperty(file, 'webkitRelativePath', {
                        value: spec.relativePath,
                        configurable: true
                    });
                } catch (_) {}
            }
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

    private nonisolated static let stageCodeFolderScript = jsCommonHelpers + """
    let capturedInput = null;
    const origClick = HTMLInputElement.prototype.click;
    HTMLInputElement.prototype.click = function() {
        if (this && (this.webkitdirectory || (this.hasAttribute && this.hasAttribute('webkitdirectory')))) {
            capturedInput = this;
            return;
        }
        return origClick.apply(this, arguments);
    };

    try {
        let dirInput = queryFirstMatching(dirInputSelectors, false);
        if (!dirInput) {
            const uploadTrigger = queryFirstMatching(uploadTriggerSelectors, false);
            if (uploadTrigger && !isElementDisabled(uploadTrigger.element)) {
                resolveClickTarget(uploadTrigger.element).click();
                await nextFrameAndMicrotask();
            }

            const codeImport = queryFirstMatching(codeImportSelectors, false);
            if (codeImport && !isElementDisabled(codeImport.element)) {
                resolveClickTarget(codeImport.element).click();
                await nextFrameAndMicrotask();
            }

            const folderItem = queryFirstMatching(folderItemSelectors, false);
            if (folderItem && !isElementDisabled(folderItem.element)) {
                resolveClickTarget(folderItem.element).click();
                await nextFrameAndMicrotask();
            }

            dirInput = capturedInput ? { element: capturedInput, selectorIndex: 0 } : queryFirstMatching(dirInputSelectors, false);
        }

        if (!dirInput || !dirInput.element) {
            return { ok: false, reason: 'missing-directory-input' };
        }

        const dt = buildDataTransfer(files);
        dirInput.element.files = dt.files;
        dirInput.element.dispatchEvent(new Event('change', { bubbles: true }));
        await nextFrameAndMicrotask();
        return { ok: true };
    } finally {
        HTMLInputElement.prototype.click = origClick;
    }
    """

    private nonisolated static let syncComposerToolScript = jsCommonHelpers + """
    const existingDeselect = queryFirstMatching(deselectSelectors, false);
    if (targetKeywords.length === 0 && targetIcons.length === 0) {
        if (existingDeselect && !isElementDisabled(existingDeselect.element)) {
            resolveClickTarget(existingDeselect.element).click();
            await nextFrameAndMicrotask();
        }
        return { ok: true, cleared: true };
    }

    const matchesTarget = (el) => {
        if (!el) return false;
        const text = String(el.textContent || el.getAttribute('aria-label') || '').toLowerCase();
        for (let i = 0; i < targetKeywords.length; i += 1) {
            if (text.includes(String(targetKeywords[i]).toLowerCase())) return true;
        }
        const icons = el.querySelectorAll ? el.querySelectorAll('mat-icon, gem-icon') : [];
        for (let i = 0; i < icons.length; i += 1) {
            const fontIcon = String(
                icons[i].getAttribute('fonticon')
                || icons[i].getAttribute('data-mat-icon-name')
                || icons[i].textContent
                || ''
            ).trim().toLowerCase();
            for (let k = 0; k < targetIcons.length; k += 1) {
                if (fontIcon === String(targetIcons[k]).toLowerCase()) return true;
            }
        }
        return false;
    };

    if (existingDeselect && matchesTarget(existingDeselect.element.closest('toolbox-drawer-item') || existingDeselect.element)) {
        return { ok: true, alreadySelected: true };
    }
    if (existingDeselect && !isElementDisabled(existingDeselect.element)) {
        resolveClickTarget(existingDeselect.element).click();
        await nextFrameAndMicrotask();
    }

    let items = queryAllFirstGroup(drawerItemSelectors).elements;
    let matchedItem = items.find(matchesTarget);

    if (!matchedItem) {
        const trigger = queryFirstMatching(drawerTriggerSelectors, false);
        if (trigger && !isElementDisabled(trigger.element)) {
            resolveClickTarget(trigger.element).click();
            await nextFrameAndMicrotask();
            items = queryAllFirstGroup(drawerItemSelectors).elements;
            matchedItem = items.find(matchesTarget);
        }
    }

    if (!matchedItem) {
        return { ok: false, reason: 'tool-not-found' };
    }

    const clickTarget = resolveClickTarget(matchedItem);
    if (!isElementDisabled(clickTarget)) {
        clickTarget.click();
        await nextFrameAndMicrotask();
    }
    return { ok: true, selected: true };
    """

    private nonisolated static let probeRichWidgetsScript = jsCommonHelpers + """
    const out = {};

    const widgets = queryAllFirstGroup(widgetSelectors).elements;
    if (widgets.length > 0) {
        const latestWidget = widgets[widgets.length - 1];
        const heading = latestWidget.querySelector('[role="heading"], .title');
        if (heading) out.planTitle = String(heading.textContent || '').trim();

        const stepEls = latestWidget.querySelectorAll('[data-test-id="plan-step"], .research-step');
        const steps = [];
        for (let i = 0; i < stepEls.length; i += 1) {
            const titleEl = stepEls[i].querySelector('.plan-step-title, .research-step-title') || stepEls[i];
            const detailEl = stepEls[i].querySelector('.research-step-description');
            const title = String(titleEl ? titleEl.textContent : '').trim();
            const detail = detailEl ? String(detailEl.textContent || '').trim() : '';
            if (title) steps.push({ title: title, detail: detail });
        }
        if (steps.length > 0) out.planSteps = steps;

        const estEl = latestWidget.querySelector('[data-test-id="time-estimation-message"], .time-estimation-message');
        if (estEl) out.timeEstimate = String(estEl.textContent || '').trim();

        const confirmBtn = latestWidget.querySelector('[data-test-id="confirm-button"], button.confirm-button');
        out.isPlanConfirmed = !confirmBtn || isElementDisabled(confirmBtn);
    }

    const statusEls = queryAllFirstGroup(statusSelectors).elements;
    if (statusEls.length > 0) {
        const latestStatus = statusEls[statusEls.length - 1];
        const text = String(latestStatus.textContent || '').replace(/\\s+/g, ' ').trim();
        if (text) {
            out.processingStatus = text;
            out.isProcessingRunning = true;
            const numMatch = text.match(/(\\d+)/);
            if (numMatch) out.sourceCount = parseInt(numMatch[1], 10);
        }
    }

    const immersive = document.querySelector('immersive-panel, deep-research-immersive-panel');
    if (immersive) {
        const titleEl = immersive.querySelector('.immersive-title, header h1, header h2, [data-test-id="immersive-title"]');
        if (titleEl) out.canvasTitle = String(titleEl.textContent || '').trim();
        const codeEl = immersive.querySelector('xap-code-editor, pre code, .cm-content, .monaco-editor');
        const docEl = immersive.querySelector('immersive-editor, .markdown-main-panel, .deep-research-content');
        if (codeEl && codeEl.textContent) {
            out.canvasText = String(codeEl.textContent);
        } else if (docEl && docEl.innerText) {
            out.canvasText = String(docEl.innerText);
        }
    }

    return out;
    """

    private nonisolated static let clickOverlayVariantOptionScript = jsCommonHelpers + #"""
    const matchesVariant = (el) => {
        if (!el) return false;
        const attrs = [
            el.getAttribute ? el.getAttribute('data-option-id') : '',
            el.getAttribute ? el.getAttribute('data-value') : '',
            el.getAttribute ? el.getAttribute('data-test-id') : '',
            el.getAttribute ? el.getAttribute('value') : '',
            el.getAttribute ? el.getAttribute('jslog') : ''
        ].map((v) => String(v || '').toLowerCase());

        if (optionCode && optionCode.length > 0) {
            const codeLower = String(optionCode).toLowerCase();
            for (let i = 0; i < attrs.length; i += 1) {
                if (attrs[i] === codeLower || attrs[i].includes(codeLower)) {
                    return true;
                }
            }
        }

        const testId = attrs[2];
        for (let i = 0; i < testIdHints.length; i += 1) {
            if (testId && testId.includes(String(testIdHints[i]).toLowerCase())) {
                return true;
            }
        }

        const labelText = String(
            (el.getAttribute && el.getAttribute('aria-label'))
            || el.textContent
            || ''
        ).replace(/\s+/g, ' ').trim().toLowerCase();
        if (labelText) {
            for (let i = 0; i < keywords.length; i += 1) {
                if (labelText.includes(String(keywords[i]).toLowerCase())) {
                    return true;
                }
            }
        }
        return false;
    };

    if (Array.isArray(explicitSelectors) && explicitSelectors.length > 0) {
        const direct = queryFirstMatching(explicitSelectors, false);
        if (direct && direct.element) {
            const target = resolveClickTarget(direct.element);
            if (!isElementDisabled(direct.element) && !isElementDisabled(target)) {
                target.click();
                await nextFrameAndMicrotask();
                return { clicked: true, via: 'explicit' };
            }
        }
    }

    const items = queryAllFirstGroup(itemSelectors).elements;
    let sawDisabled = false;
    for (let i = 0; i < items.length; i += 1) {
        const candidate = items[i];
        if (!matchesVariant(candidate)) continue;
        const target = resolveClickTarget(candidate);
        if (isElementDisabled(candidate) || isElementDisabled(target)) {
            sawDisabled = true;
            continue;
        }
        target.click();
        await nextFrameAndMicrotask();
        return { clicked: true, via: 'overlay' };
    }

    return { clicked: false, reason: sawDisabled ? 'disabled' : 'missing' };
    """#

    private nonisolated static let dismissOverlayScript = jsCommonHelpers + #"""
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
    return { ok: true };
    """#

    private nonisolated static let clickTurnBranchButtonScript = jsCommonHelpers + #"""
    const containers = queryAllFirstGroup(containerSelectors).elements;
    if (containers.length === 0) {
        return { clicked: false, reason: 'missing-container' };
    }

    const matchesId = (el, id) => {
        if (!el || !id) return false;
        const attrs = ['id', 'data-response-id', 'data-request-id', 'data-turn-id'];
        for (let i = 0; i < attrs.length; i += 1) {
            const val = el.getAttribute ? el.getAttribute(attrs[i]) : null;
            if (val && val.includes(id)) return true;
        }
        try {
            if (el.querySelector(`[id*="${CSS.escape(id)}"], [data-response-id*="${CSS.escape(id)}"], [data-request-id*="${CSS.escape(id)}"]`)) {
                return true;
            }
        } catch (_) {}
        return false;
    };

    let targetContainer = containers[containers.length - 1];
    if (responseId || requestId) {
        for (let i = containers.length - 1; i >= 0; i -= 1) {
            if ((responseId && matchesId(containers[i], responseId)) || (requestId && matchesId(containers[i], requestId))) {
                targetContainer = containers[i];
                break;
            }
        }
    }

    const directBranch = findInsideScope(targetContainer, branchSelectors, scopePrefix, false);
    if (directBranch && directBranch.element) {
        const target = resolveClickTarget(directBranch.element);
        if (!isElementDisabled(directBranch.element) && !isElementDisabled(target)) {
            target.click();
            await nextFrameAndMicrotask();
            return { clicked: true, via: 'direct' };
        }
    }

    const moreBtn = findInsideScope(targetContainer, moreSelectors, scopePrefix, false);
    if (moreBtn && moreBtn.element) {
        const moreTarget = resolveClickTarget(moreBtn.element);
        if (!isElementDisabled(moreBtn.element) && !isElementDisabled(moreTarget)) {
            moreTarget.click();
            await nextFrameAndMicrotask();

            const overlayBranch = queryFirstMatching(branchSelectors, false);
            if (overlayBranch && overlayBranch.element) {
                const target = resolveClickTarget(overlayBranch.element);
                if (!isElementDisabled(overlayBranch.element) && !isElementDisabled(target)) {
                    target.click();
                    await nextFrameAndMicrotask();
                    return { clicked: true, via: 'overflow-selector' };
                }
            }

            const menuItems = queryAllFirstGroup(overlayItemSelectors).elements;
            for (let i = 0; i < menuItems.length; i += 1) {
                const text = String(menuItems[i].textContent || menuItems[i].getAttribute('aria-label') || '').toLowerCase();
                if (text.includes('branch') || text.includes('分支')) {
                    const target = resolveClickTarget(menuItems[i]);
                    if (!isElementDisabled(menuItems[i]) && !isElementDisabled(target)) {
                        target.click();
                        await nextFrameAndMicrotask();
                        return { clicked: true, via: 'overflow-label' };
                    }
                }
            }

            const esc = new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true, cancelable: true });
            document.dispatchEvent(esc);
            await nextFrameAndMicrotask();
        }
    }

    return { clicked: false, reason: 'missing' };
    """#

    private nonisolated static let domCreateShareLinkScript = jsCommonHelpers + #"""
    const extractShareUrlFromDom = () => {
        const shareRe = /https:\/\/gemini\.google\.com\/share\/[A-Za-z0-9_-]+/;
        const inputs = document.querySelectorAll('.cdk-overlay-container input, mat-dialog-container input');
        for (let i = 0; i < inputs.length; i += 1) {
            const val = String(inputs[i].value || '');
            const m = val.match(shareRe);
            if (m) return m[0];
        }
        const links = document.querySelectorAll('.cdk-overlay-container a[href], mat-dialog-container a[href]');
        for (let i = 0; i < links.length; i += 1) {
            const href = String(links[i].getAttribute('href') || '');
            const m = href.match(shareRe);
            if (m) return m[0];
        }
        const dialogs = document.querySelectorAll('mat-dialog-container, .cdk-overlay-pane');
        for (let i = 0; i < dialogs.length; i += 1) {
            const txt = String(dialogs[i].textContent || '');
            const m = txt.match(shareRe);
            if (m) return m[0];
        }
        return '';
    };

    const dismissDialog = async () => {
        const esc = new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true, cancelable: true });
        document.dispatchEvent(esc);
        if (document.activeElement && document.activeElement !== document) {
            document.activeElement.dispatchEvent(esc);
        }
        await nextFrameAndMicrotask();
    };

    const shareTrigger = queryFirstMatching(shareSelectors, false);
    if (!shareTrigger || !shareTrigger.element) {
        return { ok: false, reason: 'missing-share-button' };
    }
    const triggerTarget = resolveClickTarget(shareTrigger.element);
    if (isElementDisabled(shareTrigger.element) || isElementDisabled(triggerTarget)) {
        return { ok: false, reason: 'disabled-share-button' };
    }

    try {
        triggerTarget.click();
        await nextFrameAndMicrotask();

        // If share opened a menu first, click the Share item.
        const menuItems = queryAllFirstGroup(overlayItemSelectors).elements;
        for (let i = 0; i < menuItems.length; i += 1) {
            const text = String(menuItems[i].textContent || menuItems[i].getAttribute('aria-label') || '').toLowerCase();
            if (text.includes('share') || text.includes('分享')) {
                const itemTarget = resolveClickTarget(menuItems[i]);
                if (!isElementDisabled(itemTarget)) {
                    itemTarget.click();
                    await nextFrameAndMicrotask();
                    break;
                }
            }
        }

        // Click "Create public link" if presented inside a share confirmation dialog.
        const dialogButtons = document.querySelectorAll('mat-dialog-container button, .cdk-overlay-pane button');
        for (let i = 0; i < dialogButtons.length; i += 1) {
            const text = String(dialogButtons[i].textContent || dialogButtons[i].getAttribute('aria-label') || '').toLowerCase();
            if ((text.includes('create') && text.includes('link')) || text.includes('创建公开链接')) {
                if (!isElementDisabled(dialogButtons[i])) {
                    dialogButtons[i].click();
                    await nextFrameAndMicrotask();
                    break;
                }
            }
        }

        const pollEnd = Date.now() + 3500;
        while (Date.now() < pollEnd) {
            const url = extractShareUrlFromDom();
            if (url) {
                return { ok: true, url: url };
            }
            await new Promise((r) => setTimeout(r, 120));
        }
        return { ok: false, reason: 'share-url-not-found' };
    } finally {
        await dismissDialog();
    }
    """#
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

    func setComposerTool(in webView: WKWebView, tool: ComposerToolMode?) async throws {
        try await actionDriver.setComposerTool(tool, in: webView)
    }

    func confirmDeepResearchPlan(in webView: WKWebView) async throws {
        try await actionDriver.confirmDeepResearchPlan(in: webView)
    }

    func probeLatestTurnDOMArtifacts(in webView: WKWebView) async -> (
        planArtifact: ArtifactCardInfo?,
        progress: DeepResearchProgress?,
        canvasText: String?,
        canvasTitle: String?
    ) {
        await actionDriver.probeLatestTurnDOMArtifacts(in: webView)
    }

    func submitPrompt(
        in webView: WKWebView,
        text: String,
        quotes: [QuotedPassage],
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
        try await actionDriver.submitPrompt(text: text, quotes: quotes, attachments: attachments, in: webView)
    }

    func regenerateLastTurn(
        in webView: WKWebView,
        variant: RegenerateVariant,
        modelId: String?
    ) async throws {
        try await actionDriver.regenerateLatestResponse(variant: variant, modelId: modelId, in: webView)
    }

    func branchConversation(
        in webView: WKWebView,
        conversationId: String,
        requestId: String?,
        responseId: String?
    ) async -> String? {
        await actionDriver.branchConversation(
            conversationId: conversationId,
            requestId: requestId,
            responseId: responseId,
            in: webView
        )
    }

    func createPublicShareLink(
        in webView: WKWebView,
        conversationId: String,
        scope: ShareLinkScope,
        selectedDraftId: String?
    ) async throws -> ShareLinkResult {
        try await actionDriver.createPublicShareLink(
            conversationId: conversationId,
            scope: scope,
            selectedDraftId: selectedDraftId,
            in: webView
        )
    }

    func exportToCloudService(
        in webView: WKWebView,
        service: CloudExportService,
        title: String,
        markdownText: String
    ) async throws -> URL {
        try await actionDriver.exportToCloudService(
            service: service,
            title: title,
            markdownText: markdownText,
            in: webView
        )
    }

    func searchRemoteConversations(
        in webView: WKWebView,
        query: String,
        limit: Int
    ) async -> [ConversationSearchHit] {
        await actionDriver.searchRemoteConversations(query: query, limit: limit, in: webView)
    }

    func synthesizeSpeechChunk(
        in webView: WKWebView,
        text: String,
        locale: String
    ) async -> Data? {
        await actionDriver.synthesizeSpeechChunk(text: text, locale: locale, in: webView)
    }
}
