import SwiftUI

// MARK: - MainRootView

/// Top-level native Liquid Glass window shell composing `MainTopBarView`, indeterminate
/// sync indicator, `ChallengeBannerView`, `DownloadToastView`, signed-out `NativeWelcomeView`,
/// and a flexible content slot ready for `ChatSurfaceView`.
struct MainRootView<Content: View>: View {

    @ObservedObject var workspace: MainWorkspaceStore
    @ObservedObject private var session: ChatSessionStore

    let downloadNotice: DownloadNotice?
    let onDismissDownloadNotice: () -> Void
    let onSignIn: () -> Void
    let onAddAccount: () -> Void
    let onVerifyChallenge: (ChallengeBannerState) -> Void
    let onSwitchToWebMode: () -> Void
    @ViewBuilder let contentSlot: () -> Content

    init(
        workspace: MainWorkspaceStore,
        downloadNotice: DownloadNotice? = nil,
        onDismissDownloadNotice: @escaping () -> Void = {},
        onSignIn: @escaping () -> Void,
        onAddAccount: @escaping () -> Void,
        onVerifyChallenge: @escaping (ChallengeBannerState) -> Void,
        onSwitchToWebMode: @escaping () -> Void,
        @ViewBuilder contentSlot: @escaping () -> Content
    ) {
        self._workspace = ObservedObject(wrappedValue: workspace)
        self._session = ObservedObject(wrappedValue: workspace.session)
        self.downloadNotice = downloadNotice
        self.onDismissDownloadNotice = onDismissDownloadNotice
        self.onSignIn = onSignIn
        self.onAddAccount = onAddAccount
        self.onVerifyChallenge = onVerifyChallenge
        self.onSwitchToWebMode = onSwitchToWebMode
        self.contentSlot = contentSlot
    }

    var body: some View {
        ZStack(alignment: .top) {
            LiquidGlassColors.canvasBackground
                .ignoresSafeArea()

            if workspace.authState == .signedOut {
                signedOutShell
            } else {
                signedInShell
            }

            if let notice = downloadNotice {
                DownloadToastView(
                    notice: notice,
                    onDismiss: onDismissDownloadNotice
                )
                .padding(.top, LiquidGlassMetrics.topBarHeight + 8)
                .padding(.horizontal, 16)
                .ignoresSafeArea(.container, edges: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(3)
            }
        }
        .frame(minWidth: 360, minHeight: 400)
        .animation(.easeInOut(duration: 0.22), value: session.isSyncing)
        .animation(.easeInOut(duration: 0.22), value: session.challengeBanner)
        .animation(.easeInOut(duration: 0.24), value: downloadNotice?.id)
    }

    // MARK: - Shell States

    private var signedOutShell: some View {
        ZStack(alignment: .top) {
            VStack {
                Spacer(minLength: LiquidGlassMetrics.topBarHeight)

                NativeWelcomeView(
                    onSignIn: onSignIn,
                    onSwitchToWebMode: onSwitchToWebMode
                )

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            WindowDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: LiquidGlassMetrics.topBarHeight)
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    private var signedInShell: some View {
        ZStack(alignment: .top) {
            contentSlot()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                MainTopBarView(
                    workspace: workspace,
                    onAddAccount: onAddAccount
                )

                if session.isSyncing {
                    LiquidGlassTopSyncBar()
                        .transition(.opacity)
                }

                if let banner = session.challengeBanner {
                    ChallengeBannerView(
                        banner: banner,
                        onVerifyInPopup: { onVerifyChallenge(banner) },
                        onSwitchToWebMode: onSwitchToWebMode,
                        onDismiss: { session.challengeBanner = nil }
                    )
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .zIndex(2)
        }
    }
}

// MARK: - LiquidGlassTopSyncBar

/// Indeterminate `1.5pt` top hairline indicator rendered while `workspace.session.isSyncing` is active.
private struct LiquidGlassTopSyncBar: View {

    @State private var phase: CGFloat = -0.35

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.05))

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.0),
                                Color.primary.opacity(0.36),
                                Color.primary.opacity(0.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(geometry.size.width * 0.35, 110), height: 1.5)
                    .offset(x: phase * geometry.size.width)
            }
        }
        .frame(height: 1.5)
        .clipped()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                phase = 0.65
            }
        }
    }
}
