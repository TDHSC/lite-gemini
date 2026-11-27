import AppKit
import Foundation
import os
import WebKit

// MARK: - GeminiWriteDriving

/// Pluggable write-path driver attached to `GeminiSessionEngine` (implemented by `GeminiActionDriver` in T08).
///
/// Keeps `GeminiSessionEngine`'s read tap, stream multiplexing, and auth lifecycle decoupled from
/// DOM mutation selectors so Wave 2 can wire write actions cleanly without modifying read plumbing.
@MainActor
protocol GeminiWriteDriving: AnyObject {

    /// Injects prompt text and staged attachments into the hidden page and submits the turn.
    func submitPrompt(
        in webView: WKWebView,
        text: String,
        attachments: [StagedAttachment],
        modelId: String?,
        isTemporaryChat: Bool
    ) async throws

    /// Triggers Gemini's Stop Generating control in the hidden page.
    func stopStreaming(in webView: WKWebView) async

    /// Replaces the most recent user turn's prompt in the hidden page and submits the edit.
    func editLastTurn(in webView: WKWebView, newText: String) async throws

    /// Triggers Regenerate / Redo on the latest assistant turn in the hidden page.
    func regenerateLastTurn(in webView: WKWebView) async throws

    /// Selects the requested model option inside the hidden page's model picker.
    func selectModel(in webView: WKWebView, id: String) async throws

    /// Synchronizes the hidden page's temporary-chat toggle to the desired enabled state.
    func setTemporaryChat(in webView: WKWebView, enabled: Bool) async throws

    /// Synchronizes an optional composer tool mode (`Canvas` or `Deep Research`) on the hidden page.
    func setComposerTool(in webView: WKWebView, tool: ComposerToolMode?) async throws

    /// Clicks the `Start Research` confirmation button on a Deep Research plan card.
    func confirmDeepResearchPlan(in webView: WKWebView) async throws

    /// Probes the hidden page DOM for Deep Research plans, progress status, or Canvas text.
    func probeLatestTurnDOMArtifacts(in webView: WKWebView) async -> (
        planArtifact: ArtifactCardInfo?,
        progress: DeepResearchProgress?,
        canvasText: String?,
        canvasTitle: String?
    )

    /// Injects prompt text with staged quotes and attachments into the hidden page and submits.
    func submitPrompt(
        in webView: WKWebView,
        text: String,
        quotes: [QuotedPassage],
        attachments: [StagedAttachment],
        modelId: String?,
        isTemporaryChat: Bool
    ) async throws

    /// Regenerates the latest assistant turn with a specific variant and optional model switch.
    func regenerateLastTurn(
        in webView: WKWebView,
        variant: RegenerateVariant,
        modelId: String?
    ) async throws

    /// Branches a conversation from the specified turn via Omakase GraphQL or DOM fallback.
    func branchConversation(
        in webView: WKWebView,
        conversationId: String,
        requestId: String?,
        responseId: String?
    ) async -> String?

    /// Creates a public `gemini.google.com/share/<id>` link for the conversation or single turn.
    func createPublicShareLink(
        in webView: WKWebView,
        conversationId: String,
        scope: ShareLinkScope,
        selectedDraftId: String?
    ) async throws -> ShareLinkResult

    /// Exports a Markdown message to Google Docs, Gmail Drafts, Colab, or Sheets.
    func exportToCloudService(
        in webView: WKWebView,
        service: CloudExportService,
        title: String,
        markdownText: String
    ) async throws -> URL

    /// Searches remote chat history via `SearchChatsPageQuery`.
    func searchRemoteConversations(
        in webView: WKWebView,
        query: String,
        limit: Int
    ) async -> [ConversationSearchHit]

    /// Synthesizes a spoken MP3 audio chunk via `useResponseTtsQuery`.
    func synthesizeSpeechChunk(
        in webView: WKWebView,
        text: String,
        locale: String
    ) async -> Data?
}

extension GeminiWriteDriving {

    func setComposerTool(in webView: WKWebView, tool: ComposerToolMode?) async throws {}

    func confirmDeepResearchPlan(in webView: WKWebView) async throws {}

    func probeLatestTurnDOMArtifacts(in webView: WKWebView) async -> (
        planArtifact: ArtifactCardInfo?,
        progress: DeepResearchProgress?,
        canvasText: String?,
        canvasTitle: String?
    ) {
        (nil, nil, nil, nil)
    }

    func submitPrompt(
        in webView: WKWebView,
        text: String,
        quotes: [QuotedPassage],
        attachments: [StagedAttachment],
        modelId: String?,
        isTemporaryChat: Bool
    ) async throws {
        let combined = QuotedPassage.formatPrompt(text, with: quotes)
        try await submitPrompt(
            in: webView,
            text: combined,
            attachments: attachments,
            modelId: modelId,
            isTemporaryChat: isTemporaryChat
        )
    }

    func regenerateLastTurn(
        in webView: WKWebView,
        variant: RegenerateVariant,
        modelId: String?
    ) async throws {
        try await regenerateLastTurn(in: webView)
    }

    func branchConversation(
        in webView: WKWebView,
        conversationId: String,
        requestId: String?,
        responseId: String?
    ) async -> String? {
        nil
    }

    func createPublicShareLink(
        in webView: WKWebView,
        conversationId: String,
        scope: ShareLinkScope,
        selectedDraftId: String?
    ) async throws -> ShareLinkResult {
        throw GeminiTransportActionError.unsupported
    }

    func exportToCloudService(
        in webView: WKWebView,
        service: CloudExportService,
        title: String,
        markdownText: String
    ) async throws -> URL {
        throw GeminiTransportActionError.unsupported
    }

    func searchRemoteConversations(
        in webView: WKWebView,
        query: String,
        limit: Int
    ) async -> [ConversationSearchHit] {
        []
    }

    func synthesizeSpeechChunk(
        in webView: WKWebView,
        text: String,
        locale: String
    ) async -> Data? {
        nil
    }
}

// MARK: - WeakBridgeMessageHandler

/// Breaks retain cycles because `WKUserContentController` retains message handlers strongly.
@MainActor
private final class WeakBridgeMessageHandler: NSObject, WKScriptMessageHandler {

    weak var delegate: (any WKScriptMessageHandler)?

    init(_ delegate: any WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - PendingRequest

/// Single-shot `@MainActor` async waiter guaranteeing its continuation resumes exactly once
/// across normal completion, timeout, cancellation, and engine teardown.
@MainActor
private final class PendingRequest<Value: Sendable> {

    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutTask: Task<Void, Never>?

    var isPending: Bool {
        continuation != nil
    }

    func wait(
        timeout: Duration,
        timeoutError: @escaping @MainActor () -> Error,
        onStart: @MainActor () -> Void
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: ChatTransportError.cancelled)
                    return
                }
                self.continuation = continuation
                self.timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.fail(with: timeoutError())
                }
                onStart()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.fail(with: ChatTransportError.cancelled)
            }
        }
    }

    func succeed(with value: Value) {
        guard let cont = continuation else {
            return
        }
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        cont.resume(returning: value)
    }

    func fail(with error: Error) {
        guard let cont = continuation else {
            return
        }
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        cont.resume(throwing: error)
    }
}

// MARK: - GeminiSessionEngine

