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
    /// Outer corner radius of Quick Mode's `.expanded` floating Liquid Glass mini-window.
    static let quickExpandedCornerRadius: CGFloat = 20
    /// Hairline stroke width for specular borders and internal pill dividers.
    static let hairlineWidth: CGFloat = 0.5

    /// Computes a concentric inner corner radius from an outer radius and inset padding,
    /// clamping at zero to avoid invalid negative radii.
    static func concentricInnerRadius(outer: CGFloat, padding: CGFloat) -> CGFloat {
        max(0, outer - padding)
    }
}

// MARK: - LiquidGlassVariant & WindowBackdropBlending

/// Optical material variant mapping directly to Apple's macOS 26+ `Glass.regular` and `Glass.clear`.
nonisolated enum LiquidGlassVariant: Sendable {
    case regular
    case clear
}

/// Controls whether `WindowBackdropView` blends with the desktop behind the window
/// (production default) or with layers behind it within the same window (e.g. previews).
nonisolated enum WindowBackdropBlending: Sendable {
    case behindWindow
    case withinWindow

    var nsBlendingMode: NSVisualEffectView.BlendingMode {
        switch self {
        case .behindWindow:
            return .behindWindow
        case .withinWindow:
            return .withinWindow
        }
    }
}

private nonisolated struct WindowBackdropBlendingKey: EnvironmentKey {
    static let defaultValue: WindowBackdropBlending = .behindWindow
}

extension EnvironmentValues {
    var windowBackdropBlending: WindowBackdropBlending {
        get { self[WindowBackdropBlendingKey.self] }
        set { self[WindowBackdropBlendingKey.self] = newValue }
    }
}

// MARK: - LiquidGlassColors

/// Adaptive semantic colors for Lite Gemini v2 surfaces across Light and Dark appearances.
enum LiquidGlassColors {

    /// Opaque fallback surface color aligned with `AppDelegate.geminiSurfaceNSColor`
    /// (`#131314` dark, `#FFFFFF` light) for Classic Web Mode and sheets.
    static let canvasBackground = Color(nsColor: AppDelegate.geminiSurfaceNSColor)

