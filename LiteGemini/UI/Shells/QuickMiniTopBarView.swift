import AppKit
import SwiftUI

// MARK: - QuickMiniTopBarView

/// Minimalist `44pt` Liquid Glass top bar for Quick Mode's expanded mini-window.
///
/// Layout (strictly omits `Recent`, `Avatar`, and any top-bar `Temp` toggle):
/// - Leading: interactive macOS traffic lights (`12pt` Close / Minimize / Zoom with hover glyphs
///   and a `40pt` accessible hit target on Close)
/// - Center: draggable `WindowDragArea` titlebar band
/// - Trailing: single `30pt` circular `+` Liquid Glass orb starting a fresh Quick Chat
struct QuickMiniTopBarView: View {

    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    let onNewQuickChat: () -> Void
    var showsNewQuickChatButton: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringTrafficLights = false
    @State private var isHoveringNewQuickChat = false
    @Namespace private var quickTopBarGlassNamespace

    private static let trafficLightDiameter: CGFloat = 12
    private static let closeHitTargetSize: CGFloat = 40
    private static let newChatOrbSize: CGFloat = 30

    var body: some View {
        ZStack {
            WindowDragArea()

            HStack(spacing: 0) {
                trafficLightsCluster

                Spacer(minLength: 8)

                LiquidGlassContainer(spacing: 8) {
                    if showsNewQuickChatButton {
                        newQuickChatButton
                    }
                }
                .padding(.trailing, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: LiquidGlassMetrics.topBarHeight)
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: showsNewQuickChatButton)
    }

    // MARK: - Leading Traffic Lights

    private var trafficLightsCluster: some View {
        ZStack(alignment: .leading) {
            // Red Close button with generous 40x40pt accessible hit target centered on x = 20.
            Button(action: onClose) {
                trafficLightDot(
                    fill: Color(nsColor: NSColor(srgbRed: 1.0, green: 0.373, blue: 0.341, alpha: 1.0)),
                    symbol: "xmark",
                    symbolColor: Color(nsColor: NSColor(srgbRed: 0.30, green: 0.0, blue: 0.0, alpha: 0.78)),
                    symbolSize: 6.5
                )
                .frame(width: Self.closeHitTargetSize, height: Self.closeHitTargetSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Close Quick Window"))
            .accessibilityLabel(Text("Close"))

            // Yellow Minimize dot centered on x = 40 (8pt gap after red dot).
            Button(action: onMinimize) {
                trafficLightDot(
                    fill: Color(nsColor: NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1.0)),
                    symbol: "minus",
                    symbolColor: Color(nsColor: NSColor(srgbRed: 0.36, green: 0.22, blue: 0.0, alpha: 0.78)),
                    symbolSize: 6.5
                )
                .frame(width: 20, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 30)
            .help(String(localized: "Minimize"))
            .accessibilityLabel(Text("Minimize"))

            // Green Zoom dot centered on x = 60 (8pt gap after yellow dot).
            Button(action: onZoom) {
                trafficLightDot(
                    fill: Color(nsColor: NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1.0)),
                    symbol: "plus",
                    symbolColor: Color(nsColor: NSColor(srgbRed: 0.0, green: 0.28, blue: 0.04, alpha: 0.78)),
                    symbolSize: 6.5
                )
                .frame(width: 20, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 50)
            .help(String(localized: "Zoom"))
            .accessibilityLabel(Text("Zoom"))
        }
        .frame(width: 76, height: LiquidGlassMetrics.topBarHeight, alignment: .leading)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHoveringTrafficLights = hovering
            }
        }
    }

    private func trafficLightDot(
        fill: Color,
        symbol: String,
        symbolColor: Color,
        symbolSize: CGFloat
    ) -> some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: Self.trafficLightDiameter, height: Self.trafficLightDiameter)
                .overlay {
                    Circle()
                        .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5)
                }

            if isHoveringTrafficLights {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize, weight: .bold))
                    .foregroundStyle(symbolColor)
            }
        }
    }

    // MARK: - Trailing New Quick Chat Orb

    private var newQuickChatButton: some View {
        Button(action: onNewQuickChat) {
            ZStack {
                Circle()
                    .fill(isHoveringNewQuickChat ? LiquidGlassColors.hoverHighlight : Color.clear)

                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(isHoveringNewQuickChat ? 0.96 : 0.80))
            }
            .glassOrb(size: Self.newChatOrbSize, variant: .clear, interactive: true)
            .liquidGlassID("quick-top-new-chat", in: quickTopBarGlassNamespace)
            .liquidGlassTransitionMaterialize()
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringNewQuickChat = hovering
            }
        }
        .help(String(localized: "New Quick Chat"))
        .accessibilityLabel(Text("New Quick Chat"))
    }
}

#Preview {
    QuickMiniTopBarView(
        onClose: {},
        onMinimize: {},
        onZoom: {},
        onNewQuickChat: {}
    )
    .frame(width: QuickPanelLayout.panelWidth)
    .glassCard(cornerRadius: 18)
    .padding()
}
