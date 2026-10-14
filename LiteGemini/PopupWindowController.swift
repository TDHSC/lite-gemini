import AppKit
import WebKit

/// Controls one in-app popup window hosting the WKWebView that WebKit created for a
/// new-window request. Sign-in and OAuth flows stay inside the app and share the main
/// session; non-Gemini destinations are handed off by `NewWindowRouter`.
final class PopupWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {

    // MARK: - Closures

    /// Loads a URL in the main web view
    private let openInMain: (URL) -> Void

    /// Routes nested new-window requests through the same rules as the main view
    private let routeNewWindow: (WKWebViewConfiguration, WKNavigationAction, WKWindowFeatures) -> WKWebView?

    /// Called when the popup window closes
    private let onClose: (PopupWindowController) -> Void

    // MARK: - State

    /// The popup's web view, built with the exact configuration WebKit passed in, which
    /// carries the shared cookie store and the opener link OAuth needs
    let webView: WKWebView

    /// The popup's window
    private let window: NSWindow

    /// True when this popup was opened for the account menu's "Add another account"
    private let openedForAccount: Bool

    /// True when the initial URL was nil or about:blank
    private let startedBlank: Bool

    /// True when the opener supplied an explicit window size
    private let hadExplicitSize: Bool

    /// True until the first http(s) main-frame navigation is decided; the initial
    /// about:blank load does not count
    private var isFirstNavigation = true

    /// Keeps the window title in sync with the web view's title
    private var titleObservation: NSKeyValueObservation?

    // MARK: - Initialization

    init(configuration: WKWebViewConfiguration,
         navigationAction: WKNavigationAction,
         windowFeatures: WKWindowFeatures,
         parentWindow: NSWindow?,
         openInMain: @escaping (URL) -> Void,
         routeNewWindow: @escaping (WKWebViewConfiguration, WKNavigationAction, WKWindowFeatures) -> WKWebView?,
         onClose: @escaping (PopupWindowController) -> Void) {
        self.openInMain = openInMain
        self.routeNewWindow = routeNewWindow
        self.onClose = onClose

        let initialURL = navigationAction.request.url
        hadExplicitSize = windowFeatures.width != nil || windowFeatures.height != nil
        openedForAccount = NewWindowRouter.isAccountFlow(initialURL: initialURL, hadExplicitSize: hadExplicitSize)
        startedBlank = NewWindowRouter.isBlankURL(initialURL)

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = AppDelegate.geminiSurfaceNSColor
        webView.setValue(false, forKey: "drawsBackground")

        // Window size from the opener's features, clamped; the default fits a sign-in form
        let width = Self.clamped(windowFeatures.width?.intValue, default: 520, range: 400...1000)
        let height = Self.clamped(windowFeatures.height?.intValue, default: 680, range: 500...900)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = parentWindow?.backgroundColor ?? AppDelegate.geminiSurfaceNSColor
        window.title = initialURL?.host ?? ""
        // With "Always on top" on, a normal-level popup would open behind the main window
        window.level = parentWindow?.level ?? .normal

        super.init()

        // A custom User-Agent is a property of the web view, not of the configuration;
        // without it Google may refuse sign-in as an embedded browser
        webView.customUserAgent = SettingsManager.shared.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self

        window.contentView = webView
        window.delegate = self

        // Centered over the main window, or on screen when there is none
        if let parentFrame = parentWindow?.frame {
            let contentFrame = NSWindow.contentRect(forFrameRect: window.frame, styleMask: window.styleMask)
            let origin = NSPoint(
                x: parentFrame.midX - contentFrame.width / 2,
                y: parentFrame.midY - contentFrame.height / 2
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }

        titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
            // KVO notifications for WKWebView arrive on the main thread
            MainActor.assumeIsolated {
                guard let title = webView.title, !title.isEmpty else { return }
                self?.window.title = title
            }
        }

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Private Methods

    /// Clamps an optional opener-supplied size to the given range
    private static func clamped(_ value: Int?, default defaultValue: Int, range: ClosedRange<Int>) -> CGFloat {
        let clamped = value.map { range.clamp($0) } ?? defaultValue
        return CGFloat(clamped)
    }

    /// Close the popup window and release its resources through `windowWillClose`
    func close() {
        window.close()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only http(s) main-frame navigations take part in popup routing
        guard navigationAction.targetFrame?.isMainFrame == true,
              let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            decisionHandler(.allow)
            return
        }

        let decision = NewWindowRouter.routeInsidePopup(
            url: url,
            openedForAccount: openedForAccount,
            startedBlank: startedBlank,
            isFirstNavigation: isFirstNavigation,
            hadExplicitSize: hadExplicitSize
        )
        isFirstNavigation = false

        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .moveToMain(let url):
            decisionHandler(.cancel)
            openInMain(url)
            close()
        case .moveToBrowser(let url):
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
            close()
        }
    }

    // MARK: - WKUIDelegate

    /// Pages call window.close() when an OAuth flow ends
    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    /// Nested popups follow the same routing rules as the main view
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        routeNewWindow(configuration, navigationAction, windowFeatures)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        webView.stopLoading()
        titleObservation?.invalidate()
        titleObservation = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        // The release is deferred on purpose: onClose removes the last strong
        // reference (in WebViewModel.popups). Releasing the controller here could
        // deallocate the WKWebView in the middle of its own delegate callback —
        // decidePolicyFor or webViewDidClose triggered this close — which is a known
        // crash source. `self` is captured strongly so the controller outlives the
        // close sequence.
        DispatchQueue.main.async { self.onClose(self) }
    }
}

/// Clamps a value into a closed range
private extension ClosedRange where Bound == Int {
    func clamp(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
