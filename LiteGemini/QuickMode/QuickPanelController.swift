import AppKit
import Combine
import Foundation
import QuartzCore
import SwiftUI

// MARK: - QuickPanelLayout

/// Pure frame geometry calculator for Quick Mode's floating bar and bottom-anchored upward expansion.
nonisolated struct QuickPanelLayout: Equatable, Sendable {

    /// Fixed width of both the `.barOnly` composer bar and `.expanded` mini-window.
    static let panelWidth: CGFloat = 548
    /// Default compact height of the single-row `.barOnly` composer pill with vertical shadow clearance.
    static let defaultBarHeight: CGFloat = 68
    /// Minimum `.barOnly` panel height.
    static let minBarHeight: CGFloat = 68
    /// Maximum `.barOnly` panel height (multi-line text + attachment tiles).
    static let maxBarHeight: CGFloat = 230
    /// Standard height of the `.expanded` Quick Mode mini-window.
    static let expandedHeight: CGFloat = 500
    /// Compact height used when presenting the signed-out welcome gate inside Quick Mode.
    static let signedOutHeight: CGFloat = 390
    /// Taller height toggled by the green Zoom traffic light in `.expanded` phase.
    static let zoomedHeight: CGFloat = 760
    /// Minimum inset kept between the floating panel and visible screen edges.
    static let screenEdgeMargin: CGFloat = 16

    /// Clamps an intrinsic composer measurement to the supported `.barOnly` height range (`68...230pt`).
    static func clampBarHeight(_ rawHeight: CGFloat) -> CGFloat {
        guard rawHeight.isFinite else {
            return defaultBarHeight
        }
        return min(max(ceil(rawHeight), minBarHeight), maxBarHeight)
    }

    /// Computes the initial centered frame on `visibleFrame`, bottom-anchored so that upward expansion
    /// to `548 × 500pt` lands centered comfortably in the active display.
    static func defaultFrame(
        for phase: QuickPhase,
        barHeight: CGFloat = defaultBarHeight,
        authState: AuthState = .unknown,
        in visibleFrame: CGRect
    ) -> CGRect {
        let targetWidth = resolvedWidth(in: visibleFrame)
        let targetHeight = resolvedHeight(for: phase, barHeight: barHeight, authState: authState, in: visibleFrame)
        let expandedReferenceHeight = min(
            expandedHeight,
            max(minBarHeight, visibleFrame.height - screenEdgeMargin * 2)
        )

        let originX = round(visibleFrame.midX - targetWidth / 2)
        let idealBottomY = round(visibleFrame.midY - expandedReferenceHeight / 2)
        let originY = clampOriginY(idealBottomY, height: targetHeight, in: visibleFrame)

        return CGRect(x: originX, y: originY, width: targetWidth, height: targetHeight)
    }

    /// Computes the updated frame when transitioning between `.barOnly` and `.expanded` (or resizing
    /// the pre-send composer), preserving the bottom origin so the composer remains visually anchored
    /// while the window expands upward.
    static func bottomAnchoredFrame(
        from currentFrame: CGRect,
        targetPhase: QuickPhase,
        barHeight: CGFloat,
        authState: AuthState = .unknown,
        in visibleFrame: CGRect
    ) -> CGRect {
        let targetWidth = resolvedWidth(in: visibleFrame)
        let targetHeight = resolvedHeight(for: targetPhase, barHeight: barHeight, authState: authState, in: visibleFrame)

        let minX = visibleFrame.minX + screenEdgeMargin
        let maxX = max(minX, visibleFrame.maxX - targetWidth - screenEdgeMargin)
        let originX = min(max(currentFrame.origin.x, minX), maxX)
        let originY = clampOriginY(currentFrame.origin.y, height: targetHeight, in: visibleFrame)

        return CGRect(x: round(originX), y: round(originY), width: targetWidth, height: round(targetHeight))
    }

    /// Computes the toggled zoom frame for `.expanded` mode while keeping the bottom edge anchored
    /// and clamping inside `visibleFrame`.
    static func zoomedFrame(
        from currentFrame: CGRect,
        isZoomed: Bool,
        in visibleFrame: CGRect
    ) -> CGRect {
        let targetWidth = resolvedWidth(in: visibleFrame)
        let maxAvailableHeight = max(minBarHeight, visibleFrame.height - screenEdgeMargin * 2)
        let desiredHeight = isZoomed ? zoomedHeight : expandedHeight
        let targetHeight = min(desiredHeight, maxAvailableHeight)

        let minX = visibleFrame.minX + screenEdgeMargin
        let maxX = max(minX, visibleFrame.maxX - targetWidth - screenEdgeMargin)
        let originX = min(max(currentFrame.origin.x, minX), maxX)
        let originY = clampOriginY(currentFrame.origin.y, height: targetHeight, in: visibleFrame)

        return CGRect(x: round(originX), y: round(originY), width: targetWidth, height: round(targetHeight))
    }

    // MARK: - Private Geometry Helpers

    private static func resolvedWidth(in visibleFrame: CGRect) -> CGFloat {
        min(panelWidth, max(360, visibleFrame.width - screenEdgeMargin * 2))
    }

    private static func resolvedHeight(
        for phase: QuickPhase,
        barHeight: CGFloat,
        authState: AuthState,
        in visibleFrame: CGRect
    ) -> CGFloat {
        let maxAvailableHeight = max(minBarHeight, visibleFrame.height - screenEdgeMargin * 2)
        if authState == .signedOut {
            return min(signedOutHeight, maxAvailableHeight)
        }
        switch phase {
        case .barOnly:
            return min(clampBarHeight(barHeight), maxAvailableHeight)
        case .expanded:
            return min(expandedHeight, maxAvailableHeight)
        }
    }

    private static func clampOriginY(_ rawY: CGFloat, height: CGFloat, in visibleFrame: CGRect) -> CGFloat {
        let minY = visibleFrame.minY + screenEdgeMargin
        let maxY = max(minY, visibleFrame.maxY - height - screenEdgeMargin)
        return min(max(rawY, minY), maxY)
    }
}

