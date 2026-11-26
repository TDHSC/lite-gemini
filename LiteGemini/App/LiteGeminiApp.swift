import Combine
import Sparkle
import SwiftUI
import WebKit

// MARK: - NoopChatTransport

/// Lightweight placeholder `ChatTransport` used until Wave 2 connects `GeminiSessionEngine`,
/// keeping T04's Native Liquid Glass shell and URL mode handoff fully functional standalone.
@MainActor
final class NoopChatTransport: ChatTransport {

    var onEvent: (@MainActor (ChatTransportEvent) -> Void)?

    func loadHome(authUser: Int?, temporaryChat: Bool) async throws -> HomeLoadResult {
        HomeLoadResult(authState: .unknown, isTemporaryChat: temporaryChat)
    }

    func loadConversation(id: String, authUser: Int?) async throws -> ConversationSnapshot {
        ConversationSnapshot(
            accountScopeId: "",
            conversationId: id,
            title: "",
            turns: []
        )
    }

    func refreshRecentConversations() async throws -> [ConversationSummary] {
        []
    }

    func sendPrompt(
        text: String,
        attachments: [StagedAttachment],
        modelId: String?,
        isTemporaryChat: Bool
    ) -> AsyncThrowingStream<StreamingDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ChatTransportError.cancelled)
        }
    }

    func stopStreaming() async {}

    func editLastTurn(newText: String) -> AsyncThrowingStream<StreamingDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ChatTransportError.cancelled)
        }
    }

    func regenerateLastTurn() -> AsyncThrowingStream<StreamingDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ChatTransportError.cancelled)
        }
    }

    func selectModel(id: String) async throws {}

    func setTemporaryChat(_ enabled: Bool) async throws {}

    func switchAccount(authUserIndex: Int) async throws -> HomeLoadResult {
        HomeLoadResult(authState: .unknown)
    }
}

// MARK: - InterfaceModeHandoffCoordinator

/// Coordinates canonical `url_reload_handoff` transitions between Native Liquid Glass and
/// Classic Web Mode, `Cmd+R` re-sync, and `.newChatRequested` dispatch across both modes.
@MainActor
final class InterfaceModeHandoffCoordinator: ObservableObject {

    let workspace: MainWorkspaceStore

    private let isNativeUIActiveProvider: () -> Bool
    private let setInterfaceMode: (InterfaceMode) -> Void
    private let currentWebURL: () -> URL?
    private let loadWebURL: (URL) -> Void
    private let reloadWebView: () -> Void
    private let postClassicNewChat: () -> Void

    private var lastSyncedNativeState: Bool

    init(
        workspace: MainWorkspaceStore,
        isNativeUIActive: @escaping () -> Bool = { SettingsManager.shared.isNativeUIActive },
        setInterfaceMode: @escaping (InterfaceMode) -> Void = { SettingsManager.shared.interfaceMode = $0 },
        currentWebURL: @escaping () -> URL?,
        loadWebURL: @escaping (URL) -> Void,
        reloadWebView: @escaping () -> Void,
        postClassicNewChat: @escaping () -> Void = {
            NotificationCenter.default.post(name: .newChatRequested, object: nil)
        }
    ) {
        self.workspace = workspace
        self.isNativeUIActiveProvider = isNativeUIActive
        self.setInterfaceMode = setInterfaceMode
        self.currentWebURL = currentWebURL
        self.loadWebURL = loadWebURL
        self.reloadWebView = reloadWebView
        self.postClassicNewChat = postClassicNewChat
        self.lastSyncedNativeState = isNativeUIActive()
    }

    // MARK: - Mode Handoff

    /// Switches from Native Mode to Classic Web Mode via canonical URL reload handoff,
    /// preserving `/app/<id>` and `?authuser=N` while cancelling any active native stream.
    func switchToWebMode(overrideConversationId: String? = nil) {
        let wasNative = isNativeUIActiveProvider()
        guard wasNative || overrideConversationId != nil else {
            return
        }

        let targetURL = workspace.urlForWebModeHandoff(overrideConversationId: overrideConversationId)
        lastSyncedNativeState = false
        setInterfaceMode(.web)
        loadWebURL(targetURL)

        if workspace.session.isStreaming {
            Task { @MainActor [weak self] in
                await self?.workspace.session.stop()
            }
        }
    }

    /// Async variant of `switchToWebMode` allowing deterministic callers/tests to await stream stop.
    func switchToWebModeAsync(overrideConversationId: String? = nil) async -> URL {
        let targetURL = workspace.urlForWebModeHandoff(overrideConversationId: overrideConversationId)
        lastSyncedNativeState = false
        if workspace.session.isStreaming {
            await workspace.session.stop()
        }
        setInterfaceMode(.web)
        loadWebURL(targetURL)
        return targetURL
    }

