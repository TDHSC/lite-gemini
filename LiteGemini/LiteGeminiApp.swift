import SwiftUI
import WebKit
import Sparkle

@main
struct LiteGeminiApp: App {
    // Use StateObject to persist the lifecycle even when the window is closed
    @StateObject private var webViewModel = WebViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: webViewModel)
        }
        .windowStyle(.hiddenTitleBar)
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
            // Global Cmd+R to reload, Cmd+[ / Cmd+] for navigation
            CommandMenu("View") {
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
            }
        }

        // Standard macOS settings window, opened with Cmd+,
        Settings {
            SettingsView(updater: appDelegate.updaterController.updater)
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
