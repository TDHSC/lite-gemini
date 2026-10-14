import SwiftUI
import Sparkle
import Combine
import WebKit

/// SwiftUI wrapper for Sparkle's "Check for Updates" button
/// Follows Sparkle's officially recommended SwiftUI integration approach
struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

/// Observes the Sparkle updater's canCheckForUpdates state
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private var cancellable: Any?

    init(updater: SPUUpdater) {
        // Use KVO to observe canCheckForUpdates property changes
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .assign(to: \.canCheckForUpdates, on: self)
    }
}

/// Settings view organized into clean macOS toolbar tabs (General, Shortcuts, Advanced, About)
struct SettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @FocusState private var isUAFieldFocused: Bool
    @State private var isEditingUA = false
    @State private var showRestartHint = false
    @State private var showClearDataConfirmation = false
    @State private var showClearDataSuccess = false
    @State private var isClearingData = false

    /// Sparkle updater instance, injected from parent
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
    }

    /// Track whether the UA has been customized (differs from default)
    private var isCustomUA: Bool {
        settings.userAgent != settings.defaultUserAgent
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            shortcutsTab
                .tabItem {
                    Label("Shortcuts", systemImage: "command")
                }

            advancedTab
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "sparkles")
                }
        }
        .frame(width: 480, height: 380)
        .onAppear {
            // Delay one frame to dismiss auto-focus on appearance
            DispatchQueue.main.async {
                isUAFieldFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)

                // If always-on-top is enabled, elevate the settings window to floating level
                if settings.alwaysOnTop, let settingsWindow = NSApp.keyWindow {
                    settingsWindow.level = .floating
                }
            }
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                Toggle("Always on Top", isOn: $settings.alwaysOnTop)
                Toggle("Window Animation", isOn: $settings.windowAnimation)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Keep Running in Background", isOn: $settings.keepRunningInBackground)
                    Text("Closing the window or pressing ⌘Q hides Lite Gemini and its Dock icon instead of quitting. Open Lite Gemini again or press the show/hide shortcut to bring it back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("New Chats Start as Temporary Chats", isOn: $settings.defaultTemporaryChat)
                    Text("Lite Gemini turns on Gemini's temporary chat whenever a new chat opens. If you turn it off in a chat, it stays off until the next new chat.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Background Timeout", selection: $settings.backgroundTimeout) {
                    ForEach(BackgroundTimeoutPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
            }

            Section {
                Picker("Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .onChange(of: settings.language) {
                    showRestartHint = true
                }

                if showRestartHint {
                    Text("Language change takes effect after restarting the app")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
        Form {
            Section {
                HotKeyRecorderView(
                    label: "Show/Hide Window",
                    hotKey: $settings.customHotKey,
                    defaultHotKey: .defaultHotKey
                )

                HotKeyRecorderView(
                    label: "New Chat",
                    hotKey: $settings.newChatHotKey,
                    defaultHotKey: .newChatDefaultHotKey
                )
            } footer: {
                Text("Click a shortcut capsule to record a new key combination, or press Esc to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Advanced Tab

    private var advancedTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("User-Agent")
                            .fontWeight(.medium)
                        Spacer()
                        if isCustomUA {
                            Button("Reset to Default") {
                                settings.userAgent = settings.defaultUserAgent
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                        if isEditingUA {
                            Button("Done") {
                                isEditingUA = false
                            }
                            .font(.caption)
                            .fontWeight(.medium)
                            .buttonStyle(.borderless)
                        } else {
                            Button("Edit") {
                                isEditingUA = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    isUAFieldFocused = true
                                }
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                    }

                    if isEditingUA {
                        TextEditor(text: $settings.userAgent)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 64)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                            )
                            .focused($isUAFieldFocused)

                        Text("Changes take effect after refreshing (Cmd+R)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(settings.userAgent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.03))
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                isEditingUA = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    isUAFieldFocused = true
                                }
                            }
                    }
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear Browsing Data")
                        Text("Remove cookies, cache and local storage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if showClearDataSuccess {
                        Label("Cleared", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    Button(role: .destructive) {
                        showClearDataConfirmation = true
                    } label: {
                        Text("Clear Data")
                    }
                    .disabled(isClearingData)
                }
                .confirmationDialog(
                    "Are you sure you want to clear all browsing data?",
                    isPresented: $showClearDataConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Clear Data", role: .destructive) {
                        clearBrowsingData()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will remove cookies, cache and local storage. You will need to sign in again.")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: 48, height: 48)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                            )

                        MonochromeSparkShape()
                            .fill(Color.primary.opacity(0.82))
                            .frame(width: 20, height: 20)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lite Gemini")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Version \(appVersion)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Auto Check for Updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))

                HStack {
                    Text("Check for Updates")
                    Spacer()
                    CheckForUpdatesView(updater: updater)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    /// Read version number from Bundle
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// Clear all browsing data (cookies, cache, localStorage) and notify WebView to reload
    private func clearBrowsingData() {
        isClearingData = true
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            dataStore.removeData(
                ofTypes: dataTypes,
                for: records
            ) {
                DispatchQueue.main.async {
                    isClearingData = false
                    withAnimation {
                        showClearDataSuccess = true
                    }
                    // Hide success indicator after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation {
                            showClearDataSuccess = false
                        }
                    }
                    // Notify WebViewModel to reload the page
                    NotificationCenter.default.post(name: .browsingDataCleared, object: nil)
                }
            }
        }
    }
}
