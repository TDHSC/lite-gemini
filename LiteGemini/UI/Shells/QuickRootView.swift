import SwiftUI

// MARK: - QuickRootView

/// Top-level SwiftUI container hosted inside `QuickFloatingPanel`.
///
/// Preserves a constant SwiftUI structural path for `surface(isExpanded)` across
/// `.barOnly → .expanded` expansion so AppKit's `NSTextView` composer is never unmounted
/// or unfocused on first prompt submission (`§2.3.2 #3`).
struct QuickRootView<Surface: View>: View {

    /// Corner radius applied to Quick Mode's `.expanded` Liquid Glass mini-window.
    static var expandedCornerRadius: CGFloat { 18 }

    @ObservedObject var controller: QuickWorkspaceController
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    let onSignIn: () -> Void
    let onSwitchToWebMode: () -> Void
    let onBarHeightChanged: ((CGFloat) -> Void)?
    @ViewBuilder let surface: (_ isExpanded: Bool) -> Surface

    init(
        controller: QuickWorkspaceController,
        onClose: (() -> Void)? = nil,
        onMinimize: @escaping () -> Void = {},
        onZoom: @escaping () -> Void = {},
        onSignIn: @escaping () -> Void = {},
        onSwitchToWebMode: @escaping () -> Void = {},
        onBarHeightChanged: ((CGFloat) -> Void)? = nil,
        @ViewBuilder surface: @escaping (_ isExpanded: Bool) -> Surface
    ) {
        self._controller = ObservedObject(wrappedValue: controller)
        self.onClose = onClose ?? {
            Task { @MainActor in
                await controller.closeQuickWindow()
            }
        }
        self.onMinimize = onMinimize
        self.onZoom = onZoom
        self.onSignIn = onSignIn
        self.onSwitchToWebMode = onSwitchToWebMode
        self.onBarHeightChanged = onBarHeightChanged
        self.surface = surface
    }

    private var isExpanded: Bool {
        controller.phase == .expanded
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if controller.authState == .signedOut {
                signedOutGate
            } else {
                activeSurfaceContainer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: isExpanded || controller.authState == .signedOut ? .infinity : nil, alignment: .bottom)
        .background(Color.clear)
    }

    // MARK: - Active Surface

    private var activeSurfaceContainer: some View {
        surface(isExpanded)
            .frame(maxWidth: .infinity, maxHeight: isExpanded ? .infinity : nil, alignment: .bottom)
            .background {
                if isExpanded {
                    Color.clear
                        .glassCard(cornerRadius: Self.expandedCornerRadius)
                }
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: isExpanded ? Self.expandedCornerRadius : 0,
                    style: .continuous
                )
            )
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: QuickBarIntrinsicHeightPreferenceKey.self, value: geometry.size.height)
                }
            )
            .onPreferenceChange(QuickBarIntrinsicHeightPreferenceKey.self) { height in
                guard !isExpanded, height > 0 else {
                    return
                }
                onBarHeightChanged?(height)
            }
    }

    // MARK: - Signed-Out Gate

    private var signedOutGate: some View {
        VStack(spacing: 0) {
            QuickMiniTopBarView(
                onClose: onClose,
                onMinimize: onMinimize,
                onZoom: onZoom,
                onNewQuickChat: {},
                showsNewQuickChatButton: false
            )

            Spacer(minLength: 4)

            NativeWelcomeView(
                onSignIn: onSignIn,
                onSwitchToWebMode: onSwitchToWebMode
            )

            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color.clear
                .glassCard(cornerRadius: Self.expandedCornerRadius)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.expandedCornerRadius, style: .continuous))
    }
}

// MARK: - QuickWorkspaceController + SwiftUI Binding

extension QuickWorkspaceController {

    /// Two-way SwiftUI `Binding<Bool>` driving Quick Mode's persisted `Temp` switch inside
    /// `ModelPickerPopover` (`§2.3.2 #5`).
    var temporaryChatBinding: Binding<Bool> {
        Binding(
            get: { [weak self] in
                self?.isTemporaryChatPreference ?? false
            },
            set: { [weak self] newValue in
                guard let controller = self else {
                    return
                }
                controller.persistTemporaryChatPreferenceImmediately(newValue)
                Task { @MainActor [weak controller] in
                    await controller?.setQuickModeTemporaryChat(newValue)
                }
            }
        )
    }
}

// MARK: - QuickBarIntrinsicHeightPreferenceKey

private nonisolated struct QuickBarIntrinsicHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = QuickPanelLayout.defaultBarHeight

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    let controller = QuickWorkspaceController(transportFactory: { NoopChatTransport() })
    QuickRootView(controller: controller) { isExpanded in
        VStack(spacing: 0) {
            if isExpanded {
                QuickMiniTopBarView(
                    onClose: {},
                    onMinimize: {},
                    onZoom: {},
                    onNewQuickChat: {}
                )
                Spacer()
            }
            Text("Ask anything…")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .glassCapsule()
                .padding(8)
        }
    }
    .frame(width: QuickPanelLayout.panelWidth)
}
