import Foundation
import os
import WebKit

/// Synchronizes Gemini's temporary-chat toggle across both Luminous (`lr26`) and legacy DOMs.
///
/// Temporary chat has no URL — it is Gemini router state — so the only lever is inspecting
/// and clicking Gemini's own toggle element (`<temp-chat-button>`).
@MainActor
final class TemporaryChatController {

    // MARK: - Types

    private enum ProbeMode: String {
        case read
        case enable
        case disable
    }

    // MARK: - Scripts

    /// Page script, injected at document start in the main frame only. It reports the
    /// page's own new-chat interactions to the `temporaryChatIntent` message handler.
    /// Only trusted events are reported, so the app's own synthetic events and page
    /// scripts cannot trigger it.
    nonisolated static let intentScriptSource: String = {
        let selectorsJSON = encodeJSONStringArray(GeminiBridgeSelectors.ComposerDOM.newChatTrigger.all)
        return """
        (function() {
            var host = (window.location && window.location.hostname ? window.location.hostname : '').toLowerCase();
            if (window.opener || (host && host !== 'gemini.google.com')) return;
            if (window.__tempChatIntentInstalled) return;
            window.__tempChatIntentInstalled = true;
            var NEW_CHAT_SELECTORS = \(selectorsJSON);
            function post() {
                try {
                    window.webkit.messageHandlers.temporaryChatIntent.postMessage('newChat');
                } catch (e) {}
            }
            document.addEventListener('click', function(event) {
                if (!event.isTrusted) return;
                var target = event.target;
                if (!target || !target.closest) return;
                for (var i = 0; i < NEW_CHAT_SELECTORS.length; i++) {
                    try {
                        if (target.closest(NEW_CHAT_SELECTORS[i])) {
                            post();
                            return;
                        }
                    } catch (e) {}
                }
            }, true);
            document.addEventListener('keydown', function(event) {
                if (!event.isTrusted) return;
                if (event.metaKey && event.shiftKey && !event.altKey && !event.ctrlKey
                    && event.key && event.key.toLowerCase() === 'o') {
                    post();
                }
            }, true);
        })();
        """
    }()

    /// Function body invoked via `WKWebView.callAsyncJavaScript` to inspect or toggle temporary chat.
    /// Supports both Luminous (`fonticon="close"` / `data-mat-icon-name="close"`) and legacy
    /// (`.temp-chat-on`) DOM trees without relying on localized labels.
    private nonisolated static let probeFunctionBody = """
    const findFirst = (selectors) => {
        for (let i = 0; i < selectors.length; i += 1) {
            try {
                const el = document.querySelector(selectors[i]);
                if (el) return el;
            } catch (_) {}
        }
        return null;
    };

    const isDisabled = (el) => {
        if (!el) return true;
        if (el.disabled === true) return true;
        if (el.hasAttribute && el.hasAttribute('disabled')) return true;
        const aria = el.getAttribute ? el.getAttribute('aria-disabled') : null;
        return typeof aria === 'string' && aria.toLowerCase() === 'true';
    };

    const host = findFirst(hostSelectors);
    if (!host) return 'missing';

    const toggle = findFirst(toggleSelectors) || host.querySelector('button') || host;

    let isOn = false;
    if (host.classList && host.classList.contains(legacyActiveClass)) {
        isOn = true;
    } else if (toggle && toggle.classList && toggle.classList.contains(legacyActiveClass)) {
        isOn = true;
    } else {
        try {
            if (host.querySelector('.' + legacyActiveClass)) {
                isOn = true;
            }
        } catch (_) {}
    }

    if (!isOn) {
        const iconCandidates = host.querySelectorAll('mat-icon, [data-mat-icon-name]');
        for (let i = 0; i < iconCandidates.length; i += 1) {
            const icon = iconCandidates[i];
            const fontIcon = icon.getAttribute('fonticon');
            const matIconName = icon.getAttribute('data-mat-icon-name');
            if (fontIcon === activeIconName || matIconName === activeIconName) {
                isOn = true;
                break;
            }
        }
    }

    const currentState = isOn ? 'on' : 'off';
    if (mode === 'read') {
        return currentState;
    }

    const targetOn = (mode === 'enable');
    if (isOn === targetOn) {
        return currentState;
    }

    if (isDisabled(toggle)) {
        return 'disabled';
    }

    toggle.click();
    return 'clicked';
    """

