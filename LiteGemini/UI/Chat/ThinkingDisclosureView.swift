import SwiftUI

// MARK: - ThinkingDisclosureView

/// Compact borderless inline thinking trigger (`✦ Thought for X.Xs ›` or live pulsing `"Thinking…"`).
/// Clicking expands a subtle left-bordered reasoning trace without introducing heavy chrome bars.
struct ThinkingDisclosureView: View {

    let turnId: String
    let thinkingText: String
    let isComplete: Bool
    let durationSeconds: Double?

    @State private var isExpanded = false
    @State private var isHoveringTrigger = false
    @State private var pulseOpacity: Double = 0.45

    private var trimmedThinking: String {
        thinkingText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasTraceContent: Bool {
        !trimmedThinking.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            triggerButton

            if isExpanded, hasTraceContent {
                expandedTraceView
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: isComplete) { oldValue, newValue in
            if !oldValue && newValue && isExpanded {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded = false
                }
            }
        }
        .task(id: isComplete) {
            guard !isComplete else {
                pulseOpacity = 1.0
                return
            }
            pulseOpacity = 0.42
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                pulseOpacity = 0.95
            }
        }
    }

    // MARK: - Subviews

    private var triggerButton: some View {
        Button {
            guard hasTraceContent else {
                return
            }
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Text(triggerLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(isHoveringTrigger ? 0.98 : 0.85))
                    .opacity(isComplete ? 1.0 : pulseOpacity)

                if hasTraceContent {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(0.75))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(isHoveringTrigger && hasTraceContent ? LiquidGlassColors.hoverHighlight : Color.clear)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!hasTraceContent)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringTrigger = hovering
            }
        }
        .accessibilityLabel(Text(triggerLabel))
        .accessibilityHint(hasTraceContent ? Text("Show reasoning") : Text(verbatim: ""))
    }

    private var expandedTraceView: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.16))
                .frame(width: 2)

            MarkdownContentView(
                markdown: trimmedThinking,
                turnId: "\(turnId)-thinking",
                partIndex: 0,
                baseFontSize: 12.5,
                foregroundOpacity: 0.72
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 5)
        .padding(.vertical, 2)
    }

    private var triggerLabel: String {
        if !isComplete {
            return String(localized: "Thinking…")
        }
        if let durationSeconds, durationSeconds >= 0.1 {
            let formatted = String(format: "%.1f", durationSeconds)
            return String(localized: "Thought for \(formatted)s")
        }
        return String(localized: "Thought")
    }
}