    /// Switches from Classic Web Mode to Native Mode by parsing the active WebView URL and
    /// triggering a clean workspace sync (`url_reload_handoff`).
    func switchToNativeMode() {
        guard !isNativeUIActiveProvider() else {
            return
        }

        let sourceURL = resolvedWebURLForNativeHandoff()
        lastSyncedNativeState = true
        setInterfaceMode(.native)

        Task { @MainActor [weak self] in
            await self?.workspace.syncFromWebModeURL(sourceURL)
        }
    }

    /// Async variant of `switchToNativeMode` allowing deterministic callers/tests to await full sync.
    func switchToNativeModeAsync() async {
        let sourceURL = resolvedWebURLForNativeHandoff()
        lastSyncedNativeState = true
        setInterfaceMode(.native)
        await workspace.syncFromWebModeURL(sourceURL)
    }

    /// Reconciles external changes to `SettingsManager.isNativeUIActive` (such as toggling the
    /// experimental Native UI switch in Settings) without double-running explicit menu handoffs.
    func reconcileExternalNativeUIState(_ isNowNative: Bool) {
        guard isNowNative != lastSyncedNativeState else {
            return
        }
        lastSyncedNativeState = isNowNative

        if isNowNative {
            let sourceURL = resolvedWebURLForNativeHandoff()
            Task { @MainActor [weak self] in
                await self?.workspace.syncFromWebModeURL(sourceURL)
            }
        } else {
            let targetURL = workspace.urlForWebModeHandoff()
            loadWebURL(targetURL)
            if workspace.session.isStreaming {
                Task { @MainActor [weak self] in
                    await self?.workspace.session.stop()
                }
            }
        }
    }

    // MARK: - Commands & Auth Fallback

    /// Routes `Cmd+R`: re-syncs the active conversation in Native Mode or reloads the WebView in Classic Mode.
    func reloadActiveSurface() {
        guard isNativeUIActiveProvider() else {
            reloadWebView()
            return
        }

        Task { @MainActor [weak self] in
            await self?.resyncActiveNativeSurface()
        }
    }

    /// Re-syncs the active native conversation (or reloads home state) and refreshes Recent Chats.
    func resyncActiveNativeSurface() async {
        if let conversationId = workspace.activeConversationId ?? workspace.session.conversationId,
           !conversationId.isEmpty {
            await workspace.selectConversation(id: conversationId)
        } else {
            await workspace.loadInitialState(authUser: workspace.activeAuthUserIndex)
        }

        if workspace.authState.isSignedIn {
            await workspace.refreshRecentConversations()
        }
    }

    /// Starts a fresh chat in whichever interface mode is currently active (triggered by File menu).
    func requestNewChat() {
        if isNativeUIActiveProvider() {
            handleNewChatNotificationInNativeMode()
        } else {
            postClassicNewChat()
        }
    }

    /// Handles `.newChatRequested` notifications while Native Mode is active.
    func handleNewChatNotificationInNativeMode() {
        guard isNativeUIActiveProvider() else {
            return
        }
        Task { @MainActor [weak self] in
            await self?.workspace.startNewChat()
        }
    }

    /// Opens an authentication or challenge recovery URL in Classic Web Mode over the shared
    /// `WKWebsiteDataStore` (Wave 2 merge routes this through `GeminiSessionEngine`'s popup flow).
    func openAuthOrChallengeURL(_ url: URL) {
        lastSyncedNativeState = false
        if workspace.session.isStreaming {
            Task { @MainActor [weak self] in
                await self?.workspace.session.stop()
            }
        }
        loadWebURL(url)
        setInterfaceMode(.web)
    }

    // MARK: - Private Helpers

    private func resolvedWebURLForNativeHandoff() -> URL {
        currentWebURL() ?? GeminiURLRoute.newChat(authUser: workspace.activeAuthUserIndex).canonicalURL
    }
}

// MARK: - LiteGeminiApp

@main
struct LiteGeminiApp: App {

