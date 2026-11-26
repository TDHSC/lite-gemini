import Combine
import Foundation
import os

// MARK: - MainWorkspaceStore

/// Main-window `@MainActor` workspace orchestrator composing the shared `ChatSessionStore`
/// with multi-account state, Recent Chats SWR caching, cold-start/background-timeout lifecycle,
/// `BrowsingDataCleared` wipe handling, and `url_reload_handoff` dual-mode synchronization.
@MainActor
final class MainWorkspaceStore: ObservableObject {

    // MARK: - Constants

    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "MainWorkspaceStore")

    // MARK: - Published State

    /// Current authentication state and available signed-in accounts.
    @Published private(set) var authState: AuthState = .unknown
    /// Recent conversations for the active account, backed by SWR cache and server refresh.
    @Published private(set) var recentConversations: [ConversationSummary] = []
    /// Whether the Recent Chats list is currently refreshing from the server.
    @Published private(set) var isRefreshingRecent: Bool = false
    /// Currently selected conversation ID in the main workspace, or `nil` for a new chat.
    @Published private(set) var activeConversationId: String?

    // MARK: - Composed Dependencies

    /// Reusable single-conversation state machine driving the main chat surface.
    let session: ChatSessionStore
    /// Account-scoped read-only SWR snapshot cache.
    let cache: SWRConversationCache
    /// Transport bridge backing this workspace.
    let transport: any ChatTransport

    // MARK: - Computed Properties

    /// Currently active signed-in account, if any.
    var activeAccount: AccountScope? {
        authState.activeAccount
    }

    /// Multi-account `?authuser=N` index of the active account, if signed in.
    var activeAuthUserIndex: Int? {
        authState.activeAccount?.authUserIndex
    }

    // MARK: - Configuration & Lifecycle State

    private let backgroundTimeoutSeconds: () -> TimeInterval?
    private let defaultTemporaryChat: () -> Bool
    private let clearDataNotificationName: Notification.Name
    private let notificationCenter: NotificationCenter
    private let now: () -> Date

    private var clearDataObserver: (any NSObjectProtocol)?
    private var lastResignedAt: Date?
    private var activeSyncGeneration: UInt64 = 0
    private var activeSyncTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        transport: any ChatTransport,
        cache: SWRConversationCache = SWRConversationCache(),
        session: ChatSessionStore? = nil,
        backgroundTimeoutSeconds: @escaping () -> TimeInterval? = { 600 },
        defaultTemporaryChat: @escaping () -> Bool = { false },
        clearDataNotificationName: Notification.Name = SWRConversationCache.defaultClearDataNotificationName,
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = { Date() }
    ) {
        self.transport = transport
        self.cache = cache
        self.backgroundTimeoutSeconds = backgroundTimeoutSeconds
        self.defaultTemporaryChat = defaultTemporaryChat
        self.clearDataNotificationName = clearDataNotificationName
        self.notificationCenter = notificationCenter
        self.now = now

        if let session {
            self.session = session
        } else {
            self.session = ChatSessionStore(
                transport: transport,
                cache: cache,
                initialTemporaryChat: defaultTemporaryChat(),
                attachToTransportEvents: false
            )
        }

        self.transport.onEvent = { [weak self] event in
            self?.handleTransportEvent(event)
        }

        self.session.onConversationCompleted = { [weak self] snapshot in
            self?.handleConversationCompleted(snapshot)
        }

        self.clearDataObserver = notificationCenter.addObserver(
            forName: clearDataNotificationName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
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
        activeSyncTask?.cancel()
        if let clearDataObserver {
            notificationCenter.removeObserver(clearDataObserver)
        }
    }

    // MARK: - Cold-Start & Lifecycle Restoration

    /// Restores cached account state in 0ms on cold launch when `backgroundTimeout` has not elapsed,
    /// or initializes an empty New Chat respecting `defaultTemporaryChat()`.
    ///
    /// Returns the conversation ID restored from cache, if any, so callers can observe or await
    /// silent background revalidation via `revalidateRestoredConversationIfNeeded()`.
    @discardableResult
    func restoreOnColdStart(
        for account: AccountScope,
        availableAccounts: [AccountScope]? = nil
    ) -> String? {
        let accounts = availableAccounts ?? [account]
        authState = .signedIn(active: account, available: accounts)
        session.updateAccountScope(account.scopeId)
        recentConversations = cache.loadRecentConversations(accountScopeId: account.scopeId)

        if let record = cache.loadLastActiveConversation(accountScopeId: account.scopeId),
           isWithinBackgroundTimeout(since: record.updatedAt),
           let cachedSnapshot = cache.loadConversation(
               accountScopeId: account.scopeId,
               conversationId: record.conversationId,
               accessedAt: now()
           ) {
            activeConversationId = record.conversationId
            session.applySnapshot(cachedSnapshot, persistToCache: false)
            scheduleBackgroundRevalidation(conversationId: record.conversationId, account: account)
            return record.conversationId
        }

        activeConversationId = nil
        session.resetToEmptyState(temporary: defaultTemporaryChat())
        return nil
    }

    /// Loads initial home metadata from the transport and reconciles cold-start cache state.
    func loadInitialState(authUser: Int? = nil) async {
        activeSyncGeneration &+= 1
        let generation = activeSyncGeneration
        session.setSyncing(true)
        defer {
            if activeSyncGeneration == generation {
                session.setSyncing(false)
            }
        }

        do {
            let result = try await transport.loadHome(
                authUser: authUser,
                temporaryChat: defaultTemporaryChat()
            )
            guard activeSyncGeneration == generation else {
                return
            }

            applyHomeResult(result, restoreCachedConversationIfEligible: true)
        } catch let error as ChatTransportError {
            guard activeSyncGeneration == generation else {
                return
            }
            if case .notSignedIn = error {
                applySignedOutState()
            } else if case .challengeRequired(let banner) = error {
                session.challengeBanner = banner
            } else {
                session.lastErrorMessage = error.errorDescription
            }
        } catch {
            guard activeSyncGeneration == generation else {
                return
            }
            session.lastErrorMessage = error.localizedDescription
        }
    }

    /// Records the timestamp when the app leaves the foreground for background timeout evaluation.
    func handleAppDidResignActive() {
        let currentTime = now()
        lastResignedAt = currentTime

        if !session.isTemporaryChat,
           let scopeId = activeAccount?.scopeId,
           let convId = activeConversationId {
            cache.saveLastActiveConversationId(
                convId,
                updatedAt: currentTime,
                accountScopeId: scopeId,
                isTemporaryChat: false
            )
        }
    }

    /// Evaluates `backgroundTimeout` upon app reactivation:
    /// - If expired, resets immediately in 0ms to an empty New Chat (purging any temporary chat)
    ///   and triggers a background `/app` load.
    /// - If still active (or `.never`), preserves the current conversation and silently revalidates
    ///   it when idle.
    func handleAppDidBecomeActive() {
        let resignedAt = lastResignedAt
        lastResignedAt = nil

        if let resignedAt,
           let timeout = backgroundTimeoutSeconds(),
           now().timeIntervalSince(resignedAt) >= timeout {
            // Timeout elapsed: immediately reset in 0ms and purge any ephemeral turns from memory.
            activeSyncGeneration &+= 1
            activeSyncTask?.cancel()
            activeSyncTask = nil

            let useTemporary = defaultTemporaryChat()
            activeConversationId = nil
            session.resetToEmptyState(temporary: useTemporary)

            if let account = activeAccount {
                let authUser = account.authUserIndex
                activeSyncTask = Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    _ = try? await self.transport.loadHome(authUser: authUser, temporaryChat: useTemporary)
                }
            }
            return
        }

        // Timeout not elapsed: preserve active conversation and silently revalidate if non-temporary.
        if let account = activeAccount,
           let convId = activeConversationId,
           !session.isTemporaryChat,
           !session.isStreaming {
            scheduleBackgroundRevalidation(conversationId: convId, account: account)
        }
    }

    // MARK: - Conversation & Recent Chats Actions

    /// Selects a conversation: renders its cached snapshot in 0ms on cache hit, then silently
    /// revalidates against the server (Server-Always-Wins) and evicts on server not-found.
    func selectConversation(id: String) async {
        guard !id.isEmpty else {
            return
        }

        if session.isStreaming {
            await session.stop()
        }

        activeSyncGeneration &+= 1
        let generation = activeSyncGeneration
        activeSyncTask?.cancel()
        activeSyncTask = nil

        let scopeId = activeAccount?.scopeId
        let authUser = activeAuthUserIndex

        activeConversationId = id

        if let cached = cache.loadConversation(accountScopeId: scopeId, conversationId: id, accessedAt: now()) {
            session.applySnapshot(cached, persistToCache: false)
        } else {
            session.prepareForConversationLoad(id: id)
        }

        session.setSyncing(true)
        defer {
            if activeSyncGeneration == generation {
                session.setSyncing(false)
            }
        }

        do {
            let authoritative = try await transport.loadConversation(id: id, authUser: authUser)
            guard activeSyncGeneration == generation,
                  activeConversationId == id,
                  activeAccount?.scopeId == scopeId || scopeId == nil else {
                return
            }

            session.applySnapshot(authoritative, persistToCache: true)
            cache.saveLastActiveConversationId(
                authoritative.conversationId,
                updatedAt: now(),
                accountScopeId: authoritative.accountScopeId,
                isTemporaryChat: false
            )
            upsertRecentSummary(from: authoritative)
        } catch let error as ChatTransportError {
            guard activeSyncGeneration == generation else {
                return
            }
            switch error {
            case .conversationNotFound(let missingId):
                handleConversationNotFound(id: missingId, scopeId: scopeId)
            case .challengeRequired(let banner):
                session.challengeBanner = banner
                session.lastErrorMessage = banner.message
            default:
                session.lastErrorMessage = error.errorDescription
            }
        } catch {
            guard activeSyncGeneration == generation else {
                return
            }
            session.lastErrorMessage = error.localizedDescription
        }
    }

    /// Refreshes the Recent Chats list from the server and atomically replaces `recent.json`.
    func refreshRecentConversations() async {
        guard let scopeId = activeAccount?.scopeId else {
            return
        }

        isRefreshingRecent = true
        defer { isRefreshingRecent = false }

        do {
            let summaries = try await transport.refreshRecentConversations()
            guard activeAccount?.scopeId == scopeId else {
                return
            }
            recentConversations = summaries
            cache.saveRecentConversations(summaries, accountScopeId: scopeId)
        } catch let error as ChatTransportError {
            if case .challengeRequired(let banner) = error {
                session.challengeBanner = banner
            }
            session.lastErrorMessage = error.errorDescription
        } catch {
            session.lastErrorMessage = error.localizedDescription
        }
    }

    /// Starts a fresh chat in the main workspace, purging any prior temporary chat turns.
    func startNewChat(temporary: Bool? = nil) async {
        activeSyncGeneration &+= 1
        activeSyncTask?.cancel()
        activeSyncTask = nil

        let useTemporary = temporary ?? defaultTemporaryChat()
        activeConversationId = nil

        if !useTemporary {
            cache.saveLastActiveConversationId(
                nil,
                updatedAt: now(),
                accountScopeId: activeAccount?.scopeId,
                isTemporaryChat: false
            )
        }

        await session.startNewChat(temporary: useTemporary, authUser: activeAuthUserIndex)
    }

    // MARK: - Multi-Account Switching

    /// Switches to another signed-in Google account, immediately isolating cached recent lists
    /// and resetting active conversation state before reloading from the transport.
    func switchAccount(_ target: AccountScope) async {
        if session.isStreaming {
            await session.stop()
        }

        activeSyncGeneration &+= 1
        let generation = activeSyncGeneration
        activeSyncTask?.cancel()
        activeSyncTask = nil

        // Swap scope and cached recent list immediately so accounts never bleed into each other.
        let available = authState.availableAccounts.isEmpty ? [target] : authState.availableAccounts
        authState = .signedIn(active: target, available: available)
        session.updateAccountScope(target.scopeId)
        activeConversationId = nil
        session.resetToEmptyState(temporary: defaultTemporaryChat())
        recentConversations = cache.loadRecentConversations(accountScopeId: target.scopeId)

        await performAccountSwitch(authUserIndex: target.authUserIndex, generation: generation)
    }

    /// Switches to another Google account by its `?authuser=N` index.
    func switchAccount(authUserIndex: Int) async {
        if let known = authState.availableAccounts.first(where: { $0.authUserIndex == authUserIndex }) {
            await switchAccount(known)
            return
        }

        if session.isStreaming {
            await session.stop()
        }

        activeSyncGeneration &+= 1
        let generation = activeSyncGeneration
        activeSyncTask?.cancel()
        activeSyncTask = nil

        activeConversationId = nil
        session.updateAccountScope(nil)
        session.resetToEmptyState(temporary: defaultTemporaryChat())
        recentConversations = []

        await performAccountSwitch(authUserIndex: authUserIndex, generation: generation)
    }

    // MARK: - Dual-Mode URL Reload Handoff

    /// Builds the canonical `https://gemini.google.com/...` URL for handing off from Native Mode
    /// to Classic Web Mode, preserving `?authuser=N` and never leaking temporary sessions.
    func urlForWebModeHandoff(overrideConversationId: String? = nil) -> URL {
        let authUser = activeAuthUserIndex
        if let overrideConversationId, !overrideConversationId.isEmpty {
            return GeminiURLRoute.conversation(id: overrideConversationId, authUser: authUser).canonicalURL
        }
        if !session.isTemporaryChat,
           let currentId = session.conversationId ?? activeConversationId,
           !currentId.isEmpty {
            return GeminiURLRoute.conversation(id: currentId, authUser: authUser).canonicalURL
        }
        return GeminiURLRoute.newChat(authUser: authUser).canonicalURL
    }

    /// Reconciles workspace state when handing off from Classic Web Mode back to Native Mode
    /// using the active `WKWebView` URL (`url_reload_handoff`).
    func syncFromWebModeURL(_ url: URL) async {
        if session.isStreaming {
            await session.stop()
        }

        let route = GeminiURLRoute.parse(url) ?? .newChat(authUser: activeAuthUserIndex)

        if let targetAuthUser = route.authUser,
           activeAuthUserIndex != targetAuthUser {
            await switchAccount(authUserIndex: targetAuthUser)
        }

        switch route {
        case .conversation(let id, _):
            await selectConversation(id: id)
        case .gem(_, let conversationId, _):
            if let conversationId, !conversationId.isEmpty {
                await selectConversation(id: conversationId)
            } else {
                await startNewChat(temporary: defaultTemporaryChat())
            }
        case .newChat:
            await startNewChat(temporary: defaultTemporaryChat())
        }
    }

    // MARK: - Clear Browsing Data

    /// Synchronously wipes the cache directory and resets workspace and session state to signed-out.
    func handleBrowsingDataCleared() {
        activeSyncGeneration &+= 1
        activeSyncTask?.cancel()
        activeSyncTask = nil
        lastResignedAt = nil

        cache.clearAll()
        applySignedOutState()
    }

    // MARK: - Private Helpers

    private func performAccountSwitch(authUserIndex: Int, generation: UInt64) async {
        session.setSyncing(true)
        defer {
            if activeSyncGeneration == generation {
                session.setSyncing(false)
            }
        }

        do {
            let result = try await transport.switchAccount(authUserIndex: authUserIndex)
            guard activeSyncGeneration == generation else {
                return
            }
            applyHomeResult(result, restoreCachedConversationIfEligible: false)
        } catch let error as ChatTransportError {
            guard activeSyncGeneration == generation else {
                return
            }
            if case .notSignedIn = error {
                applySignedOutState()
            } else if case .challengeRequired(let banner) = error {
                session.challengeBanner = banner
            } else {
                session.lastErrorMessage = error.errorDescription
            }
        } catch {
            guard activeSyncGeneration == generation else {
                return
            }
            session.lastErrorMessage = error.localizedDescription
        }
    }

    private func applyHomeResult(_ result: HomeLoadResult, restoreCachedConversationIfEligible: Bool) {
        authState = result.authState
        session.applyHomeMetadata(result)

        switch result.authState {
        case .signedIn(let active, let available):
            session.updateAccountScope(active.scopeId)
            if !result.recentConversations.isEmpty {
                recentConversations = result.recentConversations
                cache.saveRecentConversations(result.recentConversations, accountScopeId: active.scopeId)
            } else {
                recentConversations = cache.loadRecentConversations(accountScopeId: active.scopeId)
            }

            if restoreCachedConversationIfEligible {
                _ = restoreOnColdStart(for: active, availableAccounts: available)
            }

        case .signedOut:
            applySignedOutState()

        case .unknown:
            session.updateAccountScope(nil)
            recentConversations = []
        }
    }

    private func applySignedOutState() {
        authState = .signedOut
        recentConversations = []
        activeConversationId = nil
        session.updateAccountScope(nil)
        session.resetToEmptyState(temporary: false)
    }

    private func handleTransportEvent(_ event: ChatTransportEvent) {
        switch event {
        case .authStateChanged(let newState):
            let previousScopeId = activeAccount?.scopeId
            authState = newState
            switch newState {
            case .signedIn(let active, _):
                session.updateAccountScope(active.scopeId)
                if previousScopeId != active.scopeId {
                    activeConversationId = nil
                    session.resetToEmptyState(temporary: defaultTemporaryChat())
                    recentConversations = cache.loadRecentConversations(accountScopeId: active.scopeId)
                }
            case .signedOut:
                applySignedOutState()
            case .unknown:
                session.updateAccountScope(nil)
            }

        case .recentConversationsUpdated(let summaries):
            guard let scopeId = activeAccount?.scopeId else {
                return
            }
            recentConversations = summaries
            cache.saveRecentConversations(summaries, accountScopeId: scopeId)

        case .conversationNotFound(let missingId):
            handleConversationNotFound(id: missingId, scopeId: activeAccount?.scopeId)

        case .conversationSynced(let snapshot):
            guard let scopeId = activeAccount?.scopeId, snapshot.accountScopeId == scopeId else {
                return
            }
            if activeConversationId == nil || activeConversationId == snapshot.conversationId {
                activeConversationId = snapshot.conversationId
            }
            session.handleTransportEvent(event)
            if !session.isTemporaryChat {
                cache.saveLastActiveConversationId(
                    snapshot.conversationId,
                    updatedAt: now(),
                    accountScopeId: scopeId,
                    isTemporaryChat: false
                )
                upsertRecentSummary(from: snapshot)
            }

        case .modelsUpdated, .temporaryChatStateChanged, .challengeEncountered, .challengeCleared:
            session.handleTransportEvent(event)
        }
    }

    private func handleConversationCompleted(_ snapshot: ConversationSnapshot) {
        guard !session.isTemporaryChat,
              let scopeId = activeAccount?.scopeId,
              snapshot.accountScopeId == scopeId else {
            return
        }

        activeConversationId = snapshot.conversationId
        cache.saveLastActiveConversationId(
            snapshot.conversationId,
            updatedAt: now(),
            accountScopeId: scopeId,
            isTemporaryChat: false
        )
        upsertRecentSummary(from: snapshot)
    }

    private func handleConversationNotFound(id: String, scopeId: String?) {
        cache.evictConversation(accountScopeId: scopeId, conversationId: id)
        recentConversations.removeAll { $0.id == id }
        if activeConversationId == id || session.conversationId == id {
            activeConversationId = nil
            session.resetToEmptyState(temporary: defaultTemporaryChat())
        }
    }

    private func upsertRecentSummary(from snapshot: ConversationSnapshot) {
        let updatedSummary = ConversationSummary(
            id: snapshot.conversationId,
            title: snapshot.title.isEmpty ? "Untitled" : snapshot.title,
            updatedAt: snapshot.updatedAt,
            isPinned: recentConversations.first(where: { $0.id == snapshot.conversationId })?.isPinned ?? false
        )
        var list = recentConversations.filter { $0.id != snapshot.conversationId }
        list.insert(updatedSummary, at: 0)
        recentConversations = list
        cache.saveRecentConversations(list, accountScopeId: snapshot.accountScopeId)
    }

    private func isWithinBackgroundTimeout(since date: Date) -> Bool {
        guard let timeout = backgroundTimeoutSeconds() else {
            return true
        }
        return now().timeIntervalSince(date) < timeout
    }

    private func scheduleBackgroundRevalidation(conversationId: String, account: AccountScope) {
        activeSyncGeneration &+= 1
        let generation = activeSyncGeneration
        activeSyncTask?.cancel()

        activeSyncTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            self.session.setSyncing(true)
            defer {
                if self.activeSyncGeneration == generation {
                    self.session.setSyncing(false)
                }
            }

            do {
                let authoritative = try await self.transport.loadConversation(
                    id: conversationId,
                    authUser: account.authUserIndex
                )
                guard !Task.isCancelled,
                      self.activeSyncGeneration == generation,
                      self.activeAccount?.scopeId == account.scopeId,
                      self.activeConversationId == conversationId,
                      !self.session.isStreaming else {
                    return
                }
                self.session.applySnapshot(authoritative, persistToCache: true)
                self.cache.saveLastActiveConversationId(
                    authoritative.conversationId,
                    updatedAt: self.now(),
                    accountScopeId: authoritative.accountScopeId,
                    isTemporaryChat: false
                )
            } catch let error as ChatTransportError {
                guard !Task.isCancelled, self.activeSyncGeneration == generation else {
                    return
                }
                if case .conversationNotFound(let missingId) = error {
                    self.handleConversationNotFound(id: missingId, scopeId: account.scopeId)
                } else if case .challengeRequired(let banner) = error {
                    self.session.challengeBanner = banner
                }
            } catch {
                Self.logger.error("Silent background revalidation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
