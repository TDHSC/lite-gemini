import SwiftUI
import WebKit
import Combine
import os

extension Notification.Name {
    /// Posted after browsing data has been cleared from Settings
    static let browsingDataCleared = Notification.Name("BrowsingDataCleared")
    /// Posted by the global new-chat hotkey once the window is visible and focused
    static let newChatRequested = Notification.Name("NewChatRequested")
}

/// Weak wrapper to avoid retain cycle: WKUserContentController strongly retains message handlers
private class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(controller, didReceive: message)
    }
}

class WebViewModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    // MARK: - Constants

    private enum Constants {
        static let geminiURL = URL(string: "https://gemini.google.com/app")!
    }

    /// Logs new-window requests so misrouted popup flows can be diagnosed from real
    /// signed-in sessions, which cannot be reproduced headlessly. Query strings and
    /// fragments are never logged; they can contain tokens and email addresses.
    private static let newWindowLogger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "NewWindow")

    /// Settings manager reference
    private let settings = SettingsManager.shared

    /// Subscriptions for observing settings changes
    private var cancellables = Set<AnyCancellable>()

    /// Console log bridge — forwards JS console.log to native Xcode console
    private static let consoleLogBridgeScript = """
    (function() {
        if (window.__consoleBridgeInstalled) return;
        window.__consoleBridgeInstalled = true;
        var originalLog = console.log;
        console.log = function() {
            var args = Array.prototype.slice.call(arguments);
            var msg = args.map(function(a) {
                return typeof a === 'object' ? JSON.stringify(a) : String(a);
            }).join(' ');
            originalLog.apply(console, arguments);
            try {
                window.webkit.messageHandlers.consoleLog.postMessage(msg);
            } catch(e) {}
        };
    })();
    """

    /// Observes the Gemini page's computed background color so the native titlebar and
    /// window backdrop blend seamlessly in both dark (#131314) and light (#FFFFFF) themes.
    private static let themeSyncScript = """
    (function() {
        if (window.__themeSyncInstalled) return;
        window.__themeSyncInstalled = true;
        var lastColor = '';
        function reportBg() {
            var body = document.body;
            var docEl = document.documentElement;
            if (!body && !docEl) return;
            var bg = body ? window.getComputedStyle(body).backgroundColor : '';
            if (!bg || bg === 'rgba(0, 0, 0, 0)' || bg === 'transparent') {
                bg = docEl ? window.getComputedStyle(docEl).backgroundColor : '';
            }
            if (bg && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent' && bg !== lastColor) {
                lastColor = bg;
                try {
                    window.webkit.messageHandlers.themeColor.postMessage(bg);
                } catch(e) {}
            }
        }
        document.addEventListener('DOMContentLoaded', function() {
            reportBg();
            var observer = new MutationObserver(reportBg);
            if (document.documentElement) {
                observer.observe(document.documentElement, { attributes: true, attributeFilter: ['class', 'style', 'data-theme'] });
            }
            if (document.body) {
                observer.observe(document.body, { attributes: true, attributeFilter: ['class', 'style', 'data-theme'] });
            }
        });
        window.addEventListener('load', reportBg);
        setInterval(reportBg, 1500);
    })();
    """

    /// IME fix script — injected at document start to register before any page scripts.
    /// Tracks real composing state and blocks buggy Enter events from reaching the page.
    private static let imeFixScript = """
    (function() {
        if (window.__imeFixInstalled) return;
        window.__imeFixInstalled = true;

        var actuallyComposing = false;
        var fixInProgress = false;
        var syntheticKeyTimer = null;

        document.addEventListener('compositionstart', function(e) {
            actuallyComposing = true;
            console.log('[IME Debug] compositionstart, data="' + e.data + '"');
        }, true);

        document.addEventListener('compositionend', function(e) {
            actuallyComposing = false;
            console.log('[IME Debug] compositionend, data="' + e.data + '"');

            // FIX for Gemini's "recent composition" flag:
            // Gemini internally tracks composition state and swallows the first
            // Enter after compositionend. Its keydown handler clears that flag on
            // ANY keydown. We dispatch a synthetic Shift key to clear that flag,
            // so the user's next real Enter goes through normally on the first
            // press.
            //
            // A synthetic Enter must NEVER be used here. Shift can never submit
            // in any Gemini path, but an Enter submits whenever Gemini's swallow
            // flag is not armed — observed when the composer has attachments,
            // where it sent the prompt immediately.
            //
            // HOWEVER, if an Enter keydown arrives within 50ms of compositionend,
            // it means the Enter key was used to confirm the IME candidate
            // (scenario 1). In that case, we must NOT dispatch a synthetic key,
            // because Gemini's flag-clearing on that Enter is the correct behavior.
            if (syntheticKeyTimer) clearTimeout(syntheticKeyTimer);
            syntheticKeyTimer = setTimeout(function() {
                syntheticKeyTimer = null;
                var target = document.activeElement || document.body;
                console.log('[IME Debug] >>> dispatching synthetic Shift to clear Gemini flag');
                var synDown = new KeyboardEvent('keydown', {
                    key: 'Shift', code: 'ShiftLeft', keyCode: 16, which: 16,
                    bubbles: true, cancelable: true, shiftKey: true
                });
                target.dispatchEvent(synDown);
                var synUp = new KeyboardEvent('keyup', {
                    key: 'Shift', code: 'ShiftLeft', keyCode: 16, which: 16,
                    bubbles: true, cancelable: true
                });
                target.dispatchEvent(synUp);
                console.log('[IME Debug] >>> synthetic Shift dispatched, defaultPrevented=' + synDown.defaultPrevented);
            }, 50);
        }, true);

        // Capture-phase keydown logging + fix
        document.addEventListener('keydown', function(e) {
            if (e.key !== 'Enter' || e.shiftKey) return;

            // If a real Enter arrives right after compositionend (within 50ms),
            // cancel the synthetic — this Enter IS the IME confirmation key
            if (syntheticKeyTimer && e.isTrusted) {
                clearTimeout(syntheticKeyTimer);
                syntheticKeyTimer = null;
                console.log('[IME Debug] keydown Enter: cancelled synthetic (IME confirmation Enter detected)');
            }

            console.log('[IME Debug] keydown Enter: isComposing=' + e.isComposing +
                ', actuallyComposing=' + actuallyComposing +
                ', fixInProgress=' + fixInProgress +
                ', isTrusted=' + e.isTrusted);

            // Original fix: WKWebView sometimes reports isComposing=true even
            // after compositionend has fired. Block this buggy event and ask
            // native to send a fresh Enter.
            if (e.isComposing && !actuallyComposing && !fixInProgress) {
                console.log('[IME Debug] >>> isComposing FIX: blocking buggy Enter, requesting native re-send');
                e.stopImmediatePropagation();
                e.preventDefault();
                fixInProgress = true;
                setTimeout(function() { fixInProgress = false; }, 1000);
                window.webkit.messageHandlers.imeEnterFix.postMessage('sendEnter');
                return;
            }

            if (fixInProgress) {
                console.log('[IME Debug] --- re-sent fix Enter, letting through');
            } else {
                console.log('[IME Debug] --- normal Enter, letting through');
            }
        }, true);

        // Bubble-phase: check if page preventDefault'd
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Enter') {
                console.log('[IME Debug] keydown Enter (BUBBLE): defaultPrevented=' + e.defaultPrevented);
            }
        }, false);

        // Post-Enter state check
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && !e.shiftKey) {
                setTimeout(function() {
                    var el = document.activeElement;
                    var textLen = el ? (el.textContent || '').length : 0;
                    console.log('[IME Debug] post-Enter: textLen=' + textLen);
                }, 50);
            }
        }, true);

        console.log('[IME Debug] IME fix script installed with debug logging');
    })();
    """

    // MARK: - Public Properties

    @Published var isLoading: Bool = true
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    /// Loading error message; non-nil indicates an error occurred
    @Published var errorMessage: String?
    /// Whether the page input field is ready (contenteditable or textarea detected)
    @Published var isPageReady: Bool = false
    /// Latest download notice to show in the window; nil when hidden
    @Published var downloadNotice: DownloadNotice?
    /// Synced background color of the Gemini web page for seamless titlebar & backdrop blending
    @Published var pageBackgroundColor: Color = Color(nsColor: AppDelegate.geminiSurfaceNSColor)

    let webView: WKWebView

    /// Owns the web view's downloads; kept here because WKDownload's delegate is weak
    let downloadManager = DownloadManager()

    /// Turns on Gemini's temporary chat for new chats when the setting is enabled
    private var temporaryChatController: TemporaryChatController!

    /// Background timeout task; navigates back to homepage on timeout
    private var backgroundTimeoutTask: Task<Void, Never>?

    /// Task that polls for input field readiness via JavaScript
    private var inputReadyTask: Task<Void, Never>?

    /// Fallback task that loads the homepage when the new-chat shortcut had no effect
    private var newChatFallbackTask: Task<Void, Never>?

    /// Open popup windows owned by this view model (sign-in, OAuth); they remove
    /// themselves through `onClose`
    private var popups: [PopupWindowController] = []

    /// Check if currently on the Gemini homepage
    private var isOnHomePage: Bool {
        guard let url = webView.url else { return false }
        return url.host == Constants.geminiURL.host
            && url.path == Constants.geminiURL.path
    }

    // MARK: - Initialization

    override init() {
        let configuration = WKWebViewConfiguration()
        // Use default persistent data store to preserve cookies / LocalStorage across app restarts
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // Inject console log bridge first so it captures all subsequent console.log calls
        let consoleScript = WKUserScript(
            source: Self.consoleLogBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(consoleScript)

        // Inject IME fix script via WKUserScript, more reliable than evaluateJavaScript
        let imeScript = WKUserScript(
            source: Self.imeFixScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(imeScript)

        let tempChatIntentScript = WKUserScript(
            source: TemporaryChatController.intentScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(tempChatIntentScript)

        let themeScript = WKUserScript(
            source: Self.themeSyncScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(themeScript)

        webView = GeminiBaseWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = settings.userAgent
        webView.underPageBackgroundColor = AppDelegate.geminiSurfaceNSColor
        webView.setValue(false, forKey: "drawsBackground")

        super.init()

        // Register message handlers (must be after super.init() so self is available)
        let weakHandler = WeakScriptMessageHandler(self)
        webView.configuration.userContentController.add(weakHandler, name: "imeEnterFix")
        webView.configuration.userContentController.add(weakHandler, name: "consoleLog")
        webView.configuration.userContentController.add(weakHandler, name: "temporaryChatIntent")
        webView.configuration.userContentController.add(weakHandler, name: "themeColor")

        webView.navigationDelegate = self
        webView.uiDelegate = self

        temporaryChatController = TemporaryChatController(webView: webView) { [weak self] in
            self?.settings.defaultTemporaryChat ?? false
        }

        // Surface download results as notices in the window
        downloadManager.onNotice = { [weak self] notice in
            self?.downloadNotice = notice
        }

        // Apply User-Agent edits from Settings; they take effect on the next load (Cmd+R)
        settings.$userAgent
            .dropFirst()
            .sink { [weak self] userAgent in
                self?.webView.customUserAgent = userAgent
            }
            .store(in: &cancellables)

        webView.publisher(for: \.url)
            .map { $0?.path }
            .removeDuplicates()
            .sink { [weak self] path in
                guard path == "/app" else { return }
                self?.temporaryChatController.ensure(reason: "url")
            }
            .store(in: &cancellables)

        settings.$defaultTemporaryChat
            .dropFirst()
            // @Published emits from willSet; hop so the property is stored
            // before isEnabled reads it.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard enabled, let self, self.webView.url?.path == "/app" else { return }
                self.temporaryChatController.ensure(reason: "setting")
            }
            .store(in: &cancellables)

        webView.load(URLRequest(url: Constants.geminiURL))

        // Observe app activation / deactivation events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        // Listen for browsing data cleared notification to reload the page
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBrowsingDataCleared),
            name: .browsingDataCleared,
            object: nil
        )

        // Listen for the global new-chat hotkey
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNewChatRequested),
            name: .newChatRequested,
            object: nil
        )
    }

    isolated deinit {
        backgroundTimeoutTask?.cancel()
        inputReadyTask?.cancel()
        newChatFallbackTask?.cancel()
        temporaryChatController.cancel()
        closeAllPopups()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "imeEnterFix")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "consoleLog")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "temporaryChatIntent")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "themeColor")
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public Methods

    /// Focus the input field in the page (contenteditable area or textarea)
    func focusInput() {
        let js = """
        (function() {
            // Prefer contenteditable input area (used by Gemini)
            var el = document.querySelector('[contenteditable="true"]');
            if (!el) {
                el = document.querySelector('textarea');
            }
            if (el) {
                el.focus();
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// When app becomes active, cancel the timer and focus the input field
    @objc private func appDidBecomeActive() {
        backgroundTimeoutTask?.cancel()
        backgroundTimeoutTask = nil

        // Delay briefly to ensure the window and WebView are fully ready before focusing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.focusInput()
        }
    }

    /// Reload the homepage after browsing data has been cleared
    @objc private func handleBrowsingDataCleared() {
        closeAllPopups()
        webView.load(URLRequest(url: Constants.geminiURL))
    }

    /// Close every popup window; the array is copied first because closing mutates it
    /// through `onClose`
    private func closeAllPopups() {
        let controllers = popups
        for controller in controllers {
            controller.close()
        }
    }

    /// Handle the global new-chat hotkey: send Cmd+Shift+O to the page, and fall back to
    /// loading /app when the shortcut has no effect (custom non-Mac User-Agent, or a
    /// Google-side shortcut change)
    @objc private func handleNewChatRequested() {
        // No page yet: load Gemini and stop
        guard let url = webView.url else {
            webView.load(URLRequest(url: Constants.geminiURL))
            return
        }

        // Compare paths only, never full URLs, because query strings change
        let pathBefore = url.path

        if let window = webView.window {
            window.makeFirstResponder(webView)
            sendCmdShiftO(to: window)
        }
        // Without a window the shortcut cannot be sent; go straight to the fallback check

        newChatFallbackTask?.cancel()
        newChatFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            // The user is already on a fresh chat; the shortcut legitimately changes nothing
            guard pathBefore != "/app" else { return }
            // The URL path is unchanged, so the shortcut had no effect
            if self.webView.url?.path == pathBefore {
                self.webView.load(URLRequest(url: Constants.geminiURL))
            }
        }

        temporaryChatController.ensure(reason: "hotkey")
    }

    /// Start the timeout when the app enters background (not started when set to "never")
    @objc private func appDidResignActive() {
        backgroundTimeoutTask?.cancel()
        backgroundTimeoutTask = nil

        // Do not start the timeout when "never" is selected
        guard let interval = settings.backgroundTimeout.seconds else { return }

        backgroundTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self, !self.isOnHomePage else { return }
            self.webView.load(URLRequest(url: Constants.geminiURL))
        }
    }

    /// Reload the current page and clear error state; fall back to homepage if no current URL
    func retry() {
        errorMessage = nil
        if webView.url != nil {
            webView.reload()
        } else {
            webView.load(URLRequest(url: Constants.geminiURL))
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(DownloadManager.downloadPolicy(for: navigationAction))
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(DownloadManager.downloadPolicy(
            for: navigationResponse.response,
            canShowMIMEType: navigationResponse.canShowMIMEType,
            isForMainFrame: navigationResponse.isForMainFrame
        ))
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        downloadManager.begin(download)
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        downloadManager.begin(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorMessage = nil
        startInputReadyPolling()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        // Ensure page is marked ready when navigation fully completes
        if !isPageReady {
            isPageReady = true
        }
        stopInputReadyPolling()
        if webView.url?.path == "/app" {
            temporaryChatController.ensure(reason: "load")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // Ignore cancellation errors, which are normal navigation cancellations
        if !isIgnoredNavigationError(nsError) {
            print("Navigation failed: \(error.localizedDescription)")
            errorMessage = String(localized: "Failed to load. Please check your network connection.")
        }
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if !isIgnoredNavigationError(nsError) {
            print("Provisional navigation failed: \(error.localizedDescription)")
            errorMessage = String(localized: "Unable to connect to Gemini. Please check your network connection.")
        }
        isLoading = false
    }

    /// True for navigation errors that must not surface as load failures: normal
    /// cancellations, and navigations that turned into downloads (WebKit fails
    /// those with legacy WebKit error code 102).
    private func isIgnoredNavigationError(_ error: NSError) -> Bool {
        if error.code == NSURLErrorCancelled { return true }
        // WebKitErrorDomain is deprecated in Swift, so compare the raw domain string
        return error.domain == "WebKitErrorDomain"
            && error.code == WebKitErrorFrameLoadInterruptedByPolicyChange
    }

    // MARK: - Input Ready Polling

    /// Start polling for input field availability every 200ms, up to 30s
    private func startInputReadyPolling() {
        stopInputReadyPolling()
        isPageReady = false

        let js = """
        (function() {
            var el = document.querySelector('[contenteditable="true"]');
            if (!el) el = document.querySelector('textarea');
            return el !== null;
        })();
        """

        inputReadyTask = Task { [weak self] in
            // Timeout after 30 seconds, fall back to didFinish
            let deadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self else { return }

                if let ready = try? await self.webView.evaluateJavaScript(js) as? Bool, ready {
                    if !self.isPageReady {
                        self.isPageReady = true
                    }
                    return
                }
            }
        }
    }

    /// Stop the input ready polling task
    private func stopInputReadyPolling() {
        inputReadyTask?.cancel()
        inputReadyTask = nil
    }

    // MARK: - WKUIDelegate

    /// Route a new-window request: Gemini URLs load in the main view, Google sign-in and
    /// OAuth open in an in-app popup, everything else goes to the default browser.
    /// The `webView` parameter is the requesting view and may be a popup's web view in
    /// nested calls; all main-view loads go to `self.webView`.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let targetURL = navigationAction.request.url
        let isLinkActivated = navigationAction.navigationType == .linkActivated
        let hasExplicitSize = windowFeatures.width != nil || windowFeatures.height != nil
        let route = NewWindowRouter.route(url: targetURL, isLinkActivated: isLinkActivated, hasExplicitSize: hasExplicitSize)

        // One `.notice` entry shows both the request and the decision; lower levels are
        // not persisted, and the logs are read after the session.
        Self.newWindowLogger.notice("""
        new-window: scheme=\(targetURL?.scheme ?? "nil", privacy: .public) \
        host=\(targetURL?.host ?? "nil", privacy: .public) \
        path=\(targetURL?.path ?? "nil", privacy: .public) \
        type=\(Self.navigationTypeName(navigationAction.navigationType), privacy: .public) \
        size=\(Self.windowSizeDescription(windowFeatures), privacy: .public) \
        source=\(navigationAction.sourceFrame.securityOrigin.host, privacy: .public) \
        mainFrame=\(navigationAction.sourceFrame.isMainFrame, privacy: .public) \
        route=\(Self.routeName(route), privacy: .public)
        """)

        switch route {
        case .mainWebView(let url):
            self.webView.load(URLRequest(url: url))
            return nil
        case .externalBrowser(let url):
            NSWorkspace.shared.open(url)
            return nil
        case .ignore:
            return nil
        case .popup:
            let controller = PopupWindowController(
                configuration: configuration,
                navigationAction: navigationAction,
                windowFeatures: windowFeatures,
                parentWindow: self.webView.window,
                openInMain: { [weak self] url in
                    self?.webView.load(URLRequest(url: url))
                },
                routeNewWindow: { [weak self] configuration, navigationAction, windowFeatures in
                    guard let self else { return nil }
                    return self.webView(self.webView, createWebViewWith: configuration, for: navigationAction, windowFeatures: windowFeatures)
                },
                onClose: { [weak self] controller in
                    self?.popups.removeAll { $0 === controller }
                }
            )
            popups.append(controller)
            return controller.webView
        }
    }

    /// A readable name for the chosen route, for the new-window log
    private static func routeName(_ route: NewWindowRoute) -> String {
        switch route {
        case .mainWebView: return "mainWebView"
        case .popup: return "popup"
        case .externalBrowser: return "externalBrowser"
        case .ignore: return "ignore"
        }
    }

    /// A readable name for a WKNavigationType, for the new-window log
    private static func navigationTypeName(_ type: WKNavigationType) -> String {
        switch type {
        case .linkActivated: return "linkActivated"
        case .formSubmitted: return "formSubmitted"
        case .backForward: return "backForward"
        case .reload: return "reload"
        case .formResubmitted: return "formResubmitted"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }

    /// The opener-supplied window size for the new-window log, e.g. "520x680" or "nilxnil"
    private static func windowSizeDescription(_ features: WKWindowFeatures) -> String {
        let width = features.width.map { String($0.intValue) } ?? "nil"
        let height = features.height.map { String($0.intValue) } ?? "nil"
        return "\(width)x\(height)"
    }

    /// Show the system open panel for `<input type=file>` elements, which Apple disables
    /// unless the UI delegate implements this method
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if parameters.allowsDirectories {
            // The page asked for a directory (webkitdirectory, used by "Import code → Upload folder")
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
        } else {
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
        }

        if let window = webView.window {
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        } else {
            let response = panel.runModal()
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    /// Grant microphone capture only to gemini.google.com over https; deny everything else.
    /// Granting avoids WebKit's extra per-session prompt on top of the one-time macOS prompt.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        // "protocol" is a Swift keyword, hence the backticks on the scheme property
        if origin.`protocol` == "https",
           origin.host == "gemini.google.com",
           type == .microphone {
            decisionHandler(.grant)
        } else {
            decisionHandler(.deny)
        }
    }

    // MARK: - WKScriptMessageHandler (IME Enter Fix & Theme Sync)

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
        case "consoleLog":
            if let msg = message.body as? String {
                print("[JS] \(msg)")
            }
        case "imeEnterFix":
            print("[IME Debug] Native received imeEnterFix message: \(message.body)")
            // Delay to allow WKWebView to clear its internal stale composing state
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                print("[IME Debug] Native sending synthetic Enter key after 150ms delay")
                self?.sendEnterKey()
            }
        case "temporaryChatIntent":
            temporaryChatController.ensure(reason: "page")
        case "themeColor":
            if let cssColor = message.body as? String,
               let parsedColor = Self.parseCSSColor(cssColor) {
                pageBackgroundColor = Color(nsColor: parsedColor)
                webView.underPageBackgroundColor = parsedColor
                webView.window?.backgroundColor = parsedColor
            }
        default:
            break
        }
    }

    /// Parse a CSS `rgb(r, g, b)` or `rgba(r, g, b, a)` string into an `NSColor`
    private static func parseCSSColor(_ css: String) -> NSColor? {
        let numbers = css
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .compactMap { Double($0) }
        guard numbers.count >= 3 else { return nil }
        let r = min(max(numbers[0] / 255.0, 0), 1)
        let g = min(max(numbers[1] / 255.0, 0), 1)
        let b = min(max(numbers[2] / 255.0, 0), 1)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    /// Send a fresh Enter key event via CGEvent.
    /// By this point WKWebView's composing state should be cleared,
    /// so the JS keydown event will have isComposing=false.
    private func sendEnterKey() {
        guard let window = webView.window else { return }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        if let cgDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true) {
            cgDown.flags = []
            if let nsDown = NSEvent(cgEvent: cgDown) {
                window.sendEvent(nsDown)
            }
        }
        if let cgUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) {
            cgUp.flags = []
            if let nsUp = NSEvent(cgEvent: cgUp) {
                window.sendEvent(nsUp)
            }
        }
    }

    /// Send Cmd+Shift+O to the given window via CGEvent, the shortcut Gemini maps to "new chat"
    private func sendCmdShiftO(to window: NSWindow) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        // 0x1F is the O key, matching how sendEnterKey writes 0x24 for Enter
        let keyCode: CGKeyCode = 0x1F

        if let cgDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            cgDown.flags = [.maskCommand, .maskShift]
            if let nsDown = NSEvent(cgEvent: cgDown) {
                window.sendEvent(nsDown)
            }
        }
        if let cgUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            cgUp.flags = [.maskCommand, .maskShift]
            if let nsUp = NSEvent(cgEvent: cgUp) {
                window.sendEvent(nsUp)
            }
        }
    }
}
