import Foundation
import WebKit

/// Document-start JavaScript read tap injected into the main frame of `GeminiSessionEngine`.
///
/// Passively tees `window.fetch` (`Response.clone()` + `ReadableStream`) and `XMLHttpRequest`
/// (`progress` incremental `responseText` delta slicing) for the endpoints verified in §5 without
/// mutating or delaying page consumers, reports HTTP `401`/`403` challenges immediately, and
/// observes `WIZ_global_data` boot globals, auth DOM markers, and SPA URL transitions.
enum GeminiBridgeScript {

    // MARK: - Constants

    /// `WKScriptMessageHandler` channel name registered by `GeminiSessionEngine`.
    static let messageHandlerName = "geminiBridge"

    /// Streaming/RPC transport names posted by the injected script.
    nonisolated enum TransportKind: String, Sendable {
        case processSession
        case streamGenerateSSE
        case legacyStreamGenerate
        case batchExecute
    }

    // MARK: - WKUserScript Factory

    /// Builds the `.atDocumentStart`, main-frame-only `WKUserScript` read tap.
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    /// JavaScript expression invoking an on-demand boot/DOM snapshot report from the page.
    static let triggerBootSnapshotExpression = """
    (function() {
        if (typeof window.__lgBridgeReportBootSnapshot === 'function') {
            window.__lgBridgeReportBootSnapshot('probe');
            return true;
        }
        return false;
    })()
    """

    // MARK: - Generated JavaScript Source

