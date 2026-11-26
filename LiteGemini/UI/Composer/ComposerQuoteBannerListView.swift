import SwiftUI

// MARK: - ComposerQuoteBannerItem

/// Lightweight display model for a highlighted passage staged above the native composer.
nonisolated struct ComposerQuoteBannerItem: Identifiable, Equatable, Hashable, Sendable {

    let id: UUID
    let quotedText: String
    let turnId: String?

    init(
        id: UUID = UUID(),
        quotedText: String,
        turnId: String? = nil
    ) {
        self.id = id
        self.quotedText = BtwPromptBuilder.normalizeQuoteText(quotedText)
        self.turnId = turnId
    }

    init(btwQuote: BtwQuoteItem) {
        self.id = btwQuote.id
        self.quotedText = btwQuote.quotedText
        self.turnId = btwQuote.turnId
    }
}

// MARK: - ComposerQuoteBannerListView

/// Stacked Liquid Glass quote banners mounted inside the composer's top extras region.
///
/// Displays up to 2 rows when collapsed with an inline `+N` expand pill on row 2, expands smoothly
/// to show all staged quotes (up to 5) with a `Show less` toggle, and surfaces an optional max-5
/// cap info banner.
struct ComposerQuoteBannerListView: View {

    // MARK: - Constants

    static let collapsedVisibleLimit: Int = 2
    static let maxStagedQuotes: Int = 5
    static let rowCornerRadius: CGFloat = LiquidGlassMetrics.concentricInnerRadius(
        outer: LiquidGlassMetrics.composerOuterCornerRadius,
        padding: 14
    )

    // MARK: - Properties

    let items: [ComposerQuoteBannerItem]
    var showsMaxCapBanner: Bool = false
    let onRemove: (UUID) -> Void
    var onDismissMaxCapBanner: (() -> Void)? = nil

    // MARK: - Internal View State

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var quoteBannerGlassNamespace
    @State private var isExpanded: Bool = false
    @State private var isHoveringShowLess: Bool = false

    private var hasOverflow: Bool {
        items.count > Self.collapsedVisibleLimit
    }

    private var hiddenCount: Int {
        max(0, items.count - Self.collapsedVisibleLimit)
    }

    private var visibleItems: [ComposerQuoteBannerItem] {
        if isExpanded || !hasOverflow {
            return items
        }
        return Array(items.prefix(Self.collapsedVisibleLimit))
    }

    // MARK: - Body

    var body: some View {
        if !items.isEmpty || showsMaxCapBanner {
            LiquidGlassContainer(spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    if showsMaxCapBanner {
                        maxCapInfoBanner
                            .liquidGlassID("composer-quote-cap-banner", in: quoteBannerGlassNamespace)
                            .liquidGlassTransitionMaterialize()
                    }

                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        let showsInlineExpandToggle = !isExpanded
                            && hasOverflow
                            && index == Self.collapsedVisibleLimit - 1

                        ComposerQuoteBannerRowView(
                            item: item,
                            overflowCount: showsInlineExpandToggle ? hiddenCount : nil,
                            onExpandOverflow: {
                                withAnimation(LiquidGlassMotion.morph(reduceMotion: reduceMotion)) {
                                    isExpanded = true
                                }
                            },
                            onRemove: {
                                onRemove(item.id)
                            }
                        )
                        .liquidGlassID("composer-quote-\(item.id.uuidString)", in: quoteBannerGlassNamespace)
                        .liquidGlassTransitionMaterialize()
                    }

                    if isExpanded && hasOverflow {
                        HStack {
                            Spacer(minLength: 0)
                            showLessButton
                        }
                        .padding(.top, 1)
                        .transition(.opacity)
                    }
                }
            }
            .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: items.count)
            .animation(LiquidGlassMotion.morph(reduceMotion: reduceMotion), value: isExpanded)
            .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: showsMaxCapBanner)
            .onChange(of: items.count) { _, newCount in
                if newCount <= Self.collapsedVisibleLimit && isExpanded {
                    isExpanded = false
                }
            }
        }
    }

    // MARK: - Subviews

    private var showLessButton: some View {
        Button {
            withAnimation(LiquidGlassMotion.morph(reduceMotion: reduceMotion)) {
                isExpanded = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                Text("Show less")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(Color.primary.opacity(isHoveringShowLess ? 0.94 : 0.72))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .glassCapsule(
                variant: .clear,
                tint: isHoveringShowLess ? LiquidGlassColors.hoverHighlight : nil,
                interactive: true
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHoveringShowLess = hovering
            }
        }
        .accessibilityLabel(Text("Show less"))
    }

    private var maxCapInfoBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.warningAccent)
                .accessibilityHidden(true)

            Text("You can attach up to \(Self.maxStagedQuotes) quotes per message.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.86))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            if let onDismissMaxCapBanner {
                Button(action: onDismissMaxCapBanner) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .glassOrb(size: 20, variant: .clear, interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCard(
            cornerRadius: Self.rowCornerRadius,
            variant: .clear,
            tint: LiquidGlassColors.warningGlassTint
        )
    }
}

// MARK: - ComposerQuoteBannerRowView

private struct ComposerQuoteBannerRowView: View {

    let item: ComposerQuoteBannerItem
    let overflowCount: Int?
    let onExpandOverflow: () -> Void
    let onRemove: () -> Void

    @State private var isHoveringDismiss: Bool = false
    @State private var isHoveringOverflow: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2.5)
                .accessibilityHidden(true)

            Text(item.quotedText)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.76))
                .lineSpacing(2.5)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                if let overflowCount, overflowCount > 0 {
                    Button(action: onExpandOverflow) {
                        HStack(spacing: 2.5) {
                            Text(verbatim: "+\(overflowCount)")
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.primary.opacity(isHoveringOverflow ? 0.96 : 0.78))
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .glassCapsule(
                            variant: .clear,
                            tint: isHoveringOverflow ? LiquidGlassColors.hoverHighlight : nil,
                            interactive: true
                        )
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            isHoveringOverflow = hovering
                        }
                    }
                    .help(String(localized: "Show \(overflowCount) more quotes"))
                    .accessibilityLabel(Text("Show \(overflowCount) more quotes"))
                }

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(isHoveringDismiss ? 0.94 : 0.62))
                        .glassOrb(
                            size: 22,
                            variant: .clear,
                            tint: isHoveringDismiss ? LiquidGlassColors.hoverHighlight : nil,
                            interactive: true
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHoveringDismiss = hovering
                    }
                }
                .help(String(localized: "Remove quote"))
                .accessibilityLabel(Text("Remove quote"))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .glassCard(
            cornerRadius: ComposerQuoteBannerListView.rowCornerRadius,
            variant: .clear,
            tint: LiquidGlassColors.clearCardTint
        )
    }
}
