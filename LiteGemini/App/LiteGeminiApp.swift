import SwiftUI
import WebKit
import Sparkle

@main
struct LiteGeminiApp: App {
    // Use StateObject to persist the lifecycle even when the window is closed
    @StateObject private var webViewModel = ClassicWebViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: webViewModel)
        }
        .windowStyle(.hiddenTitleBar)
        // The web view has no ideal size, so give first launch an explicit one;
        // a saved frame still wins after that
        .defaultSize(width: 800, height: 600)
        .commands {
            // Cmd+Q: quit, or hide to the background when the user keeps the app running.
            // Replacing the menu item instead of vetoing applicationShouldTerminate keeps
            // logout, shutdown, Sparkle relaunches and `quit app` requests working.
            CommandGroup(replacing: .appTermination) {
                QuitCommand()
            }
            // Cmd+W: close settings window when focused; hide app when main window is focused
            CommandGroup(replacing: .saveItem) {
                Button("Close Window") {
                    if let keyWindow = NSApp.keyWindow {
                        if keyWindow.delegate is AppDelegate {
                            WindowVisibility.shared.hide()
                        } else {
                            keyWindow.close()
                        }
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            // Interface mode switch (when enabled), Cmd+R to reload, Cmd+[ / Cmd+] for
            // navigation, added to the system View menu (CommandMenu("View") would create a second View menu)
            CommandGroup(before: .toolbar) {
                InterfaceModeCommands()

                Button("Reload Page") {
                    webViewModel.webView.reload()
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Go Back") {
                    webViewModel.webView.goBack()
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Go Forward") {
                    webViewModel.webView.goForward()
                }
                .keyboardShortcut("]", modifiers: .command)

                Divider()
            }
        }

        // Standard macOS settings window, opened with Cmd+,
        Settings {
            SettingsView(updater: appDelegate.updaterController.updater)
        }
    }
}

/// View-menu items for switching between Native Liquid Glass and Classic Web Mode (⌘⇧M)
private struct InterfaceModeCommands: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        if settings.enableNativeUI {
            if settings.interfaceMode == .native {
                Toggle("Native Liquid Glass", isOn: Binding(
                    get: { true },
                    set: { _ in settings.interfaceMode = .native }
                ))
                Toggle("Classic Web Mode", isOn: Binding(
                    get: { false },
                    set: { _ in settings.interfaceMode = .web }
                ))
                .keyboardShortcut("m", modifiers: [.command, .shift])
            } else {
                Toggle("Native Liquid Glass", isOn: Binding(
                    get: { false },
                    set: { _ in settings.interfaceMode = .native }
                ))
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Toggle("Classic Web Mode", isOn: Binding(
                    get: { true },
                    set: { _ in settings.interfaceMode = .web }
                ))
            }

            Divider()
        }
    }
}

/// Cmd+Q menu item; observes the setting so the item updates when it changes
private struct QuitCommand: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        if settings.keepRunningInBackground {
            Button("Hide to Background") {
                WindowVisibility.shared.hide()
            }
            .keyboardShortcut("q", modifiers: .command)
        } else {
            Button("Quit Lite Gemini") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
