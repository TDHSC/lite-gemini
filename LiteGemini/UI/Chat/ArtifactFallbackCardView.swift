import SwiftUI

// MARK: - ArtifactFallbackCardView

/// Liquid Glass fallback card rendered for web-only Gemini rich artifacts (Canvas, Deep Research,
/// Gems, and extension widgets) with a one-click `"Open in Web ↗"` handoff button.
struct ArtifactFallbackCardView: View {

    let artifact: ArtifactCardInfo
    var onOpenInWebMode: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideLayout
            compactLayout
        }
        .environment(\.colorScheme, colorScheme)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassCard(
            cornerRadius: LiquidGlassMetrics.defaultCardCornerRadius,
            variant: .clear,
            tint: LiquidGlassColors.clearCardTint
        )
    }

    // MARK: - Layouts

    private var wideLayout: some View {
        HStack(spacing: 12) {
            iconBadge
            metadataColumn
            Spacer(minLength: 10)
            openInWebButton
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                iconBadge
                metadataColumn
            }

            openInWebButton
        }
    }

    // MARK: - Subviews

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LiquidGlassColors.sendButtonBlue.opacity(0.14))

            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.sendButtonBlue)
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }

    private var metadataColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(kindDisplayName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.sendButtonBlue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(LiquidGlassColors.sendButtonBlue.opacity(0.12))
                    )
            }

            Text(resolvedTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = artifact.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var openInWebButton: some View {
        Button {
            onOpenInWebMode?()
        } label: {
            Text("Open in Web ↗")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .controlSize(.regular)
        .liquidGlassButtonStyle(prominent: false)
        .disabled(onOpenInWebMode == nil)
        .accessibilityLabel(Text("Open in Web ↗"))
    }

    // MARK: - Helpers

    private var resolvedTitle: String {
        let trimmed = artifact.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kindDisplayName : trimmed
    }

    private var kindDisplayName: String {
        switch artifact.kind {
        case .canvas:
            return String(localized: "Canvas")
        case .deepResearch:
            return String(localized: "Deep Research")
        case .gem:
            return String(localized: "Gem")
        case .extensionWidget:
            return String(localized: "Extension")
        case .unknown:
            return String(localized: "Interactive Card")
        }
    }

    private var iconName: String {
        switch artifact.kind {
        case .canvas:
            return "doc.richtext"
        case .deepResearch:
            return "text.magnifyingglass"
        case .gem:
            return "sparkles"
        case .extensionWidget:
            return "puzzlepiece.extension"
        case .unknown:
            return "square.on.square"
        }
    }
}
