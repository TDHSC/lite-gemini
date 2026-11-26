import AppKit
import SwiftUI

// MARK: - ResponseSelectionPillController

/// Manages non-destructive selection capture and a lightweight, non-activating floating
/// Liquid Glass action pill (`[ Quote | Btw ⌘⇧B ]`) anchored `8pt` below mouse-up text
/// selections inside assistant responses.
///
/// Strictly honors the Owner Focus Gate: never calls `NSApp.activate` or `makeKeyAndOrderFront`,
/// presenting the borderless `.nonactivatingPanel` solely via `orderFrontRegardless()`.
@MainActor
final class ResponseSelectionPillController {

    // MARK: - Constants

    nonisolated static let verticalSelectionOffset: CGFloat = 8
    nonisolated static let panelShadowPadding: CGFloat = 10
    nonisolated static let screenEdgeMargin: CGFloat = 8
    nonisolated static let minimumDragSelectionDistance: CGFloat = 3

    // MARK: - Callbacks & Observable State

    var onQuote: ((String) -> Void)?
    var onAskBtw: ((String) -> Void)?

    private(set) var isVisible: Bool = false
    private(set) var currentSelectedText: String?

    // MARK: - Private Tracking State

    private weak var trackedView: NSView?
    private weak var trackedWindow: NSWindow?
    private var trackedScreenBoundsProvider: (() -> CGRect)?

    private var panel: SelectionPillPanel?
    private var localEventMonitor: Any?
    private var notificationObservers: [any NSObjectProtocol] = []
    private var pendingCaptureTask: Task<Void, Never>?

    private var lastMouseDownScreenPoint: CGPoint?
    private var lastMouseDownWindowNumber: Int?
    private var didDragSinceMouseDown: Bool = false

    private let notificationCenter: NotificationCenter

    // MARK: - Initialization

    init(
        onQuote: ((String) -> Void)? = nil,
        onAskBtw: ((String) -> Void)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.onQuote = onQuote
        self.onAskBtw = onAskBtw
        self.notificationCenter = notificationCenter
    }

    isolated deinit {
        detach()
    }

    // MARK: - Non-Destructive Selection Capture

    /// Captures the currently selected text in the active responder without clobbering the user's
    /// clipboard. Reads directly from `NSTextView` when focused, otherwise snapshots
    /// `NSPasteboard.general`, sends `copy:`, reads only if `changeCount` advanced, and restores
    /// the original pasteboard contents verbatim.
    static func captureSelectedTextNonDestructively() -> String? {
        if let textView = NSApp?.keyWindow?.firstResponder as? NSTextView {
            let selectedRange = textView.selectedRange()
            if selectedRange.length > 0 {
                let nsText = textView.string as NSString
                if NSMaxRange(selectedRange) <= nsText.length {
                    let directText = nsText.substring(with: selectedRange)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !directText.isEmpty {
                        return directText
                    }
                }
            }
        }

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let changeCountBefore = pasteboard.changeCount

        _ = NSApp?.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)

        guard pasteboard.changeCount != changeCountBefore else {
            return nil
        }

        let copiedText = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        restorePasteboard(pasteboard, from: snapshot)

