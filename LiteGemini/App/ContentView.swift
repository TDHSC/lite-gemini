//
//  ContentView.swift
//  LiteGemini
//
//  Created by Jray on 2026/2/10.
//

import AppKit
import SwiftUI

// MARK: - ContentView

struct ContentView: View {

    @ObservedObject var viewModel: ClassicWebViewModel
    @ObservedObject var workspaceStore: MainWorkspaceStore
    @ObservedObject var handoffCoordinator: InterfaceModeHandoffCoordinator
    var coordinator: AppCoordinator? = nil
    @ObservedObject private var settings = SettingsManager.shared

    /// Focus trigger counter incremented when Main Window activates or starts a new chat.
    @State private var localComposerFocusTrigger: Int = 0

    /// Tracks whether the initial Classic Web page load has completed.
    @State private var hasFinishedInitialLoad: Bool = false

    /// Hover state for the monochrome reload button in Classic Web Mode's error screen.
    @State private var isHoveringReload: Bool = false

    private static let classicTitleBarHeight: CGFloat = 28

    var body: some View {
        ZStack(alignment: .top) {
            // Paint the opaque Gemini surface backdrop only in Classic Web Mode so Native
            // Liquid Glass mode stays genuinely translucent over desktop vibrancy.
            if !settings.isNativeUIActive {
                viewModel.pageBackgroundColor
                    .ignoresSafeArea()
            }

            // Keep the underlying WebView mounted across Native ↔ Web mode transitions so
            // sessions and navigation state stay intact without tearing down WebKit.
            VStack(spacing: 0) {
                WindowDragArea()
                    .frame(height: Self.classicTitleBarHeight)
                    .frame(maxWidth: .infinity)
                    .background(viewModel.pageBackgroundColor)

                GeminiWebView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(.container, edges: .top)
            // Small floor that keeps the traffic lights and drag band usable;
            // about phone width, so both Native and Classic narrow layouts fit cleanly.
            .frame(minWidth: 360, minHeight: 400)
            .opacity(settings.isNativeUIActive ? 0 : 1)
            .allowsHitTesting(!settings.isNativeUIActive)
            .accessibilityHidden(settings.isNativeUIActive)

            if settings.enableNativeUI, let coordinator {
                HiddenSessionWebViewHost(webView: coordinator.mainSessionEngine.webView)
                    .frame(width: 360, height: 360)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                CoordinatorAuxBridgeHost(coordinator: coordinator) {
                    localComposerFocusTrigger &+= 1
                }
            }

            if settings.isNativeUIActive {
                MainRootView(
                    workspace: workspaceStore,
                    downloadNotice: viewModel.downloadNotice,
                    onDismissDownloadNotice: {
                        viewModel.downloadNotice = nil
                    },
                    onSignIn: handleSignInAction,
                    onAddAccount: handleAddAccountAction,
                    onVerifyChallenge: handleVerifyChallengeAction,
                    onSwitchToWebMode: {
                        handoffCoordinator.switchToWebMode()
                    },
                    onFocusMainComposer: {
                        localComposerFocusTrigger &+= 1
                    }
                ) {
                    ChatSurfaceView(
                        store: workspaceStore.session,
                        isExpanded: true,
                        topContentInset: LiquidGlassMetrics.topBarHeight,
                        onOpenInWebMode: { overrideConvId in
                            handoffCoordinator.switchToWebMode(overrideConversationId: overrideConvId)
                        },
                        onSaveInlineImage: { attachment in
                            coordinator?.saveInlineImage(attachment)
                        },
                        onQuoteSelection: { selectedText in
                            workspaceStore.stageQuotedText(selectedText)
                            localComposerFocusTrigger &+= 1
                        },
                        onAskBtwSelection: { selectedText in
                            workspaceStore.openBtwPanel(withQuotedText: selectedText)
                        },
                        topBar: {
                            EmptyView()
                        },
                        emptyState: {
                            NativeEmptyConversationView(
                                isTemporaryChat: workspaceStore.session.isTemporaryChat
                            )
                        },
                        composer: {
                            AdaptiveComposerView(
                                store: workspaceStore.session,
                                quickModeTempBinding: nil,
                                focusTrigger: localComposerFocusTrigger,
                                onOpenFolderInWebMode: {
                                    handoffCoordinator.switchToWebMode()
                                },
                                onEscapeUnhandled: {
                                    if workspaceStore.btwStore.isPresented {
                                        workspaceStore.btwStore.close()
                                    }
                                }
                            )
                        }
                    )
                }
                .zIndex(1.8)
            } else {
                classicWebOverlays
            }
        }
        .background(WindowSurfaceSyncView(
            isNativeUIActive: settings.isNativeUIActive,
            classicBackgroundColor: viewModel.syncedWindowNSColor
        ))
        .modifier(WindowContainerBackgroundModifier(
            isNativeUIActive: settings.isNativeUIActive,
            classicBackgroundColor: viewModel.pageBackgroundColor
        ))
        .animation(.easeInOut(duration: 0.25), value: viewModel.downloadNotice?.id)
        .onChange(of: settings.enableNativeUI) { _, _ in
            syncMainWindowSurfaceAppearance()
        }
        .onChange(of: settings.isNativeUIActive) { _, isNowNative in
            syncMainWindowSurfaceAppearance()
            handoffCoordinator.reconcileExternalNativeUIState(isNowNative)
        }
        .onChange(of: viewModel.isPageReady) { _, newValue in
            if newValue && !hasFinishedInitialLoad && viewModel.errorMessage == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    hasFinishedInitialLoad = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChatRequested)) { _ in
            handoffCoordinator.handleNewChatNotificationInNativeMode()
            if settings.isNativeUIActive {
                localComposerFocusTrigger &+= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if settings.isNativeUIActive {
                workspaceStore.handleAppDidResignActive()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if settings.isNativeUIActive {
                workspaceStore.handleAppDidBecomeActive()
                localComposerFocusTrigger &+= 1
            }
        }
    }

    // MARK: - Classic Web Overlays

    @ViewBuilder
    private var classicWebOverlays: some View {
        // Minimalist monochrome splash screen for initial load (no error).
        if !hasFinishedInitialLoad && viewModel.errorMessage == nil {
            SplashView(
                isLoading: !viewModel.isPageReady,
                backgroundColor: viewModel.pageBackgroundColor
            )
            .ignoresSafeArea()
            .zIndex(1)
        }

        // Ultra-subtle monochrome top hairline indicator for subsequent navigations.
        if hasFinishedInitialLoad && viewModel.isLoading && viewModel.errorMessage == nil {
            MonochromeTopLoadingBar()
                .padding(.top, Self.classicTitleBarHeight)
                .ignoresSafeArea(.container, edges: .top)
                .transition(.opacity)
        }

        // Minimalist monochrome error state.
        if let errorMessage = viewModel.errorMessage {
            ZStack {
                viewModel.pageBackgroundColor
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(Color.primary.opacity(0.05))
                            .frame(width: 56, height: 56)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )

                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(Color.primary.opacity(0.65))
                    }

                    Text(errorMessage)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)

                    Button {
                        viewModel.retry()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                            Text("Reload")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(isHoveringReload ? 0.12 : 0.07))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.primary.opacity(isHoveringReload ? 0.24 : 0.14), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHoveringReload = hovering
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(32)
            }
            .zIndex(1.5)
        }