    /// Complete document-start JavaScript read tap generated directly from `GeminiBridgeSelectors`.
    static let scriptSource: String = {
        typealias Endpoints = GeminiBridgeSelectors.Endpoints
        typealias WizKeys = GeminiBridgeSelectors.WizGlobalDataKeys
        typealias AuthDOM = GeminiBridgeSelectors.AuthDOM
        typealias ComposerDOM = GeminiBridgeSelectors.ComposerDOM

        let config: [String: Any] = [
            "handlerName": messageHandlerName,
            "endpoints": [
                "processSessionPaths": [
                    Endpoints.processSessionPath.lowercased(),
                    Endpoints.processSessionRPCPath.lowercased()
                ],
                "streamGenerateSSEPath": Endpoints.streamGenerateSSEPath.lowercased(),
                "legacyStreamGeneratePath": Endpoints.legacyStreamGeneratePath.lowercased(),
                "batchExecutePath": Endpoints.batchExecutePath.lowercased()
            ],
            "wizKeys": [
                "xsrfToken": WizKeys.xsrfToken,
                "gaiaUserId": WizKeys.gaiaUserId,
                "actualUserObfuscatedId": WizKeys.actualUserObfuscatedId,
                "userEmail": WizKeys.userEmail,
                "authUserIndex": WizKeys.authUserIndex,
                "buildLabel": WizKeys.buildLabel,
                "isViewerLoggedIn": WizKeys.isViewerLoggedIn
            ],
            "selectors": [
                "signedOutTrigger": AuthDOM.signedOutTrigger.all,
                "signedInAccountTrigger": AuthDOM.signedInAccountTrigger.all,
                "accountAvatarImage": AuthDOM.accountAvatarImage.all,
                "tempChatHost": ComposerDOM.tempChatHost.all,
                "tempChatLegacyActiveClass": ComposerDOM.tempChatLegacyActiveClass,
                "tempChatActiveIconName": ComposerDOM.tempChatActiveIconName,
                "tempChatInactiveIconName": ComposerDOM.tempChatInactiveIconName
            ]
        ]

        let configJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
           let encoded = String(data: data, encoding: .utf8) {
            configJSON = encoded
        } else {
            configJSON = "{}"
        }

        return """
        (function() {
            if (window.__lgGeminiBridgeInstalled) return;
            window.__lgGeminiBridgeInstalled = true;

            var CFG = \(configJSON);
            var nextReqSeq = 0;

            function post(type, payload) {
                try {
                    var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[CFG.handlerName];
                    if (!handler) return;
                    var msg = payload && typeof payload === 'object' ? Object.assign({ type: type }, payload) : { type: type };
                    handler.postMessage(msg);
                } catch (e) {}
            }

            function resolveUrlString(input) {
                try {
                    if (typeof input === 'string') return input;
                    if (input && typeof URL !== 'undefined' && input instanceof URL) return input.href;
                    if (input && typeof input.url === 'string') return input.url;
                } catch (e) {}
                return '';
            }

            function classifyTransport(rawUrl) {
                var lower = String(rawUrl || '').toLowerCase();
                if (!lower) return null;

                var psPaths = CFG.endpoints.processSessionPaths || [];
                for (var i = 0; i < psPaths.length; i++) {
                    if (lower.indexOf(psPaths[i]) >= 0) return 'processSession';
                }
                if (lower.indexOf(CFG.endpoints.streamGenerateSSEPath) >= 0) {
                    return 'streamGenerateSSE';
                }
                if (lower.indexOf(CFG.endpoints.legacyStreamGeneratePath) >= 0) {
                    return 'legacyStreamGenerate';
                }
                if (lower.indexOf(CFG.endpoints.batchExecutePath) >= 0) {
                    return 'batchExecute';
                }
                return null;
            }

            function extractRpcIds(rawUrl) {
                try {
                    var parsed = new URL(String(rawUrl || ''), location.href);
                    return parsed.searchParams.get('rpcids') || '';
                } catch (e) {
                    return '';
                }
            }

            function isAuthErrorStatus(status) {
                return status === 401 || status === 403;
            }

            function queryFirst(selectorList) {
                if (!Array.isArray(selectorList)) return null;
                for (var i = 0; i < selectorList.length; i++) {
                    try {
                        var el = document.querySelector(selectorList[i]);
                        if (el) return el;
                    } catch (e) {}
                }
                return null;
            }

            // MARK: - window.fetch Passive Tee

            var origFetch = window.fetch;
            if (typeof origFetch === 'function') {
                window.fetch = function(input, init) {
                    var rawUrl = resolveUrlString(input);
                    var transport = classifyTransport(rawUrl);
                    var reqId = transport ? ('fetch-' + (++nextReqSeq)) : null;

                    var promise = origFetch.apply(this, arguments);
                    if (!transport) {
                        return promise;
                    }

                    var rpcIds = transport === 'batchExecute' ? extractRpcIds(rawUrl) : '';

                    promise.then(function(resp) {
                        if (!resp) return;
                        var effectiveUrl = resp.url || rawUrl;
                        var status = typeof resp.status === 'number' ? resp.status : 0;

                        if (isAuthErrorStatus(status)) {
                            post('httpError', {
                                requestId: reqId,
                                transport: transport,
                                url: effectiveUrl,
                                status: status,
                                rpcids: rpcIds
                            });
                            return;
                        }

                        var cloned = null;
                        try {
                            if (typeof resp.clone === 'function') {
                                cloned = resp.clone();
                            }
                        } catch (e) {
                            return;
                        }
                        if (!cloned) return;

                        if (transport === 'batchExecute') {
                            cloned.text().then(function(bodyText) {
                                post('batchExecute', {
                                    requestId: reqId,
                                    url: effectiveUrl,
                                    status: status,
                                    rpcids: rpcIds,
                                    body: bodyText || ''
                                });
                            }).catch(function() {});
                            return;
                        }

                        post('streamStart', {
                            requestId: reqId,
                            transport: transport,
                            url: effectiveUrl,
                            status: status
                        });

                        if (cloned.body && typeof cloned.body.getReader === 'function') {
                            var reader = cloned.body.getReader();
                            var decoder = typeof TextDecoder !== 'undefined' ? new TextDecoder('utf-8') : null;

                            function pump() {
                                reader.read().then(function(result) {
                                    if (result.done) {
                                        if (decoder) {
                                            var tail = decoder.decode();
                                            if (tail && tail.length > 0) {
                                                post('streamChunk', {
                                                    requestId: reqId,
                                                    transport: transport,
                                                    url: effectiveUrl,
                                                    chunk: tail
                                                });
                                            }
                                        }
                                        post('streamEnd', {
                                            requestId: reqId,
                                            transport: transport,
                                            url: effectiveUrl,
                                            status: status
                                        });
                                        return;
                                    }

                                    var chunkText = '';
                                    if (result.value) {
                                        if (decoder) {
                                            chunkText = decoder.decode(result.value, { stream: true });
                                        } else if (typeof result.value === 'string') {
                                            chunkText = result.value;
                                        }
                                    }
                                    if (chunkText.length > 0) {
                                        post('streamChunk', {
                                            requestId: reqId,
                                            transport: transport,
                                            url: effectiveUrl,
                                            chunk: chunkText
                                        });
                                    }
                                    pump();
                                }).catch(function(err) {
                                    post('streamError', {
                                        requestId: reqId,
                                        transport: transport,
                                        url: effectiveUrl,
                                        status: status,
                                        message: String(err && err.message ? err.message : err)
                                    });
                                });
                            }
                            pump();
                        } else {
                            cloned.text().then(function(bodyText) {
                                if (bodyText && bodyText.length > 0) {
                                    post('streamChunk', {
                                        requestId: reqId,
                                        transport: transport,
                                        url: effectiveUrl,
                                        chunk: bodyText
                                    });
                                }
                                post('streamEnd', {
                                    requestId: reqId,
                                    transport: transport,
                                    url: effectiveUrl,
                                    status: status
                                });
                            }).catch(function(err) {
                                post('streamError', {
                                    requestId: reqId,
                                    transport: transport,
                                    url: effectiveUrl,
                                    status: status,
                                    message: String(err && err.message ? err.message : err)
                                });
                            });
                        }
                    }, function(err) {
                        post('streamError', {
                            requestId: reqId,
                            transport: transport,
                            url: rawUrl,
                            status: 0,
                            message: String(err && err.message ? err.message : err)
                        });
                    });

                    return promise;
                };
            }

            // MARK: - XMLHttpRequest Incremental Delta Tap

            var origOpen = XMLHttpRequest.prototype.open;
            var origSend = XMLHttpRequest.prototype.send;

            XMLHttpRequest.prototype.open = function(method, url) {
                this.__lgBridgeUrl = String(url || '');
                this.__lgBridgeTransport = classifyTransport(this.__lgBridgeUrl);
                this.__lgBridgeOffset = 0;
                this.__lgBridgeStarted = false;
                this.__lgBridgeReportedAuthErr = false;
                this.__lgBridgeReqId = null;
                return origOpen.apply(this, arguments);
            };

            XMLHttpRequest.prototype.send = function() {
                var xhr = this;
                var transport = xhr.__lgBridgeTransport;
                if (!transport) {
                    return origSend.apply(this, arguments);
                }

                var rawUrl = xhr.__lgBridgeUrl || '';
                var reqId = 'xhr-' + (++nextReqSeq);
                xhr.__lgBridgeReqId = reqId;
                var rpcIds = transport === 'batchExecute' ? extractRpcIds(rawUrl) : '';

                function reportAuthErrorIfNeeded() {
                    var status = typeof xhr.status === 'number' ? xhr.status : 0;
                    if (isAuthErrorStatus(status) && !xhr.__lgBridgeReportedAuthErr) {
                        xhr.__lgBridgeReportedAuthErr = true;
                        post('httpError', {
                            requestId: reqId,
                            transport: transport,
                            url: xhr.responseURL || rawUrl,
                            status: status,
                            rpcids: rpcIds
                        });
                        return true;
                    }
                    return xhr.__lgBridgeReportedAuthErr;
                }

                function safeResponseText() {
                    try {
                        if (xhr.responseType === '' || xhr.responseType === 'text') {
                            return typeof xhr.responseText === 'string' ? xhr.responseText : '';
                        }
                    } catch (e) {}
                    return '';
                }

                function flushStreamingDelta() {
                    if (reportAuthErrorIfNeeded()) return;
                    var text = safeResponseText();
                    var offset = xhr.__lgBridgeOffset || 0;
                    if (text.length <= offset) return;

                    var delta = text.slice(offset);
                    xhr.__lgBridgeOffset = text.length;
                    var effectiveUrl = xhr.responseURL || rawUrl;

                    if (!xhr.__lgBridgeStarted) {
                        xhr.__lgBridgeStarted = true;
                        post('streamStart', {
                            requestId: reqId,
                            transport: transport,
                            url: effectiveUrl,
                            status: typeof xhr.status === 'number' ? xhr.status : 0
                        });
                    }

                    post('streamChunk', {
                        requestId: reqId,
                        transport: transport,
                        url: effectiveUrl,
                        chunk: delta
                    });
                }

                xhr.addEventListener('readystatechange', function() {
                    if (xhr.readyState >= 2) {
                        reportAuthErrorIfNeeded();
                    }
                });

                if (transport !== 'batchExecute') {
                    xhr.addEventListener('progress', function() {
                        flushStreamingDelta();
                    });
                }

                xhr.addEventListener('loadend', function() {
                    if (reportAuthErrorIfNeeded()) return;
                    var effectiveUrl = xhr.responseURL || rawUrl;
                    var status = typeof xhr.status === 'number' ? xhr.status : 0;

                    if (transport === 'batchExecute') {
                        post('batchExecute', {
                            requestId: reqId,
                            url: effectiveUrl,
                            status: status,
                            rpcids: rpcIds,
                            body: safeResponseText()
                        });
                        return;
                    }

                    flushStreamingDelta();
                    post('streamEnd', {
                        requestId: reqId,
                        transport: transport,
                        url: effectiveUrl,
                        status: status
                    });
                });

                function handleFailure(kind) {
                    if (reportAuthErrorIfNeeded()) return;
                    if (transport === 'batchExecute') return;
                    post('streamError', {
                        requestId: reqId,
                        transport: transport,
                        url: xhr.responseURL || rawUrl,
                        status: typeof xhr.status === 'number' ? xhr.status : 0,
                        message: kind
                    });
                }

                xhr.addEventListener('error', function() { handleFailure('error'); });
                xhr.addEventListener('abort', function() { handleFailure('abort'); });
                xhr.addEventListener('timeout', function() { handleFailure('timeout'); });

                return origSend.apply(this, arguments);
            };

            // MARK: - Boot Globals, Auth DOM Markers & URL Navigation Observer

            function detectTemporaryChatState() {
                var host = queryFirst(CFG.selectors.tempChatHost);
                if (!host) return null;
                var activeClass = CFG.selectors.tempChatLegacyActiveClass;
                if (host.classList && host.classList.contains(activeClass)) return true;
                if (host.querySelector && host.querySelector('.' + activeClass)) return true;

                var icon = host.querySelector ? host.querySelector('mat-icon') : null;
                if (icon) {
                    var fontIcon = icon.getAttribute('fonticon') || icon.getAttribute('data-mat-icon-name') || '';
                    if (fontIcon === CFG.selectors.tempChatActiveIconName) return true;
                    if (fontIcon === CFG.selectors.tempChatInactiveIconName) return false;
                }
                return false;
            }

            function reportBootSnapshot(reason) {
                var wiz = (window.WIZ_global_data && typeof window.WIZ_global_data === 'object') ? window.WIZ_global_data : {};
                var wk = CFG.wizKeys;

                var xsrfVal = wiz[wk.xsrfToken];
                var wizSummary = {
                    xsrfTokenPresent: typeof xsrfVal === 'string' && xsrfVal.length > 0
                };
                if (typeof wiz[wk.gaiaUserId] === 'string') wizSummary[wk.gaiaUserId] = wiz[wk.gaiaUserId];
                if (typeof wiz[wk.actualUserObfuscatedId] === 'string') {
                    wizSummary[wk.actualUserObfuscatedId] = wiz[wk.actualUserObfuscatedId];
                }
                if (typeof wiz[wk.userEmail] === 'string') wizSummary[wk.userEmail] = wiz[wk.userEmail];
                if (wiz[wk.authUserIndex] !== undefined && wiz[wk.authUserIndex] !== null) {
                    wizSummary[wk.authUserIndex] = String(wiz[wk.authUserIndex]);
                }
                if (typeof wiz[wk.buildLabel] === 'string') wizSummary[wk.buildLabel] = wiz[wk.buildLabel];
                if (typeof wiz[wk.isViewerLoggedIn] === 'boolean') {
                    wizSummary[wk.isViewerLoggedIn] = wiz[wk.isViewerLoggedIn];
                }

                var signedOutEl = queryFirst(CFG.selectors.signedOutTrigger);
                var signedInEl = queryFirst(CFG.selectors.signedInAccountTrigger);
                var avatarEl = queryFirst(CFG.selectors.accountAvatarImage);

                var accountLabel = '';
                if (signedInEl) {
                    accountLabel = signedInEl.getAttribute('aria-label')
                        || signedInEl.getAttribute('title')
                        || '';
                }

                var avatarURL = '';
                if (avatarEl) {
                    var src = avatarEl.getAttribute('src') || avatarEl.src || '';
                    if (/^https?:\\/\\//i.test(src)) {
                        avatarURL = src;
                    }
                }

                var domSummary = {
                    hasSignedOutMarker: Boolean(signedOutEl),
                    hasSignedInMarker: Boolean(signedInEl),
                    accountLabel: accountLabel,
                    avatarURL: avatarURL
                };
                var tempState = detectTemporaryChatState();
                if (tempState !== null) {
                    domSummary.isTemporaryChat = tempState;
                }

                post('bootSnapshot', {
                    reason: reason || 'unknown',
                    url: String(location.href || ''),
                    wiz: wizSummary,
                    dom: domSummary
                });
            }

            window.__lgBridgeReportBootSnapshot = reportBootSnapshot;

            var lastObservedUrl = String(location.href || '');
            function handleUrlMutation(reason) {
                var current = String(location.href || '');
                if (current !== lastObservedUrl) {
                    lastObservedUrl = current;
                    post('urlChanged', { url: current, reason: reason });
                    reportBootSnapshot('navigation');
                }
            }

            if (window.history) {
                var origPushState = window.history.pushState;
                var origReplaceState = window.history.replaceState;
                if (typeof origPushState === 'function') {
                    window.history.pushState = function() {
                        var result = origPushState.apply(this, arguments);
                        handleUrlMutation('pushState');
                        return result;
                    };
                }
                if (typeof origReplaceState === 'function') {
                    window.history.replaceState = function() {
                        var result = origReplaceState.apply(this, arguments);
                        handleUrlMutation('replaceState');
                        return result;
                    };
                }
            }

            var postLoadTimer = null;
            window.addEventListener('popstate', function() { handleUrlMutation('popstate'); });
            window.addEventListener('hashchange', function() { handleUrlMutation('hashchange'); });
            document.addEventListener('DOMContentLoaded', function() { reportBootSnapshot('DOMContentLoaded'); });
            window.addEventListener('load', function() {
                reportBootSnapshot('load');
                if (postLoadTimer) clearTimeout(postLoadTimer);
                postLoadTimer = setTimeout(function() {
                    postLoadTimer = null;
                    reportBootSnapshot('postLoad');
                }, 350);
            });
            window.addEventListener('pagehide', function() {
                if (postLoadTimer) {
                    clearTimeout(postLoadTimer);
                    postLoadTimer = null;
                }
            });
        })();
        """
    }()
}
