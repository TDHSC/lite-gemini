import Foundation
import os
import WebKit

// MARK: - GeminiGraphQLErrorDetail

/// Structured error entry extracted from an Omakase GraphQL or Google RPC error payload.
nonisolated struct GeminiGraphQLErrorDetail: Equatable, Sendable {

    let message: String
    let code: Int?
    let bardErrorCode: Int?
    let reason: String?

    /// Canonical numeric error code, preferring `BardErrorInfo` when present.
    var effectiveCode: Int? {
        bardErrorCode ?? code
    }

    init(
        message: String,
        code: Int? = nil,
        bardErrorCode: Int? = nil,
        reason: String? = nil
    ) {
        self.message = message
        self.code = code
        self.bardErrorCode = bardErrorCode
        self.reason = reason
    }
}

// MARK: - GeminiGraphQLResponse

/// Parsed Omakase GraphQL HTTP response exposing `data`, extracted error codes, and raw JSON.
nonisolated struct GeminiGraphQLResponse: Equatable, Sendable {

    let httpStatus: Int
    let data: JSONValue?
    let errors: [GeminiGraphQLErrorDetail]
    let rawJSON: JSONValue

    var firstError: GeminiGraphQLErrorDetail? {
        errors.first
    }

    func hasErrorCode(_ targetCode: Int) -> Bool {
        errors.contains { $0.code == targetCode || $0.bardErrorCode == targetCode }
    }
}

// MARK: - GeminiGraphQLClient

/// Executes Omakase GraphQL (`ExecuteGraphqlHttp`) queries and mutations inside a `WKWebView`.
///
/// Computes `SAPISIDHASH` in-page using `crypto.subtle.digest("SHA-1", ...)` from `SAPISID` /
/// `__Secure-1PAPISID`, forwards `WIZ_global_data` headers (`X-Goog-Api-Key`, `X-Goog-AuthUser`,
/// `X-Server-Token`, `Accept-Language`), falls back cleanly to same-origin `/_/BardChatUi/graphql`,
/// and dynamically discovers unhardcoded `persistedQueryId` tokens from loaded Islands bundles.
@MainActor
struct GeminiGraphQLClient {

    // MARK: - Constants & Cache

