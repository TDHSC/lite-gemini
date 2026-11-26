#if DEBUG
import Foundation
import os
import WebKit

/// Debug-only diagnostic recorder for inspecting live Gemini web protocol and DOM structure.
///
/// Activated exclusively when `LG_SPIKE_RECORD=1` is set in the process environment.
/// Compiles to zero code in Release builds. Never logs cookies, auth tokens, raw emails,
/// or private prompt/response text — every value is redacted structurally in JavaScript
/// before crossing IPC and sanitized a second time in Swift before writing JSONL traces
/// to `/tmp/lg-spike/` with owner-only (`0600`) file permissions.
enum GeminiSpikeRecorder {

    // MARK: - Configuration

    /// Environment variable name required to opt in to structural recording in Debug builds
    static let environmentKey = "LG_SPIKE_RECORD"

    /// Default directory for sanitized JSONL diagnostic traces
    static let defaultOutputDirectory = URL(fileURLWithPath: "/tmp/lg-spike", isDirectory: true)

    /// Script message handler name registered on `WKUserContentController`
    static let scriptMessageHandlerName = "lgSpikeRecorder"

    /// True only when the owner explicitly launched the Debug build with `LG_SPIKE_RECORD=1`
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "GeminiSpike")

    // MARK: - Attachment

    /// Attach the non-destructive structural probe to a `WKWebViewConfiguration`.
    /// Returns `nil` and injects nothing unless `LG_SPIKE_RECORD=1` (or `forceEnable` in harnesses).
    static func attach(
        to configuration: WKWebViewConfiguration,
        outputDirectory: URL = defaultOutputDirectory,
        forceEnable: Bool = false
    ) -> Session? {
        guard forceEnable || isEnabled else { return nil }

        let session = Session(outputDirectory: outputDirectory)
        let userScript = makeUserScript()
        configuration.userContentController.addUserScript(userScript)
        configuration.userContentController.add(WeakMessageProxy(session), name: scriptMessageHandlerName)
        logger.notice("GeminiSpikeRecorder attached; writing sanitized traces to \(session.traceFileURL.path, privacy: .public)")
        return session
    }

    /// Build the document-start `WKUserScript` that tees network metadata and DOM shapes
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: probeScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    // MARK: - Recording Session

    /// Active recording session owning the trace file handle and receiving sanitized IPC payloads
    final class Session: NSObject, WKScriptMessageHandler {
        /// Destination JSONL file written during this session
        let traceFileURL: URL

        /// Number of sanitized events persisted so far
        private(set) var recordedEventCount = 0

        init(outputDirectory: URL) {
            let timestamp = ISO8601DateFormatter()
                .string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let fileName = "spike-\(timestamp)-\(UUID().uuidString.prefix(8)).jsonl"
            self.traceFileURL = outputDirectory.appendingPathComponent(fileName)
            super.init()
            prepareOutputFile(in: outputDirectory)
        }

        /// Remove the script message handler when tearing down the `WKWebView`
        func detach(from controller: WKUserContentController) {
            controller.removeScriptMessageHandler(forName: GeminiSpikeRecorder.scriptMessageHandlerName)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == GeminiSpikeRecorder.scriptMessageHandlerName else { return }
            recordRawPayload(message.body)
        }

        /// Sanitize an arbitrary event payload and append one JSONL record to disk
        func recordRawPayload(_ payload: Any) {
            let sanitized = GeminiSpikeRecorder.sanitizeValue(payload, depth: 0)
            let envelope: [String: Any] = [
                "recordedAt": ISO8601DateFormatter().string(from: Date()),
                "schemaVersion": GeminiBridgeSelectors.schemaVersion,
                "event": sanitized
            ]

            guard JSONSerialization.isValidJSONObject(envelope),
                  let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
                  var line = String(data: data, encoding: .utf8) else {
                return
            }
            line.append("\n")

            if let handle = try? FileHandle(forWritingTo: traceFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                if let lineData = line.data(using: .utf8) {
                    try? handle.write(contentsOf: lineData)
                    recordedEventCount += 1
                }
            }

            if let dict = sanitized as? [String: Any], let kind = dict["kind"] as? String {
                GeminiSpikeRecorder.logger.debug("spike-event kind=\(kind, privacy: .public) count=\(self.recordedEventCount, privacy: .public)")
            }
        }

        private func prepareOutputFile(in directory: URL) {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !fileManager.fileExists(atPath: traceFileURL.path) {
                fileManager.createFile(
                    atPath: traceFileURL.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                )
            }
        }
    }

    // MARK: - Swift Defense-in-Depth Sanitization

    /// Redact emails, tokens, credentials, and long arbitrary strings from any bridged structure
    nonisolated static func sanitizeValue(_ value: Any, depth: Int) -> Any {
        guard depth < 8 else { return "<max-depth>" }

        if let dict = value as? [String: Any] {
            var output: [String: Any] = [:]
            output.reserveCapacity(dict.count)
            for (key, item) in dict {
                if isSensitiveKey(key) {
                    output[key] = "<redacted>"
                } else {
                    output[key] = sanitizeValue(item, depth: depth + 1)
                }
            }
            return output
        }

        if let array = value as? [Any] {
            let capped = array.prefix(64)
            var result = capped.map { sanitizeValue($0, depth: depth + 1) }
            if array.count > 64 {
                result.append("<truncated:\(array.count - 64)>")
            }
            return result
        }

        if let string = value as? String {
            return sanitizeString(string)
        }

        if let number = value as? NSNumber {
            return number
        }

        if value is NSNull {
            return NSNull()
        }

        return "<\(type(of: value))>"
    }

    /// Redact email addresses, long bearer/API/XSRF tokens, and sensitive query parameters
    nonisolated static func sanitizeString(_ raw: String) -> String {
        var text = raw

        // Redact email addresses
        text = replacingMatches(
            in: text,
            pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
            template: "<email>"
        )

        // Redact sensitive URL query values (tokens, session IDs, encoded header bundles)
        text = replacingMatches(
            in: text,
            pattern: #"([?&](?:\$httpHeaders|%24httpHeaders|at|token|key|gsessionid|SID|f\.sid|auth|continue)=)[^&\s]+"#,
            template: "$1<redacted>"
        )

        // Redact Google API keys and bearer/SAPISIDHASH headers
        text = replacingMatches(
            in: text,
            pattern: #"AIza[0-9A-Za-z_\-]{20,}"#,
            template: "<api-key>"
        )
        text = replacingMatches(
            in: text,
            pattern: #"(?i)\b(?:Bearer|SAPISIDHASH)\s+[A-Za-z0-9._\-:\/+=]+"#,
            template: "<auth-header>"
        )

        // Redact long opaque token-like strings (preserve URLs, paths, and boq build labels)
        if !text.hasPrefix("http://"),
           !text.hasPrefix("https://"),
           !text.hasPrefix("/"),
           !text.hasPrefix("boq_") {
            text = replacingMatches(
                in: text,
                pattern: #"[A-Za-z0-9_\-+/=]{40,}"#,
                template: "<token>"
            )
        }

        if text.count > 240 {
            return String(text.prefix(240)) + "...<len=\(raw.count)>"
        }
        return text
    }

    private nonisolated static func isSensitiveKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        let exactBlocked: Set<String> = [
            "authorization", "cookie", "set-cookie", "x-goog-api-key",
            "x-server-token", "at", "snlm0e", "opep7c", "s06grb",
            "pi9wob", "tsdtv", "d2zjae", "email", "token"
        ]
        if exactBlocked.contains(lower) { return true }
        return lower.contains("cookie") || lower.contains("secret") || lower.contains("password")
    }

    private nonisolated static func replacingMatches(in input: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return input
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }

    // MARK: - Weak Script Message Proxy

    /// Breaks retain cycles because `WKUserContentController` retains registered handlers strongly
    private final class WeakMessageProxy: NSObject, WKScriptMessageHandler {
        weak var target: Session?

        init(_ target: Session) {
            self.target = target
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            target?.userContentController(userContentController, didReceive: message)
        }
    }

    // MARK: - Page Probe Script

    /// Non-destructive structural probe injected at document start when `LG_SPIKE_RECORD=1`.
    /// Tees network responses without modifying or delaying page consumers, summarizing only
    /// structural shapes (types, lengths, RPC IDs, element tags/classes/test-ids/icons).
    static let probeScriptSource: String = {
        let handlerName = scriptMessageHandlerName
        let safeWizKeys = [
            GeminiBridgeSelectors.WizGlobalDataKeys.buildLabel,
            GeminiBridgeSelectors.WizGlobalDataKeys.rpcPrefix,
            GeminiBridgeSelectors.WizGlobalDataKeys.apiHost,
            GeminiBridgeSelectors.WizGlobalDataKeys.authUserIndex,
            GeminiBridgeSelectors.WizGlobalDataKeys.locale,
            GeminiBridgeSelectors.WizGlobalDataKeys.isAnonymousSession
        ]
        let presenceWizKeys = [
            GeminiBridgeSelectors.WizGlobalDataKeys.xsrfToken,
            GeminiBridgeSelectors.WizGlobalDataKeys.gaiaUserId,
            GeminiBridgeSelectors.WizGlobalDataKeys.userEmail,
            GeminiBridgeSelectors.WizGlobalDataKeys.sessionId,
            GeminiBridgeSelectors.WizGlobalDataKeys.uploadURL
        ]
        let safeKeysJSON = (try? String(data: JSONSerialization.data(withJSONObject: safeWizKeys), encoding: .utf8)) ?? "[]"
        let presenceKeysJSON = (try? String(data: JSONSerialization.data(withJSONObject: presenceWizKeys), encoding: .utf8)) ?? "[]"

        return """
        (function() {
            if (window.__lgSpikeRecorderInstalled) return;
            window.__lgSpikeRecorderInstalled = true;

            var HANDLER = "\(handlerName)";
            var SAFE_WIZ_KEYS = \(safeKeysJSON);
            var PRESENCE_WIZ_KEYS = \(presenceKeysJSON);

            function post(kind, payload) {
                try {
                    window.webkit.messageHandlers[HANDLER].postMessage({
                        kind: kind,
                        ts: Date.now(),
                        path: String(location.pathname || ''),
                        data: payload
                    });
                } catch (e) {}
            }

            function sanitizeUrl(rawUrl) {
                try {
                    var u = new URL(String(rawUrl || ''), location.origin);
                    var params = [];
                    u.searchParams.forEach(function(v, k) {
                        var kl = k.toLowerCase();
                        if (kl === 'rpcids' || kl === 'source-path' || kl === 'bl' || kl === 'rt' || kl === 'alt' || kl === 'ver' || kl === 'type' || kl === 'authuser') {
                            params.push(k + '=' + v.slice(0, 80));
                        } else {
                            params.push(k + '=<redacted>');
                        }
                    });
                    return u.origin + u.pathname + (params.length ? '?' + params.join('&') : '');
                } catch (e) {
                    return '<unparseable-url>';
                }
            }

            function summarizeJsonShape(val, depth) {
                if (depth > 5) return '<depth>';
                if (val === null) return null;
                var t = typeof val;
                if (t === 'boolean' || t === 'number') return t;
                if (t === 'string') {
                    if (/^(c|r|rc)_[0-9a-f]{8,}$/i.test(val)) return val.slice(0, 3) + '<id>';
                    if (val === 'wrb.fr' || val === 'generic' || val === 'di' || val === 'e') return val;
                    if (/^[A-Za-z0-9_-]{4,8}$/.test(val)) return '<code:' + val.length + '>';
                    return '<str:' + val.length + '>';
                }
                if (Array.isArray(val)) {
                    var out = [];
                    var limit = Math.min(val.length, 16);
                    for (var i = 0; i < limit; i++) {
                        out.push(summarizeJsonShape(val[i], depth + 1));
                    }
                    if (val.length > limit) out.push('<+' + (val.length - limit) + '>');
                    return out;
                }
                if (t === 'object') {
                    var keys = Object.keys(val).slice(0, 16);
                    var obj = {};
                    for (var j = 0; j < keys.length; j++) {
                        obj[keys[j]] = summarizeJsonShape(val[keys[j]], depth + 1);
                    }
                    return obj;
                }
                return t;
            }

            function summarizeResponseText(txt) {
                var clean = String(txt || '');
                var hadXssi = clean.indexOf(")]}'") === 0;
                if (hadXssi) {
                    var nl = clean.indexOf('\\n');
                    clean = nl >= 0 ? clean.slice(nl + 1) : clean;
                }
                var lines = clean.split('\\n').filter(function(l) { return l.trim().length > 0; });
                var frames = [];
                for (var i = 0; i < lines.length && frames.length < 6; i++) {
                    var line = lines[i].trim();
                    if (line.indexOf('data:') === 0) line = line.slice(5).trim();
                    if (line.charAt(0) === '[' || line.charAt(0) === '{') {
                        try {
                            var parsed = JSON.parse(line);
                            var frameInfo = { shape: summarizeJsonShape(parsed, 0) };
                            if (Array.isArray(parsed) && Array.isArray(parsed[0]) && parsed[0][0] === 'wrb.fr') {
                                frameInfo.rpcId = typeof parsed[0][1] === 'string' ? parsed[0][1] : null;
                                if (typeof parsed[0][2] === 'string') {
                                    try {
                                        frameInfo.innerShape = summarizeJsonShape(JSON.parse(parsed[0][2]), 0);
                                    } catch (e) {
                                        frameInfo.innerLen = parsed[0][2].length;
                                    }
                                }
                                if (parsed[0][5] != null) frameInfo.error = parsed[0][5];
                            }
                            frames.push(frameInfo);
                        } catch (e) {}
                    }
                }
                return { len: String(txt || '').length, hadXssi: hadXssi, frameCount: frames.length, frames: frames };
            }

            function isTrackedUrl(url) {
                var lower = String(url || '').toLowerCase();
                return lower.indexOf('processsession') >= 0
                    || lower.indexOf('streamgenerate') >= 0
                    || lower.indexOf('batchexecute') >= 0
                    || lower.indexOf('/upload/') >= 0;
            }

            var origFetch = window.fetch;
            if (typeof origFetch === 'function') {
                window.fetch = function(input, init) {
                    var rawUrl = typeof input === 'string' ? input : (input && input.url) || '';
                    var method = (init && init.method) || (input && input.method) || 'GET';
                    return origFetch.apply(this, arguments).then(function(resp) {
                        if (isTrackedUrl(rawUrl) && typeof resp.clone === 'function') {
                            var safeUrl = sanitizeUrl(rawUrl);
                            var ct = resp.headers ? (resp.headers.get('content-type') || '') : '';
                            resp.clone().text().then(function(txt) {
                                post('fetch', {
                                    url: safeUrl,
                                    method: method,
                                    status: resp.status,
                                    contentType: ct,
                                    summary: summarizeResponseText(txt)
                                });
                            }).catch(function() {});
                        }
                        return resp;
                    });
                };
            }

            var origOpen = XMLHttpRequest.prototype.open;
            var origSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url) {
                this.__lgSpikeMethod = method;
                this.__lgSpikeUrl = String(url || '');
                this.__lgSpikeFrames = 0;
                return origOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function() {
                var xhr = this;
                var rawUrl = xhr.__lgSpikeUrl || '';
                if (isTrackedUrl(rawUrl)) {
                    var safeUrl = sanitizeUrl(rawUrl);
                    xhr.addEventListener('progress', function() {
                        xhr.__lgSpikeFrames = (xhr.__lgSpikeFrames || 0) + 1;
                    });
                    xhr.addEventListener('loadend', function() {
                        var txt = '';
                        try { txt = typeof xhr.responseText === 'string' ? xhr.responseText : ''; } catch (e) {}
                        post('xhr', {
                            url: safeUrl,
                            method: xhr.__lgSpikeMethod || '',
                            status: xhr.status,
                            progressTicks: xhr.__lgSpikeFrames || 0,
                            summary: summarizeResponseText(txt)
                        });
                    });
                }
                return origSend.apply(this, arguments);
            };

            function snapshotBootAndDom(phase) {
                var wiz = window.WIZ_global_data || {};
                var wizSafe = {};
                for (var i = 0; i < SAFE_WIZ_KEYS.length; i++) {
                    var k = SAFE_WIZ_KEYS[i];
                    if (k in wiz) wizSafe[k] = wiz[k];
                }
                var wizPresence = {};
                for (var j = 0; j < PRESENCE_WIZ_KEYS.length; j++) {
                    var pk = PRESENCE_WIZ_KEYS[j];
                    var pv = wiz[pk];
                    wizPresence[pk] = { present: pv !== undefined && pv !== null && pv !== '', type: typeof pv, len: typeof pv === 'string' ? pv.length : 0 };
                }

                var probeSelectors = [
                    'rich-textarea .ql-editor[contenteditable="true"]',
                    'input-area-v2 button[jslog^="173899;"]',
                    'input-area-v2 button[jslog^="188689;"]',
                    '[data-test-id="bard-mode-menu-button"]',
                    'temp-chat-button',
                    'sidenav-mavatar-footer a[gem-open-account-menu]',
                    'a[href*="accounts.google.com/ServiceLogin"]',
                    'user-query',
                    'model-response',
                    'model-thoughts',
                    'regenerate-button'
                ];
                var domCounts = {};
                for (var s = 0; s < probeSelectors.length; s++) {
                    try {
                        domCounts[probeSelectors[s]] = document.querySelectorAll(probeSelectors[s]).length;
                    } catch (e) {
                        domCounts[probeSelectors[s]] = -1;
                    }
                }
                post('dom_snapshot', {
                    phase: phase,
                    wizKeyCount: Object.keys(wiz).length,
                    wizSafe: wizSafe,
                    wizPresence: wizPresence,
                    domCounts: domCounts
                });
            }

            document.addEventListener('DOMContentLoaded', function() { snapshotBootAndDom('DOMContentLoaded'); });
            window.addEventListener('load', function() { setTimeout(function() { snapshotBootAndDom('load'); }, 1500); });
        })();
        """
    }()
}
#endif
