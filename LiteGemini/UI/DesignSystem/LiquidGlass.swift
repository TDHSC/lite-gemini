import AppKit
import SwiftUI

// MARK: - LiquidGlassMetrics

/// Shared geometric metrics and concentric radius helpers used across Main Window,
/// Chat Timeline, Adaptive Composer, and Quick Mode Liquid Glass surfaces.
nonisolated enum LiquidGlassMetrics: Sendable {

    /// Leading horizontal clearance left bare for macOS traffic-light window controls.
    static let trafficLightLeadingInset: CGFloat = 74
    /// Height of the seamless floating top bar band hosting Liquid Glass chrome.
    static let topBarHeight: CGFloat = 44
    /// Standard height for floating top-bar Liquid Glass capsules.
    static let topBarCapsuleHeight: CGFloat = 30
    /// Diameter of the standalone circular account avatar button in the main top bar.
    static let accountAvatarSize: CGFloat = 28
    /// Window width threshold below which the top-left `Recent` trigger collapses to a compact form.
    static let compactTopBarBreakpoint: CGFloat = 460
    /// Standard corner radius for floating Liquid Glass cards and banners.
    static let defaultCardCornerRadius: CGFloat = 14
    /// Standard corner radius for floating Liquid Glass popovers.
    static let defaultPopoverCornerRadius: CGFloat = 14
    /// Outer corner radius of the 3-state adaptive morphing composer capsule.
    static let composerOuterCornerRadius: CGFloat = 26
    /// Inner inset padding of the 3-state adaptive morphing composer capsule.
    static let composerInsetPadding: CGFloat = 8
    /// Hairline stroke width for specular borders and internal pill dividers.
    static let hairlineWidth: CGFloat = 0.5

    /// Computes a concentric inner corner radius from an outer radius and inset padding,
    /// clamping at zero to avoid invalid negative radii.
    static func concentricInnerRadius(outer: CGFloat, padding: CGFloat) -> CGFloat {
        max(0, outer - padding)
    }
}

// MARK: - LiquidGlassColors

/// Adaptive semantic colors for Lite Gemini v2 surfaces across Light and Dark appearances.
enum LiquidGlassColors {

    /// Primary conversation canvas backdrop aligned with `AppDelegate.geminiSurfaceNSColor`
    /// (`#131314` dark, `#FFFFFF` light) to prevent flashes during mode transitions.
    static let canvasBackground = Color(nsColor: AppDelegate.geminiSurfaceNSColor)

    /// Borderless tonal fill for user message bubbles (`+0.07 L` lightness step above dark canvas,
    /// subtle cool neutral step below light canvas).
    static let userBubbleFill = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 0.949, green: 0.953, blue: 0.965, alpha: 1.0),
        dark: NSColor(srgbRed: 0.141, green: 0.145, blue: 0.161, alpha: 1.0)
    ))

    /// Recessed tonal surface used for fenced code blocks, math containers, and subtle cards.
    static let recessedCodeSurface = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 0.965, green: 0.969, blue: 0.976, alpha: 1.0),
        dark: NSColor(srgbRed: 0.106, green: 0.110, blue: 0.122, alpha: 1.0)
    ))

    /// Violet foreground accent indicating Temporary Chat is active (icon-only color shift).
    static let tempActiveAccent = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 0.451, green: 0.298, blue: 0.878, alpha: 1.0),
        dark: NSColor(srgbRed: 0.678, green: 0.541, blue: 1.000, alpha: 1.0)
    ))

    /// Subtle translucent violet background tint paired with `tempActiveAccent` on active toggles.
    static let tempActiveTint = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 0.451, green: 0.298, blue: 0.878, alpha: 0.14),
        dark: NSColor(srgbRed: 0.678, green: 0.541, blue: 1.000, alpha: 0.20)
    ))

    /// Vivid accent blue used for primary actions and active Send buttons.
    static let sendButtonBlue = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 0.047, green: 0.439, blue: 0.980, alpha: 1.0),
        dark: NSColor(srgbRed: 0.161, green: 0.522, blue: 1.000, alpha: 1.0)
    ))

    /// Neutral muted fill for disabled/empty circular composer actions.
    static let mutedControlFill = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.07),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.10)
    ))

    /// Warm amber accent for mid-session challenge and warning banners.
    static let warningAccent = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 0.820, green: 0.467, blue: 0.020, alpha: 1.0),
        dark: NSColor(srgbRed: 1.000, green: 0.690, blue: 0.220, alpha: 1.0)
    ))

    /// Subtle amber glass tint applied to `ChallengeBannerView`.
    static let warningGlassTint = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 0.957, green: 0.651, blue: 0.129, alpha: 0.12),
        dark: NSColor(srgbRed: 1.000, green: 0.690, blue: 0.220, alpha: 0.14)
    ))

    /// Subtle hairline separator suitable for paired capsule dividers and popover rows.
    static let subtleHairline = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.10),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.12)
    ))

    /// Subtle hover fill for interactive items inside glass capsules and popovers.
    static let hoverHighlight = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.06),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.09)
    ))

    /// Builds a dynamic `NSColor` switching cleanly between Light and Dark macOS appearances.
    private static func adaptiveNSColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark ? dark : light
        }
    }
}

