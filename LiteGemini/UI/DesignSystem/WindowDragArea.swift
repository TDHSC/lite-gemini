import AppKit
import SwiftUI

/// Native NSView that enables dragging the window from the seamless top titlebar band
/// and supports standard macOS double-click to zoom.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableTitleBarView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableTitleBarView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            if event.clickCount == 2 {
                window?.performZoom(nil)
            }
        }
    }
}
