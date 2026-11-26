import AppKit
import SwiftUI

// MARK: - ConversationTimelineView

/// Virtualized 120Hz conversation timeline backed by `ScrollView` + `LazyVStack` with smart
/// auto-scroll locking during live streaming and a floating `"Scroll to bottom"` glass pill.
struct ConversationTimelineView: View {

    @ObservedObject var store: ChatSessionStore
    var topContentInset: CGFloat = LiquidGlassMetrics.topBarHeight
    var bottomContentInset: CGFloat = 80
    var isQuickMode: Bool = false
    var onOpenArtifact: ((ArtifactCardInfo) -> Void)? = nil
    var onOpenInWebMode: ((String?) -> Void)? = nil
    var onSaveInlineImage: ((ImageAttachment) -> Void)? = nil
    var onQuoteSelection: ((String) -> Void)? = nil
    var onAskBtwSelection: ((String) -> Void)? = nil

    private static let scrollCoordinateSpace = "lgConversationTimelineScrollSpace"
    private static let bottomAnchorID = "lg-timeline-bottom-anchor"
    private static let maxReadingColumnWidth: CGFloat = 780

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var timelineGlassNamespace

    @State private var isAutoScrollLocked = true
    @State private var showsScrollToBottomPill = false
    @State private var viewportSize: CGSize = CGSize(width: 640, height: 500)
    @State private var scrollTracker = TimelineScrollTracker()
    @State private var selectionPillController = ResponseSelectionPillController()
    @State private var isHoveringScrollPill = false

    private var horizontalPadding: CGFloat {
        viewportSize.width < LiquidGlassMetrics.compactTopBarBreakpoint ? 14 : 22
    }

    private var effectiveColumnWidth: CGFloat {
        let available = max(240, viewportSize.width - horizontalPadding * 2)
        return min(available, Self.maxReadingColumnWidth)
    }

    private var activeStreamingTurnId: String? {
        store.streamingState.activeTurnId
    }

    private var bottomScrollTargetID: String {
        store.turns.last?.id ?? Self.bottomAnchorID
    }

    /// Lightweight scalar change key that advances on each coalesced streaming flush so
    /// auto-scroll tracks the growing trailing response without inspecting full strings.
    private var streamingScrollSignal: Int {
        switch store.streamingState {
        case .idle:
            return 0
        case .awaitingFirstDelta:
            return 1
        case .streaming(_, let thinking, _, let markdown, let images, let citations, let artifacts):
            var hasher = Hasher()
            hasher.combine(markdown.utf8.count)
            hasher.combine(thinking?.utf8.count ?? 0)
            hasher.combine(images.count)
            hasher.combine(citations.count)
            hasher.combine(artifacts.count)
            return hasher.finalize()
        }
    }

