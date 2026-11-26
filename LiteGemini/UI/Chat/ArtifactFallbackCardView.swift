import SwiftUI

// MARK: - ArtifactFallbackCardView

/// Liquid Glass interactive artifact card handling:
/// 1. Native **Deep Research Plan** confirmation (`Start Research` / `Edit Plan`).
/// 2. Live **Deep Research Progress** status tracking during multi-source synthesis.
/// 3. Native **Canvas** & **Deep Research Report** cards opening in the Main Window Split Pane
///    (or handing off from Quick Mode to Main Window).
/// 4. Web-only fallback artifacts (`Gems`, `Extensions`) offering `"Open in Web ↗"`.
struct ArtifactFallbackCardView: View {

    let artifact: ArtifactCardInfo
    var isQuickMode: Bool = false
    var onOpenArtifact: ((ArtifactCardInfo) -> Void)? = nil
    var onConfirmResearchPlan: ((ArtifactCardInfo) -> Void)? = nil
    var onEditResearchPlan: (() -> Void)? = nil
    var onOpenInWebMode: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let plan = artifact.plan, !artifact.hasNativeContent {
                deepResearchPlanBody(plan: plan)
            } else if let progress = artifact.progress, !artifact.hasNativeContent {
                deepResearchProgressBody(progress: progress)
            } else {
                standardArtifactBody
            }
        }
        .environment(\.colorScheme, colorScheme)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassCard(
            cornerRadius: LiquidGlassMetrics.defaultCardCornerRadius,
            variant: .clear,
            tint: LiquidGlassColors.clearCardTint
        )
        .contextMenu {
            if artifact.hasNativeContent, let onOpenArtifact {
                Button(isQuickMode ? "Open in Main Window" : "Open Canvas") {
                    onOpenArtifact(artifact)
                }
            }
            if let onOpenInWebMode {
                Button("Open in Web ↗", action: onOpenInWebMode)
            }
        }
    }

    // MARK: - 1. Deep Research Plan Confirmation Card

    private func deepResearchPlanBody(plan: DeepResearchPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                iconBadge

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        kindBadge(label: String(localized: "Deep Research Plan"))

                        if let est = plan.estimatedTimeText, !est.isEmpty {
                            Text(est)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(resolvedTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 9) {
                        Text("\(index + 1)")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(LiquidGlassColors.sendButtonBlue)
                            .frame(width: 20, height: 20)
                            .background(
                                Circle()
                                    .fill(LiquidGlassColors.sendButtonBlue.opacity(0.14))
                            )
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.92))
                                .fixedSize(horizontal: false, vertical: true)

                            if let detail = step.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(.leading, 2)

            HStack(spacing: 8) {
                if !plan.isConfirmed, let onEditResearchPlan {
                    Button(action: onEditResearchPlan) {
                        Text("Edit Plan")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .controlSize(.regular)
                    .liquidGlassButtonStyle(prominent: false)
                }

                Spacer(minLength: 4)

                if plan.isConfirmed {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LiquidGlassColors.sendButtonBlue)
                        Text("Research Started")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        onConfirmResearchPlan?(artifact)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("Start Research")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .controlSize(.regular)
                    .liquidGlassButtonStyle(prominent: true, tint: LiquidGlassColors.sendButtonBlue)
                    .disabled(onConfirmResearchPlan == nil)
                }
            }
        }
    }

    // MARK: - 2. Deep Research Live Progress Card

    private func deepResearchProgressBody(progress: DeepResearchProgress) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LiquidGlassColors.sendButtonBlue.opacity(0.14))
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.85)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    kindBadge(label: String(localized: "Deep Research"))
                    if let sourceCount = progress.browsedSourceCount, sourceCount > 0 {
                        Text("\(sourceCount) sources")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(progress.statusText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
    }

    // MARK: - 3. Standard Native Canvas / Report / Fallback Card

    private var standardArtifactBody: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                iconBadge
                metadataColumn
                Spacer(minLength: 10)
                primaryActionButton
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    iconBadge
                    metadataColumn
                }
                primaryActionButton
            }
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

    private func kindBadge(label: String) -> some View {
        Text(label)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(LiquidGlassColors.sendButtonBlue)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                Capsule(style: .continuous)
                    .fill(LiquidGlassColors.sendButtonBlue.opacity(0.12))
            )
    }

    private var metadataColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                kindBadge(label: kindDisplayName)
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

    @ViewBuilder
    private var primaryActionButton: some View {
        if artifact.hasNativeContent, let onOpenArtifact {
            Button {
                onOpenArtifact(artifact)
            } label: {
                HStack(spacing: 4) {
                    Text(nativeButtonLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: isQuickMode ? "arrow.up.forward.app" : "sidebar.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .controlSize(.regular)
            .liquidGlassButtonStyle(prominent: false)
        } else {
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
    }

    // MARK: - Helpers

    private var nativeButtonLabel: LocalizedStringKey {
        if isQuickMode {
            return "Open in Main"
        }
        if artifact.kind == .deepResearch {
            return "Read Report"
        }
        if artifact.supportsLiveWebPreview {
            return "Preview"
        }
        return "Open Canvas"
    }

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
            return artifact.supportsLiveWebPreview ? "macwindow.on.rectangle" : "doc.richtext"
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
