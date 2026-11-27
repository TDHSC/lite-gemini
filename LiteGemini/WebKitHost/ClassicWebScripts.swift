import Foundation
import Security
import WebKit

/// JavaScript snippets injected into the Classic WebView (`ClassicWebViewModel`),
/// `GeminiSessionEngine`, and sign-in `PopupWindowController` instances.
enum ClassicWebScripts {

    private nonisolated static let webAuthnGuardMarker = "/* lg-webauthn-unentitled-guard */"

    /// Returns `true` only when the host process holds Apple's restricted browser WebAuthn
    /// entitlement required by `AuthenticationServicesAgent` (`+[ASCAgent isClientWithAuditTokenAWebBrowser:]`)
    /// for arbitrary-domain `WKWebView` Passkey assertions.
    nonisolated static func hasWebBrowserPasskeyEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else {
            return false
        }
        let browserEntitlements: [CFString] = [
            "com.apple.developer.web-browser.public-key-credential" as CFString,
            "com.apple.developer.web-browser" as CFString
        ]
        for key in browserEntitlements {
            if let raw = SecTaskCopyValueForEntitlement(task, key, nil),
               (raw as? Bool) == true {
                return true
            }
        }
        return false
    }

    /// Installs a `.atDocumentStart` guard removing unsupported WebAuthn globals when the app
    /// is signed without Apple's restricted browser WebAuthn entitlement.
    ///
    /// On macOS, `AuthenticationServicesAgent` rejects both modal and conditional (`mediation: "conditional"`)
    /// `PublicKeyCredential` requests from unentitled `WKWebView` hosts (`AuthorizationError 1004`),
    /// yet `WKWebView` still exposes `window.PublicKeyCredential` and `getClientCapabilities()` reporting
    /// platform and hybrid Bluetooth passkey support. Removing WebAuthn constructors at document start
    /// keeps `Credential` / `CredentialsContainer` intact for Keychain Password AutoFill while making
    /// Google Accounts route directly to `/v3/signin/challenge/pwd` (Password / Google Prompt / 2FA)
    /// instead of failing on `/v3/signin/challenge/pk` with `"Something went wrong"`.
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

    /// Document-start script removing unsupported WebAuthn APIs in unentitled `WKWebView` builds
    /// while preserving `CredentialsContainer` for standard password credentials and AutoFill.
    nonisolated static let disableUnsupportedWebAuthnScript = """
    /* lg-webauthn-unentitled-guard */
    (function() {
        if (window.__lgWebAuthnGuardInstalled) return;
        window.__lgWebAuthnGuardInstalled = true;

        try {
            if (typeof window.PublicKeyCredential !== 'undefined') {
                try {
                    window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function() {
                        return Promise.resolve(false);
                    };
                    window.PublicKeyCredential.isConditionalMediationAvailable = function() {
                        return Promise.resolve(false);
                    };
                    window.PublicKeyCredential.getClientCapabilities = function() {
                        return Promise.resolve({});
                    };
                } catch (_) {}
            }

            var webAuthnGlobals = [
                'PublicKeyCredential',
                'AuthenticatorResponse',
                'AuthenticatorAssertionResponse',
                'AuthenticatorAttestationResponse'
            ];
            var winProto = typeof Window === 'function' ? Window.prototype : null;
            for (var i = 0; i < webAuthnGlobals.length; i++) {
                var prop = webAuthnGlobals[i];
                try { delete window[prop]; } catch (_) {}
                if (winProto) {
                    try { delete winProto[prop]; } catch (_) {}
                }
            }
        } catch (_) {}

        try {
            var proto = (typeof window.CredentialsContainer === 'function' && window.CredentialsContainer.prototype)
                ? window.CredentialsContainer.prototype
                : (navigator && navigator.credentials ? Object.getPrototypeOf(navigator.credentials) : null);

            if (proto && typeof proto.get === 'function') {
                var origProtoGet = proto.get;
                proto.get = function(options) {
                    if (options && options.publicKey) {
                        if (options.password || options.federated || options.identity) {
                            var cloned = Object.assign({}, options);
                            delete cloned.publicKey;
                            return origProtoGet.call(this, cloned);
                        }
                        return Promise.reject(
                            new DOMException('The operation is not supported.', 'NotSupportedError')
                        );
                    }
                    return origProtoGet.apply(this, arguments);
                };
            }
            if (proto && typeof proto.create === 'function') {
                var origProtoCreate = proto.create;
                proto.create = function(options) {
                    if (options && options.publicKey) {
                        return Promise.reject(
                            new DOMException('The operation is not supported.', 'NotSupportedError')
                        );
                    }
                    return origProtoCreate.apply(this, arguments);
                };
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