    private var usesNativeScrollSafeAreaBars: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return true
        }
        #endif
        return false
    }

    private var contentTopPadding: CGFloat {
        usesNativeScrollSafeAreaBars ? 12 : (topContentInset + 14)
    }

    private var contentBottomPadding: CGFloat {
        usesNativeScrollSafeAreaBars ? 16 : (bottomContentInset + 18)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ZStack(alignment: .bottom) {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.turns.enumerated()), id: \.element.id) { index, turn in
                            turnRow(for: turn, index: index)
                        }

                        if store.turns.isEmpty {
                            Color.clear
                                .frame(height: contentBottomPadding)
                                .id(Self.bottomAnchorID)
                        }
                    }
                    .frame(maxWidth: Self.maxReadingColumnWidth, alignment: .leading)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, contentTopPadding)
                    .frame(maxWidth: .infinity)
                    .background(
                        GeometryReader { contentGeometry in
                            let frame = contentGeometry.frame(in: .named(Self.scrollCoordinateSpace))
                            Color.clear.preference(
                                key: TimelineScrollMetricsPreferenceKey.self,
                                value: TimelineScrollMetrics(
                                    contentMinY: frame.minY,
                                    contentMaxY: frame.maxY
                                )
                            )
                        }
                    )
                }
                .liquidGlassFloatingScrollChrome(
                    topInset: topContentInset,
                    bottomInset: bottomContentInset
                )
                .coordinateSpace(name: Self.scrollCoordinateSpace)
                .background(
                    ZStack {
                        GeometryReader { viewportGeometry in
                            Color.clear.preference(
                                key: TimelineViewportSizePreferenceKey.self,
                                value: viewportGeometry.size
                            )
                        }

                        if !isQuickMode && (onQuoteSelection != nil || onAskBtwSelection != nil) {
                            ResponseSelectionMonitorBridge(
                                controller: selectionPillController,
                                onQuote: onQuoteSelection,
                                onAskBtw: onAskBtwSelection
                            )
                            .allowsHitTesting(false)
                        }
                    }
                )
                .onPreferenceChange(TimelineViewportSizePreferenceKey.self) { newSize in
                    guard let newSize else { return }
                    let widthChanged = abs(newSize.width - viewportSize.width) > 0.5
                    let heightChanged = abs(newSize.height - viewportSize.height) > 0.5
                    if widthChanged || heightChanged {
                        viewportSize = newSize
                        if isAutoScrollLocked && !store.turns.isEmpty {
                            scrollTracker.markProgrammaticScroll()
                            scrollProxy.scrollTo(bottomScrollTargetID, anchor: .bottom)
                        }
                    }
                }
                .onPreferenceChange(TimelineScrollMetricsPreferenceKey.self) { metrics in
                    guard let metrics else { return }
                    handleScrollMetricsChange(metrics)
                }

                LiquidGlassContainer(spacing: 8) {
                    if showsScrollToBottomPill && !store.turns.isEmpty {
                        scrollToBottomButton(proxy: scrollProxy)
                            .liquidGlassID("timeline-scroll-bottom-pill", in: timelineGlassNamespace)
                            .liquidGlassTransitionMaterialize()
                            .padding(.bottom, bottomContentInset + 12)
                    }
                }
                .zIndex(2)
            }
            .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: showsScrollToBottomPill)
            .onChange(of: store.conversationId) { _, _ in
                selectionPillController.dismiss()
                reengageAutoScrollAndJump(proxy: scrollProxy, animated: false)
            }
            .onChange(of: store.turns.count) { oldCount, newCount in
                if newCount > oldCount {
                    reengageAutoScrollAndJump(proxy: scrollProxy, animated: true)
                }
            }
            .onChange(of: streamingScrollSignal) { _, newValue in
                guard newValue != 0, isAutoScrollLocked else {
                    return
                }
                scrollTracker.markProgrammaticScroll()
                scrollProxy.scrollTo(bottomScrollTargetID, anchor: .bottom)
            }
            .onChange(of: bottomContentInset) { oldInset, newInset in
                if abs(newInset - oldInset) > 1, isAutoScrollLocked, !store.turns.isEmpty {
                    scrollTracker.markProgrammaticScroll()
                    scrollProxy.scrollTo(bottomScrollTargetID, anchor: .bottom)
                }
            }
            .onAppear {
                if !store.turns.isEmpty {
                    reengageAutoScrollAndJump(proxy: scrollProxy, animated: false)
                    DispatchQueue.main.async {
                        if isAutoScrollLocked, !store.turns.isEmpty {
                            scrollTracker.markProgrammaticScroll()
                            scrollProxy.scrollTo(bottomScrollTargetID, anchor: .bottom)
                        }
                    }
                }
            }
            .onDisappear {
                selectionPillController.detach()
            }
        }
    }

    // MARK: - Turn Row Builder

    private func turnRow(for turn: ChatTurn, index: Int) -> some View {
        let isLatest = (index == store.turns.count - 1)
        let isTurnStreaming = isLatest && (store.isStreaming || activeStreamingTurnId == turn.id)
        let allowsServerTurnActions = !isQuickMode && !store.isTemporaryChat && store.conversationId != nil

        let branchAction: (() -> Void)? = allowsServerTurnActions
            ? { Task { await store.branchFromTurn(turn) } }
            : nil
        let shareTurnAction: (() -> Void)? = allowsServerTurnActions
            ? { Task { await store.createPublicShareLink(for: turn) } }
            : nil
        let shareChatAction: (() -> Void)? = allowsServerTurnActions
            ? { Task { await store.createPublicShareLink(for: nil) } }
            : nil
        let openInWebAction: (() -> Void)? = onOpenInWebMode.map { handler in
            { handler(store.conversationId) }
        }

        return ChatTurnRowView(
            turn: turn,
            containerWidth: effectiveColumnWidth,
            isLatestTurn: isLatest,
            isStreaming: isTurnStreaming,
            canEdit: isLatest && store.canEditLastTurn,
            canRegenerate: isLatest && store.canRegenerateLastTurn,
            onEdit: { store.beginEditingLastTurn() },
            onRegenerate: { Task { await store.regenerateLastTurn() } },
            onRegenerateVariant: { variant, modelId in
                Task { await store.regenerateLatestTurn(variant: variant, modelId: modelId) }
            },
            isQuickMode: isQuickMode,
            isTemporaryChat: store.isTemporaryChat,
            availableModels: store.availableModels,
            selectedModelId: store.selectedModelId,
            isBranchingThisTurn: store.branchingTurnId == turn.id,
            isShareExportBusy: store.isCreatingShareLink || store.isExportingDocument,
            speechController: store.speechController,
            onSynthesizeSpeechChunk: { [weak store] chunkText, locale in
                await store?.synthesizeSpeechChunk(text: chunkText, locale: locale)
            },
            onBranchFromTurn: branchAction,
            onShareThisTurn: shareTurnAction,
            onShareEntireChat: shareChatAction,
            onExportTurnMarkdown: { store.exportMarkdown(turn: turn) },
            onExportTurnPDF: { Task { await store.exportPDF(turn: turn) } },
            onExportGoogleDocs: { Task { await store.exportToCloud(service: .docs, turn: turn) } },
            onDraftGmail: { Task { await store.exportToCloud(service: .gmail, turn: turn) } },
            onOpenGoogleColab: { Task { await store.exportToCloud(service: .colab, turn: turn) } },
            onOpenArtifact: { artifact in
                if let onOpenArtifact {
                    onOpenArtifact(artifact)
                } else {
                    store.selectedArtifact = artifact
                }
            },
            onConfirmResearchPlan: { artifact in
                Task { await store.confirmDeepResearchPlan(for: artifact) }
            },
            onEditResearchPlan: { store.beginEditingLastTurn() },
            onOpenInWebMode: openInWebAction,
            onSaveInlineImage: onSaveInlineImage
        )
        .padding(.bottom, isLatest ? contentBottomPadding : 24)
        .id(turn.id)
    }

    // MARK: - Floating Scroll-to-Bottom Pill

    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button {
            reengageAutoScrollAndJump(proxy: proxy, animated: true)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("Scroll to bottom")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Color.primary.opacity(isHoveringScrollPill ? 0.98 : 0.86))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassCapsule(variant: .clear, interactive: true)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringScrollPill = hovering
            }
        }
        .accessibilityLabel(Text("Scroll to bottom"))
    }

    // MARK: - Smart Auto-Scroll Lock Logic

    private func reengageAutoScrollAndJump(proxy: ScrollViewProxy, animated: Bool) {
        isAutoScrollLocked = true
        showsScrollToBottomPill = false
        scrollTracker.markProgrammaticScroll()

        if animated {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(bottomScrollTargetID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomScrollTargetID, anchor: .bottom)
        }
    }

    private func handleScrollMetricsChange(_ metrics: TimelineScrollMetrics) {
        let viewportHeight = viewportSize.height
        guard viewportHeight > 0 else {
            return
        }

        let scrollOffsetY = -metrics.contentMinY
        let effectiveViewportBottom = usesNativeScrollSafeAreaBars
            ? max(0, viewportHeight - bottomContentInset)
            : viewportHeight
        let distanceFromBottom = max(0, metrics.contentMaxY - effectiveViewportBottom)
        let previousOffsetY = scrollTracker.lastScrollOffsetY
        scrollTracker.lastScrollOffsetY = scrollOffsetY

        // Ignore transient geometry deltas while our own programmatic scrollTo settles.
        if scrollTracker.isWithinProgrammaticGraceWindow {
            if distanceFromBottom <= 32 {
                if !isAutoScrollLocked {
                    isAutoScrollLocked = true
                }
                if showsScrollToBottomPill {
                    showsScrollToBottomPill = false
                }
            }
            return
        }

        if let previousOffsetY, abs(scrollOffsetY - previousOffsetY) > 2 {
            selectionPillController.handleScrollDidOccur()
        }

        let userScrolledUpward = (previousOffsetY != nil) && (scrollOffsetY < (previousOffsetY ?? scrollOffsetY) - 6)

        if userScrolledUpward && distanceFromBottom > 36 {
            if isAutoScrollLocked {
                isAutoScrollLocked = false
            }
        } else if distanceFromBottom <= 28 {
            if !isAutoScrollLocked {
                isAutoScrollLocked = true
            }
        }

        let shouldShowPill = !isAutoScrollLocked && distanceFromBottom > 64
        if shouldShowPill != showsScrollToBottomPill {
            showsScrollToBottomPill = shouldShowPill
        }
    }
}

