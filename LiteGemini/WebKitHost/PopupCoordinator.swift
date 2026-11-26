import AppKit
import Foundation
import os
import WebKit

/// Owns active in-app popup windows (`PopupWindowController`) and routes `WKUIDelegate`
/// new-window requests through `NewWindowRouter`. Shared across Classic Web Mode and
/// future `GeminiSessionEngine` instances so sign-in and OAuth flows stay unified.
@MainActor
final class PopupCoordinator {

    // MARK: - Logging

    /// Logs new-window requests so misrouted popup flows can be diagnosed from real
    /// signed-in sessions, which cannot be reproduced headlessly. Query strings and
    /// fragments are never logged; they can contain tokens and email addresses.
    private static let newWindowLogger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "NewWindow")

    // MARK: - State

    /// Active popup windows owned by this coordinator; they remove themselves via `onClose`.
    private var popups: [PopupWindowController] = []

    /// Number of currently open popup windows managed by this coordinator.
    var activePopupCount: Int {
        popups.count
    }

    // MARK: - New-Window Routing

    /// Route a `WKUIDelegate` new-window request: Gemini URLs load via `openInMain`,
    /// Google sign-in and OAuth open in an in-app popup window, and everything else
    /// opens in the default browser.
    func handleCreateWebView(
        configuration: WKWebViewConfiguration,
        navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures,
        parentWindow: NSWindow?,
        openInMain: @escaping (URL) -> Void
    ) -> WKWebView? {
        let targetURL = navigationAction.request.url
        let isLinkActivated = navigationAction.navigationType == .linkActivated
        let hasExplicitSize = windowFeatures.width != nil || windowFeatures.height != nil
        let route = NewWindowRouter.route(
            url: targetURL,
            isLinkActivated: isLinkActivated,
            hasExplicitSize: hasExplicitSize
        )

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
            openInMain(url)
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
                parentWindow: parentWindow,
                openInMain: openInMain,
                routeNewWindow: { [weak self, weak parentWindow] nestedConfig, nestedAction, nestedFeatures in
                    self?.handleCreateWebView(
                        configuration: nestedConfig,
                        navigationAction: nestedAction,
                        windowFeatures: nestedFeatures,
                        parentWindow: parentWindow,
                        openInMain: openInMain
                    )
                },
                onClose: { [weak self] controller in
                    self?.popups.removeAll { $0 === controller }
                }
            )
            popups.append(controller)
            return controller.webView
        }
    }

    /// Close every open popup window; the array is copied first because closing mutates
    /// it through `onClose`.
    func closeAll() {
        let controllers = popups
        for controller in controllers {
            controller.close()
        }
    }

    // MARK: - Logging Helpers

    /// A readable name for the chosen route, for the new-window log.
    private static func routeName(_ route: NewWindowRoute) -> String {
        switch route {
        case .mainWebView: return "mainWebView"
        case .popup: return "popup"
        case .externalBrowser: return "externalBrowser"
        case .ignore: return "ignore"
        }
    }

    /// A readable name for a `WKNavigationType`, for the new-window log.
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

    /// The opener-supplied window size for the new-window log, e.g. "520x680" or "nilxnil".
    private static func windowSizeDescription(_ features: WKWindowFeatures) -> String {
        let width = features.width.map { String($0.intValue) } ?? "nil"
        let height = features.height.map { String($0.intValue) } ?? "nil"
        return "\(width)x\(height)"
    }
}