    /// Logs one line per ensure or explicit sync attempt so misbehavior can be diagnosed from real sessions
    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "TemporaryChat")

    /// Polling cadence used while waiting for DOM appearance or state transitions during explicit sync
    private static let syncPollInterval: Duration = .milliseconds(50)

    // MARK: - State

    /// The controlled web view; held weakly so the controller never extends its lifetime
    private weak var webView: WKWebView?

    /// Reads the current value of the defaultTemporaryChat setting
    private let isEnabled: () -> Bool

    /// The running background ensure task, if any
    private var task: Task<Void, Never>?

    /// When the toggle was last clicked. A second click within 2 s, before Gemini
    /// updates its DOM state, would toggle temporary chat back off
    private var lastClickAt: ContinuousClock.Instant?

    // MARK: - Initialization

    init(webView: WKWebView, isEnabled: @escaping () -> Bool) {
        self.webView = webView
        self.isEnabled = isEnabled
    }

    /// Convenience initializer for callers that only drive explicit bidirectional sync via `setTemporaryChat`
    convenience init(webView: WKWebView) {
        self.init(webView: webView, isEnabled: { false })
    }

    // MARK: - Ensuring Temporary Chat (Legacy & Classic Web Mode)

    /// Make sure Gemini's temporary chat is on for the chat currently open.
    /// Several triggers can fire for the same new chat; the 2-second click guard and
    /// the single click per task are what prevent toggling temporary chat back off.
    func ensure(reason: String) {
        guard isEnabled() else {
            Self.logger.notice("ensure [\(reason, privacy: .public)]: disabled")
            return
        }
        if let lastClickAt, ContinuousClock.now - lastClickAt < .seconds(2) {
            Self.logger.notice("ensure [\(reason, privacy: .public)]: skipped-recent-click")
            return
        }

        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let webView = self.webView else { return }

            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                guard !Task.isCancelled else { return }
                switch await self.probe(webView: webView, mode: .enable) {
                case "on":
                    // Gemini resets a new chat to normal (isTemporaryChat: false)
                    // after our first read, so an early "on" can be the previous
                    // chat. Confirm before stopping.
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    if await self.probe(webView: webView, mode: .read) == "on" {
                        Self.logger.notice("ensure [\(reason, privacy: .public)]: already-on")
                        return
                    }
                    continue
                case "clicked":
                    self.lastClickAt = ContinuousClock.now
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    let verified = await self.probe(webView: webView, mode: .read)
                    Self.logger.notice("ensure [\(reason, privacy: .public)]: clicked → \(verified, privacy: .public)")
                    return
                default:
                    // "missing" or "disabled": keep polling; the toggle may appear late
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            Self.logger.notice("ensure [\(reason, privacy: .public)]: missing")
        }
    }

    /// Cancel a running ensure task
    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - Explicit Bidirectional Sync (Native Mode & Quick Mode)

    /// Reads the current temporary-chat toggle state from the page DOM.
    ///
    /// - Returns: `true` if Temporary Chat is active, `false` if inactive, or `nil` if the toggle
    ///   element is currently absent (for example, inside an existing saved conversation).
    func readState() async -> Bool? {
        guard let webView else { return nil }
        switch await probe(webView: webView, mode: .read) {
        case "on":
            return true
        case "off":
            return false
        default:
            return nil
        }
    }

    /// Explicitly synchronizes Gemini's temporary-chat toggle to either ON (`true`) or OFF (`false`)
    /// and polls until the DOM confirms the target state.
    ///
    /// Cancels any background `ensure(reason:)` task so automatic enablement cannot race with an
    /// explicit toggle. Clicks at most once per call to prevent accidentally flipping state back.
    ///
    /// - Parameters:
    ///   - targetEnabled: Desired temporary-chat state (`true` for ON, `false` for OFF).
    ///   - reason: Short non-sensitive diagnostic label recorded in `os.Logger`.
    ///   - timeout: Maximum duration to wait for the control to appear and reflect `targetEnabled`.
    /// - Returns: The verified temporary-chat state (`targetEnabled`).
    @discardableResult
    func setTemporaryChat(
        _ targetEnabled: Bool,
        reason: String,
        timeout: Duration = .seconds(10)
    ) async throws -> Bool {
        cancel()

        guard let webView else {
            Self.logger.error("setTemporaryChat [\(reason, privacy: .public)] target=\(targetEnabled, privacy: .public): webview-deallocated")
            throw ChatTransportError.actionDriverFailed(
                reason: "Temporary chat control is unavailable because the WebView is no longer active."
            )
        }

        let targetState = targetEnabled ? "on" : "off"
        let actionMode: ProbeMode = targetEnabled ? .enable : .disable
        let deadline = ContinuousClock.now + timeout
        var didClick = false

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()

            if !didClick {
                let result = await probe(webView: webView, mode: actionMode)
                if result == targetState {
                    Self.logger.notice("setTemporaryChat [\(reason, privacy: .public)] target=\(targetEnabled, privacy: .public): already-\(targetState, privacy: .public)")
                    return targetEnabled
                }
                if result == "clicked" {
                    didClick = true
                    lastClickAt = ContinuousClock.now
                }
            } else {
                let verified = await probe(webView: webView, mode: .read)
                if verified == targetState {
                    Self.logger.notice("setTemporaryChat [\(reason, privacy: .public)] target=\(targetEnabled, privacy: .public): clicked → \(verified, privacy: .public)")
                    return targetEnabled
                }
            }

            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { break }
            let sleepDuration = remaining < Self.syncPollInterval ? remaining : Self.syncPollInterval
            try await Task.sleep(for: sleepDuration)
        }

        try Task.checkCancellation()

        // Final verification after deadline in case the DOM settled during the last sleep interval.
        let finalState = await probe(webView: webView, mode: .read)
        if finalState == targetState {
            let outcome = didClick ? "clicked → \(finalState)" : "already-\(finalState)"
            Self.logger.notice("setTemporaryChat [\(reason, privacy: .public)] target=\(targetEnabled, privacy: .public): \(outcome, privacy: .public)")
            return targetEnabled
        }

        if didClick {
            Self.logger.error("setTemporaryChat [\(reason, privacy: .public)] target=\(targetEnabled, privacy: .public): timeout-after-click final=\(finalState, privacy: .public)")
            throw ChatTransportError.actionDriverFailed(
                reason: "Temporary chat toggle did not reach target state (\(targetState)) within timeout."
            )
        } else {
            Self.logger.error("setTemporaryChat [\(reason, privacy: .public)] target=\(targetEnabled, privacy: .public): unavailable final=\(finalState, privacy: .public)")
            throw ChatTransportError.actionDriverFailed(
                reason: "Temporary chat toggle was unavailable within timeout."
            )
        }
    }

    // MARK: - Private Methods

    /// Runs the selector-driven probe function via `callAsyncJavaScript` and returns `"on"`,
    /// `"off"`, `"clicked"`, `"disabled"`, or `"missing"`.
    private func probe(webView: WKWebView, mode: ProbeMode) async -> String {
        let arguments: [String: Any] = [
            "hostSelectors": GeminiBridgeSelectors.ComposerDOM.tempChatHost.all,
            "toggleSelectors": GeminiBridgeSelectors.ComposerDOM.tempChatToggle.all,
            "legacyActiveClass": GeminiBridgeSelectors.ComposerDOM.tempChatLegacyActiveClass,
            "activeIconName": GeminiBridgeSelectors.ComposerDOM.tempChatActiveIconName,
            "mode": mode.rawValue
        ]

        do {
            let result = try await webView.callAsyncJavaScript(
                Self.probeFunctionBody,
                arguments: arguments,
                in: nil,
                contentWorld: .page
            )
            return (result as? String) ?? "missing"
        } catch {
            return "missing"
        }
    }

    private nonisolated static func encodeJSONStringArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}
