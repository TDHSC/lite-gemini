import Foundation
import Security
import WebKit

/// JavaScript snippets injected into the Classic WebView (`ClassicWebViewModel`),
/// `GeminiSessionEngine`, and sign-in `PopupWindowController` instances.
enum ClassicWebScripts {

    private nonisolated static let webAuthnGuardMarker = "/* lg-webauthn-unentitled-guard */"

    /// Returns `true` only when the host process holds Apple's restricted
    /// `com.apple.developer.web-browser.public-key-credential` entitlement required by
    /// `AuthenticationServicesAgent` for arbitrary-domain `WKWebView` Passkey assertions.
    nonisolated static func hasWebBrowserPasskeyEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let raw = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.web-browser.public-key-credential" as CFString,
                  nil
              ) else {
            return false
        }
        return (raw as? Bool) == true
    }

    /// Installs a `.atDocumentStart` guard disabling `window.PublicKeyCredential` when the app
    /// is ad-hoc signed without Apple's restricted browser WebAuthn entitlement.
    ///
    /// Without this guard, `WKWebView` reports `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable() == true`
    /// (checking Mac Touch ID hardware rather than app entitlements), causing `accounts.google.com`
    /// to auto-force the Passkey screen and fail with `"Something went wrong"` (`AuthorizationError 1004`).
    /// Hiding `PublicKeyCredential` makes Google Accounts smoothly offer Password, Google Prompt, and 2FA.
    @MainActor
    static func installWebAuthnFallbackIfNeeded(on contentController: WKUserContentController) {
        guard !hasWebBrowserPasskeyEntitlement() else {
            return
        }
        let alreadyInstalled = contentController.userScripts.contains {
            $0.source.contains(webAuthnGuardMarker)
        }
        guard !alreadyInstalled else {
            return
        }
        let script = WKUserScript(
            source: disableUnsupportedWebAuthnScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(script)
    }

    /// Document-start script hiding unsupported WebAuthn APIs on Google sign-in pages in unentitled builds.
    nonisolated static let disableUnsupportedWebAuthnScript = """
    /* lg-webauthn-unentitled-guard */
    (function() {
        if (window.__lgWebAuthnGuardInstalled) return;
        window.__lgWebAuthnGuardInstalled = true;

        var host = (window.location && window.location.hostname ? window.location.hostname : '').toLowerCase();
        if (host && host !== 'accounts.google.com' && !host.endsWith('.google.com')) {
            return;
        }

        try {
            if (typeof window.PublicKeyCredential !== 'undefined') {
                try {
                    window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function() {
                        return Promise.resolve(false);
                    };
                    window.PublicKeyCredential.isConditionalMediationAvailable = function() {
                        return Promise.resolve(false);
                    };
                } catch (_) {}

                var deleted = false;
                try {
                    deleted = delete window.PublicKeyCredential;
                } catch (_) {}
                if (!deleted && typeof window.PublicKeyCredential !== 'undefined') {
                    try {
                        Object.defineProperty(window, 'PublicKeyCredential', {
                            value: undefined,
                            configurable: true,
                            writable: true
                        });
                    } catch (_) {}
                }
            }
        } catch (_) {}

        try {
            var creds = navigator && navigator.credentials;
            if (creds) {
                if (typeof creds.get === 'function') {
                    var origGet = creds.get.bind(creds);
                    creds.get = function(options) {
                        if (options && options.publicKey) {
                            return Promise.reject(
                                new DOMException('Passkeys require a browser WebAuthn entitlement on macOS.', 'NotSupportedError')
                            );
                        }
                        return origGet(options);
                    };
                }
                if (typeof creds.create === 'function') {
                    var origCreate = creds.create.bind(creds);
                    creds.create = function(options) {
                        if (options && options.publicKey) {
                            return Promise.reject(
                                new DOMException('Passkeys require a browser WebAuthn entitlement on macOS.', 'NotSupportedError')
                            );
                        }
                        return origCreate(options);
                    };
                }
            }
        } catch (_) {}
    })();
    """

    #if DEBUG
    /// Console log bridge — forwards JS `console.log` calls to the native Xcode console.
    static let consoleLogBridgeScript = """
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
    #endif

    /// Observes the Gemini page's computed background color so the native titlebar and
    /// window backdrop blend seamlessly in both dark (#131314) and light (#FFFFFF) themes.
    static let themeSyncScript = """
    (function() {
        var host = (window.location && window.location.hostname ? window.location.hostname : '').toLowerCase();
        if (window.opener || (host && host !== 'gemini.google.com')) return;
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
        if (window.matchMedia) {
            var mq = window.matchMedia('(prefers-color-scheme: dark)');
            if (mq && mq.addEventListener) {
                mq.addEventListener('change', reportBg);
            }
        }
    })();
    """

    /// IME fix script — injected at document start to register before any page scripts.
    /// Tracks real composing state and blocks buggy Enter events from reaching the page.
    static let imeFixScript = """
    (function() {
        var host = (window.location && window.location.hostname ? window.location.hostname : '').toLowerCase();
        if (window.opener || (host && host !== 'gemini.google.com')) return;
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
}
