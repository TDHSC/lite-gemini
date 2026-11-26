import Combine
import Foundation
import os

// MARK: - QuickPhase

/// Presentation lifecycle phase of Quick Mode's floating window.
nonisolated enum QuickPhase: String, Equatable, Sendable {
    /// Pre-send borderless Spotlight-style floating composer bar; hides on outside click preserving draft.
    case barOnly
    /// Post-send Liquid Glass mini-window with conversation timeline; stays pinned until explicitly closed.
    case expanded
}

// MARK: - QuickWorkspaceController

/// `@MainActor` state machine orchestrating Quick Mode (`⌥Space` / `⌥⇧Space`) with lazy transport
/// allocation, pre-send draft preservation, post-send pinning, cold-launch fallback, and a persisted
/// Quick Mode temporary-chat preference independent from the main window.
@MainActor
final class QuickWorkspaceController: ObservableObject {

    // MARK: - Constants

    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "QuickWorkspaceController")

    private nonisolated static let mainQueueSpecificKey: DispatchSpecificKey<Bool> = {
        let key = DispatchSpecificKey<Bool>()
        DispatchQueue.main.setSpecific(key: key, value: true)
        return key
    }()

    private nonisolated static var isOnMainQueue: Bool {
        Thread.isMainThread || DispatchQueue.getSpecific(key: mainQueueSpecificKey) == true
    }

    // MARK: - Published State

    /// Current presentation phase (`.barOnly` prior to first send, `.expanded` after first send).
    @Published private(set) var phase: QuickPhase = .barOnly

    /// Whether the Quick Mode floating panel is currently shown on screen.
    @Published private(set) var isVisible: Bool = false

    /// Monotonically incremented token signaling the composer to claim keyboard focus.
    @Published private(set) var focusTrigger: Int = 0

    /// Authentication status observed from Quick Mode's dedicated session transport.
    @Published private(set) var authState: AuthState = .unknown

    /// Persisted Quick Mode temporary-chat toggle state mirrored for reactive UI bindings.
    @Published private(set) var isTemporaryChatPreference: Bool

    // MARK: - Session Archive & Lazy Ownership

    /// Snapshot of the most recent Quick Mode conversation that sent at least one message
    /// during this app process lifetime. Starts `nil` on fresh app launch.
    private(set) var mostRecentQuickSession: ConversationSnapshot?

    /// Whether the lazy `ChatTransport` and `ChatSessionStore` have been allocated yet.
    var hasInitializedSession: Bool {
        _session != nil
    }

    /// Existing `ChatSessionStore` if Quick Mode has already been summoned, or `nil` at cold launch.
    var activeSessionIfLoaded: ChatSessionStore? {
        _session
    }

    /// Reusable `ChatSessionStore` backing Quick Mode, created lazily on first summon/access so
    /// zero `WKWebView` / `GeminiSessionEngine` memory is consumed at cold launch.
    var session: ChatSessionStore {
        ensureSession().store
    }

    // MARK: - Dependencies & Internal State

    private let transportFactory: @MainActor () -> any ChatTransport
    private let cache: SWRConversationCache?
    private let quickModeTempGetter: @MainActor () -> Bool
    private let quickModeTempSetter: @MainActor (Bool) -> Void
    private let activeAuthUserProvider: @MainActor () -> Int?
    private let streamStartTimeout: Duration
    private let streamCoalesceInterval: Duration
    private let notificationCenter: NotificationCenter
    private let now: () -> Date

    private var _transport: (any ChatTransport)?
    private var _session: ChatSessionStore?
    private var hasCompletedInitialHomeLoad: Bool = false
    private var mostRecentQuickWasTemporary: Bool = false
    private var homeLoadGeneration: UInt64 = 0
    private var homeLoadTask: Task<Void, Never>?
    private var isPerformingHomeLoad: Bool = false
    private var clearDataObserver: (any NSObjectProtocol)?

    // MARK: - Initialization

    /// Creates a Quick Mode controller without allocating its `ChatTransport` until first summon.
    init(
        transportFactory: @escaping @MainActor () -> any ChatTransport,
        cache: SWRConversationCache? = nil,
        quickModeTempGetter: @escaping @MainActor () -> Bool = { SettingsManager.shared.quickModeTemporaryChat },
        quickModeTempSetter: @escaping @MainActor (Bool) -> Void = { SettingsManager.shared.quickModeTemporaryChat = $0 },
        activeAuthUserProvider: @escaping @MainActor () -> Int? = { nil },
        streamStartTimeout: Duration = ChatSessionStore.defaultStreamStartTimeout,
        streamCoalesceInterval: Duration = ChatSessionStore.defaultStreamCoalesceInterval,
        clearDataNotificationName: Notification.Name = SWRConversationCache.defaultClearDataNotificationName,
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = { Date() }
    ) {
        self.transportFactory = transportFactory
        self.cache = cache
        self.quickModeTempGetter = quickModeTempGetter
        self.quickModeTempSetter = quickModeTempSetter
        self.activeAuthUserProvider = activeAuthUserProvider
        self.streamStartTimeout = streamStartTimeout
        self.streamCoalesceInterval = streamCoalesceInterval
        self.notificationCenter = notificationCenter
        self.now = now
        self.isTemporaryChatPreference = quickModeTempGetter()

        self.clearDataObserver = notificationCenter.addObserver(
            forName: clearDataNotificationName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            if QuickWorkspaceController.isOnMainQueue {
                MainActor.assumeIsolated {
                    self?.handleBrowsingDataCleared()
                }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        self?.handleBrowsingDataCleared()
                    }
                }
            }
        }
    }

    isolated deinit {
        homeLoadTask?.cancel()
        if let clearDataObserver {
            notificationCenter.removeObserver(clearDataObserver)
        }
    }

    // MARK: - Global HotKey Triggers

    /// Handles the New Quick Chat hotkey (`⌥Space`):
    /// - Hidden `.barOnly`: re-shows the floating bar with unsent draft text & attachments intact.
    /// - Visible `.barOnly`: hides the floating bar while preserving unsent draft state.
    /// - `.expanded` (visible or closed): archives the session into `mostRecentQuickSession`,
    ///   resets to a fresh `.barOnly` bar inheriting `quickModeTemporaryChat`, and focuses input.
    func triggerNewQuickChat() {
        switch phase {
        case .barOnly:
            if isVisible {
                dismissPreSendBar()
                return
            }

            _ = ensureSession()
            let desiredTemp = quickModeTempGetter()
            isTemporaryChatPreference = desiredTemp

            if !hasCompletedInitialHomeLoad && !isPerformingHomeLoad {
                scheduleHomeLoad(temporaryChat: desiredTemp)
            }

            isVisible = true
            focusTrigger &+= 1

        case .expanded:
            let (store, _) = ensureSession()
            let wasStreaming = store.isStreaming
            captureMostRecentQuickSessionIfNeeded()

            let desiredTemp = quickModeTempGetter()
            isTemporaryChatPreference = desiredTemp
            store.resetToEmptyState(temporary: desiredTemp, preserveDraft: false)

            phase = .barOnly
            isVisible = true
            focusTrigger &+= 1

            scheduleHomeLoad(temporaryChat: desiredTemp, stopActiveStreamFirst: wasStreaming)
        }
    }

    /// Handles the Recent Quick Chat hotkey (`⌥⇧Space`):
    /// - Existing `.expanded` session with turns: re-shows and focuses it immediately.
    /// - Archived `mostRecentQuickSession`: restores it into `.expanded` phase in 0ms and syncs `/app/<id>`.
    /// - Cold-launch fallback (`mostRecentQuickSession == nil`): automatically falls back to `triggerNewQuickChat()`.
    func triggerRecentQuickChat() {
        if phase == .expanded, let store = _session, store.hasTurns {
            isVisible = true
            focusTrigger &+= 1
            return
        }

        if let recent = mostRecentQuickSession, !recent.turns.isEmpty {
            let (store, _) = ensureSession()
            let wasTemporary = mostRecentQuickWasTemporary
            cancelPendingHomeLoad()
            store.applySnapshot(recent, persistToCache: false)
            if wasTemporary {
                store.handleTransportEvent(.temporaryChatStateChanged(true))
            }

            phase = .expanded
            isVisible = true
            focusTrigger &+= 1

            if !wasTemporary,
               !recent.conversationId.isEmpty,
               !recent.conversationId.hasPrefix("quick-"),
               let transport = _transport {
                let generation = homeLoadGeneration
                let authUser = activeAuthUserProvider()
                homeLoadTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let refreshed = try? await transport.loadConversation(id: recent.conversationId, authUser: authUser),
                       !Task.isCancelled,
                       self.homeLoadGeneration == generation,
                       self.phase == .expanded,
                       self._session?.conversationId == recent.conversationId {
                        self._session?.applySnapshot(refreshed, persistToCache: false)
                    }
                }
            }
            return
        }

        triggerNewQuickChat()
    }

    // MARK: - Window & Session Lifecycle Actions

    /// Transitions Quick Mode from `.barOnly` to `.expanded` synchronously when the first prompt is submitted.
    func expandForFirstSend() {
        guard phase == .barOnly else {
            return
        }
        phase = .expanded
        isVisible = true
    }

    /// Hides the pre-send floating bar without clearing unsent composer text or staged attachments.
    func dismissPreSendBar() {
        guard phase == .barOnly else {
            return
        }
        isVisible = false
    }

    /// Handles `NSWindow.didResignKeyNotification` when focus leaves Quick Mode:
    /// - `.barOnly`: auto-hides while keeping `session.draft` intact.
    /// - `.expanded`: no-op so the post-send window remains pinned until explicitly closed.
    func handleOutsideFocusLoss() {
        guard phase == .barOnly else {
            return
        }
        dismissPreSendBar()
    }

    /// Handles `Esc` key presses when no popover or IME marked text owns focus.
    /// Returns `true` if the pre-send bar was dismissed.
    @discardableResult
    func handleEscapeKey() -> Bool {
        guard phase == .barOnly, isVisible else {
            return false
        }
        dismissPreSendBar()
        return true
    }

    /// Explicitly closes Quick Mode (red Close traffic light or `Cmd+W`):
    /// stops any active stream, archives the expanded conversation into `mostRecentQuickSession`,
    /// and hides the panel (preserving pre-send draft if still in `.barOnly`).
    func closeQuickWindow() async {
        if let store = _session {
            if store.isStreaming {
                await store.stop()
            }
            if phase == .expanded {
                if store.hasTurns {
                    captureMostRecentQuickSessionIfNeeded()
                } else {
                    phase = .barOnly
                }
            }
        }
        isVisible = false
    }

    /// Handles the minimalist top-right `+` orb button inside the `.expanded` Quick Mini-Window:
    /// stops any active stream, archives the current session, resets inheriting `quickModeTemporaryChat`,
    /// returns to `.barOnly`, and focuses the composer.
    func startFreshQuickChatFromPlusButton() async {
        let (store, _) = ensureSession()
        if store.isStreaming {
            await store.stop()
        }
        captureMostRecentQuickSessionIfNeeded()

        let desiredTemp = quickModeTempGetter()
        isTemporaryChatPreference = desiredTemp
        store.resetToEmptyState(temporary: desiredTemp, preserveDraft: false)

        phase = .barOnly
        isVisible = true
        focusTrigger &+= 1

        scheduleHomeLoad(temporaryChat: desiredTemp)
    }

    /// Persists Quick Mode's `Temp` switch choice and synchronizes the active `ChatSessionStore`
    /// so both the current session and all future Quick sessions inherit it automatically.
    func setQuickModeTemporaryChat(_ enabled: Bool) async {
        quickModeTempSetter(enabled)
        isTemporaryChatPreference = enabled

        guard let store = _session else {
            return
        }

        if isPerformingHomeLoad || (!hasCompletedInitialHomeLoad && !store.hasTurns) {
            store.handleTransportEvent(.temporaryChatStateChanged(enabled))
            scheduleHomeLoad(temporaryChat: enabled)
            if let task = homeLoadTask {
                await task.value
            }
            return
        }

        await store.setTemporaryChat(enabled)
    }

    /// Synchronously updates the persisted Quick Mode temporary-chat preference before dispatching
    /// async transport synchronization (used by two-way SwiftUI toggle bindings to avoid flicker).
    func persistTemporaryChatPreferenceImmediately(_ enabled: Bool) {
        quickModeTempSetter(enabled)
        isTemporaryChatPreference = enabled
    }

    /// Resets Quick Mode to a clean signed-out state when browsing data is cleared (`§4 #5`).
    func handleBrowsingDataCleared() {
        cancelPendingHomeLoad()
        hasCompletedInitialHomeLoad = false
        mostRecentQuickSession = nil
        mostRecentQuickWasTemporary = false
        authState = .signedOut
        phase = .barOnly
        isVisible = false

        if let store = _session {
            store.updateAccountScope(nil)
            store.resetToEmptyState(temporary: false, preserveDraft: false)
        }
    }

    // MARK: - Private Helpers

    @discardableResult
    private func ensureSession() -> (store: ChatSessionStore, wasNewlyCreated: Bool) {
        if let existing = _session {
            return (existing, false)
        }

        let transport = transportFactory()
        let initialTemp = quickModeTempGetter()
        isTemporaryChatPreference = initialTemp

        let store = ChatSessionStore(
            transport: transport,
            cache: cache,
            initialTemporaryChat: initialTemp,
            streamStartTimeout: streamStartTimeout,
            streamCoalesceInterval: streamCoalesceInterval,
            attachToTransportEvents: false
        )

        transport.onEvent = { [weak self] event in
            self?.handleTransportEvent(event)
        }

        store.onFirstSendAttempted = { [weak self] in
            self?.expandForFirstSend()
        }

        store.onConversationCompleted = { [weak self] snapshot in
            self?.handleConversationCompleted(snapshot)
        }

        _transport = transport
        _session = store
        return (store, true)
    }

    private func captureMostRecentQuickSessionIfNeeded() {
        guard let store = _session, phase == .expanded, store.hasTurns else {
            return
        }

        mostRecentQuickSession = ConversationSnapshot(
            accountScopeId: store.accountScopeId ?? "",
            conversationId: store.conversationId ?? "quick-\(UUID().uuidString)",
            title: store.title,
            modelId: store.selectedModelId,
            updatedAt: now(),
            turns: store.turns
        )
        mostRecentQuickWasTemporary = store.isTemporaryChat
    }

    private func handleConversationCompleted(_ snapshot: ConversationSnapshot) {
        guard phase == .expanded else {
            return
        }
        mostRecentQuickSession = snapshot
        mostRecentQuickWasTemporary = false
    }

    private func handleTransportEvent(_ event: ChatTransportEvent) {
        switch event {
        case .authStateChanged(let newState):
            authState = newState
            switch newState {
            case .signedIn(let active, _):
                _session?.updateAccountScope(active.scopeId)
            case .signedOut:
                mostRecentQuickSession = nil
                mostRecentQuickWasTemporary = false
                phase = .barOnly
                _session?.updateAccountScope(nil)
                _session?.resetToEmptyState(temporary: false, preserveDraft: false)
            case .unknown:
                _session?.updateAccountScope(nil)
            }

        case .temporaryChatStateChanged:
            guard !isPerformingHomeLoad else {
                return
            }
            _session?.handleTransportEvent(event)

        case .conversationSynced,
             .conversationNotFound,
             .modelsUpdated,
             .challengeEncountered,
             .challengeCleared:
            _session?.handleTransportEvent(event)

        case .recentConversationsUpdated:
            break
        }
    }

    private func scheduleHomeLoad(temporaryChat: Bool, stopActiveStreamFirst: Bool = false) {
        cancelPendingHomeLoad()
        guard let transport = _transport else {
            return
        }

        let generation = homeLoadGeneration
        let authUser = activeAuthUserProvider()
        isPerformingHomeLoad = true

        homeLoadTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.homeLoadGeneration == generation {
                    self.isPerformingHomeLoad = false
                }
            }

            if stopActiveStreamFirst {
                await transport.stopStreaming()
            }

            guard !Task.isCancelled, self.homeLoadGeneration == generation else {
                return
            }

            do {
                let result = try await transport.loadHome(authUser: authUser, temporaryChat: temporaryChat)
                guard !Task.isCancelled, self.homeLoadGeneration == generation else {
                    return
                }
                self.hasCompletedInitialHomeLoad = true
                self.applyHomeLoadResult(result)
            } catch let error as ChatTransportError {
                guard !Task.isCancelled, self.homeLoadGeneration == generation else {
                    return
                }
                if case .notSignedIn = error {
                    self.authState = .signedOut
                    self._session?.updateAccountScope(nil)
                } else if case .challengeRequired(let banner) = error {
                    self._session?.challengeBanner = banner
                } else {
                    Self.logger.error("Quick Mode home load failed: \(error.localizedDescription, privacy: .public)")
                }
            } catch {
                guard !Task.isCancelled, self.homeLoadGeneration == generation else {
                    return
                }
                Self.logger.error("Quick Mode home load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applyHomeLoadResult(_ result: HomeLoadResult) {
        authState = result.authState

        guard let store = _session else {
            return
        }

        switch result.authState {
        case .signedIn(let active, _):
            store.updateAccountScope(active.scopeId)
        case .signedOut:
            store.updateAccountScope(nil)
            if !store.hasTurns {
                phase = .barOnly
            }
        case .unknown:
            store.updateAccountScope(nil)
        }

        if !result.availableModels.isEmpty {
            store.handleTransportEvent(
                .modelsUpdated(available: result.availableModels, selectedId: result.selectedModelId)
            )
        }
    }

    private func cancelPendingHomeLoad() {
        homeLoadGeneration &+= 1
        homeLoadTask?.cancel()
        homeLoadTask = nil
        isPerformingHomeLoad = false
    }
}
