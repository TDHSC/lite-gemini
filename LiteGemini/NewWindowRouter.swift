import Foundation

/// Where a new-window request should go.
enum NewWindowRoute: Equatable {
    /// Load it in the main web view
    case mainWebView(URL)
    /// Open it in an in-app popup window
    case popup
    /// Hand it to the default browser
    case externalBrowser(URL)
    /// Do nothing
    case ignore
}

/// What to do with a main-frame navigation inside a popup window.
enum PopupNavigationDecision: Equatable {
    /// Let the popup navigate
    case allow
    /// Load it in the main web view instead
    case moveToMain(URL)
    /// Open it in the default browser instead
    case moveToBrowser(URL)
}

/// Pure routing rules for new-window requests and popup navigations. A caseless enum
/// used as a namespace; all inputs are plain values so tests need no WebKit objects.
/// The rules are designed without signed-in logs; the NewWindow log lines exist to
/// correct them if acceptance finds a misrouted flow.
enum NewWindowRouter {

    /// Route for a new-window request. First match wins.
    static func route(url: URL?, isLinkActivated: Bool, hasExplicitSize: Bool) -> NewWindowRoute {
        // 1. A script will navigate it later; routeInsidePopup decides then.
        if isBlankURL(url) {
            return .popup
        }
        let url = url!
        let scheme = url.scheme?.lowercased() ?? ""
        // 2.
        if scheme == "javascript" {
            return .ignore
        }
        // 3. mailto:, tel:, … belong to the system browser
        if scheme != "http" && scheme != "https" {
            return .externalBrowser(url)
        }
        let host = url.host?.lowercased() ?? ""
        // 4. Account switching with ?authuser=N, chat links.
        if host == "gemini.google.com" {
            return .mainWebView(url)
        }
        // 5. Add account, re-auth, Google OAuth.
        if host == "accounts.google.com" {
            return .popup
        }
        let path = url.path.lowercased()
        // 6. A script-opened OAuth window; some OAuth popups are opened without a size.
        // A clicked link is never an OAuth popup.
        if !isLinkActivated && (hasExplicitSize || path.contains("oauth") || path.contains("authorize")) {
            return .popup
        }
        // 7. Answer links, citations, store links.
        return .externalBrowser(url)
    }

    /// True when this popup was opened for the account menu's "Add another account":
    /// a plain accounts.google.com link without a size and without an OAuth path.
    /// An OAuth popup must never be treated as an account flow: rule 1 of
    /// `routeInsidePopup` would pull its Gemini callback into the main view and break
    /// the handshake with the page that opened it.
    static func isAccountFlow(initialURL: URL?, hadExplicitSize: Bool) -> Bool {
        guard !hadExplicitSize,
              initialURL?.host?.lowercased() == "accounts.google.com",
              !(initialURL?.path.lowercased().contains("oauth") ?? false) else {
            return false
        }
        return true
    }

    /// Decision for a main-frame navigation inside a popup. First match wins.
    static func routeInsidePopup(url: URL,
                                 openedForAccount: Bool,
                                 startedBlank: Bool,
                                 isFirstNavigation: Bool,
                                 hadExplicitSize: Bool) -> PopupNavigationDecision {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        // 1. The add-account flow finished and returned to Gemini.
        if openedForAccount,
           host == "gemini.google.com",
           path == "/" || path.hasPrefix("/app") || path.hasPrefix("/gem") {
            return .moveToMain(url)
        }
        if startedBlank && isFirstNavigation && !hadExplicitSize {
            // 2.
            if host == "accounts.google.com" {
                return .allow
            }
            // 3.
            if host == "gemini.google.com" {
                return .moveToMain(url)
            }
            // 4. For example Export to Docs.
            return .moveToBrowser(url)
        }
        // 5. OAuth popups wander across hosts and then close themselves.
        return .allow
    }

    /// True for nil and `about:blank` URLs.
    static func isBlankURL(_ url: URL?) -> Bool {
        url == nil || url?.absoluteString.lowercased() == "about:blank"
    }
}