        if let notice = viewModel.downloadNotice {
            DownloadToastView(
                notice: notice,
                onDismiss: {
                    viewModel.downloadNotice = nil
                }
            )
            .padding(.top, Self.classicTitleBarHeight + 8)
            .padding(.horizontal, 16)
            .ignoresSafeArea(.container, edges: .top)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(2)
        }
    }

    // MARK: - Auth & Challenge Handlers

    private func handleSignInAction() {
        if let coordinator {
            coordinator.handleSignInFromMain()
        } else if let url = URL(string: GeminiBridgeSelectors.Endpoints.signInURLString) {
            handoffCoordinator.openAuthOrChallengeURL(url)
        } else {
            handoffCoordinator.switchToWebMode()
        }
    }

    private func handleAddAccountAction() {
        if let coordinator {
            coordinator.handleAddAccountFromMain()
        } else if let url = URL(string: GeminiBridgeSelectors.Endpoints.addAccountURLString) {
            handoffCoordinator.openAuthOrChallengeURL(url)
        } else {
            handoffCoordinator.switchToWebMode()
        }
    }

    private func handleVerifyChallengeAction(_ banner: ChallengeBannerState) {
        if let coordinator {
            coordinator.handleVerifyChallengeFromMain(banner)
        } else {
            let targetURL = banner.challengeURL ?? workspaceStore.urlForWebModeHandoff()
            handoffCoordinator.openAuthOrChallengeURL(targetURL)
        }
    }

    private func syncMainWindowSurfaceAppearance() {
        let isNative = settings.isNativeUIActive
        let classicColor = viewModel.syncedWindowNSColor
        for window in NSApp.windows where window.delegate is AppDelegate {
            AppDelegate.applyWindowSurfaceAppearance(
                for: window,
                isNativeUIActive: isNative,
                classicBackgroundColor: classicColor
            )
        }
    }
}

