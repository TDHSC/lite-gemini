import SwiftUI
import Carbon

/// Sleek capsule hotkey recorder with individual keycap badges (Raycast / CleanShot style).
/// Click the capsule to record a new shortcut; includes compact inline clear and reset actions.
struct HotKeyRecorderView: View {
    let label: String
    @Binding var hotKey: CustomHotKey?
    let defaultHotKey: CustomHotKey

    @State private var isRecording = false
    @State private var isHovering = false
    @State private var eventMonitor: Any?

    /// Discrete keycap tokens for the current hotkey (e.g. ["⌘", "⇧", "N"])
    private var keyTokens: [String] {
        guard let hk = hotKey else { return [] }
        var tokens: [String] = []
        if hk.modifiers & UInt32(controlKey) != 0 { tokens.append("⌃") }
        if hk.modifiers & UInt32(optionKey) != 0  { tokens.append("⌥") }
        if hk.modifiers & UInt32(shiftKey) != 0   { tokens.append("⇧") }
        if hk.modifiers & UInt32(cmdKey) != 0     { tokens.append("⌘") }
        tokens.append(CustomHotKey.keyName(for: hk.keyCode))
        return tokens
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(label))

            Spacer()

            // Reset button (only visible when modified from default and not recording)
            if !isRecording && hotKey != defaultHotKey {
                Button {
                    hotKey = defaultHotKey
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help(String(localized: "Reset to Default"))
            }

            // Interactive recorder pill
            HStack(spacing: 5) {
                if isRecording {
                    Circle()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 5, height: 5)
                    Text(String(localized: "Press a key combination…"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 2)
                } else if !keyTokens.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(Array(keyTokens.enumerated()), id: \.offset) { _, token in
                            Text(token)
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.primary.opacity(0.88))
                                .frame(minWidth: 19, minHeight: 19)
                                .padding(.horizontal, token.count > 1 ? 5 : 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                        .fill(Color.primary.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                                )
                        }
                    }

                    // Inline clear button
                    Button {
                        hotKey = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 2)
                    .help(String(localized: "Clear"))
                } else {
                    Text(String(localized: "Record"))
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isRecording ? 0.09 : (isHovering ? 0.06 : 0.035)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(isRecording ? 0.45 : (isHovering ? 0.22 : 0.12)),
                        lineWidth: isRecording ? 1.2 : 0.8
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onTapGesture {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }
        }
        .onDisappear {
            // Ensure monitoring stops when the view disappears
            stopRecording()
        }
    }

    // MARK: - Recording Control

    /// Start recording: install local event monitor
    private func startRecording() {
        // Unregister current hotkey first to avoid interception during recording
        HotKeyManager.shared.reRegister(enabled: false)

        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleKeyEvent(event)
            return nil // Consume the event, do not propagate
        }
    }

    /// Stop recording: remove event monitor
    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        // Re-register the current hotkey
        HotKeyManager.shared.reRegister(enabled: true)
    }

    /// Handle captured key event
    private func handleKeyEvent(_ event: NSEvent) {
        // Esc cancels recording
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        // Convert Cocoa NSEvent.ModifierFlags to Carbon modifier mask
        let carbonModifiers = cocoaToCarbonModifiers(event.modifierFlags)

        // Must contain at least one modifier key
        guard carbonModifiers != 0 else { return }

        let newHotKey = CustomHotKey(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers
        )

        guard newHotKey.isValid else { return }

        // Update the binding (automatically triggers HotKeyManager.reRegister via didSet)
        hotKey = newHotKey
        stopRecording()
    }

    /// Convert Cocoa NSEvent.ModifierFlags to Carbon modifier mask
    private func cocoaToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }
}