    // Persist lifecycle across window hide/reopen transitions.
    @StateObject private var appCoordinator = AppCoordinator()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(
                viewModel: appCoordinator.classicWebViewModel,
                workspaceStore: appCoordinator.workspaceStore,
                handoffCoordinator: appCoordinator.handoffCoordinator,
                coordinator: appCoordinator
            )
        }
        .windowStyle(.hiddenTitleBar)
        // The web view has no ideal size, so give first launch an explicit one;
        // a saved frame still wins after that.
        .defaultSize(width: 800, height: 600)
        .commands {
            // Cmd+Q: quit, or hide to the background when the user keeps the app running.
            // Replacing the menu item instead of vetoing applicationShouldTerminate keeps
            // logout, shutdown, Sparkle relaunches and `quit app` requests working.
            CommandGroup(replacing: .appTermination) {
                QuitCommand()
            }

            // Cmd+Shift+N: start a fresh chat in whichever interface mode is active.
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    appCoordinator.handoffCoordinator.requestNewChat()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            // Cmd+W: close settings window when focused; hide app when main window is focused.
            CommandGroup(replacing: .saveItem) {
                Button("Close Window") {
                    if let keyWindow = NSApp.keyWindow {
                        if keyWindow.delegate is AppDelegate {
                            WindowVisibility.shared.hide()
                        } else {
                            keyWindow.close()
                        }
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            // Interface mode switch (when enabled), Cmd+R to reload/re-sync, Cmd+[ / Cmd+] for
            // Classic Web navigation inside the system View menu.
            CommandGroup(before: .toolbar) {
                InterfaceModeCommands(
                    onSwitchToNative: { appCoordinator.handoffCoordinator.switchToNativeMode() },
                    onSwitchToWeb: { appCoordinator.handoffCoordinator.switchToWebMode() }
                )

                Button("Reload Page") {
                    appCoordinator.handoffCoordinator.reloadActiveSurface()
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                NavigationHistoryCommands(webViewModel: appCoordinator.classicWebViewModel)

                Divider()
            }

            // Native v2.2 conversational power tools: Search Chats (⌘K), Quote Selection (⌘⇧'), Ask in Btw (⌘⇧B).
            CommandMenu("Chat") {
                NativeChatCommands(coordinator: appCoordinator)
            }
        }

        // Standard macOS settings window, opened with Cmd+,
        Settings {
            SettingsView(updater: appDelegate.updaterController.updater)
        }
    }
}

// MARK: - Menu Commands

/// View-menu items for switching between Native Liquid Glass and Classic Web Mode (`⌘⇧M`).
private struct InterfaceModeCommands: View {
    @ObservedObject private var settings = SettingsManager.shared
    let onSwitchToNative: () -> Void
    let onSwitchToWeb: () -> Void

    var body: some View {
        if settings.enableNativeUI {
            if settings.interfaceMode == .native {
                Toggle("Native Liquid Glass", isOn: Binding(
                    get: { true },
                    set: { _ in onSwitchToNative() }
                ))
                Toggle("Classic Web Mode", isOn: Binding(
                    get: { false },
                    set: { _ in onSwitchToWeb() }
                ))
                .keyboardShortcut("m", modifiers: [.command, .shift])
            } else {
                Toggle("Native Liquid Glass", isOn: Binding(
                    get: { false },
                    set: { _ in onSwitchToNative() }
                ))
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Toggle("Classic Web Mode", isOn: Binding(
                    get: { true },
                    set: { _ in onSwitchToWeb() }
                ))
            }

            Divider()
        }
    }
}

/// View-menu back/forward navigation commands for Classic Web Mode.
private struct NavigationHistoryCommands: View {
    @ObservedObject var webViewModel: ClassicWebViewModel
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        Button("Go Back") {
            webViewModel.webView.goBack()
        }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(settings.isNativeUIActive || !webViewModel.canGoBack)

        Button("Go Forward") {
            webViewModel.webView.goForward()
        }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(settings.isNativeUIActive || !webViewModel.canGoForward)
    }
}

/// Menu commands & global window shortcuts for v2.2 conversational power tools.
private struct NativeChatCommands: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        Button("Search Chats…") {
            coordinator.toggleSearchChats()
        }
        .keyboardShortcut("k", modifiers: .command)
        .disabled(!settings.isNativeUIActive)

        Divider()

        Button("Quote Selection") {
            coordinator.quoteCurrentSelectionIntoComposer()
        }
        .keyboardShortcut("'", modifiers: [.command, .shift])
        .disabled(!settings.isNativeUIActive)

        Button("Ask in Btw") {
            coordinator.triggerBtwFromShortcut()
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
        .disabled(!settings.isNativeUIActive)
    }
}

/// Cmd+Q menu item; observes the setting so the item updates when it changes.
private struct QuitCommand: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        if settings.keepRunningInBackground {
            Button("Hide to Background") {
                WindowVisibility.shared.hide()
            }
            .keyboardShortcut("q", modifiers: .command)
        } else {
            Button("Quit Lite Gemini") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
