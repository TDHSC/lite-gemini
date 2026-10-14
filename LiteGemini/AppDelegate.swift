import SwiftUI
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Sparkle updater controller, initialized at app launch
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    /// Adaptive surface color matching Gemini's dark (#131314) and light (#FFFFFF) themes
    static let geminiSurfaceNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        return isDark
            ? NSColor(srgbRed: 0x13 / 255.0, green: 0x13 / 255.0, blue: 0x14 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
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
            // Pick the main window, not any key window: a popup could otherwise be
            // brought forward instead of the main window
            if let window = sender.windows.first(where: { $0.delegate is AppDelegate }) {
                window.makeKeyAndOrderFront(nil)
                return false
            }
            return true
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
