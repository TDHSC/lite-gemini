import SwiftUI
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Sparkle updater controller; lazy so it can pass self as the user driver delegate.
    /// applicationWillFinishLaunching creates it at the latest, which starts the updater.
    private(set) lazy var updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)

    /// A scheduled check found an update while the app was hidden; show it when the user comes back
    private var hasDeferredUpdate = false

    /// Adaptive surface color matching Gemini's dark (#131314) and light (#FFFFFF) themes
    static let geminiSurfaceNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        return isDark
            ? NSColor(srgbRed: 0x13 / 255.0, green: 0x13 / 255.0, blue: 0x14 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = updaterController
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register global hotkeys
        HotKeyManager.shared.register()

        // Delay one frame to configure delegate and window appearance after SwiftUI creates the main window
        DispatchQueue.main.async {
            self.configureMainWindow()
            // Restore window always-on-top state
            SettingsManager.shared.updateWindowLevel()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            return true
        } else {
            // Show the main window, not any key window: a popup could otherwise be
            // brought forward instead of the main window
            if sender.windows.contains(where: { $0.delegate is AppDelegate }) {
                WindowVisibility.shared.show()
                return false
            }
            return true
        }
    }

    /// Every way back into the app (reopening it, the hotkey, a notification) brings back
    /// the Dock icon and menu bar that hiding to the background removed
    func applicationWillBecomeActive(_ notification: Notification) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard hasDeferredUpdate else { return }
        // Wait for the main window to come forward so the update alert lands on top of it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard self.hasDeferredUpdate, NSApp.isActive else { return }
            // Brings the already-found update into focus
            self.updaterController.checkForUpdates(nil)
        }
    }

    // MARK: - NSWindowDelegate

    /// Intercept window close event: hide the app instead of destroying it to preserve WebView lifecycle
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        WindowVisibility.shared.hide()
        return false
    }

    // MARK: - Private Methods

    /// Find the main window, set AppDelegate as its delegate, and make its titlebar seamlessly blend with Gemini
    private func configureMainWindow() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeKey }) else { return }
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.backgroundColor = Self.geminiSurfaceNSColor
        window.toolbar = nil
    }
}

// MARK: - SPUStandardUserDriverDelegate

/// Gentle update reminders: a scheduled check that finds an update while the app is hidden
/// would otherwise pop the app up from the background. Hold the alert until the user brings
/// the app back instead.
extension AppDelegate: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        !NSApp.isHidden
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate {
            hasDeferredUpdate = true
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        hasDeferredUpdate = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        hasDeferredUpdate = false
    }
}
