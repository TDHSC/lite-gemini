import SwiftUI

// MARK: - ChatSurfaceView

/// Shared native conversation surface reused identically by both Main Window (`isExpanded = true`)
/// and Quick Mode (`isExpanded = (phase == .expanded)`).
///
/// Structural identity invariant (§2.3.2 #3): `composer()` stays mounted at a constant SwiftUI
/// structural view path inside the outer `ZStack` regardless of `isExpanded`. Flipping
/// `isExpanded` from `false` to `true` (Quick Mode `.barOnly` → `.expanded`) only mounts the
/// upper `topBar` + `ConversationTimelineView` branch, ensuring AppKit's `NSTextView` inside the
/// composer is never destroyed or unfocused during upward expansion.
struct ChatSurfaceView<TopBar: View, EmptyState: View, Composer: View>: View {

    @ObservedObject var store: ChatSessionStore
    var isExpanded: Bool
    var topContentInset: CGFloat
    var isQuickMode: Bool
    var onOpenArtifact: ((ArtifactCardInfo) -> Void)?
    var onOpenInWebMode: ((String?) -> Void)?
    var onSaveInlineImage: ((ImageAttachment) -> Void)?
    var onQuoteSelection: ((String) -> Void)?
    var onAskBtwSelection: ((String) -> Void)?
    @ViewBuilder var topBar: () -> TopBar
    @ViewBuilder var emptyState: () -> EmptyState
    @ViewBuilder var composer: () -> Composer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measuredComposerHeight: CGFloat = 72
    @Namespace private var surfaceGlassNamespace

    init(
        store: ChatSessionStore,
        isExpanded: Bool = true,
        topContentInset: CGFloat = LiquidGlassMetrics.topBarHeight,
        isQuickMode: Bool = false,
        onOpenArtifact: ((ArtifactCardInfo) -> Void)? = nil,
        onOpenInWebMode: ((String?) -> Void)? = nil,
        onSaveInlineImage: ((ImageAttachment) -> Void)? = nil,
        onQuoteSelection: ((String) -> Void)? = nil,
        onAskBtwSelection: ((String) -> Void)? = nil,
        @ViewBuilder topBar: @escaping () -> TopBar,
        @ViewBuilder emptyState: @escaping () -> EmptyState,
        @ViewBuilder composer: @escaping () -> Composer
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self.isExpanded = isExpanded
        self.topContentInset = topContentInset
        self.isQuickMode = isQuickMode
        self.onOpenArtifact = onOpenArtifact
        self.onOpenInWebMode = onOpenInWebMode
        self.onSaveInlineImage = onSaveInlineImage
        self.onQuoteSelection = onQuoteSelection
        self.onAskBtwSelection = onAskBtwSelection
        self.topBar = topBar
        self.emptyState = emptyState
        self.composer = composer
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isExpanded {
                expandedSurface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }

            composerSlot
                .zIndex(2)
        }
        .frame(maxWidth: .infinity, maxHeight: isExpanded ? .infinity : nil, alignment: .bottom)
        .onPreferenceChange(ComposerHeightPreferenceKey.self) { height in
            if let height, height > 0 && abs(height - measuredComposerHeight) > 0.5 {
                measuredComposerHeight = height
            }
        }
    }

    // MARK: - Expanded Surface

    private var expandedSurface: some View {
        ZStack(alignment: .top) {
            if store.turns.isEmpty {
                VStack(spacing: 0) {
                    Spacer(minLength: topContentInset + 12)
                    emptyState()
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: measuredComposerHeight + 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ConversationTimelineView(
                    store: store,
                    topContentInset: topContentInset,
                    bottomContentInset: measuredComposerHeight,
                    isQuickMode: isQuickMode,
                    onOpenArtifact: onOpenArtifact,
                    onOpenInWebMode: onOpenInWebMode,
                    onSaveInlineImage: onSaveInlineImage,
                    onQuoteSelection: onQuoteSelection,
                    onAskBtwSelection: onAskBtwSelection
                )
            }

            topBar()
                .zIndex(2)
        }
        .overlay(alignment: .bottom) {
            LiquidGlassContainer(spacing: 8) {
                if let errorMessage = store.lastErrorMessage,
                   !errorMessage.isEmpty,
                   store.challengeBanner == nil {
                    InlineSurfaceErrorBanner(message: errorMessage) {
                        store.lastErrorMessage = nil
                    }
                    .liquidGlassID("inline-error-banner", in: surfaceGlassNamespace)
                    .liquidGlassTransitionMaterialize()
                    .padding(.horizontal, 16)
                    .padding(.bottom, measuredComposerHeight + 10)
                }
            }
        }
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: store.lastErrorMessage)
    }

    // MARK: - Constant-Identity Composer Slot

    private var composerSlot: some View {
        composer()
            .frame(maxWidth: 640)
            .padding(.horizontal, isExpanded ? 14 : 0)
            .padding(.bottom, isExpanded ? 12 : 0)
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ComposerHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            )
    }
}

// MARK: - InlineSurfaceErrorBanner

private struct InlineSurfaceErrorBanner: View {

    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.warningAccent)
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 6)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 560)
        .glassCard(cornerRadius: 12, variant: .clear, tint: LiquidGlassColors.warningGlassTint)
    }
}

// MARK: - ComposerHeightPreferenceKey

private nonisolated struct ComposerHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() {
            value = next
        }
    }
}
