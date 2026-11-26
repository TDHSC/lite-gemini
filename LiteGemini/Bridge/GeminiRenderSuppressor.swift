import Foundation
import os
import WebKit

/// Manages a toggleable CSS stylesheet (`<style id="lg-native-render-suppressor">`) inside
/// hidden `GeminiSessionEngine` `WKWebView` instances to suppress offscreen paint, animation,
/// and syntax-highlight churn while Native Mode is active.
///
/// Design invariants:
/// - Disables CSS animations, transitions, smooth scrolling, backdrop blurs, and GPU layer
///   promotion hints globally while suppressed.
/// - Applies safe CSS containment (`contain: layout style paint;`) strictly to read-only prose,
///   code blocks, thinking traces, and spinner SVGs — never setting `display: none` or
///   `visibility: hidden` on interactive DOM nodes required by `GeminiActionDriver` or
///   `TemporaryChatController`.
/// - Disabling suppression immediately removes `#lg-native-render-suppressor` from the live
///   document and removes the `.atDocumentStart` user script so Classic Web Mode renders with
///   100% normal computed styles.
@MainActor
final class GeminiRenderSuppressor {

    // MARK: - Constants

    /// DOM `id` assigned to the injected suppression `<style>` element.
    nonisolated static let styleElementId = "lg-native-render-suppressor"

    /// Data attribute tagging `<style>` nodes owned by `GeminiRenderSuppressor`.
    nonisolated static let styleDataAttribute = "data-lg-render-suppressor"

