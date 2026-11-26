import AppKit
import Combine
import SwiftUI
import WebKit

// MARK: - HiddenSessionWebViewHost

/// Mounts a `GeminiSessionEngine`'s `WKWebView` with valid non-zero geometry behind the opaque/glass
/// native layer so WebKit keeps layout and `requestAnimationFrame` active for `GeminiActionDriver`
/// without intercepting clicks or accessibility traversal.
struct HiddenSessionWebViewHost: NSViewRepresentable {

    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - NativeEmptyConversationView

/// Calm monochrome empty-state view shown in Main Window when starting a fresh conversation.
struct NativeEmptyConversationView: View {

    let isTemporaryChat: Bool

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if isTemporaryChat {
                    TemporaryChatGhostShape()
                        .fill(LiquidGlassColors.tempActiveAccent, style: FillStyle(eoFill: true))
                        .frame(width: 24, height: 24)
                } else {
                    MonochromeSparkShape()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.primary.opacity(0.86),
                                    Color.primary.opacity(0.42)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 24, height: 24)
                }
            }
            .glassOrb(
                size: 52,
                tint: isTemporaryChat ? LiquidGlassColors.tempActiveTint : nil,
                interactive: false
            )
            .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(isTemporaryChat ? LocalizedStringKey("Temporary Chat") : LocalizedStringKey("How can I help?"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.90))

                Text(
                    isTemporaryChat
                        ? LocalizedStringKey("Chats here aren't saved to local cache or Gemini history.")
                        : LocalizedStringKey("Ask anything with 120Hz native Liquid Glass.")
                )
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - AppCoordinator

/// Single `@MainActor` composition root wiring `ClassicWebViewModel`, `MainWorkspaceStore`,
/// `InterfaceModeHandoffCoordinator`, lazy `QuickWorkspaceController` (`⌥Space` / `⌥⇧Space`),
/// and `HotKeyManager` callbacks.
@MainActor
final class AppCoordinator: ObservableObject {

    // MARK: - Owned Subsystems

    let classicWebViewModel: ClassicWebViewModel
    let mainSessionEngine: GeminiSessionEngine
    let workspaceStore: MainWorkspaceStore
    let handoffCoordinator: InterfaceModeHandoffCoordinator
    let quickWorkspaceController: QuickWorkspaceController
    private(set) var quickPanelController: QuickPanelController!

    /// Published lazily when Quick Mode allocates its isolated `GeminiSessionEngine` on first summon.
    @Published private(set) var activeQuickEngine: GeminiSessionEngine?

    /// Monotonically incremented token focusing Main Window's native `ComposerTextView`.
    @Published var mainComposerFocusTrigger: Int = 0

    private var hasBootstrappedMainNativeEngine: Bool = false
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Initialization

    init(settings: SettingsManager = .shared) {
        let classicVM = ClassicWebViewModel()
        let sharedCache = SWRConversationCache()

        let mainEngine = GeminiSessionEngine(
            websiteDataStore: .default(),
            downloadManager: classicVM.downloadManager,
            userAgent: settings.userAgent,
            surfaceBackgroundColor: AppDelegate.geminiSurfaceNSColor,
            defaultTemporaryChat: { SettingsManager.shared.defaultTemporaryChat }
        )

        let workspace = MainWorkspaceStore(
            transport: mainEngine,
            cache: sharedCache,
            backgroundTimeoutSeconds: { SettingsManager.shared.backgroundTimeout.seconds },
            defaultTemporaryChat: { SettingsManager.shared.defaultTemporaryChat }
        )

        let handoff = InterfaceModeHandoffCoordinator(
            workspace: workspace,
            currentWebURL: { [weak classicVM] in
                classicVM?.webView.url
            },
            loadWebURL: { [weak classicVM] url in
                classicVM?.webView.load(URLRequest(url: url))
            },
            reloadWebView: { [weak classicVM] in
                classicVM?.webView.reload()
            }
        )

        self.classicWebViewModel = classicVM
        self.mainSessionEngine = mainEngine
        self.workspaceStore = workspace
        self.handoffCoordinator = handoff

        var weakSelf: AppCoordinator?
        let quickController = QuickWorkspaceController(
            transportFactory: { [weak classicVM] in
                let quickEngine = GeminiSessionEngine(
                    websiteDataStore: .default(),
                    userAgent: SettingsManager.shared.userAgent,
                    surfaceBackgroundColor: AppDelegate.geminiSurfaceNSColor,
                    defaultTemporaryChat: { SettingsManager.shared.quickModeTemporaryChat }
                )
                quickEngine.onDownloadNotice = { [weak classicVM] notice in
                    classicVM?.downloadNotice = notice
                }
                weakSelf?.activeQuickEngine = quickEngine
                return quickEngine
            },
            cache: sharedCache,
            activeAuthUserProvider: { [weak workspace] in
                workspace?.activeAuthUserIndex
            }
        )
        self.quickWorkspaceController = quickController
        weakSelf = self

        mainEngine.onDownloadNotice = { [weak classicVM] notice in
            classicVM?.downloadNotice = notice
        }

        self.quickPanelController = QuickPanelController(controller: quickController) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(self.makeQuickPanelContent())
        }

        bindSettingsAndHotKeys(settings: settings)

