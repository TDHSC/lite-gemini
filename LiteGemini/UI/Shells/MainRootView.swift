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
    let onFocusMainComposer: () -> Void
    @ViewBuilder let contentSlot: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shellWidth: CGFloat = 960
    @State private var splitPaneRatio: CGFloat = 0.48
    @State private var dragStartRatio: CGFloat?
    @Namespace private var rootGlassNamespace

    init(
        workspace: MainWorkspaceStore,
        downloadNotice: DownloadNotice? = nil,
        onDismissDownloadNotice: @escaping () -> Void = {},
        onSignIn: @escaping () -> Void,
        onAddAccount: @escaping () -> Void,
        onVerifyChallenge: @escaping (ChallengeBannerState) -> Void,
        onSwitchToWebMode: @escaping () -> Void,
        onFocusMainComposer: @escaping () -> Void = {},
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
        self.onFocusMainComposer = onFocusMainComposer
        self.contentSlot = contentSlot
    }

    var body: some View {
        ZStack(alignment: .top) {
            WindowBackdropView()
                .ignoresSafeArea()

            if workspace.authState == .signedOut {
                signedOutShell
            } else {
                signedInShell
            }

            LiquidGlassContainer(spacing: 8) {
                if let notice = downloadNotice {
                    DownloadToastView(
                        notice: notice,
                        onDismiss: onDismissDownloadNotice
                    )
                    .liquidGlassID("main-download-toast", in: rootGlassNamespace)
                    .liquidGlassTransitionMaterialize()
                    .padding(.top, LiquidGlassMetrics.topBarHeight + 8)
                    .padding(.horizontal, 16)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .zIndex(3)
        }
        .frame(minWidth: 360, minHeight: 400)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: MainShellWidthPreferenceKey.self, value: geometry.size.width)
            }
        )
        .onPreferenceChange(MainShellWidthPreferenceKey.self) { width in
            if let width, abs(width - shellWidth) > 0.5 {
                shellWidth = width
            }
        }
        .clearWindowContainerBackground()
        .animation(.easeOut(duration: 0.20), value: session.isSyncing)
        .animation(LiquidGlassMotion.morph(reduceMotion: reduceMotion), value: session.selectedArtifact?.id)
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: session.challengeBanner)
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: session.activeShareLinkResult)
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: session.transientStatusMessage)
        .animation(LiquidGlassMotion.morph(reduceMotion: reduceMotion), value: workspace.btwStore.isPresented)
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: workspace.isSearchModalPresented)
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: downloadNotice?.id)
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

    private var usesSideBySideSplit: Bool {
        shellWidth >= 740
    }

    private var resolvedSplitPaneWidth: CGFloat {
        let clampedRatio = min(max(splitPaneRatio, 0.34), 0.64)
        return min(max(340, round(shellWidth * clampedRatio)), max(340, shellWidth - 360))
    }

    private var signedInShell: some View {
        // Constant SwiftUI structural path: `HStack -> ZStack -> contentSlot()` never changes branch identity
        // when opening/closing `CanvasSplitPaneView` or resizing across the 740pt breakpoint.
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                contentSlot()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)

                VStack(spacing: 0) {
                    MainTopBarView(
                        workspace: workspace,
                        onAddAccount: onAddAccount
                    )

                    if session.isSyncing {
                        LiquidGlassTopSyncBar()
                            .transition(.opacity)
                    }

                    LiquidGlassContainer(spacing: 8) {
                        if let banner = session.challengeBanner {
                            ChallengeBannerView(
                                banner: banner,
                                onVerifyInPopup: { onVerifyChallenge(banner) },
                                onSwitchToWebMode: onSwitchToWebMode,
                                onDismiss: { session.challengeBanner = nil }
                            )
                            .liquidGlassID("main-challenge-banner", in: rootGlassNamespace)
                            .liquidGlassTransitionMaterialize()
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                        }
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
                .zIndex(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                LiquidGlassContainer(spacing: 8) {
                    VStack(spacing: 6) {
                        if let shareResult = session.activeShareLinkResult {
                            ShareLinkBannerPillView(
                                url: shareResult.url,
                                onDismiss: {
                                    session.dismissShareLinkBanner()
                                }
                            )
                            .liquidGlassID("main-share-link-banner", in: rootGlassNamespace)
                            .liquidGlassTransitionMaterialize()
                        }

                        if let statusMessage = session.transientStatusMessage, !statusMessage.isEmpty {
                            TransientStatusPillView(message: statusMessage) {
                                session.dismissTransientStatus()
                            }
                            .liquidGlassID("main-transient-status", in: rootGlassNamespace)
                            .liquidGlassTransitionMaterialize()
                        }
                    }
                    .padding(.top, LiquidGlassMetrics.topBarHeight + 8)
                    .padding(.horizontal, 16)
                }
                .ignoresSafeArea(.container, edges: .top)
            }
            .overlay(alignment: .bottomTrailing) {
                if workspace.btwStore.isPresented {
                    BtwPopoverPanelView(
                        store: workspace.btwStore,
                        mainTurns: session.turns,
                        onSendNotesToMainChat: { notes in
                            workspace.appendBtwNotesToComposer(notes)
                            onFocusMainComposer()
                        },
                        onClose: {
                            workspace.btwStore.close()
                            onFocusMainComposer()
                        }
                    )
                    .padding(.trailing, 18)
                    .padding(
                        .bottom,
                        (!session.draft.quotes.isEmpty || !session.draft.stagedAttachments.isEmpty || session.draft.activeToolMode != nil)
                            ? 142
                            : 86
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            if usesSideBySideSplit, let artifact = session.selectedArtifact {
                splitResizeHandle

                CanvasSplitPaneView(
                    artifact: artifact,
                    isCompactOverlay: false,
                    onOpenInWebMode: onSwitchToWebMode,
                    onClose: {
                        session.selectedArtifact = nil
                    }
                )
                .frame(width: resolvedSplitPaneWidth)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if !usesSideBySideSplit, let artifact = session.selectedArtifact {
                CanvasSplitPaneView(
                    artifact: artifact,
                    isCompactOverlay: true,
                    onOpenInWebMode: onSwitchToWebMode,
                    onClose: {
                        session.selectedArtifact = nil
                    }
                )
                .padding(.top, LiquidGlassMetrics.topBarHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
                .transition(.opacity)
            }
        }
        .overlay {
            if workspace.isSearchModalPresented {
                ConversationSearchModalView(
                    query: $workspace.searchQuery,
                    results: workspace.searchResults,
                    isSearchingCloud: workspace.isSearchingCloud,
                    activeConversationId: workspace.activeConversationId,
                    onSelect: { item in
                        Task {
                            await workspace.selectSearchResult(item)
                            onFocusMainComposer()
                        }
                    },
                    onDismiss: {
                        workspace.dismissSearchModal()
                        onFocusMainComposer()
                    }
                )
                .transition(.opacity)
            }
        }
    }

    private var splitResizeHandle: some View {
        ZStack {
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())

            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.16))
                .frame(width: 3, height: 36)
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let base = dragStartRatio ?? splitPaneRatio
                    if dragStartRatio == nil {
                        dragStartRatio = splitPaneRatio
                    }
                    guard shellWidth > 0 else { return }
                    let deltaRatio = -value.translation.width / shellWidth
                    splitPaneRatio = min(max(base + deltaRatio, 0.34), 0.64)
                }
                .onEnded { _ in
                    dragStartRatio = nil
                }
        )
        .accessibilityHidden(true)
    }
}

private nonisolated struct MainShellWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() {
            value = next
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

// MARK: - TransientStatusPillView

/// Subtle floating top Liquid Glass confirmation pill (e.g. `"Branched into a new chat"`).
private struct TransientStatusPillView: View {

    let message: String
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.sendButtonBlue)
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.90))
                .lineLimit(1)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .environment(\.colorScheme, colorScheme)
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .glassCapsule(variant: .clear, tint: LiquidGlassColors.clearCardTint)
    }
}