    /// Delicate translucent reading wash layered over `WindowBackdropView`'s `.underWindowBackground`
    /// vibrancy so desktop color diffuses naturally while keeping long-form Markdown WCAG AA+ legible.
    static let canvasReadingTint = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.54),
        dark: NSColor(srgbRed: 0x13 / 255.0, green: 0x13 / 255.0, blue: 0x14 / 255.0, alpha: 0.46)
    ))

    /// Subtle translucent tint for `.clear` Liquid Glass cards so foreground labels stay crisp
    /// while refracted text silhouettes and hues remain visible underneath.
    static let clearCardTint = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.08),
        dark: NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.12)
    ))

    /// Subtle translucent tint for user message bubbles rendered over `.clear` Liquid Glass.
    static let userBubbleGlassTint = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 0.08, green: 0.12, blue: 0.22, alpha: 0.055),
        dark: NSColor(srgbRed: 0.86, green: 0.90, blue: 1.00, alpha: 0.08)
    ))

    /// Borderless tonal fill fallback for user message bubbles.
    static let userBubbleFill = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 0.949, green: 0.953, blue: 0.965, alpha: 0.78),
        dark: NSColor(srgbRed: 0.141, green: 0.145, blue: 0.161, alpha: 0.72)
    ))

    /// Recessed translucent surface used for fenced code blocks, math containers, and subtle cards.
    static let recessedCodeSurface = Color(nsColor: adaptiveNSColor(
        light: NSColor(srgbRed: 0.965, green: 0.969, blue: 0.976, alpha: 0.68),
        dark: NSColor(srgbRed: 0.095, green: 0.100, blue: 0.114, alpha: 0.62)
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

// MARK: - VisualEffectBlurView & WindowBackdropView

/// AppKit `NSVisualEffectView` bridge providing genuine macOS translucency for window canvases
/// and macOS 14–15 floating glass fallbacks.
struct VisualEffectBlurView: NSViewRepresentable {

    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .active
    var isEmphasized: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.wantsLayer = true
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
        view.appearance = resolvedAppearance
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material {
            nsView.material = material
        }
        if nsView.blendingMode != blendingMode {
            nsView.blendingMode = blendingMode
        }
        if nsView.state != state {
            nsView.state = state
        }
        if nsView.isEmphasized != isEmphasized {
            nsView.isEmphasized = isEmphasized
        }
        if nsView.appearance?.name != resolvedAppearance?.name {
            nsView.appearance = resolvedAppearance
        }
    }

    private var resolvedAppearance: NSAppearance? {
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }
}

/// Translucent window canvas pairing `.underWindowBackground` desktop vibrancy with a delicate
/// adaptive reading tint wash (`~52%` dark / `~58%` light) so Liquid Glass controls refract real
/// ambient color while keeping long-form Markdown and code effortlessly legible.
struct WindowBackdropView: View {

    @Environment(\.windowBackdropBlending) private var blending

    var body: some View {
        ZStack {
            VisualEffectBlurView(
                material: .underWindowBackground,
                blendingMode: blending.nsBlendingMode,
                state: .active
            )

            LiquidGlassColors.canvasReadingTint
        }
    }
}

/// Directional specular perimeter stroke used on floating translucent glass sheets (such as Quick Mode).
struct SpecularGlassRim<S: InsettableShape>: View {

    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        shape
            .strokeBorder(strokeGradient, lineWidth: LiquidGlassMetrics.hairlineWidth)
            .allowsHitTesting(false)
    }

    private var strokeGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(0.32), location: 0.0),
                    .init(color: Color.white.opacity(0.13), location: 0.35),
                    .init(color: Color.white.opacity(0.08), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            stops: [
                .init(color: Color.white.opacity(0.90), location: 0.0),
                .init(color: Color.white.opacity(0.35), location: 0.42),
                .init(color: Color.black.opacity(0.10), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
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

/// Internal view modifier encapsulating native macOS 26+ `.glassEffect` (`.regular` / `.clear`,
/// `.tint(_:)`, `.interactive(_:)`) while explicitly preserving `@Environment(\.colorScheme)`
/// inside the glass layer and providing a genuine `NSVisualEffectView` fallback on macOS 14–15.
private struct LiquidGlassSurfaceModifier<S: InsettableShape>: ViewModifier {

    let shape: S
    let variant: LiquidGlassVariant
    let tint: Color?
    let interactive: Bool
    let fallbackBlending: WindowBackdropBlending
    let fallbackMaterial: NSVisualEffectView.Material

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.windowBackdropBlending) private var environmentBlending

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .environment(\.colorScheme, colorScheme)
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
        var glass: Glass = switch variant {
        case .regular:
            .regular
        case .clear:
            .clear
        }
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
        let resolvedBlending: NSVisualEffectView.BlendingMode =
            (fallbackBlending == .behindWindow && environmentBlending == .behindWindow)
            ? .behindWindow
            : .withinWindow

        content
            .environment(\.colorScheme, colorScheme)
            .background {
                ZStack {
                    VisualEffectBlurView(
                        material: fallbackMaterial,
                        blendingMode: resolvedBlending,
                        state: .active
                    )

                    shape.fill(baseSurfaceWash)

                    if let tint {
                        shape.fill(tint)
                    }
                }
                .clipShape(shape)
            }
            .overlay {
                SpecularGlassRim(shape: shape)
            }
            .shadow(
                color: primaryShadowColor,
                radius: variant == .clear ? 4 : (colorScheme == .dark ? 11 : 8),
                x: 0,
                y: variant == .clear ? 2 : (colorScheme == .dark ? 4 : 3)
            )
            .shadow(
                color: contactShadowColor,
                radius: 1.5,
                x: 0,
                y: 1
            )
    }

    private var baseSurfaceWash: Color {
        switch variant {
        case .regular:
            return colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.26)
        case .clear:
            return colorScheme == .dark ? Color.white.opacity(0.02) : Color.white.opacity(0.12)
        }
    }

    private var primaryShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.32) : Color.black.opacity(0.08)
    }

    private var contactShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.18) : Color.black.opacity(0.04)
    }
}