        if settings.isNativeUIActive {
            bootstrapMainNativeEngineIfNeeded()
        }
    }

    // MARK: - Public Actions

    func bootstrapMainNativeEngineIfNeeded() {
        guard !hasBootstrappedMainNativeEngine else { return }
        hasBootstrappedMainNativeEngine = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.workspaceStore.loadInitialState()
        }
    }

    func focusMainComposer() {
        mainComposerFocusTrigger &+= 1
    }

    func handleSignInFromMain() {
        mainSessionEngine.openSignInPopup()
    }

    func handleAddAccountFromMain() {
        mainSessionEngine.openAddAccountPopup()
    }

    func handleVerifyChallengeFromMain(_ banner: ChallengeBannerState) {
        mainSessionEngine.openChallengePopup(url: banner.challengeURL)
    }

    func saveInlineImage(_ attachment: ImageAttachment) {
        classicWebViewModel.downloadManager.saveImageAttachment(attachment)
    }

    func openArtifactInMainWebMode(conversationId: String?) {
        WindowVisibility.shared.show()
        handoffCoordinator.switchToWebMode(overrideConversationId: conversationId)
    }

    // MARK: - Private Wiring

    private func bindSettingsAndHotKeys(settings: SettingsManager) {
        HotKeyManager.shared.onQuickNewHotKey = { [weak self] in
            self?.quickWorkspaceController.triggerNewQuickChat()
        }
        HotKeyManager.shared.onQuickRecentHotKey = { [weak self] in
            self?.quickWorkspaceController.triggerRecentQuickChat()
        }

        settings.$userAgent
            .dropFirst()
            .sink { [weak self] ua in
                self?.mainSessionEngine.updateUserAgent(ua)
                self?.activeQuickEngine?.updateUserAgent(ua)
            }
            .store(in: &cancellables)

        settings.$enableNativeUI
            .combineLatest(settings.$interfaceMode)
            .sink { [weak self] enabled, mode in
                guard enabled, mode == .native else { return }
                self?.bootstrapMainNativeEngineIfNeeded()
            }
            .store(in: &cancellables)
    }

    @ViewBuilder
    private func makeQuickPanelContent() -> some View {
        ZStack {
            if let quickEngine = activeQuickEngine {
                HiddenSessionWebViewHost(webView: quickEngine.webView)
                    .frame(width: 320, height: 240)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            QuickRootView(
                controller: quickWorkspaceController,
                onClose: { [weak self] in
                    self?.quickPanelController.handleCloseButton()
                },
                onMinimize: { [weak self] in
                    self?.quickPanelController.handleMinimizeButton()
                },
                onZoom: { [weak self] in
                    self?.quickPanelController.handleZoomButton()
                },
                onSignIn: { [weak self] in
                    guard let self else { return }
                    _ = self.quickWorkspaceController.session
                    self.activeQuickEngine?.openSignInPopup()
                },
                onSwitchToWebMode: { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.quickWorkspaceController.closeQuickWindow()
                        self.openArtifactInMainWebMode(conversationId: nil)
                    }
                },
                onBarHeightChanged: { [weak self] height in
                    self?.quickPanelController.updateIntrinsicBarHeight(height)
                }
            ) { [weak self] isExpanded in
                if let coordinator = self {
                    ChatSurfaceView(
                        store: coordinator.quickWorkspaceController.session,
                        isExpanded: isExpanded,
                        topContentInset: LiquidGlassMetrics.topBarHeight,
                        onOpenInWebMode: { [weak coordinator] convId in
                            guard let coordinator else { return }
                            Task { @MainActor in
                                await coordinator.quickWorkspaceController.closeQuickWindow()
                                coordinator.openArtifactInMainWebMode(conversationId: convId)
                            }
                        },
                        onSaveInlineImage: { [weak coordinator] attachment in
                            coordinator?.saveInlineImage(attachment)
                        },
                        topBar: { [weak coordinator] in
                            QuickMiniTopBarView(
                                onClose: { [weak coordinator] in coordinator?.quickPanelController.handleCloseButton() },
                                onMinimize: { [weak coordinator] in coordinator?.quickPanelController.handleMinimizeButton() },
                                onZoom: { [weak coordinator] in coordinator?.quickPanelController.handleZoomButton() },
                                onNewQuickChat: { [weak coordinator] in coordinator?.quickPanelController.handleNewQuickChatButton() }
                            )
                        },
                        emptyState: {
                            EmptyView()
                        },
                        composer: { [weak coordinator] in
                            if let coordinator {
                                AdaptiveComposerView(
                                    store: coordinator.quickWorkspaceController.session,
                                    quickModeTempBinding: coordinator.quickWorkspaceController.temporaryChatBinding,
                                    focusTrigger: coordinator.quickWorkspaceController.focusTrigger,
                                    onOpenFolderInWebMode: { [weak coordinator] in
                                        guard let coordinator else { return }
                                        Task { @MainActor in
                                            await coordinator.quickWorkspaceController.closeQuickWindow()
                                            coordinator.openArtifactInMainWebMode(conversationId: nil)
                                        }
                                    },
                                    onEscapeUnhandled: { [weak coordinator] in
                                        _ = coordinator?.quickWorkspaceController.handleEscapeKey()
                                    }
                                )
                            }
                        }
                    )
                }
            }
        }
    }
}
