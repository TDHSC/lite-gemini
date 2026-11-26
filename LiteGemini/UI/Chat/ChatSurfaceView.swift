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
    var onOpenInWebMode: ((String?) -> Void)?
    var onSaveInlineImage: ((ImageAttachment) -> Void)?
    @ViewBuilder var topBar: () -> TopBar
    @ViewBuilder var emptyState: () -> EmptyState
    @ViewBuilder var composer: () -> Composer

    @State private var measuredComposerHeight: CGFloat = 72

    init(
        store: ChatSessionStore,
        isExpanded: Bool = true,
        topContentInset: CGFloat = LiquidGlassMetrics.topBarHeight,
        onOpenInWebMode: ((String?) -> Void)? = nil,
        onSaveInlineImage: ((ImageAttachment) -> Void)? = nil,
        @ViewBuilder topBar: @escaping () -> TopBar,
        @ViewBuilder emptyState: @escaping () -> EmptyState,
        @ViewBuilder composer: @escaping () -> Composer
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self.isExpanded = isExpanded
        self.topContentInset = topContentInset
        self.onOpenInWebMode = onOpenInWebMode
        self.onSaveInlineImage = onSaveInlineImage
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
            if height > 0 && abs(height - measuredComposerHeight) > 0.5 {
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
                    onOpenInWebMode: onOpenInWebMode,
                    onSaveInlineImage: onSaveInlineImage
                )
            }

            topBar()
                .zIndex(2)
        }
        .overlay(alignment: .bottom) {
            if let errorMessage = store.lastErrorMessage,
               !errorMessage.isEmpty,
               store.challengeBanner == nil {
                InlineSurfaceErrorBanner(message: errorMessage) {
                    store.lastErrorMessage = nil
                }
                .padding(.horizontal, 16)
                .padding(.bottom, measuredComposerHeight + 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.lastErrorMessage)
    }

    // MARK: - Constant-Identity Composer Slot

    private var composerSlot: some View {
        composer()
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
        .glassCard(cornerRadius: 12, tint: LiquidGlassColors.warningGlassTint)
    }
}

// MARK: - ComposerHeightPreferenceKey

private nonisolated struct ComposerHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 72

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