// MARK: - TimelineScrollTracker

/// Non-observable `@MainActor` reference tracker holding continuous scroll metrics so scrolling
/// does not trigger redundant SwiftUI view-body invalidations at 120Hz.
@MainActor
private final class TimelineScrollTracker {

    var lastScrollOffsetY: CGFloat?
    private var programmaticScrollGraceUntil: ContinuousClock.Instant?

    var isWithinProgrammaticGraceWindow: Bool {
        guard let deadline = programmaticScrollGraceUntil else {
            return false
        }
        return ContinuousClock.now < deadline
    }

    func markProgrammaticScroll() {
        programmaticScrollGraceUntil = ContinuousClock.now + .milliseconds(120)
    }
}

// MARK: - Preference Keys

private nonisolated struct TimelineScrollMetrics: Equatable, Sendable {
    let contentMinY: CGFloat
    let contentMaxY: CGFloat
}

private nonisolated struct TimelineScrollMetricsPreferenceKey: PreferenceKey {
    static let defaultValue: TimelineScrollMetrics? = nil

    static func reduce(value: inout TimelineScrollMetrics?, nextValue: () -> TimelineScrollMetrics?) {
        if let next = nextValue() {
            value = next
        }
    }
}

private nonisolated struct TimelineViewportSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize? = nil

    static func reduce(value: inout CGSize?, nextValue: () -> CGSize?) {
        if let next = nextValue() {
            value = next
        }
    }
}