// MARK: - LiquidGlassContainer

/// Groups adjacent Liquid Glass controls inside SwiftUI's native `GlassEffectContainer`
/// on macOS 26+ while passing through cleanly on macOS 14–15.
struct LiquidGlassContainer<Content: View>: View {

    let spacing: CGFloat?
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

// MARK: - LiquidGlassSurfaceModifier

/// Internal view modifier encapsulating native macOS 26+ `.glassEffect` with a crafted
/// macOS 14–15 material fallback featuring directional top specular highlights and elevation.
private struct LiquidGlassSurfaceModifier<S: InsettableShape>: ViewModifier {

    enum FallbackMaterialStyle {
        case ultraThin
        case regular
    }

    let shape: S
    let tint: Color?
    let interactive: Bool
    let fallbackStyle: FallbackMaterialStyle

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(resolvedNativeGlass, in: shape)
        } else {
            fallbackSurface(for: content)
        }
        #else
        fallbackSurface(for: content)
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private var resolvedNativeGlass: Glass {
        var glass: Glass = .regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
    #endif

    @ViewBuilder
    private func fallbackSurface(for content: Content) -> some View {
        content
            .background {
                ZStack {
                    switch fallbackStyle {
                    case .ultraThin:
                        shape.fill(.ultraThinMaterial)
                    case .regular:
                        shape.fill(.regularMaterial)
                    }

                    shape.fill(baseSurfaceWash)

                    if let tint {
                        shape.fill(tint)
                    }
                }
            }
            .overlay {
                shape.strokeBorder(specularStrokeGradient, lineWidth: LiquidGlassMetrics.hairlineWidth)
            }
            .shadow(
                color: primaryShadowColor,
                radius: colorScheme == .dark ? 12 : 9,
                x: 0,
                y: colorScheme == .dark ? 5 : 3
            )
            .shadow(
                color: contactShadowColor,
                radius: 2,
                x: 0,
                y: 1
            )
    }

    private var baseSurfaceWash: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.04)
        }
        return Color.white.opacity(0.32)
    }

    private var specularStrokeGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(0.28), location: 0.0),
                    .init(color: Color.white.opacity(0.11), location: 0.38),
                    .init(color: Color.white.opacity(0.07), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            stops: [
                .init(color: Color.white.opacity(0.88), location: 0.0),
                .init(color: Color.white.opacity(0.30), location: 0.45),
                .init(color: Color.black.opacity(0.09), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var primaryShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.34) : Color.black.opacity(0.09)
    }

    private var contactShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.20) : Color.black.opacity(0.05)
    }
}

// MARK: - LiquidGlass View Extensions

extension View {