// MARK: - QuickFloatingPanel

/// Borderless, transparent, floating non-activating `NSPanel` hosting Quick Mode across all Spaces
/// and fullscreen apps while accepting direct keyboard and CJK IME input.
@MainActor
final class QuickFloatingPanel: NSPanel {

    /// Invoked when the user triggers `Cmd+W` or `performClose(_:)`.
    var onCloseRequested: (@MainActor () -> Void)?

    /// Invoked on `Esc`; returns `true` when Quick Mode consumed the key to dismiss `.barOnly`.
    var onEscapeRequested: (@MainActor () -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Whether a sheet, popover, or open panel child window currently owns focus on behalf of this panel.
    var hasBlockingSheetOrChildWindow: Bool {
        if attachedSheet != nil || NSApp.modalWindow != nil {
            return true
        }
        if let childWindows, childWindows.contains(where: { $0.isVisible || $0.isKeyWindow }) {
            return true
        }
        if NSApp.windows.contains(where: { $0 !== self && ($0 is NSSavePanel) && $0.isVisible }) {
            return true
        }
        if let keyWindow = NSApp.keyWindow,
           keyWindow !== self,
           (keyWindow.parent === self || keyWindow is NSSavePanel) {
            return true
        }
        return false
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            onCloseRequested?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func performClose(_ sender: Any?) {
        onCloseRequested?()
    }

    override func close() {
        if let onCloseRequested {
            onCloseRequested()
        } else {
            super.close()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if let textClient = firstResponder as? any NSTextInputClient, textClient.hasMarkedText() {
            super.cancelOperation(sender)
            return
        }
        guard !hasBlockingSheetOrChildWindow else {
            super.cancelOperation(sender)
            return
        }
        if onEscapeRequested?() == true {
            return
        }
        super.cancelOperation(sender)
    }
}

// MARK: - QuickPanelPresenting

/// Window-presentation abstraction allowing `QuickPanelController` to drive a real `QuickFloatingPanel`
/// in production while running 100% headless with a mock presenter in automated harnesses.
@MainActor
protocol QuickPanelPresenting: AnyObject {

    /// Whether the underlying panel is currently visible on screen.
    var isPanelVisible: Bool { get }

    /// Current screen-coordinate frame of the floating panel.
    var panelFrame: CGRect { get }

    /// Whether an attached sheet or child popover currently owns focus and should suppress resign-key auto-hide.
    var hasAttachedSheetOrChildPopover: Bool { get }

    /// Called when the panel loses key window focus outside any attached sheet or child popover.
    var onResignKey: (@MainActor () -> Void)? { get set }

    /// Called when `Cmd+W` or window close is requested on the panel.
    var onCloseRequested: (@MainActor () -> Void)? { get set }

    /// Called on `Esc`; returns `true` if handled.
    var onEscapeRequested: (@MainActor () -> Bool)? { get set }

    /// Updates the panel's screen frame, optionally animating smoothly.
    func setFrame(_ frame: CGRect, animated: Bool)

    /// Orders the floating panel front and focuses it for keyboard input.
    func showAndFocus()

    /// Hides the floating panel without destroying its hosted SwiftUI view hierarchy.
    func hide()

    /// Miniaturizes the floating panel.
    func minimize()
}

// MARK: - AppKitQuickPanelPresenter

/// Production `QuickPanelPresenting` implementation lazily creating and managing `QuickFloatingPanel`.
@MainActor
final class AppKitQuickPanelPresenter: QuickPanelPresenting {

    // MARK: - Properties

    var onResignKey: (@MainActor () -> Void)?
    var onCloseRequested: (@MainActor () -> Void)?
    var onEscapeRequested: (@MainActor () -> Bool)?

    var isPanelVisible: Bool {
        panel?.isVisible ?? false
    }

    var panelFrame: CGRect {
        panel?.frame ?? pendingFrame
    }

    var hasAttachedSheetOrChildPopover: Bool {
        panel?.hasBlockingSheetOrChildWindow ?? false
    }

    private nonisolated static let mainQueueSpecificKey: DispatchSpecificKey<Bool> = {
        let key = DispatchSpecificKey<Bool>()
        DispatchQueue.main.setSpecific(key: key, value: true)
        return key
    }()

    private nonisolated static var isOnMainQueue: Bool {
        Thread.isMainThread || DispatchQueue.getSpecific(key: mainQueueSpecificKey) == true
    }

    private let contentViewBuilder: @MainActor () -> NSView
    private let notificationCenter: NotificationCenter
    private let animationDuration: TimeInterval

    private var panel: QuickFloatingPanel?
    private var pendingFrame: CGRect
    private var resignKeyObserver: (any NSObjectProtocol)?

    // MARK: - Initialization

    init<Content: View>(
        initialFrame: CGRect = CGRect(x: 0, y: 0, width: QuickPanelLayout.panelWidth, height: QuickPanelLayout.defaultBarHeight),
        notificationCenter: NotificationCenter = .default,
        animationDuration: TimeInterval = 0.20,
        @ViewBuilder content: @escaping @MainActor () -> Content
    ) {
        self.pendingFrame = initialFrame
        self.notificationCenter = notificationCenter
        self.animationDuration = animationDuration
        self.contentViewBuilder = {
            let hostingView = NSHostingView(rootView: content())
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            return hostingView
        }
    }

    isolated deinit {
        if let resignKeyObserver {
            notificationCenter.removeObserver(resignKeyObserver)
        }
        panel?.orderOut(nil)
    }

    // MARK: - QuickPanelPresenting

    func setFrame(_ frame: CGRect, animated: Bool) {
        pendingFrame = frame
        guard let panel else {
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak panel] in
                Task { @MainActor in
                    panel?.invalidateShadow()
                }
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    func showAndFocus() {
        let panel = ensurePanel()
        if panel.frame != pendingFrame {
            panel.setFrame(pendingFrame, display: true)
        }
        panel.invalidateShadow()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func minimize() {
        panel?.miniaturize(nil)
    }

    // MARK: - Private Panel Construction

    private func ensurePanel() -> QuickFloatingPanel {
        if let panel {
            return panel
        }

        let created = QuickFloatingPanel(contentRect: pendingFrame)
        created.contentView = contentViewBuilder()

        created.onCloseRequested = { [weak self] in
            self?.onCloseRequested?()
        }
        created.onEscapeRequested = { [weak self] in
            self?.onEscapeRequested?() ?? false
        }

        resignKeyObserver = notificationCenter.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: created,
            queue: nil
        ) { [weak self] _ in
            if AppKitQuickPanelPresenter.isOnMainQueue {
                MainActor.assumeIsolated {
                    self?.handleDidResignKey()
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.handleDidResignKey()
                    }
                }
            }
        }

        self.panel = created
        return created
    }

    private func handleDidResignKey() {
        guard !hasAttachedSheetOrChildPopover else {
            return
        }
        onResignKey?()
    }
}

// MARK: - QuickPanelController

/// Coordinates `QuickWorkspaceController` state transitions with `QuickPanelPresenting` geometry,
/// bottom-anchored upward expansion animations, resign-key filtering, and `Cmd+W` / `Esc` actions.
@MainActor
final class QuickPanelController {

    // MARK: - Public Dependencies & State

    /// State machine driving Quick Mode's phase, visibility, and lazy session lifecycle.
    let controller: QuickWorkspaceController

    /// Underlying window presenter (`AppKitQuickPanelPresenter` in production, mock in headless tests).
    let presenter: any QuickPanelPresenting

    /// Most recent intrinsic height reported by the `.barOnly` composer (`68...230pt`).
    private(set) var currentBarHeight: CGFloat = QuickPanelLayout.defaultBarHeight

    /// Whether the `.expanded` mini-window is currently toggled to its taller zoomed height.
    private(set) var isZoomed: Bool = false

    // MARK: - Private Configuration & Reconciliation State

    private let activeScreenVisibleFrame: @MainActor () -> CGRect
    private let animationsEnabled: @MainActor () -> Bool

    private var cancellables: Set<AnyCancellable> = []
    private var hasPositionedPanel: Bool = false
    private var lastAppliedPhase: QuickPhase
    private var lastAppliedVisible: Bool
    private var lastAppliedFocusTrigger: Int
    private var lastAppliedAuthState: AuthState

    // MARK: - Initialization

    /// Creates a `QuickPanelController` with an injectable presenter (for headless test harnesses).
    init(
        controller: QuickWorkspaceController,
        presenter: any QuickPanelPresenting,
        activeScreenVisibleFrame: @escaping @MainActor () -> CGRect = QuickPanelController.defaultActiveScreenVisibleFrame,
        animationsEnabled: @escaping @MainActor () -> Bool = { SettingsManager.shared.windowAnimation }
    ) {
        self.controller = controller
        self.presenter = presenter
        self.activeScreenVisibleFrame = activeScreenVisibleFrame
        self.animationsEnabled = animationsEnabled

        self.lastAppliedPhase = controller.phase
        self.lastAppliedVisible = controller.isVisible
        self.lastAppliedFocusTrigger = controller.focusTrigger
        self.lastAppliedAuthState = controller.authState

        wirePresenterCallbacks()
        observeControllerState()
    }

    /// Convenience production initializer mounting a SwiftUI root view lazily inside `QuickFloatingPanel`.
    convenience init<Content: View>(
        controller: QuickWorkspaceController,
        activeScreenVisibleFrame: @escaping @MainActor () -> CGRect = QuickPanelController.defaultActiveScreenVisibleFrame,
        animationsEnabled: @escaping @MainActor () -> Bool = { SettingsManager.shared.windowAnimation },
        @ViewBuilder content: @escaping @MainActor () -> Content
    ) {
        let presenter = AppKitQuickPanelPresenter(content: content)
        self.init(
            controller: controller,
            presenter: presenter,
            activeScreenVisibleFrame: activeScreenVisibleFrame,
            animationsEnabled: animationsEnabled
        )
    }

    // MARK: - Intrinsic Bar Height & Window Chrome Actions

    /// Updates the compact `.barOnly` height as the adaptive composer grows or shrinks (`~68–230pt`),
    /// keeping the bottom edge anchored cleanly.
    func updateIntrinsicBarHeight(_ rawHeight: CGFloat) {
        let clamped = QuickPanelLayout.clampBarHeight(rawHeight)
        guard abs(clamped - currentBarHeight) > 0.5 else {
            return
        }
        currentBarHeight = clamped

        guard lastAppliedPhase == .barOnly, lastAppliedAuthState != .signedOut else {
            return
        }

        let visibleFrame = activeScreenVisibleFrame()
        let baseFrame = hasPositionedPanel
            ? presenter.panelFrame
            : QuickPanelLayout.defaultFrame(
                for: .barOnly,
                barHeight: currentBarHeight,
                authState: lastAppliedAuthState,
                in: visibleFrame
            )
        let targetFrame = QuickPanelLayout.bottomAnchoredFrame(
            from: baseFrame,
            targetPhase: .barOnly,
            barHeight: currentBarHeight,
            authState: lastAppliedAuthState,
            in: visibleFrame
        )
        presenter.setFrame(targetFrame, animated: false)
    }

    /// Handles the red Close traffic light button or `Cmd+W`.
    func handleCloseButton() {
        Task { @MainActor [weak self] in
            await self?.controller.closeQuickWindow()
        }
    }

    /// Handles the yellow Minimize traffic light button.
    func handleMinimizeButton() {
        presenter.minimize()
    }

    /// Handles the green Zoom traffic light button in `.expanded` phase.
    func handleZoomButton() {
        guard lastAppliedPhase == .expanded, lastAppliedVisible else {
            return
        }
        isZoomed.toggle()
        let visibleFrame = activeScreenVisibleFrame()
        let targetFrame = QuickPanelLayout.zoomedFrame(
            from: presenter.panelFrame,
            isZoomed: isZoomed,
            in: visibleFrame
        )
        presenter.setFrame(targetFrame, animated: animationsEnabled())
    }

    /// Handles the top-right `+` orb button in `.expanded` phase.
    func handleNewQuickChatButton() {
        Task { @MainActor [weak self] in
            await self?.controller.startFreshQuickChatFromPlusButton()
        }
    }

    // MARK: - Default Screen Resolution

    /// Resolves the visible frame of the screen under the user's pointer, falling back to `NSScreen.main`.
    static func defaultActiveScreenVisibleFrame() -> CGRect {
        let mouseLocation = NSEvent.mouseLocation
        if let pointerScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return pointerScreen.visibleFrame
        }
        if let mainScreen = NSScreen.main {
            return mainScreen.visibleFrame
        }
        return CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    // MARK: - Private Wiring & State Reconciliation

    private func wirePresenterCallbacks() {
        presenter.onResignKey = { [weak self] in
            guard let self, !self.presenter.hasAttachedSheetOrChildPopover else {
                return
            }
            self.controller.handleOutsideFocusLoss()
        }

        presenter.onCloseRequested = { [weak self] in
            self?.handleCloseButton()
        }

        presenter.onEscapeRequested = { [weak self] in
            self?.controller.handleEscapeKey() ?? false
        }
    }

    private func observeControllerState() {
        Publishers.CombineLatest4(
            controller.$phase,
            controller.$isVisible,
            controller.$focusTrigger,
            controller.$authState
        )
        .dropFirst()
        .sink { [weak self] phase, isVisible, focusTrigger, authState in
            self?.reconcile(
                phase: phase,
                isVisible: isVisible,
                focusTrigger: focusTrigger,
                authState: authState
            )
        }
        .store(in: &cancellables)
    }

    private func reconcile(
        phase: QuickPhase,
        isVisible: Bool,
        focusTrigger: Int,
        authState: AuthState
    ) {
        let phaseChanged = phase != lastAppliedPhase
        let visibilityChanged = isVisible != lastAppliedVisible
        let focusChanged = focusTrigger != lastAppliedFocusTrigger
        let signedOutChanged = (authState == .signedOut) != (lastAppliedAuthState == .signedOut)

        lastAppliedPhase = phase
        lastAppliedVisible = isVisible
        lastAppliedFocusTrigger = focusTrigger
        lastAppliedAuthState = authState

        let visibleFrame = activeScreenVisibleFrame()

        if !isVisible {
            if visibilityChanged {
                isZoomed = false
                presenter.hide()
            } else if (phaseChanged || signedOutChanged), hasPositionedPanel {
                isZoomed = false
                let targetFrame = QuickPanelLayout.bottomAnchoredFrame(
                    from: presenter.panelFrame,
                    targetPhase: phase,
                    barHeight: currentBarHeight,
                    authState: authState,
                    in: visibleFrame
                )
                presenter.setFrame(targetFrame, animated: false)
            }
            return
        }

        // Panel is (or just became) visible.
        if visibilityChanged {
            isZoomed = false
            let targetFrame: CGRect
            if !hasPositionedPanel || !visibleFrame.intersects(presenter.panelFrame) {
                targetFrame = QuickPanelLayout.defaultFrame(
                    for: phase,
                    barHeight: currentBarHeight,
                    authState: authState,
                    in: visibleFrame
                )
                hasPositionedPanel = true
            } else {
                targetFrame = QuickPanelLayout.bottomAnchoredFrame(
                    from: presenter.panelFrame,
                    targetPhase: phase,
                    barHeight: currentBarHeight,
                    authState: authState,
                    in: visibleFrame
                )
            }
            presenter.setFrame(targetFrame, animated: false)
            presenter.showAndFocus()
            return
        }

        if phaseChanged || signedOutChanged {
            isZoomed = false
            if phase == .barOnly,
               let activeSession = controller.activeSessionIfLoaded,
               !activeSession.draft.hasUnsentContent {
                currentBarHeight = QuickPanelLayout.defaultBarHeight
            }
            let baseFrame = hasPositionedPanel
                ? presenter.panelFrame
                : QuickPanelLayout.defaultFrame(
                    for: phase,
                    barHeight: currentBarHeight,
                    authState: authState,
                    in: visibleFrame
                )
            hasPositionedPanel = true
            let targetFrame = QuickPanelLayout.bottomAnchoredFrame(
                from: baseFrame,
                targetPhase: phase,
                barHeight: currentBarHeight,
                authState: authState,
                in: visibleFrame
            )
            presenter.setFrame(targetFrame, animated: animationsEnabled())
        }

        if focusChanged {
            presenter.showAndFocus()
        }
    }
}