// MARK: - CoordinatorAuxBridgeHost

/// Observes `AppCoordinator` for lazy ephemeral `Btw` engine hosting and programmatic composer
/// focus triggers without re-rendering `ContentView` or perturbing `MainRootView`'s view tree.
private struct CoordinatorAuxBridgeHost: View {

    @ObservedObject var coordinator: AppCoordinator
    let onComposerFocusRequested: () -> Void

    var body: some View {
        ZStack {
            if let btwEngine = coordinator.activeBtwEngine {
                HiddenSessionWebViewHost(webView: btwEngine.webView)
                    .frame(width: 320, height: 240)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: coordinator.mainComposerFocusTrigger) { _, _ in
            onComposerFocusRequested()
        }
    }
}

// MARK: - WindowSurfaceSyncView & WindowContainerBackgroundModifier

/// Tracks the hosting `NSWindow` and synchronizes its translucency immediately on attach and
/// whenever Native Liquid Glass ↔ Classic Web Mode toggles live.
private struct WindowSurfaceSyncView: NSViewRepresentable {

    let isNativeUIActive: Bool
    let classicBackgroundColor: NSColor

    func makeNSView(context: Context) -> ObserverNSView {
        let view = ObserverNSView()
        view.isNativeUIActive = isNativeUIActive
        view.classicBackgroundColor = classicBackgroundColor
        return view
    }

    func updateNSView(_ nsView: ObserverNSView, context: Context) {
        nsView.isNativeUIActive = isNativeUIActive
        nsView.classicBackgroundColor = classicBackgroundColor
        nsView.syncWindowAppearance()
    }

    final class ObserverNSView: NSView {
        var isNativeUIActive: Bool = false
        var classicBackgroundColor: NSColor = AppDelegate.geminiSurfaceNSColor

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncWindowAppearance()
        }

        func syncWindowAppearance() {
            guard let window else {
                return
            }
            AppDelegate.applyWindowSurfaceAppearance(
                for: window,
                isNativeUIActive: isNativeUIActive,
                classicBackgroundColor: classicBackgroundColor
            )
        }
    }
}

/// Applies a structurally invariant `.containerBackground(..., for: .window)` on macOS 15+
/// so toggling between Native Liquid Glass and Classic Web Mode never tears down hosted views.
private struct WindowContainerBackgroundModifier: ViewModifier {

    let isNativeUIActive: Bool
    let classicBackgroundColor: Color

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(
                isNativeUIActive ? AnyShapeStyle(.clear) : AnyShapeStyle(classicBackgroundColor),
                for: .window
            )
        } else {
            content
        }
    }
}

// MARK: - MonochromeTopLoadingBar

/// Subtle 1.5pt monochrome indeterminate bar for subsequent Classic Web Mode page loads.
private struct MonochromeTopLoadingBar: View {
    @State private var phase: CGFloat = -0.35

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.05))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.0),
                                Color.primary.opacity(0.32),
                                Color.primary.opacity(0.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(geo.size.width * 0.35, 120), height: 1.5)
                    .offset(x: phase * geo.size.width)
            }
        }
        .frame(height: 1.5)
        .clipped()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                phase = 0.65
            }
        }
    }
}

#Preview {
    let webVM = ClassicWebViewModel()
    let workspace = MainWorkspaceStore(transport: NoopChatTransport())
    let coordinator = InterfaceModeHandoffCoordinator(
        workspace: workspace,
        currentWebURL: { nil },
        loadWebURL: { _ in },
        reloadWebView: {}
    )
    ContentView(
        viewModel: webVM,
        workspaceStore: workspace,
        handoffCoordinator: coordinator
    )
}