/// Hidden `WKWebView` Session Bridge conforming to `ChatTransport`.
///
/// Owns a `GeminiBaseWebView` configured with both `ClassicWebScripts` (so the same WebView
/// serves Classic Web Mode directly during dual-mode handoffs) and `GeminiBridgeScript` (for
/// passive read-tap observation of WebChannel, SSE, legacy Boq, `batchexecute`, and auth state).
/// Shares `WKWebsiteDataStore`, `PopupCoordinator`, `DownloadManager`, and `TemporaryChatController`.
@MainActor
final class GeminiSessionEngine: NSObject, ChatTransport, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    // MARK: - Nested Types

    private enum StreamBufferState {
        case webChannel(WebChannelStreamBuffer)
        case sse(SSEStreamBuffer)
        case legacyBoq(LegacyBoqStreamBuffer)
    }

    private struct ActiveStreamSession {
        let id: UUID
        let continuation: AsyncThrowingStream<StreamingDelta, Error>.Continuation
        let preexistingRequestIds: Set<String>
        var accumulator = StreamingDeltaAccumulator()
        var boundRequestId: String?
        var driverTask: Task<Void, Never>?
        var progressPollTask: Task<Void, Never>?
    }

    private struct HomeLoadCollector {
        let generation: UInt64
        let requestedAuthUser: Int?
        let requestedTemporaryChat: Bool
        var didCommitNavigation: Bool = false
        var didFinishNavigation: Bool = false
        var receivedBootSnapshot: Bool = false
        var receivedListConversations: Bool = false
        var receivedUserStatus: Bool = false
        var receivedPeopleProfile: Bool = false
        var rpcPermissionDenied: Bool = false
        var bootSnapshot: BootAuthSnapshot?
        var peopleProfile: PeopleProfile?
        var userStatus: UserStatusResult?
        var conversations: [ConversationSummary]?
    }

    private struct ConversationLoadContext {
        let generation: UInt64
        let targetId: String
        var pendingTurns: [ChatTurn]?
        var didCommitNavigation: Bool = false
        var didFinishNavigation: Bool = false
    }

    // MARK: - Logging & Constants

    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "GeminiBridge")

    private enum ScriptHandlerName {
        static let bridge = GeminiBridgeScript.messageHandlerName
        static let imeEnterFix = "imeEnterFix"
        static let temporaryChatIntent = "temporaryChatIntent"
        static let themeColor = "themeColor"
        #if DEBUG
        static let consoleLog = "consoleLog"
        #endif
    }

    // MARK: - Public Dependencies & Hooks

    /// Underlying `WKWebView` backing both Native Mode (hidden) and Classic Web Mode (visible).
    let webView: GeminiBaseWebView

    /// Shared popup coordinator routing sign-in, add-account, and OAuth popups via `NewWindowRouter`.
    let popupCoordinator: PopupCoordinator

    /// Shared download manager owning in-flight `WKDownload` instances.
    let downloadManager: DownloadManager

    /// Controller synchronizing Gemini's temporary-chat toggle state on new chats.
    let temporaryChatController: TemporaryChatController

    /// Pluggable write-path driver (injected with `GeminiActionDriver` in T08).
    var writeDriver: (any GeminiWriteDriving)?

    /// Out-of-band `ChatTransport` event listener.
    var onEvent: (@MainActor (ChatTransportEvent) -> Void)?

    /// Optional callback invoked when the page's computed background color changes (for Classic Web Mode).
    var onPageBackgroundColorChanged: (@MainActor (NSColor) -> Void)?

    /// Optional callback forwarding `DownloadManager` result notices.
    var onDownloadNotice: (@MainActor (DownloadNotice) -> Void)?

    // MARK: - Observable Read State

    private(set) var authState: AuthState = .unknown
    private(set) var recentConversations: [ConversationSummary] = []
    private(set) var availableModels: [ModelOption] = []
    private(set) var selectedModelId: String?
    private(set) var isTemporaryChat: Bool = false
    private(set) var activeChallenge: ChallengeBannerState?
    private(set) var knownAccounts: [AccountScope] = []
    /// Whether offscreen CSS paint suppression is currently enabled on the underlying `WKWebView`.
    private(set) var isRenderSuppressed: Bool

    // MARK: - Configuration & Internal State

    private let baseURL: URL
    private let expectedHost: String
    private let requestTimeout: Duration
    private let homeSettleDelay: Duration
    private let redirectGraceDelay: Duration
    private let renderSuppressor: GeminiRenderSuppressor
    private var renderSuppressionTask: Task<Void, Never>?

    private var latestBootSnapshot: BootAuthSnapshot?
    private var latestPeopleProfile: PeopleProfile?
    private var latestUserStatus: UserStatusResult?
    private var lastObservedRPCPermissionDenied: Bool = false

    private var loadGeneration: UInt64 = 0
    private var pendingHomeLoad: PendingRequest<HomeLoadResult>?
    private var homeLoadCollector: HomeLoadCollector?
    private var homeSettleTask: Task<Void, Never>?

    private var pendingConversationLoad: PendingRequest<ConversationSnapshot>?
    private var conversationLoadContext: ConversationLoadContext?
    private var conversationRedirectCheckTask: Task<Void, Never>?

    private var pendingRecentRefresh: PendingRequest<[ConversationSummary]>?

    private var activeStreamSession: ActiveStreamSession?
    private var streamBuffers: [String: StreamBufferState] = [:]

    #if DEBUG
    private var spikeSession: GeminiSpikeRecorder.Session?
    #endif

    // MARK: - Initialization

    /// Creates a `GeminiSessionEngine` sharing the provided data store, popup coordinator, and download manager.
    ///
    /// Production callers use `WKWebsiteDataStore.default()`; headless harnesses pass `.nonPersistent()`
    /// and a `WKURLSchemeHandler` (`lgtest://`) with zero visible windows.
    init(
        websiteDataStore: WKWebsiteDataStore = .default(),
        popupCoordinator: PopupCoordinator = PopupCoordinator(),
        downloadManager: DownloadManager = DownloadManager(),
        userAgent: String? = nil,
        surfaceBackgroundColor: NSColor? = nil,
        defaultTemporaryChat: @escaping () -> Bool = { false },
        baseURL: URL? = nil,
        customURLSchemeHandlers: [(scheme: String, handler: any WKURLSchemeHandler)] = [],
        requestTimeout: Duration = .seconds(15),
        homeSettleDelay: Duration = .milliseconds(600),
        redirectGraceDelay: Duration = .milliseconds(350),
        suppressRender: Bool = true
    ) {
        let resolvedBaseURL = baseURL
            ?? URL(string: GeminiBridgeSelectors.Endpoints.appURLString)
            ?? URL(fileURLWithPath: "/")
        self.baseURL = resolvedBaseURL
        self.expectedHost = resolvedBaseURL.host?.lowercased() ?? GeminiBridgeSelectors.Endpoints.geminiHost
        self.popupCoordinator = popupCoordinator
        self.downloadManager = downloadManager
        self.requestTimeout = requestTimeout
        self.homeSettleDelay = homeSettleDelay
        self.redirectGraceDelay = redirectGraceDelay
        let suppressor = GeminiRenderSuppressor(suppressRenderByDefault: suppressRender)
        self.isRenderSuppressed = suppressRender
        self.renderSuppressor = suppressor

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        for entry in customURLSchemeHandlers {
            configuration.setURLSchemeHandler(entry.handler, forURLScheme: entry.scheme)
        }

        #if DEBUG
        let consoleScript = WKUserScript(
            source: ClassicWebScripts.consoleLogBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(consoleScript)
        #endif

        ClassicWebScripts.installWebAuthnFallbackIfNeeded(on: configuration.userContentController)

        let imeScript = WKUserScript(
            source: ClassicWebScripts.imeFixScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(imeScript)

        let tempChatIntentScript = WKUserScript(
            source: TemporaryChatController.intentScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(tempChatIntentScript)

        let themeScript = WKUserScript(
            source: ClassicWebScripts.themeSyncScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(themeScript)

        configuration.userContentController.addUserScript(GeminiBridgeScript.makeUserScript())
        suppressor.configureInitialUserScript(on: configuration)

        #if DEBUG
        let attachedSpikeSession = GeminiSpikeRecorder.attach(to: configuration)
        #endif

        let webView = GeminiBaseWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        if let userAgent, !userAgent.isEmpty {
            webView.customUserAgent = userAgent
        }
        if let surfaceBackgroundColor {
            webView.underPageBackgroundColor = surfaceBackgroundColor
        }
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView
        self.temporaryChatController = TemporaryChatController(
            webView: webView,
            isEnabled: defaultTemporaryChat
        )

        super.init()

        #if DEBUG
        self.spikeSession = attachedSpikeSession
        #endif

        let weakHandler = WeakBridgeMessageHandler(self)
        let contentController = webView.configuration.userContentController
        contentController.add(weakHandler, name: ScriptHandlerName.bridge)
        contentController.add(weakHandler, name: ScriptHandlerName.imeEnterFix)
        contentController.add(weakHandler, name: ScriptHandlerName.temporaryChatIntent)
        contentController.add(weakHandler, name: ScriptHandlerName.themeColor)
        #if DEBUG
        contentController.add(weakHandler, name: ScriptHandlerName.consoleLog)
        #endif

        webView.navigationDelegate = self
        webView.uiDelegate = self

        self.downloadManager.onNotice = { [weak self] notice in
            self?.onDownloadNotice?(notice)
        }
        self.writeDriver = DefaultGeminiWriteDriver(
            actionDriver: GeminiActionDriver(timeout: requestTimeout),
            temporaryChatController: self.temporaryChatController
        )
    }

    isolated deinit {
        homeSettleTask?.cancel()
        conversationRedirectCheckTask?.cancel()
        renderSuppressionTask?.cancel()
        pendingHomeLoad?.fail(with: ChatTransportError.cancelled)
        pendingConversationLoad?.fail(with: ChatTransportError.cancelled)
        pendingRecentRefresh?.fail(with: ChatTransportError.cancelled)
        if let active = activeStreamSession {
            active.driverTask?.cancel()
            active.continuation.finish()
            activeStreamSession = nil
        }
        temporaryChatController.cancel()

        let contentController = webView.configuration.userContentController
        contentController.removeScriptMessageHandler(forName: ScriptHandlerName.bridge)
        contentController.removeScriptMessageHandler(forName: ScriptHandlerName.imeEnterFix)
        contentController.removeScriptMessageHandler(forName: ScriptHandlerName.temporaryChatIntent)
        contentController.removeScriptMessageHandler(forName: ScriptHandlerName.themeColor)
        #if DEBUG
        contentController.removeScriptMessageHandler(forName: ScriptHandlerName.consoleLog)
        spikeSession?.detach(from: contentController)
        #endif
    }

    // MARK: - ChatTransport Read & Auth Methods

    func loadHome(authUser: Int?, temporaryChat: Bool) async throws -> HomeLoadResult {
        cancelPendingHomeLoad()
        loadGeneration &+= 1
        let generation = loadGeneration

        // Reset per-navigation auth probes while retaining known accounts across switches.
        latestBootSnapshot = nil
        latestPeopleProfile = nil
        latestUserStatus = nil
        lastObservedRPCPermissionDenied = false

        let collector = HomeLoadCollector(
            generation: generation,
            requestedAuthUser: authUser,
            requestedTemporaryChat: temporaryChat
        )
        homeLoadCollector = collector

        let request = PendingRequest<HomeLoadResult>()
        pendingHomeLoad = request

        let targetURL = buildRouteURL(.newChat(authUser: authUser))

        return try await request.wait(
            timeout: requestTimeout,
            timeoutError: { ChatTransportError.networkError(message: "Timed out loading Gemini home.") },
            onStart: { [weak self] in
                self?.webView.load(URLRequest(url: targetURL))
            }
        )
    }

    func loadConversation(id: String, authUser: Int?) async throws -> ConversationSnapshot {
        let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw ChatTransportError.conversationNotFound(id: id)
        }

        cancelPendingConversationLoad()
        loadGeneration &+= 1
        let generation = loadGeneration

        conversationLoadContext = ConversationLoadContext(
            generation: generation,
            targetId: trimmedId
        )

        let request = PendingRequest<ConversationSnapshot>()
        pendingConversationLoad = request

        let targetURL = buildRouteURL(.conversation(id: trimmedId, authUser: authUser))

        return try await request.wait(
            timeout: requestTimeout,
            timeoutError: { ChatTransportError.networkError(message: "Timed out loading conversation.") },
            onStart: { [weak self] in
                self?.webView.load(URLRequest(url: targetURL))
            }
        )
    }

    func refreshRecentConversations() async throws -> [ConversationSummary] {
        if case .signedOut = authState {
            throw ChatTransportError.notSignedIn
        }

        pendingRecentRefresh?.fail(with: ChatTransportError.cancelled)
        let request = PendingRequest<[ConversationSummary]>()
        pendingRecentRefresh = request

        let authUser = authState.activeAccount?.authUserIndex
        let fallbackHomeURL = buildRouteURL(.newChat(authUser: authUser))

        return try await request.wait(
            timeout: requestTimeout,
            timeoutError: { ChatTransportError.networkError(message: "Timed out refreshing recent conversations.") },
            onStart: { [weak self] in
                guard let self else { return }
                if self.webView.url != nil {
                    self.webView.reload()
                } else {
                    self.webView.load(URLRequest(url: fallbackHomeURL))
                }
            }
        )
    }

    func switchAccount(authUserIndex: Int) async throws -> HomeLoadResult {
        let clampedIndex = max(0, authUserIndex)
        return try await loadHome(authUser: clampedIndex, temporaryChat: false)
    }

    // MARK: - ChatTransport Write Hooks (Delegated to GeminiWriteDriving)

    func sendPrompt(
        text: String,
        attachments: [StagedAttachment],
        modelId: String?,
        isTemporaryChat: Bool
    ) -> AsyncThrowingStream<StreamingDelta, Error> {
        startStreamSession { [weak self] driver in
            guard let self else { return }
            try await driver.submitPrompt(
                in: self.webView,
                text: text,
                attachments: attachments,
                modelId: modelId,
                isTemporaryChat: isTemporaryChat
            )
        }
    }

    func stopStreaming() async {
        finishActiveStream(throwing: nil)
        if let driver = writeDriver {
            await driver.stopStreaming(in: webView)
        }
    }

    func editLastTurn(newText: String) -> AsyncThrowingStream<StreamingDelta, Error> {
        startStreamSession { [weak self] driver in
            guard let self else { return }
            try await driver.editLastTurn(in: self.webView, newText: newText)
        }
    }

    func regenerateLastTurn() -> AsyncThrowingStream<StreamingDelta, Error> {
        startStreamSession { [weak self] driver in
            guard let self else { return }
            try await driver.regenerateLastTurn(in: self.webView)
        }
    }

    func selectModel(id: String) async throws {
        guard let driver = writeDriver else {
            throw ChatTransportError.actionDriverFailed(reason: "Model switching is unavailable without a write driver.")
        }
        try await driver.selectModel(in: webView, id: id)
        selectedModelId = id
        onEvent?(.modelsUpdated(available: availableModels, selectedId: id))
    }

    func setTemporaryChat(_ enabled: Bool) async throws {
        guard let driver = writeDriver else {
            throw ChatTransportError.actionDriverFailed(reason: "Temporary chat toggling is unavailable without a write driver.")
        }
        try await driver.setTemporaryChat(in: webView, enabled: enabled)
        isTemporaryChat = enabled
        onEvent?(.temporaryChatStateChanged(enabled))
    }

    func setComposerTool(_ tool: ComposerToolMode?) async throws {
        guard let driver = writeDriver else { return }
        try await driver.setComposerTool(in: webView, tool: tool)
    }

    func confirmDeepResearchPlan() -> AsyncThrowingStream<StreamingDelta, Error> {
        startStreamSession(enableProgressPolling: true) { [weak self] driver in
            guard let self else { return }
            try await driver.confirmDeepResearchPlan(in: self.webView)
        }
    }

    // MARK: - ChatTransport v2.2 Conversational Power Tools

    func sendPrompt(
        text: String,
        quotes: [QuotedPassage],
        attachments: [StagedAttachment],
        modelId: String?,
        isTemporaryChat: Bool
    ) -> AsyncThrowingStream<StreamingDelta, Error> {
        startStreamSession { [weak self] driver in
            guard let self else { return }
            try await driver.submitPrompt(
                in: self.webView,
                text: text,
                quotes: quotes,
                attachments: attachments,
                modelId: modelId,
                isTemporaryChat: isTemporaryChat
            )
        }
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
            modelId: selectedModelId,
            isTemporaryChat: isTemporaryChat
        )
        do {
            for try await _ in stream {}
        } catch {}
    }

    func regenerateLastTurn(
        variant: RegenerateVariant,
        modelId: String?
    ) -> AsyncThrowingStream<StreamingDelta, Error> {
        startStreamSession { [weak self] driver in
            guard let self else { return }
            try await driver.regenerateLastTurn(
                in: self.webView,
                variant: variant,
                modelId: modelId
            )
            if let modelId = modelId?.trimmingCharacters(in: .whitespacesAndNewlines), !modelId.isEmpty {
                self.selectedModelId = modelId
                self.onEvent?(.modelsUpdated(available: self.availableModels, selectedId: modelId))
            }
        }
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
        guard let driver = writeDriver else {
            return nil
        }
        return await driver.branchConversation(
            in: webView,
            conversationId: conversationId,
            requestId: requestId,
            responseId: responseId
        )
    }

    func createPublicShareLink(
        conversationId: String,
        scope: ShareLinkScope,
        selectedDraftId: String?
    ) async throws -> ShareLinkResult {
        guard let driver = writeDriver else {
            throw GeminiTransportActionError.unsupported
        }
        return try await driver.createPublicShareLink(
            in: webView,
            conversationId: conversationId,
            scope: scope,
            selectedDraftId: selectedDraftId
        )
    }

    func exportToCloudService(
        service: CloudExportService,
        title: String,
        markdownText: String
    ) async throws -> URL {
        guard let driver = writeDriver else {
            throw GeminiTransportActionError.unsupported
        }
        return try await driver.exportToCloudService(
            in: webView,
            service: service,
            title: title,
            markdownText: markdownText
        )
    }

    func searchRemoteConversations(query: String, limit: Int) async -> [ConversationSearchHit] {
        guard let driver = writeDriver else {
            return []
        }
        return await driver.searchRemoteConversations(in: webView, query: query, limit: limit)
    }

    func synthesizeSpeechChunk(text: String, locale: String) async -> Data? {
        guard let driver = writeDriver else {
            return nil
        }
        return await driver.synthesizeSpeechChunk(in: webView, text: text, locale: locale)
    }

    // MARK: - Sign-In, Add Account & Challenge Popups

    /// Opens Google's `ServiceLogin` flow via `window.open` routed through `PopupCoordinator`.
    func openSignInPopup() {
        openInAppPopup(urlString: GeminiBridgeSelectors.Endpoints.signInURLString)
    }

    /// Opens Google's `AddSession` flow via `window.open` routed through `PopupCoordinator`.
    func openAddAccountPopup() {
        openInAppPopup(urlString: GeminiBridgeSelectors.Endpoints.addAccountURLString)
    }

    /// Opens a verification popup for the active challenge URL (falling back to `ServiceLogin`).
    func openChallengePopup(url: URL? = nil) {
        let target = url?.absoluteString
            ?? activeChallenge?.challengeURL?.absoluteString
            ?? GeminiBridgeSelectors.Endpoints.signInURLString
        openInAppPopup(urlString: target)
    }

    /// Updates the WebView's User-Agent string (takes effect on the next navigation/reload).
    func updateUserAgent(_ userAgent: String) {
        webView.customUserAgent = userAgent
    }

    /// Loads a URL directly in the underlying WebView (used by Classic Web Mode handoffs).
    func loadDirectURL(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Enables or disables hidden-WebView CSS paint suppression on this engine.
    ///
    /// Disabling suppression immediately removes `#lg-native-render-suppressor` and stops
    /// injecting it on future navigations so Classic Web Mode renders with normal computed styles.
    func setRenderSuppressed(_ suppressed: Bool) async {
        renderSuppressionTask?.cancel()
        renderSuppressionTask = nil
        isRenderSuppressed = suppressed
        await renderSuppressor.setSuppressed(suppressed, in: webView)
    }

    // MARK: - WKNavigationDelegate (Completion-Handler Overloads Only)

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let downloadPolicy = DownloadManager.downloadPolicy(for: navigationAction)
        if downloadPolicy == .download {
            decisionHandler(.download)
            return
        }

        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url,
           let challenge = detectChallenge(for: url) {
            handleChallengeEncountered(challenge)
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let httpResponse = navigationResponse.response as? HTTPURLResponse,
           httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            let banner = challengeBanner(forHTTPStatus: httpResponse.statusCode, url: httpResponse.url)
            handleChallengeEncountered(banner)
        }

        let policy = DownloadManager.downloadPolicy(
            for: navigationResponse.response,
            canShowMIMEType: navigationResponse.canShowMIMEType,
            isForMainFrame: navigationResponse.isForMainFrame
        )
        decisionHandler(policy)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        downloadManager.begin(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        downloadManager.begin(download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        scheduleRenderSuppressionReconcile()
        if let url = webView.url, let challenge = detectChallenge(for: url) {
            handleChallengeEncountered(challenge)
            return
        }
        homeLoadCollector?.didCommitNavigation = true
        conversationLoadContext?.didCommitNavigation = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scheduleRenderSuppressionReconcile()
        if let url = webView.url, let challenge = detectChallenge(for: url) {
            handleChallengeEncountered(challenge)
            return
        }

        if homeLoadCollector != nil {
            homeLoadCollector?.didFinishNavigation = true
        }
        if conversationLoadContext != nil {
            conversationLoadContext?.didFinishNavigation = true
            scheduleConversationRedirectCheckIfNeeded()
        }

        // Trigger an immediate boot/DOM probe in case DOMContentLoaded fired before injection settled.
        webView.evaluateJavaScript(GeminiBridgeScript.triggerBootSnapshotExpression, completionHandler: nil)

        evaluateHomeLoadCompletion()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    // MARK: - WKUIDelegate (Completion-Handler Overloads Only)

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        popupCoordinator.handleCreateWebView(
            configuration: configuration,
            navigationAction: navigationAction,
            windowFeatures: windowFeatures,
            parentWindow: self.webView.window,
            openInMain: { [weak self] url in
                self?.handlePopupReturnedToMain(url)
            }
        )
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if parameters.allowsDirectories {
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
        } else {
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
        }

        if let window = webView.window {
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        } else {
            completionHandler(nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        if origin.`protocol` == "https",
           origin.host == GeminiBridgeSelectors.Endpoints.geminiHost,
           type == .microphone {
            decisionHandler(.grant)
        } else {
            decisionHandler(.deny)
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case ScriptHandlerName.bridge:
            handleBridgeMessage(message.body)

        case ScriptHandlerName.imeEnterFix:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.sendSyntheticEnterKey()
            }

        case ScriptHandlerName.temporaryChatIntent:
            temporaryChatController.ensure(reason: "page")

        case ScriptHandlerName.themeColor:
            if let cssColor = message.body as? String,
               let parsedColor = Self.parseCSSColor(cssColor) {
                webView.underPageBackgroundColor = parsedColor
                onPageBackgroundColorChanged?(parsedColor)
            }

        #if DEBUG
        case ScriptHandlerName.consoleLog:
            if let text = message.body as? String {
                Self.logger.debug("[JS] \(text, privacy: .public)")
            }
        #endif

        default:
            break
        }
    }

    // MARK: - Bridge Message Dispatch

    private func handleBridgeMessage(_ body: Any) {
        guard let payload = JSONValue.from(body),
              let type = payload["type"]?.stringValue else {
            Self.logger.error("GeminiSessionEngine received malformed bridge message")
            return
        }

        switch type {
        case "bootSnapshot":
            handleBootSnapshotMessage(payload)
        case "urlChanged":
            handleURLChangedMessage(payload)
        case "batchExecute":
            handleBatchExecuteMessage(payload)
        case "streamStart":
            handleStreamStartMessage(payload)
        case "streamChunk":
            handleStreamChunkMessage(payload)
        case "streamEnd":
            handleStreamEndMessage(payload)
        case "streamError":
            handleStreamErrorMessage(payload)
        case "httpError":
            handleHTTPErrorMessage(payload)
        default:
            Self.logger.error("GeminiSessionEngine ignored unknown bridge message type=\(type, privacy: .public)")
        }
    }

    private func handleBootSnapshotMessage(_ payload: JSONValue) {
        let url = payload["url"]?.nonEmptyStringValue.flatMap { URL(string: $0) } ?? webView.url
        if let url, let challenge = detectChallenge(for: url) {
            handleChallengeEncountered(challenge)
            return
        }

        let wizJSON = payload["wiz"] ?? .object([:])
        let domJSON = payload["dom"]
        let snapshot = GeminiPayloadParser.parseBootAuthSnapshot(
            wizJSON: wizJSON,
            domJSON: domJSON,
            pageURL: url
        )

        if let collector = homeLoadCollector, !collector.didCommitNavigation {
            return
        }

        latestBootSnapshot = snapshot
        if let domTemp = snapshot.isTemporaryChat, domTemp != isTemporaryChat {
            isTemporaryChat = domTemp
            onEvent?(.temporaryChatStateChanged(domTemp))
        }

        if homeLoadCollector != nil {
            homeLoadCollector?.bootSnapshot = snapshot
            homeLoadCollector?.receivedBootSnapshot = true
        }

        recomputeAuthStateAndEmit()
        clearChallengeIfRecovered(url: url)
        tryFulfillPendingConversationIfReady()
        evaluateHomeLoadCompletion()
    }

    private func handleURLChangedMessage(_ payload: JSONValue) {
        guard let urlString = payload["url"]?.nonEmptyStringValue,
              let url = URL(string: urlString) else {
            return
        }
        if let challenge = detectChallenge(for: url) {
            handleChallengeEncountered(challenge)
            return
        }
        if conversationLoadContext != nil {
            scheduleConversationRedirectCheckIfNeeded(observedURL: url)
        }
    }

    private func handleBatchExecuteMessage(_ payload: JSONValue) {
        let status = payload["status"]?.intValue ?? 0
        let url = payload["url"]?.nonEmptyStringValue.flatMap { URL(string: $0) }
        if status == 401 || status == 403 {
            let banner = challengeBanner(forHTTPStatus: status, url: url)
            handleChallengeEncountered(banner)
            return
        }

        guard let bodyText = payload["body"]?.stringValue, !bodyText.isEmpty else {
            return
        }

        let frames = GeminiPayloadParser.parseBatchExecuteEnvelope(bodyText)
        let queryRpcIds = payload["rpcids"]?.nonEmptyStringValue

        for frame in frames {
            let rpcId = frame.rpcId ?? queryRpcIds
            handleBatchExecuteFrame(frame, resolvedRpcId: rpcId)
        }
    }

    private func handleBatchExecuteFrame(_ frame: BatchExecuteEnvelopeFrame, resolvedRpcId: String?) {
        typealias RPC = GeminiBridgeSelectors.BatchExecuteRPC

        // Ignore stale in-flight RPC replies from the previous page before a new navigation commits.
        if let collector = homeLoadCollector, !collector.didCommitNavigation {
            return
        }
        if let convContext = conversationLoadContext, !convContext.didCommitNavigation, resolvedRpcId == RPC.listConversationTurns {
            return
        }

        switch resolvedRpcId {
        case RPC.listConversations:
            if let errorKind = frame.errorKind {
                handleBatchExecuteError(errorKind, rpcId: RPC.listConversations)
                return
            }
            guard let innerJSON = frame.innerJSON else { return }
            let summaries = GeminiPayloadParser.parseListConversations(innerJSON)
            recentConversations = summaries
            homeLoadCollector?.conversations = summaries
            homeLoadCollector?.receivedListConversations = true
            onEvent?(.recentConversationsUpdated(summaries))

            if let pendingRefresh = pendingRecentRefresh {
                pendingRecentRefresh = nil
                pendingRefresh.succeed(with: summaries)
            }
            evaluateHomeLoadCompletion()

        case RPC.listConversationTurns:
            if let errorKind = frame.errorKind {
                handleBatchExecuteError(errorKind, rpcId: RPC.listConversationTurns)
                return
            }
            guard let innerJSON = frame.innerJSON else { return }
            let turns = GeminiPayloadParser.parseListConversationTurns(innerJSON)
            handleParsedConversationTurns(turns)

        case RPC.getUserStatus:
            if let errorKind = frame.errorKind {
                handleBatchExecuteError(errorKind, rpcId: RPC.getUserStatus)
                return
            }
            guard let innerJSON = frame.innerJSON,
                  let result = GeminiPayloadParser.parseUserStatus(innerJSON) else {
                return
            }
            latestUserStatus = result
            homeLoadCollector?.userStatus = result
            homeLoadCollector?.receivedUserStatus = true

            if !result.models.isEmpty {
                availableModels = result.models
                if selectedModelId == nil || !result.models.contains(where: { $0.id == selectedModelId }) {
                    selectedModelId = result.models.first?.id
                }
                onEvent?(.modelsUpdated(available: availableModels, selectedId: selectedModelId))
            }

            if result.isUnauthenticated {
                if pendingHomeLoad != nil && !authState.isSignedIn {
                    recomputeAuthStateAndEmit()
                    evaluateHomeLoadCompletion()
                } else if let challenge = result.challenge {
                    handleChallengeEncountered(challenge)
                } else {
                    recomputeAuthStateAndEmit()
                    evaluateHomeLoadCompletion()
                }
            } else if let challenge = result.challenge {
                handleChallengeEncountered(challenge)
            } else {
                evaluateHomeLoadCompletion()
            }

        case RPC.getPeople:
            if let errorKind = frame.errorKind {
                if errorKind == .permissionDenied || errorKind == .unauthenticated {
                    lastObservedRPCPermissionDenied = true
                    homeLoadCollector?.rpcPermissionDenied = true
                    homeLoadCollector?.receivedPeopleProfile = true
                    recomputeAuthStateAndEmit()
                    evaluateHomeLoadCompletion()
                }
                return
            }
            guard let innerJSON = frame.innerJSON,
                  let profile = GeminiPayloadParser.parsePeopleProfile(innerJSON) else {
                return
            }
            latestPeopleProfile = profile
            homeLoadCollector?.peopleProfile = profile
            homeLoadCollector?.receivedPeopleProfile = true
            recomputeAuthStateAndEmit()
            tryFulfillPendingConversationIfReady()
            evaluateHomeLoadCompletion()

        default:
            if let errorKind = frame.errorKind,
               errorKind == .unauthenticated {
                let transportError = GeminiPayloadParser.transportError(for: errorKind)
                if case .challengeRequired(let banner) = transportError {
                    handleChallengeEncountered(banner)
                }
            }
        }
    }

    private func handleBatchExecuteError(_ errorKind: BatchExecuteErrorKind, rpcId: String) {
        typealias RPC = GeminiBridgeSelectors.BatchExecuteRPC
        Self.logger.error("GeminiSessionEngine RPC error rpcId=\(rpcId, privacy: .public)")

        switch errorKind {
        case .conversationNotFound:
            let missingId = conversationLoadContext?.targetId ?? currentRouteConversationId() ?? ""
            if !missingId.isEmpty {
                onEvent?(.conversationNotFound(conversationId: missingId))
            }
            if let pendingConv = pendingConversationLoad {
                let targetId = conversationLoadContext?.targetId ?? missingId
                cancelPendingConversationLoad(failWith: nil)
                pendingConv.fail(with: ChatTransportError.conversationNotFound(id: targetId))
            }

        case .permissionDenied, .unauthenticated:
            // If we are clearly signed out during home load, resolve cleanly as signed out instead of a mid-session challenge.
            if pendingHomeLoad != nil && !authState.isSignedIn {
                lastObservedRPCPermissionDenied = true
                homeLoadCollector?.rpcPermissionDenied = true
                recomputeAuthStateAndEmit()
                evaluateHomeLoadCompletion()
                return
            }
            let error = GeminiPayloadParser.transportError(for: errorKind)
            if case .challengeRequired(let banner) = error {
                handleChallengeEncountered(banner)
            }

        case .other(let code):
            let error = ChatTransportError.networkError(message: "Gemini RPC \(rpcId) failed (code \(code)).")
            if rpcId == RPC.listConversationTurns, let pendingConv = pendingConversationLoad {
                cancelPendingConversationLoad(failWith: nil)
                pendingConv.fail(with: error)
            } else if rpcId == RPC.listConversations, let pendingRefresh = pendingRecentRefresh {
                pendingRecentRefresh = nil
                pendingRefresh.fail(with: error)
            }
        }
    }

    // MARK: - Streaming Tap Handling

    private func handleStreamStartMessage(_ payload: JSONValue) {
        guard let requestId = payload["requestId"]?.nonEmptyStringValue,
              let transportRaw = payload["transport"]?.stringValue,
              let transport = GeminiBridgeScript.TransportKind(rawValue: transportRaw) else {
            return
        }

        if streamBuffers[requestId] == nil {
            streamBuffers[requestId] = makeStreamBuffer(for: transport)
        }
        // Do not eagerly bind `.processSession` on `streamStart`: short-lived uplink `POST /v1/processSession`
        // requests carry zero downlink frames and would prematurely close the session on `loadend`.
        // `.processSession` requests bind lazily in `processStreamOutputs` on the first decoded `ParsedStreamFrame`.
        if transport != .processSession,
           let active = activeStreamSession,
           active.boundRequestId == nil,
           !active.preexistingRequestIds.contains(requestId) {
            activeStreamSession?.boundRequestId = requestId
        }
    }

    private func handleStreamChunkMessage(_ payload: JSONValue) {
        guard let requestId = payload["requestId"]?.nonEmptyStringValue,
              let transportRaw = payload["transport"]?.stringValue,
              let transport = GeminiBridgeScript.TransportKind(rawValue: transportRaw),
              let chunk = payload["chunk"]?.stringValue,
              !chunk.isEmpty else {
            return
        }

        var buffer = streamBuffers[requestId] ?? makeStreamBuffer(for: transport)
        let outputs: [StreamParseOutput]

        switch buffer {
        case .webChannel(var wc):
            let frames = wc.appendDelta(chunk)
            buffer = .webChannel(wc)
            outputs = frames.map { .frame($0) }
        case .sse(var sse):
            outputs = sse.append(chunk)
            buffer = .sse(sse)
        case .legacyBoq(var boq):
            outputs = boq.append(chunk)
            buffer = .legacyBoq(boq)
        }

        streamBuffers[requestId] = buffer
        processStreamOutputs(outputs, requestId: requestId)
    }

    private func handleStreamEndMessage(_ payload: JSONValue) {
        guard let requestId = payload["requestId"]?.nonEmptyStringValue else {
            return
        }

        if let buffer = streamBuffers.removeValue(forKey: requestId) {
            let trailingOutputs: [StreamParseOutput]
            switch buffer {
            case .webChannel(var wc):
                trailingOutputs = wc.finish().map { .frame($0) }
            case .sse(var sse):
                trailingOutputs = sse.finish()
            case .legacyBoq(var boq):
                trailingOutputs = boq.finish()
            }
            processStreamOutputs(trailingOutputs, requestId: requestId)
        }

        let transport = payload["transport"]?.stringValue.flatMap(GeminiBridgeScript.TransportKind.init(rawValue:))
        if let active = activeStreamSession,
           shouldTerminateActiveStream(active, forRequestId: requestId, transport: transport) {
            finishActiveStream(throwing: nil)
        }
    }

    private func handleStreamErrorMessage(_ payload: JSONValue) {
        let requestId = payload["requestId"]?.nonEmptyStringValue
        let transport = payload["transport"]?.stringValue.flatMap(GeminiBridgeScript.TransportKind.init(rawValue:))
        if let requestId {
            streamBuffers.removeValue(forKey: requestId)
        }
        let message = payload["message"]?.nonEmptyStringValue ?? "Stream connection failed."
        if let active = activeStreamSession,
           requestId.map({ shouldTerminateActiveStream(active, forRequestId: $0, transport: transport) }) ?? true {
            finishActiveStream(throwing: ChatTransportError.networkError(message: message))
        }
    }

    private func shouldTerminateActiveStream(
        _ session: ActiveStreamSession,
        forRequestId requestId: String,
        transport: GeminiBridgeScript.TransportKind?
    ) -> Bool {
        if let bound = session.boundRequestId {
            return bound == requestId
        }
        if transport == .processSession {
            return false
        }
        return !session.preexistingRequestIds.contains(requestId)
    }

    private func handleHTTPErrorMessage(_ payload: JSONValue) {
        let status = payload["status"]?.intValue ?? 401
        let url = payload["url"]?.nonEmptyStringValue.flatMap { URL(string: $0) }
        if let requestId = payload["requestId"]?.nonEmptyStringValue {
            streamBuffers.removeValue(forKey: requestId)
        }
        Self.logger.error("GeminiSessionEngine observed HTTP auth challenge status=\(status, privacy: .public)")
        let banner = challengeBanner(forHTTPStatus: status, url: url)
        handleChallengeEncountered(banner)
    }

    private func processStreamOutputs(_ outputs: [StreamParseOutput], requestId: String) {
        for output in outputs {
            switch output {
            case .rpcError(let errorKind):
                let transportError = GeminiPayloadParser.transportError(for: errorKind)
                if case .challengeRequired(let banner) = transportError {
                    handleChallengeEncountered(banner)
                } else {
                    finishActiveStream(throwing: transportError)
                }
                return

            case .frame(let parsedFrame):
                if let tempState = parsedFrame.isTemporaryChat, tempState != isTemporaryChat {
                    isTemporaryChat = tempState
                    onEvent?(.temporaryChatStateChanged(tempState))
                }
                if let modeId = parsedFrame.modeId {
                    selectedModelId = modeId
                }

                guard var session = activeStreamSession else {
                    continue
                }
                if session.boundRequestId == nil {
                    session.boundRequestId = requestId
                }
                let cumulative = session.accumulator.merge(parsedFrame.delta)
                activeStreamSession = session
                session.continuation.yield(cumulative)

                if cumulative.isFinal {
                    finalizeStreamWithDOMEnrichment(sessionId: session.id, cumulative: cumulative)
                }
            }
        }
    }

    private func makeStreamBuffer(for transport: GeminiBridgeScript.TransportKind) -> StreamBufferState {
        switch transport {
        case .processSession:
            return .webChannel(WebChannelStreamBuffer())
        case .streamGenerateSSE:
            return .sse(SSEStreamBuffer())
        case .legacyStreamGenerate, .batchExecute:
            return .legacyBoq(LegacyBoqStreamBuffer())
        }
    }

    private func startStreamSession(
        enableProgressPolling: Bool = false,
        driverAction: @escaping @MainActor (any GeminiWriteDriving) async throws -> Void
    ) -> AsyncThrowingStream<StreamingDelta, Error> {
        finishActiveStream(throwing: ChatTransportError.cancelled)

        let sessionId = UUID()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.activeStreamSession?.id == sessionId else {
                        return
                    }
                    self.activeStreamSession?.driverTask?.cancel()
                    self.activeStreamSession?.progressPollTask?.cancel()
                    self.activeStreamSession = nil
                }
            }

            let driverTask = Task { @MainActor [weak self] in
                guard let self else { return }
                guard let driver = self.writeDriver else {
                    self.finishActiveStream(
                        sessionId: sessionId,
                        throwing: ChatTransportError.actionDriverFailed(reason: "Write actions require an attached GeminiActionDriver.")
                    )
                    return
                }
                do {
                    try await driverAction(driver)
                } catch {
                    self.finishActiveStream(sessionId: sessionId, throwing: error)
                }
            }

            let pollTask: Task<Void, Never>? = enableProgressPolling
                ? Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(1400))
                        guard !Task.isCancelled,
                              let self,
                              let driver = self.writeDriver,
                              var current = self.activeStreamSession,
                              current.id == sessionId else {
                            return
                        }
                        let dom = await driver.probeLatestTurnDOMArtifacts(in: self.webView)
                        if let progress = dom.progress {
                            let progressCard = ArtifactCardInfo(
                                id: "deep-research-progress",
                                kind: .deepResearch,
                                title: String(localized: "Deep Research"),
                                subtitle: progress.statusText,
                                progress: progress
                            )
                            let merged = current.accumulator.merge(
                                StreamingDelta(artifacts: [progressCard], isFinal: false)
                            )
                            self.activeStreamSession = current
                            current.continuation.yield(merged)
                        }
                    }
                }
                : nil

            self.activeStreamSession = ActiveStreamSession(
                id: sessionId,
                continuation: continuation,
                preexistingRequestIds: Set(self.streamBuffers.keys),
                driverTask: driverTask,
                progressPollTask: pollTask
            )
        }
    }

    private func finalizeStreamWithDOMEnrichment(sessionId: UUID, cumulative: StreamingDelta) {
        guard let driver = writeDriver else {
            finishActiveStream(sessionId: sessionId, throwing: nil)
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, var current = self.activeStreamSession, current.id == sessionId else {
                return
            }
            let dom = await driver.probeLatestTurnDOMArtifacts(in: self.webView)
            var extraArtifacts: [ArtifactCardInfo] = []

            if let planArtifact = dom.planArtifact,
               !cumulative.artifacts.contains(where: { $0.isDeepResearchPlanCard }) {
                extraArtifacts.append(planArtifact)
            }

            if let canvasText = dom.canvasText, !canvasText.isEmpty {
                if let existingIdx = cumulative.artifacts.firstIndex(where: { !$0.hasNativeContent && ($0.kind == .canvas || $0.kind == .deepResearch) }) {
                    let base = cumulative.artifacts[existingIdx]
                    extraArtifacts.append(
                        ArtifactCardInfo(
                            id: base.id,
                            kind: base.kind,
                            title: dom.canvasTitle ?? base.title,
                            subtitle: base.subtitle,
                            content: canvasText,
                            language: base.language
                        )
                    )
                }
            }

            if !extraArtifacts.isEmpty {
                let enriched = current.accumulator.merge(
                    StreamingDelta(artifacts: extraArtifacts, isFinal: true)
                )
                self.activeStreamSession = current
                current.continuation.yield(enriched)
            }
            self.finishActiveStream(sessionId: sessionId, throwing: nil)
        }
    }

    private func finishActiveStream(sessionId: UUID? = nil, throwing error: Error?) {
        guard let session = activeStreamSession else {
            return
        }
        if let sessionId, session.id != sessionId {
            return
        }
        activeStreamSession = nil
        session.driverTask?.cancel()
        session.progressPollTask?.cancel()
        if let error {
            session.continuation.finish(throwing: error)
        } else {
            session.continuation.finish()
        }
    }

    // MARK: - Auth & Home/Conversation Resolution

    private func recomputeAuthStateAndEmit() {
        let resolved = GeminiPayloadParser.resolveAuthState(
            boot: latestBootSnapshot,
            peopleProfile: latestPeopleProfile,
            rpcPermissionDenied: lastObservedRPCPermissionDenied,
            userStatusCode: latestUserStatus?.statusCode,
            existingAvailableAccounts: knownAccounts
        )

        if case .signedIn(_, let available) = resolved {
            knownAccounts = available
        }

        if resolved != authState {
            authState = resolved
            onEvent?(.authStateChanged(resolved))
        }
    }

    private func evaluateHomeLoadCompletion() {
        guard let collector = homeLoadCollector,
              collector.didCommitNavigation,
              let pending = pendingHomeLoad,
              pending.isPending else {
            return
        }

        let hasFreshAuthSignal = collector.receivedBootSnapshot
            || collector.receivedUserStatus
            || collector.receivedPeopleProfile
            || collector.rpcPermissionDenied

        // Never complete using stale `authState` from an earlier page before this navigation reports fresh signals.
        if hasFreshAuthSignal {
            let resolvedAuth = GeminiPayloadParser.resolveAuthState(
                boot: collector.bootSnapshot,
                peopleProfile: collector.peopleProfile,
                rpcPermissionDenied: collector.rpcPermissionDenied,
                userStatusCode: collector.userStatus?.statusCode,
                existingAvailableAccounts: knownAccounts
            )

            // Immediate completion for verified signed-out sessions.
            if case .signedOut = resolvedAuth, collector.receivedBootSnapshot {
                let hasDefinitiveSignedOutSignal =
                    collector.didFinishNavigation
                    || collector.bootSnapshot?.isAnonymousSession == true
                    || collector.bootSnapshot?.hasSignedOutDOMMarker == true
                    || collector.userStatus?.isUnauthenticated == true
                    || collector.rpcPermissionDenied

                if hasDefinitiveSignedOutSignal {
                    completeHomeLoad(collector: collector, pending: pending)
                    return
                }
            }

            // Immediate completion once signed in and primary boot RPCs have landed.
            if case .signedIn(let active, _) = resolvedAuth {
                let hasIdentityEnriched = !active.email.isEmpty || collector.receivedPeopleProfile
                if collector.receivedListConversations && collector.receivedUserStatus && hasIdentityEnriched {
                    completeHomeLoad(collector: collector, pending: pending)
                    return
                }
            }
        }

        // Schedule a bounded settle window once navigation finished and at least one fresh signal arrived.
        let readyToSettle = collector.didFinishNavigation && (hasFreshAuthSignal || collector.receivedListConversations)

        if readyToSettle && homeSettleTask == nil {
            let generation = collector.generation
            let delay = homeSettleDelay
            homeSettleTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self,
                      let currentCollector = self.homeLoadCollector,
                      currentCollector.generation == generation,
                      let currentPending = self.pendingHomeLoad,
                      currentPending.isPending else {
                    return
                }
                self.completeHomeLoad(collector: currentCollector, pending: currentPending)
            }
        }
    }

    private func completeHomeLoad(collector: HomeLoadCollector, pending: PendingRequest<HomeLoadResult>) {
        homeSettleTask?.cancel()
        homeSettleTask = nil
        homeLoadCollector = nil
        pendingHomeLoad = nil

        if collector.requestedTemporaryChat, authState.isSignedIn {
            temporaryChatController.ensure(reason: "loadHome")
        }

        let effectiveTempChat = collector.bootSnapshot?.isTemporaryChat
            ?? (collector.requestedTemporaryChat && authState.isSignedIn)
        isTemporaryChat = effectiveTempChat

        let result = HomeLoadResult(
            authState: authState,
            recentConversations: authState.isSignedIn ? (collector.conversations ?? recentConversations) : [],
            availableModels: authState.isSignedIn ? availableModels : [],
            selectedModelId: authState.isSignedIn ? selectedModelId : nil,
            isTemporaryChat: effectiveTempChat
        )
        pending.succeed(with: result)
    }

    private func handleParsedConversationTurns(_ turns: [ChatTurn]) {
        if var context = conversationLoadContext {
            context.pendingTurns = turns
            conversationLoadContext = context
            tryFulfillPendingConversationIfReady()
            return
        }

        // Out-of-band conversation load (e.g., navigation inside Classic Web Mode).
        guard let scopeId = authState.activeAccount?.scopeId,
              let convId = currentRouteConversationId() else {
            return
        }
        let snapshot = makeConversationSnapshot(accountScopeId: scopeId, conversationId: convId, turns: turns)
        onEvent?(.conversationSynced(snapshot))
    }

    private func tryFulfillPendingConversationIfReady() {
        guard let context = conversationLoadContext,
              let turns = context.pendingTurns,
              let pending = pendingConversationLoad,
              pending.isPending else {
            return
        }

        if case .signedOut = authState {
            cancelPendingConversationLoad(failWith: nil)
            pending.fail(with: ChatTransportError.notSignedIn)
            return
        }

        guard let scopeId = authState.activeAccount?.scopeId else {
            return
        }

        let snapshot = makeConversationSnapshot(
            accountScopeId: scopeId,
            conversationId: context.targetId,
            turns: turns
        )
        cancelPendingConversationLoad(failWith: nil)
        onEvent?(.conversationSynced(snapshot))
        pending.succeed(with: snapshot)
    }

    private func makeConversationSnapshot(
        accountScopeId: String,
        conversationId: String,
        turns: [ChatTurn]
    ) -> ConversationSnapshot {
        let matchedTitle = recentConversations.first(where: { $0.id == conversationId })?.title
        let pageTitle = webView.title?
            .replacingOccurrences(of: " - Gemini", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let promptFallback = turns.first?.userPrompt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0.prefix(80)) }

        let resolvedTitle = [matchedTitle, pageTitle, promptFallback]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && $0.lowercased() != "gemini" }) ?? "Untitled"

        let modelId = turns.last?.metadata.modelId ?? selectedModelId
        let updatedAt = turns.last?.createdAt ?? Date()

        return ConversationSnapshot(
            accountScopeId: accountScopeId,
            conversationId: conversationId,
            title: resolvedTitle,
            modelId: modelId,
            updatedAt: updatedAt,
            turns: turns
        )
    }

    private func scheduleConversationRedirectCheckIfNeeded(observedURL: URL? = nil) {
        guard let context = conversationLoadContext,
              context.pendingTurns == nil,
              let url = observedURL ?? webView.url,
              isNewChatRoute(url) else {
            return
        }

        conversationRedirectCheckTask?.cancel()
        let generation = context.generation
        let missingId = context.targetId
        let delay = redirectGraceDelay

        conversationRedirectCheckTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  let currentContext = self.conversationLoadContext,
                  currentContext.generation == generation,
                  currentContext.pendingTurns == nil,
                  let pending = self.pendingConversationLoad,
                  pending.isPending else {
                return
            }
            self.cancelPendingConversationLoad(failWith: nil)
            self.onEvent?(.conversationNotFound(conversationId: missingId))
            pending.fail(with: ChatTransportError.conversationNotFound(id: missingId))
        }
    }

    // MARK: - Challenge Detection & Recovery

    /// Evaluates whether a main-frame URL indicates an off-host auth redirect, CAPTCHA, or unavailable gate.
    func detectChallenge(for url: URL) -> ChallengeBannerState? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "data" || scheme == "blob" || scheme.isEmpty {
            return nil
        }

        let host = url.host?.lowercased() ?? ""
        let lowerPath = url.path.lowercased()
        let indicators = GeminiBridgeSelectors.Endpoints.challengePathIndicators.map { $0.lowercased() }
        let matchedIndicator = indicators.first { lowerPath.contains($0) }

        if host != expectedHost {
            if host == GeminiBridgeSelectors.Endpoints.accountsHost
                || matchedIndicator == "/servicelogin"
                || matchedIndicator == "/v3/signin"
                || matchedIndicator == "/signin/"
                || matchedIndicator == "/accountchooser" {
                return ChallengeBannerState(
                    kind: .reauthRequired,
                    message: "Sign in to your Google account to continue.",
                    challengeURL: url
                )
            }
            if matchedIndicator == "/sorry/" || matchedIndicator == "/unavailable" {
                return ChallengeBannerState(
                    kind: .captchaOrPolicy,
                    message: "Google requested verification before continuing.",
                    challengeURL: url
                )
            }
            return ChallengeBannerState(
                kind: .unexpectedRedirect,
                message: "Gemini redirected to \(host.isEmpty ? "another page" : host). Verify in popup or switch to Web Mode.",
                challengeURL: url
            )
        }

        if let matchedIndicator {
            if matchedIndicator == "/sorry/" || matchedIndicator == "/unavailable" {
                return ChallengeBannerState(
                    kind: .captchaOrPolicy,
                    message: "Gemini is temporarily unavailable or requires verification.",
                    challengeURL: url
                )
            }
            return ChallengeBannerState(
                kind: .reauthRequired,
                message: "Sign in to your Google account to continue.",
                challengeURL: url
            )
        }

        return nil
    }

    private func challengeBanner(forHTTPStatus status: Int, url: URL?) -> ChallengeBannerState {
        let signInURL = URL(string: GeminiBridgeSelectors.Endpoints.signInURLString)
        let appURL = URL(string: GeminiBridgeSelectors.Endpoints.appURLString)
        if status == 401 {
            return ChallengeBannerState(
                kind: .reauthRequired,
                message: "Your Google session expired (HTTP 401). Verify in popup or switch to Web Mode.",
                challengeURL: signInURL ?? url
            )
        }
        return ChallengeBannerState(
            kind: .captchaOrPolicy,
            message: "Gemini rejected this request (HTTP \(status)). Verify in popup or switch to Web Mode.",
            challengeURL: appURL ?? url
        )
    }

    private func handleChallengeEncountered(_ banner: ChallengeBannerState) {
        activeChallenge = banner
        let error = ChatTransportError.challengeRequired(banner)

        finishActiveStream(throwing: error)
        cancelPendingHomeLoad(failWith: error)
        cancelPendingConversationLoad(failWith: error)

        if let pendingRefresh = pendingRecentRefresh {
            pendingRecentRefresh = nil
            pendingRefresh.fail(with: error)
        }

        onEvent?(.challengeEncountered(banner))
    }

    private func clearChallengeIfRecovered(url: URL?) {
        guard activeChallenge != nil,
              let url,
              detectChallenge(for: url) == nil,
              authState.isSignedIn else {
            return
        }
        activeChallenge = nil
        onEvent?(.challengeCleared)
    }

    // MARK: - Popup & URL Helpers

    private func openInAppPopup(urlString: String) {
        guard let encodedData = try? JSONSerialization.data(withJSONObject: [urlString]),
              let encodedArray = String(data: encodedData, encoding: .utf8) else {
            return
        }
        let previousAllowance = webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically
        webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Pass no explicit window features so `NewWindowRouter.isAccountFlow` stays true
        // and returning to gemini.google.com routes `.moveToMain` automatically.
        let script = "(function(){ var u = \(encodedArray)[0]; window.open(u, '_blank'); return true; })()"
        webView.evaluateJavaScript(script) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = previousAllowance
            }
        }
    }

    private func handlePopupReturnedToMain(_ url: URL) {
        if activeChallenge != nil {
            activeChallenge = nil
            onEvent?(.challengeCleared)
        }
        webView.load(URLRequest(url: url))
    }

    private func buildRouteURL(_ route: GeminiURLRoute) -> URL {
        let canonical = route.canonicalURL
        let targetScheme = baseURL.scheme?.lowercased() ?? "https"
        if targetScheme == "https" && expectedHost == GeminiURLRoute.canonicalHost {
            return canonical
        }
        guard var components = URLComponents(url: canonical, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        components.scheme = targetScheme
        components.host = expectedHost
        if let port = baseURL.port {
            components.port = port
        }
        return components.url ?? baseURL
    }

    private func currentRouteConversationId() -> String? {
        guard let url = webView.url else {
            return nil
        }
        if let route = parseNormalizedRoute(url) {
            return route.conversationId
        }
        return nil
    }

    private func isNewChatRoute(_ url: URL) -> Bool {
        guard let route = parseNormalizedRoute(url) else {
            return false
        }
        if case .newChat = route {
            return true
        }
        return false
    }

    private func parseNormalizedRoute(_ url: URL) -> GeminiURLRoute? {
        if let direct = GeminiURLRoute.parse(url) {
            return direct
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == expectedHost else {
            return nil
        }
        components.scheme = "https"
        components.host = GeminiURLRoute.canonicalHost
        components.port = nil
        return components.url.flatMap { GeminiURLRoute.parse($0) }
    }

    // MARK: - Navigation Failure & Waiter Cleanup

    private func handleNavigationFailure(_ error: Error) {
        let nsError = error as NSError
        if isIgnoredNavigationError(nsError) {
            return
        }
        let transportError = ChatTransportError.networkError(message: error.localizedDescription)
        cancelPendingHomeLoad(failWith: transportError)
        cancelPendingConversationLoad(failWith: transportError)
        if let pendingRefresh = pendingRecentRefresh {
            pendingRecentRefresh = nil
            pendingRefresh.fail(with: transportError)
        }
    }

    private func isIgnoredNavigationError(_ error: NSError) -> Bool {
        if error.code == NSURLErrorCancelled {
            return true
        }
        return error.domain == "WebKitErrorDomain"
            && error.code == WebKitErrorFrameLoadInterruptedByPolicyChange
    }

    private func cancelPendingHomeLoad(failWith error: Error? = ChatTransportError.cancelled) {
        homeSettleTask?.cancel()
        homeSettleTask = nil
        homeLoadCollector = nil
        if let pending = pendingHomeLoad {
            pendingHomeLoad = nil
            if let error {
                pending.fail(with: error)
            }
        }
    }

    private func cancelPendingConversationLoad(failWith error: Error? = ChatTransportError.cancelled) {
        conversationRedirectCheckTask?.cancel()
        conversationRedirectCheckTask = nil
        conversationLoadContext = nil
        if let pending = pendingConversationLoad {
            pendingConversationLoad = nil
            if let error {
                pending.fail(with: error)
            }
        }
    }

    private func scheduleRenderSuppressionReconcile() {
        renderSuppressionTask?.cancel()
        renderSuppressionTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.renderSuppressor.reconcileNavigation(in: self.webView)
        }
    }

    // MARK: - Classic Web Mode Compatibility Helpers

    private static func parseCSSColor(_ css: String) -> NSColor? {
        let numbers = css
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .compactMap { Double($0) }
        guard numbers.count >= 3 else {
            return nil
        }
        let r = min(max(numbers[0] / 255.0, 0), 1)
        let g = min(max(numbers[1] / 255.0, 0), 1)
        let b = min(max(numbers[2] / 255.0, 0), 1)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    private func sendSyntheticEnterKey() {
        guard let window = webView.window,
              let source = CGEventSource(stateID: .combinedSessionState) else {
            return
        }
        if let cgDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true) {
            cgDown.flags = []
            if let nsDown = NSEvent(cgEvent: cgDown) {
                window.sendEvent(nsDown)
            }
        }
        if let cgUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) {
            cgUp.flags = []
            if let nsUp = NSEvent(cgEvent: cgUp) {
                window.sendEvent(nsUp)
            }
        }
    }
}
