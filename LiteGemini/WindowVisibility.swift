import Cocoa

/// Single show/hide path for the main window, shared by the close button, Cmd+W
/// and the global hotkeys.
class WindowVisibility {
    static let shared = WindowVisibility()

    /// Prevent repeated triggers during animation
    private(set) var isAnimating = false

    /// Animation duration (seconds), no more than 200ms
    private let animationDuration: TimeInterval = 0.15

    private init() {}

    /// Whether the app is in the foreground with a visible window
    var isShown: Bool {
        NSApp.windows.contains { $0.isVisible } && NSApp.isActive
    }

    /// Show the main window with a fade-in animation
    /// - Parameter completion: optional callback after activation completes
    func show(completion: (@MainActor () -> Void)? = nil) {
        let useAnimation = SettingsManager.shared.windowAnimation

        NSApp.activate(ignoringOtherApps: true)

        for window in NSApp.windows where window.delegate is AppDelegate {
            if useAnimation {
                // Set fully transparent first, then fade in
                window.alphaValue = 0
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()

            if useAnimation {
                isAnimating = true
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = animationDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().alphaValue = 1.0
                }, completionHandler: { [weak self] in
                    // AppKit calls the completion handler on the main thread
                    MainActor.assumeIsolated {
                        self?.isAnimating = false
                        completion?()
                    }
                })
            } else {
                window.alphaValue = 1.0
                completion?()
            }
        }
    }

    /// Hide the app with a fade-out animation instead of closing the window, preserving the WebView
    func hide() {
        guard !isAnimating else { return }
        let windows = NSApp.windows.filter { $0.delegate is AppDelegate && $0.isVisible }

        guard SettingsManager.shared.windowAnimation, !windows.isEmpty else {
            NSApp.hide(nil)
            return
        }

        isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windows {
                window.animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            // AppKit calls the completion handler on the main thread
            MainActor.assumeIsolated {
                NSApp.hide(nil)
                // Restore alphaValue for the next show
                for window in windows {
                    window.alphaValue = 1.0
                }
                self?.isAnimating = false
            }
        })
    }
}