// MARK: - LiquidGlassButtonStyle

/// Availability-guarded button modifier applying native `.buttonStyle(.glassProminent)` or
/// `.buttonStyle(.glass)` on macOS 26+ with a translucent Liquid Glass capsule style on macOS 14–15.
private struct LiquidGlassButtonStyleModifier: ViewModifier {

    let prominent: Bool
    let tint: Color?

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                let resolvedTint = tint ?? LiquidGlassColors.sendButtonBlue
                content
                    .foregroundStyle(Color.white)
                    .environment(\.colorScheme, colorScheme)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(resolvedTint)
                    .background(
                        Capsule(style: .continuous)
                            .fill(resolvedTint.opacity(0.86))
                    )
            } else {
                content
                    .foregroundStyle(Color.primary.opacity(0.90))
                    .environment(\.colorScheme, colorScheme)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .tint(tint)
            }
        } else {
            content
                .buttonStyle(LiquidGlassFallbackButtonStyle(prominent: prominent, tint: tint))
        }
        #else
        content
            .buttonStyle(LiquidGlassFallbackButtonStyle(prominent: prominent, tint: tint))
        #endif
    }
}

private struct LiquidGlassFallbackButtonStyle: ButtonStyle {

    let prominent: Bool
    let tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.90))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassCapsule(
                variant: prominent ? .regular : .clear,
                tint: prominent ? (tint ?? LiquidGlassColors.sendButtonBlue) : tint,
                interactive: true
            )
            .opacity(configuration.isPressed ? 0.84 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - LiquidGlassMotion

/// Centralized animation curves tuned for Apple's Liquid Glass morphing and materialization,
/// automatically degrading to fast, non-spatial fades when `accessibilityReduceMotion` is enabled.
enum LiquidGlassMotion {

    static func morph(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .smooth(duration: 0.26, extraBounce: 0.04)
    }

    static func materialize(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.15)
            : .bouncy(duration: 0.28, extraBounce: 0.06)
    }

    static func tintShift(reduceMotion: Bool) -> Animation {
        .easeOut(duration: reduceMotion ? 0.14 : 0.20)
    }
}

// MARK: - LiquidGlass View Extensions

extension View {

    /// Styles the view as a floating Liquid Glass capsule with macOS 26+ native `Glass`
    /// (defaulting to `.clear` optical lensing) and a macOS 14–15 `NSVisualEffectView` fallback.
    func glassCapsule(
        variant: LiquidGlassVariant = .clear,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(LiquidGlassSurfaceModifier(
            shape: Capsule(style: .continuous),
            variant: variant,
            tint: tint,
            interactive: interactive,
            fallbackBlending: .withinWindow,
            fallbackMaterial: variant == .regular ? .hudWindow : .headerView
        ))
    }

    /// Styles the view as a rounded Liquid Glass card surface (defaulting to `.clear` optical lensing;
    /// pass `.regular` for high-density input surfaces like the bottom composer).
    func glassCard(
        cornerRadius: CGFloat = LiquidGlassMetrics.defaultCardCornerRadius,
        variant: LiquidGlassVariant = .clear,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(LiquidGlassSurfaceModifier(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            variant: variant,
            tint: tint,
            interactive: interactive,
            fallbackBlending: .withinWindow,
            fallbackMaterial: variant == .regular ? .hudWindow : .headerView
        ))
    }

    /// Sizes and styles the view as a circular Liquid Glass orb button or emblem.
    func glassOrb(
        size: CGFloat = LiquidGlassMetrics.topBarCapsuleHeight,
        variant: LiquidGlassVariant = .clear,
        tint: Color? = nil,
        interactive: Bool = true
    ) -> some View {
        frame(width: size, height: size)
            .modifier(LiquidGlassSurfaceModifier(
                shape: Circle(),
                variant: variant,
                tint: tint,
                interactive: interactive,
                fallbackBlending: .withinWindow,
                fallbackMaterial: variant == .regular ? .hudWindow : .headerView
            ))
    }

