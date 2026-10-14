import Foundation
import os
import WebKit

/// Turns on Gemini's temporary chat for every new chat when the setting is enabled.
/// Temporary chat has no URL — it is Gemini router state — so the only lever is
/// clicking Gemini's own toggle element.
final class TemporaryChatController {

    // MARK: - Scripts

    /// Page script, injected at document start in the main frame only. It reports the
    /// page's own new-chat interactions to the `temporaryChatIntent` message handler.
    /// Only trusted events are reported, so the app's own synthetic events and page
    /// scripts cannot trigger it.
    static let intentScriptSource = """
    (function() {
        if (window.__tempChatIntentInstalled) return;
        window.__tempChatIntentInstalled = true;
        function post() {
            try {
                window.webkit.messageHandlers.temporaryChatIntent.postMessage('newChat');
            } catch (e) {}
        }
        document.addEventListener('click', function(event) {
            if (!event.isTrusted) return;
            var target = event.target;
            if (!target || !target.closest) return;
            if (target.closest('new-chat-button')
                || target.closest('[data-test-id="side-nav-sparkle-button"]')) {
                post();
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

    /// Logs one line per ensure attempt, so misbehavior can be diagnosed from real sessions
    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "TemporaryChat")

    // MARK: - State

    /// The main web view; held weakly so the controller never extends its lifetime
    private weak var webView: WKWebView?

    /// Reads the current value of the defaultTemporaryChat setting
    private let isEnabled: () -> Bool

    /// The running ensure task, if any
    private var task: Task<Void, Never>?

    /// When the toggle was last clicked. A second click within 2 s, before Gemini
    /// updates the class, would turn temporary chat back off
    private var lastClickAt: ContinuousClock.Instant?

    // MARK: - Initialization

    init(webView: WKWebView, isEnabled: @escaping () -> Bool) {
        self.webView = webView
        self.isEnabled = isEnabled
    }

    // MARK: - Ensuring Temporary Chat

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
                switch await self.probe(webView: webView, click: true) {
                case "on":
                    // Gemini resets a new chat to normal (isTemporaryChat: false)
                    // after our first read, so an early "on" can be the previous
                    // chat. Confirm before stopping.
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    if await self.probe(webView: webView, click: false) == "on" {
                        Self.logger.notice("ensure [\(reason, privacy: .public)]: already-on")
                        return
                    }
                    continue
                case "clicked":
                    self.lastClickAt = ContinuousClock.now
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    let verified = await self.probe(webView: webView, click: false)
                    Self.logger.notice("ensure [\(reason, privacy: .public)]: clicked → \(verified, privacy: .public)")
                    return
                default:
                    // "missing": keep polling; the toggle may appear late
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            Self.logger.notice("ensure [\(reason, privacy: .public)]: missing")
        }
    }

    /// Cancel a running ensure task
    func cancel() {
        task?.cancel()
    }

    // MARK: - Private Methods

    /// Runs the probe script and returns its result string, or "missing" on failure
    private func probe(webView: WKWebView, click: Bool) async -> String {
        (try? await webView.evaluateJavaScript(Self.probeScript(click: click)) as? String) ?? "missing"
    }

    /// One JavaScript snippet that finds the temporary-chat toggle. It looks up
    /// `temp-chat-button`, then the element with class `temp-chat-button` inside it
    /// (or the host itself). These names do not depend on the UI language, unlike the
    /// localized labels. In click mode it clicks once; in verify mode it only reports.
    private static func probeScript(click: Bool) -> String {
        """
        (function() {
            var host = document.querySelector('temp-chat-button');
            if (!host) return 'missing';
            var el = host.querySelector('.temp-chat-button') || host;
            if (el.classList.contains('temp-chat-on')) return 'on';
            \(click ? "el.click(); return 'clicked';" : "return 'off';")
        })()
        """
    }
}