        guard let copiedText, !copiedText.isEmpty else {
            return nil
        }
        return copiedText
    }

    // MARK: - Tracking Lifecycle

    /// Attaches selection monitoring to an `NSView` hosting assistant conversation responses.
    func attach(
        to trackedView: NSView,
        onQuote: ((String) -> Void)? = nil,
        onAskBtw: ((String) -> Void)? = nil
    ) {
        detach()
        if let onQuote {
            self.onQuote = onQuote
        }
        if let onAskBtw {
            self.onAskBtw = onAskBtw
        }
        self.trackedView = trackedView
        self.trackedWindow = trackedView.window
        self.trackedScreenBoundsProvider = { [weak trackedView] in
            guard let view = trackedView, let window = view.window else {
                return .zero
            }
            let rectInWindow = view.convert(view.bounds, to: nil)
            return window.convertToScreen(rectInWindow)
        }

        installMonitors(for: trackedView.window)
    }

    /// Attaches selection monitoring to a window using an explicit screen-coordinate bounds closure.
    func attach(
        to window: NSWindow,
        trackedScreenBounds: @escaping () -> CGRect,
        onQuote: ((String) -> Void)? = nil,
        onAskBtw: ((String) -> Void)? = nil
    ) {
        detach()
        if let onQuote {
            self.onQuote = onQuote
        }
        if let onAskBtw {
            self.onAskBtw = onAskBtw
        }
        self.trackedView = nil
        self.trackedWindow = window
        self.trackedScreenBoundsProvider = trackedScreenBounds

        installMonitors(for: window)
    }

    /// Stops all event monitors and notifications and dismisses any visible pill.
    func detach() {
        pendingCaptureTask?.cancel()
        pendingCaptureTask = nil
        dismiss()

        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        for observer in notificationObservers {
            notificationCenter.removeObserver(observer)
        }
        notificationObservers.removeAll()

        trackedView = nil
        trackedWindow = nil
        trackedScreenBoundsProvider = nil
        lastMouseDownScreenPoint = nil
        lastMouseDownWindowNumber = nil
        didDragSinceMouseDown = false
    }

    /// Dismisses the floating selection pill if currently visible.
    func dismiss() {
        pendingCaptureTask?.cancel()
        pendingCaptureTask = nil
        panel?.orderOut(nil)
        isVisible = false
        currentSelectedText = nil
    }

    /// Convenience hook for SwiftUI scroll observers to dismiss the pill immediately on scroll.
    func handleScrollDidOccur() {
        if isVisible || pendingCaptureTask != nil {
            dismiss()
        }
    }

    /// Presents the floating Liquid Glass selection pill `8pt` below `anchorScreenPoint`
    /// without activating the application or stealing key-window focus.
    func show(
        selectedText: String,
        anchorScreenPoint: CGPoint,
        relativeTo window: NSWindow? = nil
    ) {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            dismiss()
            return
        }

        currentSelectedText = trimmed

        let hostWindow = window ?? trackedView?.window ?? trackedWindow
        let resolvedAppearance = hostWindow?.effectiveAppearance ?? NSApp?.effectiveAppearance
        let isDark = resolvedAppearance?.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        let colorScheme: ColorScheme = isDark ? .dark : .light

        let pillView = SelectionActionPillView(
            onQuote: { [weak self] in
                guard let self, let text = self.currentSelectedText else {
                    return
                }
                self.dismiss()
                self.onQuote?(text)
            },
            onAskBtw: { [weak self] in
                guard let self, let text = self.currentSelectedText else {
                    return
                }
                self.dismiss()
                self.onAskBtw?(text)
            }
        )
        .padding(Self.panelShadowPadding)
        .environment(\.colorScheme, colorScheme)

        let hostingView = NSHostingView(rootView: pillView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layoutSubtreeIfNeeded()

        let fittingSize = hostingView.fittingSize
        let panelSize = CGSize(
            width: max(ceil(fittingSize.width), 160),
            height: max(ceil(fittingSize.height), 48)
        )
        let visibleFrame = Self.screenVisibleFrame(containing: anchorScreenPoint, fallbackWindow: hostWindow)
        let targetFrame = Self.pillPanelFrame(
            anchorScreenPoint: anchorScreenPoint,
            panelSize: panelSize,
            shadowPadding: Self.panelShadowPadding,
            verticalOffset: Self.verticalSelectionOffset,
            in: visibleFrame
        )

        let floatingPanel = ensurePanel(initialFrame: targetFrame)
        floatingPanel.appearance = resolvedAppearance
        floatingPanel.contentView = hostingView
        floatingPanel.setFrame(targetFrame, display: true)
        floatingPanel.orderFrontRegardless()
        isVisible = true
    }

    // MARK: - Pure Geometry Helper

    /// Computes the borderless panel frame positioned `verticalOffset` (`8pt`) below `anchorScreenPoint`,
    /// flipping above the anchor if placing below would clip past the bottom edge of `visibleFrame`.
    nonisolated static func pillPanelFrame(
        anchorScreenPoint: CGPoint,
        panelSize: CGSize,
        shadowPadding: CGFloat = ResponseSelectionPillController.panelShadowPadding,
        verticalOffset: CGFloat = ResponseSelectionPillController.verticalSelectionOffset,
        in visibleFrame: CGRect
    ) -> CGRect {
        let visiblePillHeight = max(1, panelSize.height - shadowPadding * 2)
        let idealOriginX = round(anchorScreenPoint.x - panelSize.width / 2)
        let belowVisibleBottomY = anchorScreenPoint.y - verticalOffset - visiblePillHeight
        let belowPanelOriginY = round(belowVisibleBottomY - shadowPadding)

        let minAllowedY = visibleFrame.minY + screenEdgeMargin - shadowPadding
        let maxAllowedY = max(minAllowedY, visibleFrame.maxY - panelSize.height - screenEdgeMargin + shadowPadding)

        let resolvedOriginY: CGFloat
        if belowVisibleBottomY < visibleFrame.minY + screenEdgeMargin {
            let aboveVisibleBottomY = anchorScreenPoint.y + verticalOffset
            let abovePanelOriginY = round(aboveVisibleBottomY - shadowPadding)
            resolvedOriginY = min(max(abovePanelOriginY, minAllowedY), maxAllowedY)
        } else {
            resolvedOriginY = min(max(belowPanelOriginY, minAllowedY), maxAllowedY)
        }

        let minAllowedX = visibleFrame.minX + screenEdgeMargin - shadowPadding
        let maxAllowedX = max(minAllowedX, visibleFrame.maxX - panelSize.width - screenEdgeMargin + shadowPadding)
        let resolvedOriginX = min(max(idealOriginX, minAllowedX), maxAllowedX)

        return CGRect(
            x: resolvedOriginX,
            y: resolvedOriginY,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    // MARK: - Private Event & Notification Monitoring

    private func installMonitors(for window: NSWindow?) {
        let eventMask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp,
            .rightMouseDown,
            .scrollWheel,
            .keyDown
        ]

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            guard let self else {
                return event
            }
            return self.handleLocalEvent(event)
        }

        let appResignObserver = notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
        notificationObservers.append(appResignObserver)

        let targetWindow = window ?? trackedView?.window
        let dismissNotifications: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.willCloseNotification
        ]
        for name in dismissNotifications {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: targetWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dismiss()
                }
            }
            notificationObservers.append(observer)
        }
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            if let panel, event.window === panel {
                return event
            }
            if isVisible {
                dismiss()
            }
            if let eventWindow = event.window {
                lastMouseDownScreenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
                lastMouseDownWindowNumber = eventWindow.windowNumber
                didDragSinceMouseDown = false
            } else {
                lastMouseDownScreenPoint = nil
                lastMouseDownWindowNumber = nil
                didDragSinceMouseDown = false
            }
            return event

        case .leftMouseDragged:
            if let start = lastMouseDownScreenPoint,
               let eventWindow = event.window,
               eventWindow.windowNumber == lastMouseDownWindowNumber {
                let current = eventWindow.convertPoint(toScreen: event.locationInWindow)
                let distance = hypot(current.x - start.x, current.y - start.y)
                if distance >= Self.minimumDragSelectionDistance {
                    didDragSinceMouseDown = true
                }
            }
            return event

        case .leftMouseUp:
            if let panel, event.window === panel {
                return event
            }
            handleLeftMouseUp(event)
            return event

        case .rightMouseDown, .scrollWheel:
            if isVisible || pendingCaptureTask != nil {
                dismiss()
            }
            return event

        case .keyDown:
            if isVisible {
                if event.keyCode == 53 { // Escape
                    dismiss()
                    return nil
                }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let key = event.charactersIgnoringModifiers?.lowercased()
                let isQuoteOrBtwShortcut = modifiers == [.command, .shift] && (key == "'" || key == "\"" || key == "b")
                if !isQuoteOrBtwShortcut {
                    dismiss()
                }
            }
            return event

        default:
            return event
        }
    }

    private func handleLeftMouseUp(_ event: NSEvent) {
        let shouldProbeSelection = didDragSinceMouseDown || event.clickCount >= 2
        let dragStartPoint = lastMouseDownScreenPoint
        lastMouseDownScreenPoint = nil
        lastMouseDownWindowNumber = nil
        didDragSinceMouseDown = false

        guard shouldProbeSelection else {
            dismiss()
            return
        }

        guard let eventWindow = event.window,
              let resolvedTrackedWindow = trackedView?.window ?? trackedWindow,
              eventWindow === resolvedTrackedWindow else {
            dismiss()
            return
        }

        // Never surface the response quote pill for selections inside editable composer/text fields.
        if isEditableTextInputEvent(event, in: eventWindow) {
            dismiss()
            return
        }

        let releaseScreenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
        let trackedBounds = trackedScreenBoundsProvider?() ?? .zero
        guard !trackedBounds.isEmpty, trackedBounds.contains(releaseScreenPoint) else {
            dismiss()
            return
        }

        // Anchor horizontally at the midpoint of the drag (when available) and vertically at the
        // lowest edge of the selection so the pill sits cleanly 8pt below the highlighted text.
        let anchorPoint: CGPoint
        if let start = dragStartPoint, trackedBounds.contains(start) {
            anchorPoint = CGPoint(
                x: (start.x + releaseScreenPoint.x) / 2,
                y: min(start.y, releaseScreenPoint.y)
            )
        } else {
            anchorPoint = releaseScreenPoint
        }

        pendingCaptureTask?.cancel()
        pendingCaptureTask = Task { @MainActor [weak self, weak eventWindow] in
            // Yield one turn so AppKit / SwiftUI finishes committing the mouse-up text selection.
            await Task.yield()
            guard let self, !Task.isCancelled else {
                return
            }
            guard let window = eventWindow, window.isKeyWindow else {
                self.dismiss()
                return
            }
            if let textView = window.firstResponder as? NSTextView, textView.isEditable {
                self.dismiss()
                return
            }
            guard let selected = Self.captureSelectedTextNonDestructively(), !selected.isEmpty else {
                self.dismiss()
                return
            }
            self.show(
                selectedText: selected,
                anchorScreenPoint: anchorPoint,
                relativeTo: window
            )
        }
    }

    private func isEditableTextInputEvent(_ event: NSEvent, in window: NSWindow) -> Bool {
        if let hitView = window.contentView?.hitTest(event.locationInWindow) {
            var cursor: NSView? = hitView
            while let current = cursor {
                if let textView = current as? NSTextView, textView.isEditable {
                    return true
                }
                if let textField = current as? NSTextField, textField.isEditable {
                    return true
                }
                cursor = current.superview
            }
        }
        return false
    }

    private func ensurePanel(initialFrame: CGRect) -> SelectionPillPanel {
        if let panel {
            return panel
        }
        let created = SelectionPillPanel(contentRect: initialFrame)
        self.panel = created
        return created
    }

    private static func screenVisibleFrame(
        containing point: CGPoint,
        fallbackWindow: NSWindow?
    ) -> CGRect {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return screen.visibleFrame
        }
        if let windowScreen = fallbackWindow?.screen {
            return windowScreen.visibleFrame
        }
        if let mainScreen = NSScreen.main {
            return mainScreen.visibleFrame
        }
        return CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    // MARK: - Pasteboard Snapshot & Restore

    private struct PasteboardItemSnapshot {
        let entries: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return []
        }
        var snapshots: [PasteboardItemSnapshot] = []
        snapshots.reserveCapacity(items.count)

        for item in items {
            var entries: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    entries.append((type: type, data: data))
                }
            }
            if !entries.isEmpty {
                snapshots.append(PasteboardItemSnapshot(entries: entries))
            }
        }
        return snapshots
    }

    private static func restorePasteboard(
        _ pasteboard: NSPasteboard,
        from snapshots: [PasteboardItemSnapshot]
    ) {
        pasteboard.clearContents()
        guard !snapshots.isEmpty else {
            return
        }
        let restoredItems: [NSPasteboardItem] = snapshots.compactMap { snapshot in
            guard !snapshot.entries.isEmpty else {
                return nil
            }
            let item = NSPasteboardItem()
            for entry in snapshot.entries {
                item.setData(entry.data, forType: entry.type)
            }
            return item
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

// MARK: - SelectionPillPanel

/// Borderless, transparent, non-activating floating `NSPanel` that never steals key or main
/// window focus when surfaced over an active text selection.
@MainActor
private final class SelectionPillPanel: NSPanel {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
    }
}

// MARK: - SelectionActionPillView

/// Compact floating Liquid Glass toolbar pill (`[ Quote | Btw ⌘⇧B ]`) hosted inside `SelectionPillPanel`.
private struct SelectionActionPillView: View {

    let onQuote: () -> Void
    let onAskBtw: () -> Void

    @State private var isHoveringQuote: Bool = false
    @State private var isHoveringBtw: Bool = false

    var body: some View {
        LiquidGlassContainer(spacing: 4) {
            HStack(spacing: 2) {
                Button(action: onQuote) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrowshape.turn.up.left")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(isHoveringQuote ? 0.96 : 0.78))

                        Text("Quote")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(isHoveringQuote ? 0.98 : 0.88))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isHoveringQuote ? LiquidGlassColors.hoverHighlight : Color.clear)
                    )
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHoveringQuote = hovering
                    }
                }
                .help(String(localized: "Quote in Reply"))
                .accessibilityLabel(Text("Quote"))

                Rectangle()
                    .fill(LiquidGlassColors.subtleHairline)
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)

                Button(action: onAskBtw) {
                    HStack(spacing: 5) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LiquidGlassColors.tempActiveAccent)

                        Text("Btw")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(isHoveringBtw ? 0.98 : 0.88))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Text(verbatim: "⌘⇧B")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isHoveringBtw ? LiquidGlassColors.hoverHighlight : Color.clear)
                    )
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHoveringBtw = hovering
                    }
                }
                .help(String(localized: "Ask in Btw"))
                .accessibilityLabel(Text("Btw"))
            }
            .padding(3)
            .glassCapsule(variant: .regular, interactive: true)
        }
    }
}