    /// Styles the view as a floating Liquid Glass capsule with macOS 26+ native glass
    /// and a macOS 14–15 specular material fallback.
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(LiquidGlassSurfaceModifier(
            shape: Capsule(style: .continuous),
            tint: tint,
            interactive: interactive,
            fallbackStyle: .ultraThin
        ))
    }

    /// Styles the view as a rounded Liquid Glass card surface.
    func glassCard(
        cornerRadius: CGFloat = LiquidGlassMetrics.defaultCardCornerRadius,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(LiquidGlassSurfaceModifier(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint,
            interactive: interactive,
            fallbackStyle: .ultraThin
        ))
    }

    /// Sizes and styles the view as a circular Liquid Glass orb button or emblem.
    func glassOrb(
        size: CGFloat = LiquidGlassMetrics.topBarCapsuleHeight,
        tint: Color? = nil,
        interactive: Bool = true
    ) -> some View {
        frame(width: size, height: size)
            .modifier(LiquidGlassSurfaceModifier(
                shape: Circle(),
                tint: tint,
                interactive: interactive,
                fallbackStyle: .ultraThin
            ))
    }

    /// Styles the view as a floating Liquid Glass popover surface using denser material on macOS 14–15.
    func glassPopover(
        cornerRadius: CGFloat = LiquidGlassMetrics.defaultPopoverCornerRadius,
        tint: Color? = nil
    ) -> some View {
        modifier(LiquidGlassSurfaceModifier(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint,
            interactive: false,
            fallbackStyle: .regular
        ))
    }

    /// Convenience modifier for interactive floating toolbar capsule triggers.
    func glassToolbarButton(tint: Color? = nil) -> some View {
        glassCapsule(tint: tint, interactive: true)
    }
}

// MARK: - TemporaryChatGhostShape

/// Minimalist incognito ghost vector glyph used for the icon-only Temporary Chat toggle
/// across all supported macOS versions without SF Symbols version drift.
struct TemporaryChatGhostShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let x0 = rect.minX
        let y0 = rect.minY

        var path = Path()
        // Rounded dome top and tapered wavy hem
        path.move(to: CGPoint(x: x0 + w * 0.14, y: y0 + h * 0.88))
        path.addLine(to: CGPoint(x: x0 + w * 0.14, y: y0 + h * 0.44))
        path.addCurve(
            to: CGPoint(x: x0 + w * 0.86, y: y0 + h * 0.44),
            control1: CGPoint(x: x0 + w * 0.14, y: y0 + h * 0.04),
            control2: CGPoint(x: x0 + w * 0.86, y: y0 + h * 0.04)
        )
        path.addLine(to: CGPoint(x: x0 + w * 0.86, y: y0 + h * 0.88))
        path.addQuadCurve(
            to: CGPoint(x: x0 + w * 0.68, y: y0 + h * 0.82),
            control: CGPoint(x: x0 + w * 0.78, y: y0 + h * 0.94)
        )
        path.addQuadCurve(
            to: CGPoint(x: x0 + w * 0.50, y: y0 + h * 0.88),
            control: CGPoint(x: x0 + w * 0.59, y: y0 + h * 0.73)
        )
        path.addQuadCurve(
            to: CGPoint(x: x0 + w * 0.32, y: y0 + h * 0.82),
            control: CGPoint(x: x0 + w * 0.41, y: y0 + h * 0.73)
        )
        path.addQuadCurve(
            to: CGPoint(x: x0 + w * 0.14, y: y0 + h * 0.88),
            control: CGPoint(x: x0 + w * 0.22, y: y0 + h * 0.94)
        )
        path.closeSubpath()

        // Left and right eye cutouts (rendered with even-odd fill)
        let eyeRadius = min(w, h) * 0.075
        let eyeY = y0 + h * 0.45
        path.addEllipse(in: CGRect(
            x: x0 + w * 0.36 - eyeRadius,
            y: eyeY - eyeRadius,
            width: eyeRadius * 2,
            height: eyeRadius * 2
        ))
        path.addEllipse(in: CGRect(
            x: x0 + w * 0.64 - eyeRadius,
            y: eyeY - eyeRadius,
            width: eyeRadius * 2,
            height: eyeRadius * 2
        ))

        return path
    }
}