// MARK: - ResponseSelectionMonitorBridge

/// Lightweight AppKit host view attaching `ResponseSelectionPillController` to the Main Window's
/// conversation timeline viewport without stealing hit testing or altering SwiftUI identity.
private struct ResponseSelectionMonitorBridge: NSViewRepresentable {

    let controller: ResponseSelectionPillController
    let onQuote: ((String) -> Void)?
    let onAskBtw: ((String) -> Void)?

    func makeNSView(context: Context) -> MonitorAnchorNSView {
        let view = MonitorAnchorNSView()
        view.controller = controller
        view.onQuote = onQuote
        view.onAskBtw = onAskBtw
        return view
    }

    func updateNSView(_ nsView: MonitorAnchorNSView, context: Context) {
        nsView.controller = controller
        nsView.onQuote = onQuote
        nsView.onAskBtw = onAskBtw
        nsView.syncAttachment()
    }

    static func dismantleNSView(_ nsView: MonitorAnchorNSView, coordinator: ()) {
        nsView.detach()
    }

    final class MonitorAnchorNSView: NSView {
        weak var controller: ResponseSelectionPillController?
        var onQuote: ((String) -> Void)?
        var onAskBtw: ((String) -> Void)?
        private var isAttached: Bool = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncAttachment()
        }

        func syncAttachment() {
            controller?.onQuote = onQuote
            controller?.onAskBtw = onAskBtw

            if window != nil {
                if !isAttached {
                    controller?.attach(to: self, onQuote: onQuote, onAskBtw: onAskBtw)
                    isAttached = true
                }
            } else if isAttached {
                controller?.detach()
                isAttached = false
            }
        }

        func detach() {
            if isAttached {
                controller?.detach()
                isAttached = false
            }
        }
    }
}
