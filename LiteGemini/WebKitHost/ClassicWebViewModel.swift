import SwiftUI
import WebKit
import Combine

extension Notification.Name {
    /// Posted after browsing data has been cleared from Settings
    static let browsingDataCleared = Notification.Name("BrowsingDataCleared")
    /// Posted by the global new-chat hotkey once the window is visible and focused
    static let newChatRequested = Notification.Name("NewChatRequested")
}

/// Convenience alias preserving compatibility with legacy `WebViewModel` references.
typealias WebViewModel = ClassicWebViewModel

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

/// View model managing the Classic `WKWebView` session, navigation delegates, downloads,
/// popups, IME workarounds, and theme synchronization.
class ClassicWebViewModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    // MARK: - Constants

    private enum Constants {
        static let geminiURL = URL(string: "https://gemini.google.com/app")!
    }

    /// Settings manager reference
    private let settings = SettingsManager.shared

    /// Subscriptions for observing settings changes
    private var cancellables = Set<AnyCancellable>()

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
    private(set) var syncedWindowNSColor: NSColor = AppDelegate.geminiSurfaceNSColor

    let webView: WKWebView

    /// Owns the web view's downloads; kept here because WKDownload's delegate is weak
    let downloadManager: DownloadManager

    /// Shared coordinator owning open in-app sign-in and OAuth popup windows
    let popupCoordinator: PopupCoordinator

    /// Turns on Gemini's temporary chat for new chats when the setting is enabled
    private var temporaryChatController: TemporaryChatController!

    /// Background timeout task; navigates back to homepage on timeout
    private var backgroundTimeoutTask: Task<Void, Never>?

    /// Task that polls for input field readiness via JavaScript
    private var inputReadyTask: Task<Void, Never>?

    /// Fallback task that loads the homepage when the new-chat shortcut had no effect
    private var newChatFallbackTask: Task<Void, Never>?

    /// Check if currently on the Gemini homepage
    private var isOnHomePage: Bool {
        guard let url = webView.url else { return false }
        return url.host == Constants.geminiURL.host
            && url.path == Constants.geminiURL.path
    }

    // MARK: - Initialization

    init(
        popupCoordinator: PopupCoordinator = PopupCoordinator(),
        downloadManager: DownloadManager = DownloadManager()
    ) {
        self.popupCoordinator = popupCoordinator
        self.downloadManager = downloadManager

        let configuration = WKWebViewConfiguration()
        // Use default persistent data store to preserve cookies / LocalStorage across app restarts
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        #if DEBUG
        // Inject console log bridge first so it captures all subsequent console.log calls
        let consoleScript = WKUserScript(
            source: ClassicWebScripts.consoleLogBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(consoleScript)
        #endif

        ClassicWebScripts.installWebAuthnFallbackIfNeeded(on: configuration.userContentController)

        // Inject IME fix script via WKUserScript, more reliable than evaluateJavaScript
        let imeScript = WKUserScript(
            source: ClassicWebScripts.imeFixScript,
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
            source: ClassicWebScripts.themeSyncScript,
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
        #if DEBUG
        webView.configuration.userContentController.add(weakHandler, name: "consoleLog")
        #endif
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
        popupCoordinator.closeAll()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "imeEnterFix")
        #if DEBUG
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "consoleLog")
        #endif
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

    /// When app becomes active, cancel the timer and focus the input field in Classic Web Mode
    @objc private func appDidBecomeActive() {
        backgroundTimeoutTask?.cancel()
        backgroundTimeoutTask = nil
        guard !settings.isNativeUIActive else { return }

        // Delay briefly to ensure the window and WebView are fully ready before focusing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.settings.isNativeUIActive else { return }
            self.focusInput()
        }
    }

    /// Reload the homepage after browsing data has been cleared
    @objc private func handleBrowsingDataCleared() {
        popupCoordinator.closeAll()
        webView.load(URLRequest(url: Constants.geminiURL))
    }

    /// Handle the global new-chat hotkey: send Cmd+Shift+O to the page, and fall back to
    /// loading /app when the shortcut has no effect (custom non-Mac User-Agent, or a
    /// Google-side shortcut change)
    @objc private func handleNewChatRequested() {
        guard !settings.isNativeUIActive else { return }
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

    /// Route a new-window request through `PopupCoordinator`.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        popupCoordinator.handleCreateWebView(
            configuration: configuration,
            navigationAction: navigationAction,
            windowFeatures: windowFeatures,
            parentWindow: self.webView.window,
            openInMain: { [weak self] url in
                self?.webView.load(URLRequest(url: url))
            }
        )
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
        #if DEBUG
        case "consoleLog":
            if let msg = message.body as? String {
                print("[JS] \(msg)")
            }
        #endif
        case "imeEnterFix":
            #if DEBUG
            print("[IME Debug] Native received imeEnterFix message: \(message.body)")
            #endif
            // Delay to allow WKWebView to clear its internal stale composing state
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                #if DEBUG
                print("[IME Debug] Native sending synthetic Enter key after 150ms delay")
                #endif
                self?.sendEnterKey()
            }
        case "temporaryChatIntent":
            temporaryChatController.ensure(reason: "page")
        case "themeColor":
            if let cssColor = message.body as? String,
               let parsedColor = Self.parseCSSColor(cssColor) {
                syncedWindowNSColor = parsedColor
                pageBackgroundColor = Color(nsColor: parsedColor)
                webView.underPageBackgroundColor = parsedColor
                if !SettingsManager.shared.isNativeUIActive {
                    webView.window?.backgroundColor = parsedColor
                }
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