    /// Unique comment marker embedded in the `.atDocumentStart` `WKUserScript` so it can be
    /// cleanly added or removed from `WKUserContentController` without disturbing other scripts.
    private nonisolated static let userScriptMarker = "/* lg-native-render-suppressor-user-script */"

    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "GeminiBridge")

    // MARK: - Suppression Stylesheet & Scripts

    /// Deduplicated selectors for heavy read-only markdown bodies, syntax-highlighted code blocks,
    /// reasoning traces, and progress-spinner SVGs isolated via CSS containment.
    nonisolated static let paintContainedSelectors: [String] = {
        var ordered: [String] = []
        var seen: Set<String> = []
        let candidates: [String] = [
            "message-content .markdown-main-panel"
        ]
        + GeminiBridgeSelectors.ConversationDOM.modelMessageContent.all
        + [
            "code-block",
            "code-block pre",
            "message-content pre"
        ]
        + GeminiBridgeSelectors.ConversationDOM.modelThoughts.all
        + [
            "mat-progress-spinner svg"
        ]

        for selector in candidates where seen.insert(selector).inserted {
            ordered.append(selector)
        }
        return ordered
    }()

    /// Stylesheet injected into `#lg-native-render-suppressor` when render suppression is active.
    ///
    /// Keeps every interactive composer, overlay, turn-action, temporary-chat, and upload-status
    /// element mounted, visible, focusable, and clickable while eliminating offscreen animation,
    /// transition, smooth-scroll, and syntax-highlight repaint churn.
    nonisolated static let suppressionCSS: String = {
        let containedSelectorList = paintContainedSelectors.joined(separator: ",\n")
        return """
        *, *::before, *::after {
            animation: none !important;
            animation-duration: 0s !important;
            animation-delay: 0s !important;
            animation-iteration-count: 1 !important;
            transition: none !important;
            transition-duration: 0s !important;
            transition-delay: 0s !important;
            scroll-behavior: auto !important;
            will-change: auto !important;
            backdrop-filter: none !important;
            -webkit-backdrop-filter: none !important;
        }

        \(containedSelectorList) {
            contain: layout style paint !important;
            box-shadow: none !important;
            text-shadow: none !important;
            filter: none !important;
        }
        """
    }()

    /// Document-start JavaScript injected into the main frame when suppression is enabled.
    nonisolated static let documentStartScriptSource: String = {
        let config: [String: String] = [
            "styleId": styleElementId,
            "dataAttr": styleDataAttribute,
            "cssText": suppressionCSS
        ]
        let configJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
           let encoded = String(data: data, encoding: .utf8) {
            configJSON = encoded
        } else {
            configJSON = "{}"
        }

        return """
        \(userScriptMarker)
        (function() {
            var CFG = \(configJSON);
            if (!CFG.styleId || !CFG.cssText) return;
            window.__lgRenderSuppressorActive = true;

            function installStyle() {
                if (!window.__lgRenderSuppressorActive) return false;
                var host = document.head || document.documentElement;
                if (!host) return false;

                var existing = document.getElementById(CFG.styleId);
                if (existing) {
                    if (existing.textContent !== CFG.cssText) {
                        existing.textContent = CFG.cssText;
                    }
                    if (document.head && existing.parentNode !== document.head) {
                        document.head.appendChild(existing);
                    }
                    return true;
                }

                var style = document.createElement('style');
                style.id = CFG.styleId;
                style.setAttribute(CFG.dataAttr, 'true');
                style.textContent = CFG.cssText;
                host.appendChild(style);
                return true;
            }

            var installed = installStyle();
            if (!installed || !document.head) {
                document.addEventListener('DOMContentLoaded', function() {
                    installStyle();
                }, { once: true });
            }
        })();
        """
    }()

    /// Function body executed via `WKWebView.callAsyncJavaScript` to toggle `#lg-native-render-suppressor`
    /// dynamically without reloading the page.
    private nonisolated static let setSuppressedFunctionBody = """
    window.__lgRenderSuppressorActive = Boolean(suppressed);

    if (!suppressed) {
        var removedCount = 0;
        try {
            var nodes = document.querySelectorAll('#' + styleId + ', style[' + dataAttr + ']');
            for (var i = 0; i < nodes.length; i += 1) {
                if (nodes[i] && nodes[i].parentNode) {
                    nodes[i].parentNode.removeChild(nodes[i]);
                    removedCount += 1;
                }
            }
        } catch (_) {
            var fallback = document.getElementById(styleId);
            if (fallback && fallback.parentNode) {
                fallback.parentNode.removeChild(fallback);
                removedCount += 1;
            }
        }
        return { active: false, removedCount: removedCount };
    }

    function ensureStyle() {
        if (!window.__lgRenderSuppressorActive) return false;
        var host = document.head || document.documentElement;
        if (!host) return false;

        var existing = document.getElementById(styleId);
        if (existing) {
            if (existing.textContent !== cssText) {
                existing.textContent = cssText;
            }
            if (document.head && existing.parentNode !== document.head) {
                document.head.appendChild(existing);
            }
            return true;
        }

        var style = document.createElement('style');
        style.id = styleId;
        style.setAttribute(dataAttr, 'true');
        style.textContent = cssText;
        host.appendChild(style);
        return true;
    }

    var applied = ensureStyle();
    if (!applied || !document.head) {
        document.addEventListener('DOMContentLoaded', function() {
            ensureStyle();
        }, { once: true });
    }
    return { active: true, applied: applied };
    """

    // MARK: - State

    /// Whether render suppression is currently active.
    private(set) var isSuppressed: Bool

    /// Monotonic counter preventing stale navigation reconciliation tasks from overriding newer toggles.
    private var stateGeneration: UInt64 = 0

    // MARK: - Initialization

    /// Creates a render suppressor controller.
    ///
    /// - Parameter suppressRenderByDefault: Whether suppression begins active (`true` by default
    ///   for hidden Native Mode `WKWebView` instances).
    init(suppressRenderByDefault: Bool = true) {
        self.isSuppressed = suppressRenderByDefault
    }

    // MARK: - WKUserScript Management

    /// Builds the `.atDocumentStart`, main-frame-only `WKUserScript` that installs
    /// `<style id="lg-native-render-suppressor">` prior to initial paint.
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: documentStartScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    /// Configures `configuration.userContentController` with the initial `.atDocumentStart`
    /// suppressor script when `isSuppressed == true`.
    func configureInitialUserScript(on configuration: WKWebViewConfiguration) {
        syncUserScript(suppressed: isSuppressed, on: configuration.userContentController)
    }

    // MARK: - Dynamic Suppression Control

    /// Enables or disables paint suppression immediately in `webView` and updates its
    /// `WKUserContentController` so future navigations honor the requested state.
    func setSuppressed(_ suppressed: Bool, in webView: WKWebView) async {
        isSuppressed = suppressed
        stateGeneration &+= 1
        let targetGeneration = stateGeneration

        syncUserScript(suppressed: suppressed, on: webView.configuration.userContentController)
        await applyDocumentState(
            suppressed: suppressed,
            in: webView,
            expectedGeneration: targetGeneration
        )
    }

    /// Re-synchronizes the currently loaded document in `webView` with `isSuppressed` after a
    /// navigation commits or finishes.
    func reconcileNavigation(in webView: WKWebView) async {
        let targetState = isSuppressed
        let targetGeneration = stateGeneration

        syncUserScript(suppressed: targetState, on: webView.configuration.userContentController)
        await applyDocumentState(
            suppressed: targetState,
            in: webView,
            expectedGeneration: targetGeneration
        )
    }

    // MARK: - Private Helpers

    private func syncUserScript(
        suppressed: Bool,
        on contentController: WKUserContentController
    ) {
        let existing = contentController.userScripts
        let hasSuppressorScript = existing.contains(where: Self.isSuppressorScript)

        if suppressed {
            if !hasSuppressorScript {
                contentController.addUserScript(Self.makeUserScript())
            }
        } else if hasSuppressorScript {
            let preserved = existing.filter { !Self.isSuppressorScript($0) }
            contentController.removeAllUserScripts()
            for script in preserved {
                contentController.addUserScript(script)
            }
        }
    }

    private func applyDocumentState(
        suppressed: Bool,
        in webView: WKWebView,
        expectedGeneration: UInt64
    ) async {
        guard stateGeneration == expectedGeneration else { return }

        let arguments: [String: Any] = [
            "suppressed": suppressed,
            "styleId": Self.styleElementId,
            "dataAttr": Self.styleDataAttribute,
            "cssText": Self.suppressionCSS
        ]

        do {
            _ = try await webView.callAsyncJavaScript(
                Self.setSuppressedFunctionBody,
                arguments: arguments,
                in: nil,
                contentWorld: .page
            )
        } catch {
            Self.logger.debug(
                "GeminiRenderSuppressor sync deferred suppressed=\(suppressed, privacy: .public) code=\((error as NSError).code, privacy: .public)"
            )
        }
    }

    private static func isSuppressorScript(_ script: WKUserScript) -> Bool {
        script.source.contains(userScriptMarker)
    }
}