    static let defaultTimeout: Duration = .seconds(15)

    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "GeminiBridge")
    private static var cachedPersistedQueryIds: [String: String] = [:]

    let timeout: Duration

    init(timeout: Duration = GeminiGraphQLClient.defaultTimeout) {
        self.timeout = timeout
    }

    static func cachePersistedQueryId(_ id: String, for operationName: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !operationName.isEmpty else { return }
        cachedPersistedQueryIds[operationName] = trimmed
    }

    static func clearPersistedQueryCache() {
        cachedPersistedQueryIds.removeAll()
    }

    // MARK: - Execution

    /// Executes an Omakase GraphQL operation inside `webView`.
    ///
    /// When `persistedQueryId` is `nil`, looks up the operation's `persistedQueryId` dynamically
    /// from loaded Islands `ChatTranscript` modules via `<script type="importmap">`.
    func execute(
        operationName: String,
        persistedQueryId: String? = nil,
        variables: [String: Any],
        in webView: WKWebView
    ) async throws -> GeminiGraphQLResponse {
        try Task.checkCancellation()

        let resolvedQueryId: String
        if let explicit = persistedQueryId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            resolvedQueryId = explicit
        } else if let cached = Self.cachedPersistedQueryIds[operationName], !cached.isEmpty {
            resolvedQueryId = cached
        } else if let discovered = await resolvePersistedQueryId(for: operationName, in: webView) {
            resolvedQueryId = discovered
        } else {
            throw GeminiTransportActionError.fallbackUnavailable(
                "Persisted query ID unavailable for \(operationName)."
            )
        }

        let variablesJson = try serializeVariablesJSON(variables)
        let timeoutMs = max(1000, Self.durationMilliseconds(timeout))

        typealias Gateway = GeminiBridgeSelectors.GraphQLGateway
        typealias WizKeys = GeminiBridgeSelectors.WizGlobalDataKeys

        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(
                Self.executeGraphQLScript,
                arguments: [
                    "operationName": operationName,
                    "persistedQueryId": resolvedQueryId,
                    "variablesJson": variablesJson,
                    "executePath": Gateway.executePath,
                    "fallbackPath": Gateway.sameOriginFallbackPath,
                    "defaultOrigin": Gateway.defaultOrigin,
                    "defaultApiOrigin": Gateway.defaultApiOrigin,
                    "timeoutMs": timeoutMs,
                    "wizKeys": [
                        "apiHost": WizKeys.apiHost,
                        "apiKey": WizKeys.apiKey,
                        "authUserIndex": WizKeys.authUserIndex,
                        "serverToken": WizKeys.serverToken,
                        "locale": WizKeys.locale
                    ]
                ],
                in: nil,
                contentWorld: .page
            )
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            let nsError = error as NSError
            Self.logger.error(
                "GeminiGraphQLClient[\(operationName, privacy: .public)] JS call failed code=\(nsError.code, privacy: .public)"
            )
            throw GeminiTransportActionError.fallbackUnavailable(
                "GraphQL call failed during WebView execution (code \(nsError.code))."
            )
        }

        guard let payload = raw.flatMap({ JSONValue.from($0) }) else {
            throw GeminiTransportActionError.malformedResponse(
                "GraphQL bridge returned an empty response."
            )
        }

        let status = payload["status"]?.intValue ?? 0
        let transport = payload["transport"]?.nonEmptyStringValue ?? "unknown"
        let jsError = payload["error"]?.nonEmptyStringValue
        let responseText = payload["text"]?.stringValue ?? ""

        if responseText.isEmpty {
            if status == 401 || status == 403 {
                throw GeminiTransportActionError.authenticationUnavailable
            }
            let detail = jsError ?? "Empty GraphQL HTTP response (status \(status), transport \(transport))."
            Self.logger.error(
                "GeminiGraphQLClient[\(operationName, privacy: .public)] empty body status=\(status, privacy: .public) transport=\(transport, privacy: .public)"
            )
            throw GeminiTransportActionError.fallbackUnavailable(detail)
        }

        let cleanedText = Self.stripXSSIPrefix(responseText)
        guard let rootJSON = JSONValue.parse(cleanedText) else {
            if status == 401 || status == 403 {
                throw GeminiTransportActionError.authenticationUnavailable
            }
            if status == 404 || status >= 500 || status == 0 {
                Self.logger.error(
                    "GeminiGraphQLClient[\(operationName, privacy: .public)] fallbackUnavailable non-JSON status=\(status, privacy: .public)"
                )
                throw GeminiTransportActionError.fallbackUnavailable(
                    "GraphQL endpoint unavailable (HTTP \(status))."
                )
            }
            Self.logger.error(
                "GeminiGraphQLClient[\(operationName, privacy: .public)] non-JSON body status=\(status, privacy: .public)"
            )
            throw GeminiTransportActionError.malformedResponse(
                "GraphQL response was not valid JSON (HTTP \(status))."
            )
        }

        let parsed = Self.parseResponse(rootJSON, httpStatus: status)

        if (status == 401 || status == 403) && parsed.data == nil && parsed.errors.isEmpty {
            throw GeminiTransportActionError.authenticationUnavailable
        }

        Self.logger.notice(
            "GeminiGraphQLClient[\(operationName, privacy: .public)] status=\(status, privacy: .public) transport=\(transport, privacy: .public) errors=\(parsed.errors.count, privacy: .public)"
        )
        return parsed
    }

    /// Dynamically resolves a `persistedQueryId` (`"2/..."`) for `operationName` by inspecting
    /// `<script type="importmap">` (`@messages/assets/ChatTranscript-...`) and loaded Islands assets.
    func resolvePersistedQueryId(
        for operationName: String,
        in webView: WKWebView
    ) async -> String? {
        guard !operationName.isEmpty else { return nil }
        if let cached = Self.cachedPersistedQueryIds[operationName], !cached.isEmpty {
            return cached
        }

        let timeoutMs = min(8000, max(1500, Self.durationMilliseconds(timeout)))
        do {
            let raw = try await webView.callAsyncJavaScript(
                Self.resolvePersistedQueryIdScript,
                arguments: [
                    "operationName": operationName,
                    "timeoutMs": timeoutMs
                ],
                in: nil,
                contentWorld: .page
            )
            if let payload = raw.flatMap({ JSONValue.from($0) }),
               let discovered = payload["persistedQueryId"]?.nonEmptyStringValue {
                Self.cachedPersistedQueryIds[operationName] = discovered
                Self.logger.notice(
                    "GeminiGraphQLClient discovered persistedQueryId for \(operationName, privacy: .public)"
                )
                return discovered
            }
        } catch {
            let nsError = error as NSError
            Self.logger.notice(
                "GeminiGraphQLClient dynamic persistedQueryId lookup failed for \(operationName, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
        }
        return nil
    }

    // MARK: - Pure Response Parsers & Decoders

    /// Parses an Omakase GraphQL JSON root (or wrapped `responseJson` / `graphqlResponse` / gRPC
    /// `error` object) into a `GeminiGraphQLResponse` with extracted `BardErrorInfo` codes.
    nonisolated static func parseResponse(_ root: JSONValue, httpStatus: Int = 200) -> GeminiGraphQLResponse {
        let unwrapped: JSONValue
        if let responseJsonString = root["responseJson"]?.nonEmptyStringValue,
           let decoded = JSONValue.parse(stripXSSIPrefix(responseJsonString)) {
            unwrapped = decoded
        } else if let nested = root["graphqlResponse"], nested.objectValue != nil {
            unwrapped = nested
        } else {
            unwrapped = root
        }

        let dataNode: JSONValue?
        if let directData = unwrapped["data"], !directData.isNull {
            dataNode = directData
        } else if let dataJsonString = unwrapped["dataJson"]?.nonEmptyStringValue,
                  let decodedData = JSONValue.parse(stripXSSIPrefix(dataJsonString)) {
            dataNode = decodedData
        } else {
            dataNode = nil
        }

        var errors: [GeminiGraphQLErrorDetail] = []

        if let rawErrors = unwrapped["errors"]?.arrayValue {
            for entry in rawErrors {
                errors.append(parseGraphQLErrorEntry(entry))
            }
        }
        if let topLevelError = unwrapped["error"], topLevelError.objectValue != nil {
            errors.append(parseGraphQLErrorEntry(topLevelError))
        }
        // Check outer wrapper if `responseJson` didn't carry a top-level gRPC error.
        if errors.isEmpty, unwrapped != root, let outerError = root["error"], outerError.objectValue != nil {
            errors.append(parseGraphQLErrorEntry(outerError))
        }

        return GeminiGraphQLResponse(
            httpStatus: httpStatus,
            data: dataNode,
            errors: errors,
            rawJSON: unwrapped
        )
    }

    /// Extracts an adjacent `"2/..."` persisted query ID next to `operationName` in minified JS source.
    nonisolated static func extractPersistedQueryId(
        fromModuleSource source: String,
        operationName: String
    ) -> String? {
        guard !source.isEmpty, !operationName.isEmpty else {
            return nil
        }

        let patterns = [
            "name:\"\(operationName)\"",
            "name:'\(operationName)'",
            "name:`\(operationName)`",
            "\"\(operationName)\"",
            "'\(operationName)'",
            "`\(operationName)`",
            operationName
        ]

        let idRegexPattern = #"(?:\b(?:id|persistedQueryId)|["'`](?:id|persistedQueryId)["'`])\s*:\s*["'`](2/[A-Za-z0-9+/_=-]{16,128})["'`]"#
        guard let regex = try? NSRegularExpression(pattern: idRegexPattern) else {
            return nil
        }

        for marker in patterns {
            var searchStart = source.startIndex
            while let range = source.range(of: marker, range: searchStart..<source.endIndex) {
                let windowStart = source.index(range.lowerBound, offsetBy: -360, limitedBy: source.startIndex) ?? source.startIndex
                let windowEnd = source.index(range.upperBound, offsetBy: 360, limitedBy: source.endIndex) ?? source.endIndex
                let window = String(source[windowStart..<windowEnd])
                let nsRange = NSRange(window.startIndex..<window.endIndex, in: window)
                if let match = regex.firstMatch(in: window, range: nsRange),
                   match.numberOfRanges >= 2,
                   let tokenRange = Range(match.range(at: 1), in: window) {
                    return String(window[tokenRange])
                }
                searchStart = range.upperBound
            }
        }

        return nil
    }

    /// Normalizes a Gemini conversation identifier to canonical `"c_..."` format for GraphQL requests.
    nonisolated static func canonicalConversationId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let prefix = GeminiBridgeSelectors.WireFormat.conversationIdPrefix
        if trimmed.hasPrefix(prefix) || trimmed.contains("_") {
            return trimmed
        }
        return prefix + trimmed
    }

    /// Extracts the newly created `conversationId` from `ChatResponseActionBarBranchMutation`.
    nonisolated static func decodeBranchConversationId(from response: GeminiGraphQLResponse) -> String? {
        guard let branch = response.data?["branchConversation"] else {
            return nil
        }
        return branch["clientConversation"]?["conversationId"]?.nonEmptyStringValue
            ?? branch["clientConversation"]?["id"]?.nonEmptyStringValue
            ?? branch["conversation"]?["conversationId"]?.nonEmptyStringValue
            ?? branch["conversation"]?["id"]?.nonEmptyStringValue
            ?? branch["conversationId"]?.nonEmptyStringValue
    }

    /// Decodes `ShareLinkResult` from `useCreatePublicShareLinkMutation`, surfacing `1218` as `.targetNotPersisted`.
    nonisolated static func decodeShareLinkResult(from response: GeminiGraphQLResponse) throws -> ShareLinkResult {
        if response.hasErrorCode(GeminiBridgeSelectors.GraphQLGateway.shareTargetNotPersistedErrorCode) {
            throw GeminiTransportActionError.targetNotPersisted
        }

        if let node = response.data?["createSharedConversation"] {
            let externalUrlId = node["externalUrlId"]?.nonEmptyStringValue
            let shareToken = node["shareToken"]?.nonEmptyStringValue
            let rawURLString = node["shortenedUrl"]?.nonEmptyStringValue
                ?? node["shareUrl"]?.nonEmptyStringValue
                ?? node["url"]?.nonEmptyStringValue
                ?? externalUrlId.map { "https://gemini.google.com/share/\($0)" }

            if let rawURLString,
               let url = URL(string: rawURLString),
               url.scheme?.lowercased() == "https" {
                return ShareLinkResult(
                    url: url,
                    externalUrlId: externalUrlId,
                    shareToken: shareToken
                )
            }
        }

        if let error = response.firstError {
            throw GeminiTransportActionError.graphQLError(
                code: error.effectiveCode,
                message: error.message
            )
        }

        throw GeminiTransportActionError.malformedResponse(
            "Share link response did not contain a valid HTTPS URL."
        )
    }

    /// Decodes and host-validates the artifact `URL` returned by `useExportMessageMutation`.
    nonisolated static func decodeExportArtifactURL(
        from response: GeminiGraphQLResponse,
        service: CloudExportService
    ) throws -> URL {
        if let node = response.data?["exportMessage"] {
            var candidateURLString = node["artifactUrl"]?.nonEmptyStringValue
                ?? node["url"]?.nonEmptyStringValue

            if candidateURLString == nil, service == .gmail, let gmail = node["gmailArtifacts"] {
                let messageId = gmail["messageId"]?.nonEmptyStringValue
                let threadId = gmail["threadId"]?.nonEmptyStringValue
                if let draftRef = messageId ?? threadId {
                    candidateURLString = "https://mail.google.com/mail/u/0/#drafts/\(draftRef)"
                } else if gmail.objectValue != nil {
                    candidateURLString = "https://mail.google.com/mail/u/0/#drafts"
                }
            }

            if let candidateURLString {
                guard let url = URL(string: candidateURLString),
                      url.scheme?.lowercased() == "https",
                      let host = url.host?.lowercased(),
                      isAllowedExportHost(host) else {
                    throw GeminiTransportActionError.invalidArtifactURL(
                        "Export returned an unrecognized or non-HTTPS destination URL."
                    )
                }
                return url
            }
        }

        if let error = response.firstError {
            throw GeminiTransportActionError.graphQLError(
                code: error.effectiveCode,
                message: error.message
            )
        }

        throw GeminiTransportActionError.malformedResponse(
            "Cloud export response did not contain an artifact URL."
        )
    }

    /// Decodes remote semantic search hits from `SearchChatsPageQuery`.
    nonisolated static func decodeSearchHits(
        from response: GeminiGraphQLResponse,
        limit: Int
    ) -> [ConversationSearchHit] {
        guard limit > 0 else { return [] }

        let searchHistory = response.data?["viewer"]?["rpcs"]?["searchHistory"]
            ?? response.data?["searchHistory"]

        let rawItems: [JSONValue] = searchHistory?["historySnippets"]?.arrayValue
            ?? searchHistory?["results"]?.arrayValue
            ?? searchHistory?["conversations"]?.arrayValue
            ?? searchHistory?["items"]?.arrayValue
            ?? []

        var seenIds: Set<String> = []
        var hits: [ConversationSearchHit] = []
        hits.reserveCapacity(min(rawItems.count, limit))

        for item in rawItems {
            let convNode = item["clientConversation"] ?? item["conversation"]
            guard let conversationId = item["conversationId"]?.nonEmptyStringValue
                ?? convNode?["conversationId"]?.nonEmptyStringValue
                ?? convNode?["id"]?.nonEmptyStringValue
                ?? item["id"]?.nonEmptyStringValue else {
                continue
            }
            guard seenIds.insert(conversationId).inserted else {
                continue
            }

            let rawSnippet = item["snippet"]?.nonEmptyStringValue
                ?? item["matchedSnippet"]?.nonEmptyStringValue
                ?? item["textSnippet"]?.nonEmptyStringValue
                ?? item["preview"]?.nonEmptyStringValue
                ?? item["highlight"]?.nonEmptyStringValue
            let cleanedSnippet = rawSnippet.map(stripSimpleHighlightTags)

            let rawTitle = item["title"]?.nonEmptyStringValue
                ?? item["conversationTitle"]?.nonEmptyStringValue
                ?? convNode?["title"]?.nonEmptyStringValue
                ?? cleanedSnippet
                ?? "Untitled"
            let title = stripSimpleHighlightTags(rawTitle)

            let updatedAt = parseFlexibleDate(
                item["lastUpdatedTimestamp"]
                    ?? item["updatedAt"]
                    ?? item["timestamp"]
                    ?? item["lastModifiedTime"]
                    ?? convNode?["lastUpdatedTimestamp"]
                    ?? convNode?["updatedAt"]
            )

            hits.append(
                ConversationSearchHit(
                    id: conversationId,
                    conversationId: conversationId,
                    title: title,
                    snippet: cleanedSnippet,
                    updatedAt: updatedAt,
                    source: .cloudSemantic
                )
            )
            if hits.count >= limit {
                break
            }
        }

        return hits
    }

    /// Decodes `base64url`-encoded MP3 audio bytes from `useResponseTtsQuery`.
    nonisolated static func decodeAudioData(from response: GeminiGraphQLResponse) -> Data? {
        let ttsNode = response.data?["viewer"]?["rpcs"]?["getTts"]
            ?? response.data?["getTts"]
        guard let encoded = ttsNode?["encodedAudio"]?.nonEmptyStringValue
            ?? ttsNode?["audioContent"]?.nonEmptyStringValue else {
            return nil
        }
        return decodeBase64URL(encoded)
    }

    /// Decodes a `base64url` (or standard `base64`) string into raw bytes, adding missing `=` padding.
    nonisolated static func decodeBase64URL(_ encoded: String) -> Data? {
        let stripped = encoded
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard !stripped.isEmpty else {
            return nil
        }

        var normalized = stripped
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = normalized.count % 4
        if remainder == 1 {
            return nil
        }
        if remainder > 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }

        guard let data = Data(base64Encoded: normalized), !data.isEmpty else {
            return nil
        }
        return data
    }

    // MARK: - Private Parsing Helpers

    private nonisolated static func stripXSSIPrefix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(")]}'") else {
            return trimmed
        }
        let afterMarker = trimmed.dropFirst(4)
        return String(afterMarker).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func parseGraphQLErrorEntry(_ entry: JSONValue) -> GeminiGraphQLErrorDetail {
        let message = entry["message"]?.nonEmptyStringValue ?? "GraphQL request failed."
        let extensions = entry["extensions"]

        let directCode = entry["code"]?.intValue
            ?? extensions?["code"]?.intValue
            ?? extensions?["statusCode"]?.intValue
            ?? extensions?["errorCode"]?.intValue

        var bardCode = extractBardErrorCode(from: extensions)
            ?? extractBardErrorCode(from: entry["details"])
            ?? extractBardErrorCode(from: entry["bardErrorInfo"])
            ?? extractBardErrorCode(from: entry["bard_error_info"])

        let reason = extensions?["bardErrorInfo"]?["reason"]?.nonEmptyStringValue
            ?? extensions?["bard_error_info"]?["reason"]?.nonEmptyStringValue
            ?? extensions?["reason"]?.nonEmptyStringValue
            ?? extensions?["classification"]?.nonEmptyStringValue
            ?? extensions?["code"]?.nonEmptyStringValue
            ?? entry["status"]?.nonEmptyStringValue

        if bardCode == nil {
            let combinedText = [message, reason ?? ""].joined(separator: " ")
            if combinedText.contains("SHARE_ERROR_TARGET_NOT_PERSISTED") {
                bardCode = GeminiBridgeSelectors.GraphQLGateway.shareTargetNotPersistedErrorCode
            }
        }

        return GeminiGraphQLErrorDetail(
            message: message,
            code: directCode,
            bardErrorCode: bardCode,
            reason: reason
        )
    }

    private nonisolated static func extractBardErrorCode(from node: JSONValue?, depth: Int = 0) -> Int? {
        guard let node, depth < 8 else { return nil }

        if let bardInfo = node["bardErrorInfo"] ?? node["bard_error_info"] {
            if let code = bardInfo["code"]?.intValue
                ?? bardInfo["errorCode"]?.intValue
                ?? bardInfo["error_code"]?.intValue {
                return code
            }
        }

        if let direct = node["bardErrorCode"]?.intValue ?? node["bard_error_code"]?.intValue {
            return direct
        }

        if let typeStr = node["@type"]?.nonEmptyStringValue,
           typeStr.localizedCaseInsensitiveContains("BardErrorInfo") {
            if let code = node["code"]?.intValue
                ?? node["errorCode"]?.intValue
                ?? node["error_code"]?.intValue {
                return code
            }
        }

        if let details = node["details"]?.arrayValue {
            for detail in details {
                if let code = extractBardErrorCode(from: detail, depth: depth + 1) {
                    return code
                }
            }
        }

        if let array = node.arrayValue {
            for item in array {
                if let code = extractBardErrorCode(from: item, depth: depth + 1) {
                    return code
                }
            }
        }

        if let dict = node.objectValue {
            for (key, value) in dict where key.localizedCaseInsensitiveContains("bard") || key == "error" || key == "detail" {
                if let code = extractBardErrorCode(from: value, depth: depth + 1) {
                    return code
                }
            }
        }

        return nil
    }

    private nonisolated static func isAllowedExportHost(_ host: String) -> Bool {
        GeminiBridgeSelectors.GraphQLGateway.allowedExportHosts.contains { allowed in
            host == allowed || host.hasSuffix(".\(allowed)")
        }
    }

    private nonisolated static func stripSimpleHighlightTags(_ raw: String) -> String {
        var result = raw
        for tag in ["<b>", "</b>", "<em>", "</em>", "<mark>", "</mark>", "<strong>", "</strong>"] {
            result = result.replacingOccurrences(of: tag, with: "", options: .caseInsensitive)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func parseFlexibleDate(_ node: JSONValue?) -> Date? {
        guard let node else { return nil }

        if let numeric = node.doubleValue, numeric > 0 {
            let seconds = numeric > 1_000_000_000_000 ? (numeric / 1000.0) : numeric
            return Date(timeIntervalSince1970: seconds)
        }

        if let seconds = node["seconds"]?.doubleValue, seconds > 0 {
            let nanos = node["nanos"]?.doubleValue ?? 0
            return Date(timeIntervalSince1970: seconds + nanos / 1_000_000_000.0)
        }

        if let iso = node.nonEmptyStringValue {
            if let fractional = try? Date(iso, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return fractional
            }
            if let standard = try? Date(iso, strategy: .iso8601) {
                return standard
            }
        }

        return nil
    }

    private func serializeVariablesJSON(_ variables: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(variables),
              let data = try? JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            throw GeminiTransportActionError.invalidArguments("Failed to serialize GraphQL variables.")
        }
        return json
    }

    private nonisolated static func durationMilliseconds(_ duration: Duration) -> Int {
        let secMs = Double(duration.components.seconds) * 1000.0
        let attoMs = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
        return max(0, Int((secMs + attoMs).rounded()))
    }

    // MARK: - JavaScript Bridge Scripts

    private nonisolated static let executeGraphQLScript = #"""
    const readCookie = (name) => {
        const raw = String(document.cookie || '');
        if (!raw) return '';
        const parts = raw.split(';');
        for (let i = 0; i < parts.length; i += 1) {
            const entry = parts[i].trim();
            const eq = entry.indexOf('=');
            if (eq <= 0) continue;
            if (entry.slice(0, eq).trim() === name) {
                return entry.slice(eq + 1).trim();
            }
        }
        return '';
    };

    const sha1Hex = async (input) => {
        if (!window.crypto || !window.crypto.subtle || typeof TextEncoder === 'undefined') {
            return '';
        }
        const bytes = new TextEncoder().encode(input);
        const digest = await window.crypto.subtle.digest('SHA-1', bytes);
        const view = new Uint8Array(digest);
        let hex = '';
        for (let i = 0; i < view.length; i += 1) {
            hex += view[i].toString(16).padStart(2, '0');
        }
        return hex;
    };

    const pageOrigin = (window.location && window.location.origin && /^https?:/i.test(window.location.origin))
        ? window.location.origin
        : defaultOrigin;

    const wiz = (window && window.WIZ_global_data && typeof window.WIZ_global_data === 'object')
        ? window.WIZ_global_data
        : {};

    const apiOriginRaw = typeof wiz[wizKeys.apiHost] === 'string' ? wiz[wizKeys.apiHost].trim() : '';
    const apiOrigin = (apiOriginRaw && /^https?:/i.test(apiOriginRaw))
        ? apiOriginRaw.replace(/\/+$/, '')
        : defaultApiOrigin;

    const apiKey = typeof wiz[wizKeys.apiKey] === 'string' ? wiz[wizKeys.apiKey].trim() : '';
    const rawAuthUser = wiz[wizKeys.authUserIndex];
    const authUser = (rawAuthUser !== undefined && rawAuthUser !== null && String(rawAuthUser).trim() !== '')
        ? String(rawAuthUser).trim()
        : '0';
    const serverToken = typeof wiz[wizKeys.serverToken] === 'string' ? wiz[wizKeys.serverToken].trim() : '';
    const locale = (typeof wiz[wizKeys.locale] === 'string' && wiz[wizKeys.locale].trim())
        ? wiz[wizKeys.locale].trim()
        : (navigator.language || 'en-US');

    const unixSec = Math.floor(Date.now() / 1000);
    const sapisid = readCookie('SAPISID');
    const sapisid1p = readCookie('__Secure-1PAPISID');
    const sapisid3p = readCookie('__Secure-3PAPISID');
    const primarySid = sapisid || sapisid1p || sapisid3p;

    const authTokens = [];
    let primaryHash = '';
    if (primarySid) {
        try {
            primaryHash = await sha1Hex(`${unixSec} ${primarySid} ${pageOrigin}`);
            if (primaryHash) {
                authTokens.push(`SAPISIDHASH ${unixSec}_${primaryHash}`);
            }
        } catch (_) {}
    }
    if (sapisid1p) {
        try {
            const hash1p = (sapisid1p === primarySid && primaryHash)
                ? primaryHash
                : await sha1Hex(`${unixSec} ${sapisid1p} ${pageOrigin}`);
            if (hash1p) {
                authTokens.push(`SAPISID1PHASH ${unixSec}_${hash1p}`);
            }
        } catch (_) {}
    }
    if (sapisid3p) {
        try {
            const hash3p = (sapisid3p === primarySid && primaryHash)
                ? primaryHash
                : await sha1Hex(`${unixSec} ${sapisid3p} ${pageOrigin}`);
            if (hash3p) {
                authTokens.push(`SAPISID3PHASH ${unixSec}_${hash3p}`);
            }
        } catch (_) {}
    }

    const headers = {
        'Content-Type': 'application/json',
        'Accept-Language': locale,
        'X-Goog-AuthUser': authUser
    };
    if (apiKey) headers['X-Goog-Api-Key'] = apiKey;
    if (serverToken) headers['X-Server-Token'] = serverToken;
    if (authTokens.length > 0) headers['Authorization'] = authTokens.join(' ');

    const body = JSON.stringify({
        persistedQueryId: persistedQueryId,
        operationName: operationName,
        variablesJson: variablesJson
    });

    const primaryUrl = apiOrigin + executePath;
    const fallbackUrl = pageOrigin + fallbackPath;

    const runFetch = async (url, label) => {
        const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
        const timer = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
        try {
            const response = await fetch(url, {
                method: 'POST',
                credentials: 'include',
                headers: headers,
                body: body,
                signal: controller ? controller.signal : undefined
            });
            const text = await response.text();
            return { ok: response.ok, status: response.status, text: text, transport: label };
        } catch (err) {
            return {
                ok: false,
                status: 0,
                text: '',
                transport: label,
                error: String(err && err.message ? err.message : err)
            };
        } finally {
            if (timer !== null) clearTimeout(timer);
        }
    };

    const attempts = authTokens.length > 0
        ? [
            { url: primaryUrl, label: 'omakase' },
            { url: fallbackUrl, label: 'same-origin-fallback' }
        ]
        : [
            { url: fallbackUrl, label: 'same-origin-fallback' },
            { url: primaryUrl, label: 'omakase-cookie' }
        ];

    let lastAuthFailure = null;
    let lastResult = { ok: false, status: 0, text: '', transport: 'none', error: 'No transport attempted' };
    var authFailureResult = lastAuthFailure;
    for (let i = 0; i < attempts.length; i += 1) {
        const res = await runFetch(attempts[i].url, attempts[i].label);
        if (res.status === 401 || res.status === 403) {
            authFailureResult = res;
        }
        lastResult = res;
        if (res.ok && res.text && res.text.trim().length > 0) {
            return res;
        }
        // Return structured HTTP 4xx/5xx GraphQL JSON errors immediately unless it's auth/not-found fallback territory.
        const shouldRetryFallback = res.status === 0 || res.status === 401 || res.status === 403 || res.status === 404 || !res.text;
        if (!shouldRetryFallback) {
            return res;
        }
    }

    if (authFailureResult && (lastResult.status === 0 || lastResult.status === 404)) {
        return authFailureResult;
    }
    return lastResult;
    """#

    private nonisolated static let resolvePersistedQueryIdScript = #"""
    const cache = window.__lgPersistedQueryIdCache || (window.__lgPersistedQueryIdCache = Object.create(null));
    if (typeof cache[operationName] === 'string' && cache[operationName].length > 0) {
        return { persistedQueryId: cache[operationName], source: 'cache' };
    }

    const extractIdNearOperation = (source, opName) => {
        if (!source || !opName) return '';
        const markers = [
            `name:"${opName}"`,
            `name:'${opName}'`,
            `name:\`${opName}\``,
            `"${opName}"`,
            `'${opName}'`,
            `\`${opName}\``,
            opName
        ];
        const idPattern = /(?:\b(?:id|persistedQueryId)|["'`](?:id|persistedQueryId)["'`])\s*:\s*["'`](2\/[A-Za-z0-9+\/_=-]{16,128})["'`]/;
        for (let m = 0; m < markers.length; m += 1) {
            const marker = markers[m];
            let idx = source.indexOf(marker);
            while (idx !== -1) {
                const start = Math.max(0, idx - 360);
                const end = Math.min(source.length, idx + marker.length + 360);
                const slice = source.slice(start, end);
                const match = slice.match(idPattern);
                if (match && match[1]) {
                    return match[1];
                }
                idx = source.indexOf(marker, idx + marker.length);
            }
        }
        return '';
    };

    const candidateUrls = [];
    const seen = new Set();
    const addCandidate = (rawUrl) => {
        if (typeof rawUrl !== 'string') return;
        const trimmed = rawUrl.trim();
        if (!trimmed || trimmed.startsWith('data:') || trimmed.startsWith('blob:')) return;
        let resolved = trimmed;
        try {
            resolved = new URL(trimmed, window.location.href).href;
        } catch (_) {}
        if (!seen.has(resolved)) {
            seen.add(resolved);
            candidateUrls.push(resolved);
        }
    };

    const addImportMapEntry = (key, value) => {
        if (typeof value !== 'string') return;
        const keyStr = String(key || '');
        const isChatTranscript = keyStr.includes('ChatTranscript') || value.includes('ChatTranscript');
        if (!isChatTranscript) return;

        // Derive the executable chunk URL from the importmap key (`@messages/assets/<ChunkWithCodeHash>.js`)
        // before rewriting the message bundle value URL, since message and code chunk hashes differ.
        const keyAssetMatch = keyStr.match(/@messages\/(assets\/[^?#\s]+)/i);
        if (keyAssetMatch && keyAssetMatch[1]) {
            const assetPath = keyAssetMatch[1].endsWith('.js')
                ? keyAssetMatch[1]
                : `${keyAssetMatch[1]}.js`;
            const islandsBaseMatch = value.match(/^(https?:\/\/[^?#]*?\/islands\/)/i);
            if (islandsBaseMatch && islandsBaseMatch[1]) {
                addCandidate(islandsBaseMatch[1] + assetPath);
            }
            addCandidate('https://www.gstatic.com/bg3/boq-bard-web/islands/' + assetPath);
        }

        if (keyStr.includes('@messages/assets/ChatTranscript') || value.includes('-messages')) {
            const directEnRewrite = value.replace('/en/', '/').replace('-messages', '');
            addCandidate(directEnRewrite);
            const anyLocaleRewrite = value
                .replace(/\/[a-z]{2,3}(?:[-_][A-Za-z0-9]{2,4})?\/(?=(?:assets\/)?[^\/]*ChatTranscript)/i, '/')
                .replace(/-messages(?=\.js(?:$|[?#]))/, '');
            addCandidate(anyLocaleRewrite);
        } else {
            addCandidate(value);
        }
    };

    const importMapScripts = document.querySelectorAll('script[type="importmap"]');
    for (let i = 0; i < importMapScripts.length; i += 1) {
        try {
            const parsed = JSON.parse(importMapScripts[i].textContent || '{}');
            if (parsed && parsed.imports && typeof parsed.imports === 'object') {
                const keys = Object.keys(parsed.imports);
                for (let k = 0; k < keys.length; k += 1) {
                    addImportMapEntry(keys[k], parsed.imports[keys[k]]);
                }
            }
            if (parsed && parsed.scopes && typeof parsed.scopes === 'object') {
                const scopeKeys = Object.keys(parsed.scopes);
                for (let s = 0; s < scopeKeys.length; s += 1) {
                    const scopeMap = parsed.scopes[scopeKeys[s]];
                    if (!scopeMap || typeof scopeMap !== 'object') continue;
                    const entryKeys = Object.keys(scopeMap);
                    for (let e = 0; e < entryKeys.length; e += 1) {
                        addImportMapEntry(entryKeys[e], scopeMap[entryKeys[e]]);
                    }
                }
            }
        } catch (_) {}
    }

    const scriptEls = document.querySelectorAll('script[src], link[rel="modulepreload"][href]');
    for (let i = 0; i < scriptEls.length; i += 1) {
        const href = scriptEls[i].getAttribute('src') || scriptEls[i].getAttribute('href') || '';
        if (href.includes('ChatTranscript')) {
            addCandidate(href);
        }
    }

    if (window.performance && typeof window.performance.getEntriesByType === 'function') {
        const resources = window.performance.getEntriesByType('resource');
        for (let i = 0; i < resources.length; i += 1) {
            const name = resources[i] && typeof resources[i].name === 'string' ? resources[i].name : '';
            if (name.includes('ChatTranscript') && !name.includes('-messages')) {
                addCandidate(name);
            }
        }
    }

    const maxToInspect = Math.min(candidateUrls.length, 8);
    for (let i = 0; i < maxToInspect; i += 1) {
        const url = candidateUrls[i];
        const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
        const timer = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
        try {
            const response = await fetch(url, {
                method: 'GET',
                credentials: 'same-origin',
                signal: controller ? controller.signal : undefined
            });
            if (!response.ok) continue;
            const source = await response.text();
            const found = extractIdNearOperation(source, operationName);
            if (found) {
                cache[operationName] = found;
                return { persistedQueryId: found, source: url };
            }
        } catch (_) {
        } finally {
            if (timer !== null) clearTimeout(timer);
        }
    }

    return { persistedQueryId: null };
    """#
}
