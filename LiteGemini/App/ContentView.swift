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
    @ObservedObject private var settings = SettingsManager.shared

    /// Tracks whether the initial Classic Web page load has completed.
    @State private var hasFinishedInitialLoad: Bool = false

    /// Hover state for the monochrome reload button in Classic Web Mode's error screen.
    @State private var isHoveringReload: Bool = false

    private static let classicTitleBarHeight: CGFloat = 28

    var body: some View {
        ZStack(alignment: .top) {
            // Seamless backdrop matching the Gemini surface color.
            viewModel.pageBackgroundColor
                .ignoresSafeArea()

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
            .allowsHitTesting(!settings.isNativeUIActive)
            .accessibilityHidden(settings.isNativeUIActive)

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
                    }
                ) {
                    NativeChatSlotPlaceholder(
                        workspace: workspaceStore,
                        onSwitchToWebMode: {
                            handoffCoordinator.switchToWebMode()
                        }
                    )
                }
                .zIndex(1.8)
            } else {
                classicWebOverlays
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.downloadNotice?.id)
        .onChange(of: settings.isNativeUIActive) { _, isNowNative in
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
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if settings.isNativeUIActive {
                workspaceStore.handleAppDidResignActive()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if settings.isNativeUIActive {
                workspaceStore.handleAppDidBecomeActive()
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
        if let url = URL(string: GeminiBridgeSelectors.Endpoints.signInURLString) {
            handoffCoordinator.openAuthOrChallengeURL(url)
        } else {
            handoffCoordinator.switchToWebMode()
        }
    }

    private func handleAddAccountAction() {
        if let url = URL(string: GeminiBridgeSelectors.Endpoints.addAccountURLString) {
            handoffCoordinator.openAuthOrChallengeURL(url)
        } else {
            handoffCoordinator.switchToWebMode()
        }
    }

    private func handleVerifyChallengeAction(_ banner: ChallengeBannerState) {
        let targetURL = banner.challengeURL ?? workspaceStore.urlForWebModeHandoff()
        handoffCoordinator.openAuthOrChallengeURL(targetURL)
    }
}

// MARK: - NativeChatSlotPlaceholder

/// Clean content-slot placeholder rendered inside `MainRootView` until Wave 3 mounts `ChatSurfaceView`.
private struct NativeChatSlotPlaceholder: View {

    @ObservedObject var workspace: MainWorkspaceStore
    @ObservedObject private var session: ChatSessionStore
    let onSwitchToWebMode: () -> Void

    @State private var isHoveringSwitch = false

    init(workspace: MainWorkspaceStore, onSwitchToWebMode: @escaping () -> Void) {
        self._workspace = ObservedObject(wrappedValue: workspace)
        self._session = ObservedObject(wrappedValue: workspace.session)
        self.onSwitchToWebMode = onSwitchToWebMode
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: LiquidGlassMetrics.topBarHeight)

            MonochromeSparkShape()
                .fill(
                    LinearGradient(
                        colors: [
                            session.isTemporaryChat ? LiquidGlassColors.tempActiveAccent : Color.primary.opacity(0.86),
                            session.isTemporaryChat ? LiquidGlassColors.tempActiveAccent.opacity(0.55) : Color.primary.opacity(0.42)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 24, height: 24)
                .glassOrb(size: 54, tint: session.isTemporaryChat ? LiquidGlassColors.tempActiveTint : nil, interactive: false)

            VStack(spacing: 6) {
                Text(session.isTemporaryChat ? LocalizedStringKey("Temporary Chat") : LocalizedStringKey("Native Liquid Glass"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.90))

                Text("Preview of the native Liquid Glass interface. Switch back to Classic Web Mode anytime from the View menu (⌘⇧M).")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Button(action: onSwitchToWebMode) {
                Text("Switch to Classic Web Mode")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(isHoveringSwitch ? 0.96 : 0.84))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .glassCapsule(interactive: true)
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.14)) {
                    isHoveringSwitch = hovering
                }
            }
            .padding(.top, 4)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
