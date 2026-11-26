import Cocoa
import Carbon

/// Hotkey ID constants for distinguishing multiple global hotkeys
private enum HotKeyIDs {
    static let showHide: UInt32 = 1
    static let newChat: UInt32 = 2
    static let quickNew: UInt32 = 3
    static let quickRecent: UInt32 = 4
    static let signature: OSType = OSType(0x53574654)
}

/// Global hotkey callback function conforming to @convention(c).
/// Nonisolated so it can be passed as a C function pointer; the actual work hops to the main actor.
nonisolated private func hotKeyHandler(nextHandler: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event = event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr else { return status }

    DispatchQueue.main.async {
        switch hotKeyID.id {
        case HotKeyIDs.showHide:
            HotKeyManager.shared.onHotKeyPressed()
        case HotKeyIDs.newChat:
            HotKeyManager.shared.onNewChatHotKeyPressed()
        case HotKeyIDs.quickNew:
            HotKeyManager.shared.onQuickNewHotKeyPressed()
        case HotKeyIDs.quickRecent:
            HotKeyManager.shared.onQuickRecentHotKeyPressed()
        default:
            break
        }
    }
    return noErr
}

class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var newChatHotKeyRef: EventHotKeyRef?
    private var quickNewHotKeyRef: EventHotKeyRef?
    private var quickRecentHotKeyRef: EventHotKeyRef?
    /// Event handler only needs to be installed once
    private var handlerInstalled = false

    /// Handler invoked when the New Quick Chat global hotkey (`⌥Space`) fires while Native UI is enabled.
    @MainActor var onQuickNewHotKey: (@MainActor () -> Void)?

    /// Handler invoked when the Recent Quick Chat global hotkey (`⌥⇧Space`) fires while Native UI is enabled.
    @MainActor var onQuickRecentHotKey: (@MainActor () -> Void)?

    private init() {}

    /// Register hotkeys on initial launch
    func register() {
        installHandlerIfNeeded()
        registerCurrentHotKey()
        registerNewChatHotKey()
        registerQuickNewHotKey()
        registerQuickRecentHotKey()
    }

    /// Re-register hotkeys (called when settings change)
    /// - Parameter enabled: when false, only unregister without re-registering (recording mode)
    func reRegister(enabled: Bool = true) {
        unregisterHotKey()
        unregisterNewChatHotKey()
        unregisterQuickNewHotKey()
        unregisterQuickRecentHotKey()
        if enabled {
            registerCurrentHotKey()
            registerNewChatHotKey()
            registerQuickNewHotKey()
            registerQuickRecentHotKey()
        }
    }

    // MARK: - Private Methods

    /// Install Carbon event handler (only once)
    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventType, nil, nil)
        
        if status != noErr {
            print("Failed to install event handler: \(status)")
        } else {
            handlerInstalled = true
        }
    }

    /// Register show/hide hotkey based on current settings
    private func registerCurrentHotKey() {
        guard let hotKey = SettingsManager.shared.customHotKey else {
            print("Global hotkey disabled, skipping registration")
            return
        }
        let hotKeyID = EventHotKeyID(signature: HotKeyIDs.signature, id: HotKeyIDs.showHide)
        
        let regStatus = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if regStatus != noErr {
            print("Failed to register hotkey: \(regStatus)")
        } else {
            print("Global hotkey \(hotKey.displayName) registered successfully")
        }
    }

    /// Register new-chat hotkey based on current settings
    private func registerNewChatHotKey() {
        guard let hotKey = SettingsManager.shared.newChatHotKey else {
            print("New-chat hotkey disabled, skipping registration")
            return
        }
        let hotKeyID = EventHotKeyID(signature: HotKeyIDs.signature, id: HotKeyIDs.newChat)

        let regStatus = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newChatHotKeyRef
        )

        if regStatus != noErr {
            print("Failed to register new-chat hotkey: \(regStatus)")
        } else {
            print("New-chat hotkey \(hotKey.displayName) registered successfully")
        }
    }

    /// Register Quick Mode new-chat hotkey based on current settings
    private func registerQuickNewHotKey() {
        guard SettingsManager.shared.enableNativeUI else {
            return
        }
        guard let hotKey = SettingsManager.shared.quickNewHotKey else {
            print("Quick Mode new-chat hotkey disabled, skipping registration")
            return
        }
        let hotKeyID = EventHotKeyID(signature: HotKeyIDs.signature, id: HotKeyIDs.quickNew)

        let regStatus = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &quickNewHotKeyRef
        )

        if regStatus != noErr {
            print("Failed to register Quick Mode new-chat hotkey: \(regStatus)")
        } else {
            print("Quick Mode new-chat hotkey \(hotKey.displayName) registered successfully")
        }
    }

    /// Register Quick Mode recent-chat hotkey based on current settings
    private func registerQuickRecentHotKey() {
        guard SettingsManager.shared.enableNativeUI else {
            return
        }
        guard let hotKey = SettingsManager.shared.quickRecentHotKey else {
            print("Quick Mode recent-chat hotkey disabled, skipping registration")
            return
        }
        let hotKeyID = EventHotKeyID(signature: HotKeyIDs.signature, id: HotKeyIDs.quickRecent)

        let regStatus = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &quickRecentHotKeyRef
        )

        if regStatus != noErr {
            print("Failed to register Quick Mode recent-chat hotkey: \(regStatus)")
        } else {
            print("Quick Mode recent-chat hotkey \(hotKey.displayName) registered successfully")
        }
    }

    /// Unregister the show/hide hotkey
    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    /// Unregister the new-chat hotkey
    private func unregisterNewChatHotKey() {
        if let ref = newChatHotKeyRef {
            UnregisterEventHotKey(ref)
            newChatHotKeyRef = nil
        }
    }

    /// Unregister the Quick Mode new-chat hotkey
    private func unregisterQuickNewHotKey() {
        if let ref = quickNewHotKeyRef {
            UnregisterEventHotKey(ref)
            quickNewHotKeyRef = nil
        }
    }

    /// Unregister the Quick Mode recent-chat hotkey
    private func unregisterQuickRecentHotKey() {
        if let ref = quickRecentHotKeyRef {
            UnregisterEventHotKey(ref)
            quickRecentHotKeyRef = nil
        }
    }

    // MARK: - HotKey Dispatch

    func onHotKeyPressed() {
        let visibility = WindowVisibility.shared
        // If animation is in progress, ignore this trigger
        guard !visibility.isAnimating else { return }

        if visibility.isShown {
            // App is in the foreground with visible windows → hide
            visibility.hide()
        } else {
            // Otherwise (background / window not visible) → activate and show
            visibility.show()
        }
    }

    /// Handle new-chat hotkey: activate the window, then ask WebViewModel for a new chat
    func onNewChatHotKeyPressed() {
        let visibility = WindowVisibility.shared
        guard !visibility.isAnimating else { return }

        if visibility.isShown {
            // Window is already visible, request a new chat directly
            NotificationCenter.default.post(name: .newChatRequested, object: nil)
        } else {
            // Activate and show window first, then request a new chat
            visibility.show {
                // Delay slightly to ensure the window and WebView are fully ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NotificationCenter.default.post(name: .newChatRequested, object: nil)
                }
            }
        }
    }

    /// Handle Quick Mode new-chat hotkey (`⌥Space`) when Native UI is enabled.
    func onQuickNewHotKeyPressed() {
        guard SettingsManager.shared.enableNativeUI else { return }
        onQuickNewHotKey?()
    }

    /// Handle Quick Mode recent-chat hotkey (`⌥⇧Space`) when Native UI is enabled.
    func onQuickRecentHotKeyPressed() {
        guard SettingsManager.shared.enableNativeUI else { return }
        onQuickRecentHotKey?()
    }
}