    /// Styles the view as a floating Liquid Glass popover surface using `.clear` optical lensing.
    func glassPopover(
        cornerRadius: CGFloat = LiquidGlassMetrics.defaultPopoverCornerRadius,
        variant: LiquidGlassVariant = .clear,
        tint: Color? = nil
    ) -> some View {
        modifier(LiquidGlassSurfaceModifier(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            variant: variant,
            tint: tint,
            interactive: false,
            fallbackBlending: .behindWindow,
            fallbackMaterial: .popover
        ))
    }

    /// Convenience modifier for interactive floating toolbar capsule triggers.
    func glassToolbarButton(
        variant: LiquidGlassVariant = .clear,
        tint: Color? = nil
    ) -> some View {
        glassCapsule(variant: variant, tint: tint, interactive: true)
    }

    /// Associates a glass surface with a `Namespace.ID` inside `LiquidGlassContainer` on macOS 26+.
    @ViewBuilder
    func liquidGlassID<ID: Hashable & Sendable>(_ id: ID?, in namespace: Namespace.ID) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Optically merges sibling glass surfaces sharing `id` inside `LiquidGlassContainer` on macOS 26+.
    @ViewBuilder
    func liquidGlassUnion<ID: Hashable & Sendable>(id: ID?, namespace: Namespace.ID) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffectUnion(id: id, namespace: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Applies matched-geometry Liquid Glass morphing transitions on macOS 26+.
    @ViewBuilder
    func liquidGlassTransitionMatchedGeometry() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffectTransition(.matchedGeometry)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Applies Apple's native droplet condensation/evaporation `.glassEffectTransition(.materialize)`
    /// on macOS 26+, falling back to an origin-friendly scale+opacity transition on macOS 14–15.
    @ViewBuilder
    func liquidGlassTransitionMaterialize() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffectTransition(.materialize)
        } else {
            self.transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        #else
        self.transition(.opacity.combined(with: .scale(scale: 0.96)))
        #endif
    }

    /// Applies Apple's native `.buttonStyle(.glassProminent)` or `.buttonStyle(.glass)` on macOS 26+
    /// with a cohesive Liquid Glass capsule fallback on macOS 14–15.
    func liquidGlassButtonStyle(
        prominent: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(LiquidGlassButtonStyleModifier(prominent: prominent, tint: tint))
    }

    /// Applies macOS 26+ soft scroll edge effects so scrolling content blends seamlessly under floating glass chrome.
    @ViewBuilder
    func liquidGlassScrollEdgeEffect(edges: Edge.Set = [.bottom]) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Pairs macOS 26+ top/bottom `.safeAreaBar` reservations with un-faded scroll-under edges
    /// (matching T3 Code's `scrollEdgeEffects` `bottom: "hidden"` pattern so `.soft` never paints
    /// a local frosted curtain over prose before it refracts through `.clear` / `.regular` glass).
    @ViewBuilder
    func liquidGlassFloatingScrollChrome(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self
                .safeAreaBar(edge: .top, spacing: 0) {
                    Color.clear
                        .frame(height: max(0, topInset))
                        .allowsHitTesting(false)
                }
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    Color.clear
                        .frame(height: max(0, bottomInset))
                        .allowsHitTesting(false)
                }
                .scrollEdgeEffectHidden(true, for: [.top, .bottom])
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Clears the SwiftUI window container background on macOS 26+ so translucent window vibrancy shines through.
    @ViewBuilder
    func clearWindowContainerBackground() -> some View {
        if #available(macOS 15.0, *) {
            self.containerBackground(.clear, for: .window)
        } else {
            self
        }
    }

    /// Configures whether `WindowBackdropView` blends with the desktop behind the window or layers within the window.
    func windowBackdropBlending(_ blending: WindowBackdropBlending) -> some View {
        environment(\.windowBackdropBlending, blending)
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
