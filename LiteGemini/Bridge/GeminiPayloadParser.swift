import Foundation
import os

// MARK: - JSONValue

/// Strict-concurrency-safe (`Sendable`) JSON AST with bounds-checked optional accessors.
nonisolated enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    private static let boolNumberType: AnyClass = type(of: NSNumber(value: true))
    private static let maxParseDepth = 64

    /// Parses a UTF-8 JSON string into a `JSONValue`, returning `nil` on malformed input.
    static func parse(_ string: String) -> JSONValue? {
        guard let data = string.data(using: .utf8) else {
            return nil
        }
        return parse(data)
    }

    /// Parses raw UTF-8 JSON bytes into a `JSONValue`, returning `nil` on malformed input.
    static func parse(_ data: Data) -> JSONValue? {
        guard !data.isEmpty,
              let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return from(raw, depth: 0)
    }

    /// Converts a Foundation JSON object (`NSArray`/`NSDictionary`/`NSString`/`NSNumber`/`NSNull`) into `JSONValue`.
    static func from(_ raw: Any, depth: Int = 0) -> JSONValue? {
        guard depth <= maxParseDepth else {
            return nil
        }
        if raw is NSNull {
            return .null
        }
        if let string = raw as? String {
            return .string(string)
        }
        if let number = raw as? NSNumber {
            if type(of: number) == boolNumberType {
                return .bool(number.boolValue)
            }
            let typeChar = UInt8(bitPattern: number.objCType.pointee)
            if typeChar == UInt8(ascii: "f") || typeChar == UInt8(ascii: "d") {
                let value = number.doubleValue
                if value.isFinite, value.rounded(.towardZero) == value, let exactInt = Int(exactly: value) {
                    return .int(exactInt)
                }
                return .double(value)
            }
            if let exactInt = Int(exactly: number.int64Value) {
                return .int(exactInt)
            }
            return .double(number.doubleValue)
        }
        if let array = raw as? [Any] {
            var result: [JSONValue] = []
            result.reserveCapacity(array.count)
            for item in array {
                guard let converted = from(item, depth: depth + 1) else {
                    return nil
                }
                result.append(converted)
            }
            return .array(result)
        }
        if let dict = raw as? [String: Any] {
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(dict.count)
            for (key, value) in dict {
                guard let converted = from(value, depth: depth + 1) else {
                    return nil
                }
                result[key] = converted
            }
            return .object(result)
        }
        return nil
    }

    /// Bounds-checked array subscript.
    subscript(index: Int) -> JSONValue? {
        guard case .array(let items) = self, index >= 0, index < items.count else {
            return nil
        }
        return items[index]
    }

    /// Keyed object subscript.
    subscript(key: String) -> JSONValue? {
        guard case .object(let map) = self else {
            return nil
        }
        return map[key]
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var nonEmptyStringValue: String? {
        guard let value = stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            return Int(exactly: value)
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        case .string(let value):
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .int(let value):
            return value != 0
        default:
            return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let items) = self {
            return items
        }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let map) = self {
            return map
        }
        return nil
    }

    var isNull: Bool {
        if case .null = self {
            return true
        }
        return false
    }
}

// MARK: - ProtoWireMessage

/// Lightweight, zero-dependency binary Protobuf wire decoder supporting varints (wire type 0),
/// 64-bit/32-bit fixed fields (wire types 1 and 5), and length-delimited bytes/strings/submessages (wire type 2).
nonisolated struct ProtoWireMessage: Equatable, Sendable {

    nonisolated enum WireValue: Equatable, Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case lengthDelimited(Data)
        case fixed32(UInt32)
    }

    nonisolated struct Field: Equatable, Sendable {
        let number: Int
        let value: WireValue
    }

    let fields: [Field]

    private static let maxDecodeDepth = 20

    /// Decodes a binary protobuf message, returning `nil` if the wire bytes are truncated or malformed.
    static func decode(_ data: Data) -> ProtoWireMessage? {
        let bytes = [UInt8](data)
        var offset = 0
        var fields: [Field] = []

        while offset < bytes.count {
            guard let tag = readVarint(bytes: bytes, offset: &offset) else {
                return nil
            }
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            guard fieldNumber > 0 else {
                return nil
            }

            switch wireType {
            case 0:
                guard let value = readVarint(bytes: bytes, offset: &offset) else {
                    return nil
                }
                fields.append(Field(number: fieldNumber, value: .varint(value)))
            case 1:
                guard bytes.count - offset >= 8 else {
                    return nil
                }
                var value: UInt64 = 0
                for shift in 0..<8 {
                    value |= UInt64(bytes[offset + shift]) << UInt64(shift * 8)
                }
                offset += 8
                fields.append(Field(number: fieldNumber, value: .fixed64(value)))
            case 2:
                guard let length = readVarint(bytes: bytes, offset: &offset),
                      length <= UInt64(bytes.count - offset) else {
                    return nil
                }
                let byteCount = Int(length)
                let slice = Data(bytes[offset..<(offset + byteCount)])
                offset += byteCount
                fields.append(Field(number: fieldNumber, value: .lengthDelimited(slice)))
            case 5:
                guard bytes.count - offset >= 4 else {
                    return nil
                }
                var value: UInt32 = 0
                for shift in 0..<4 {
                    value |= UInt32(bytes[offset + shift]) << UInt32(shift * 8)
                }
                offset += 4
                fields.append(Field(number: fieldNumber, value: .fixed32(value)))
            default:
                return nil
            }
        }

        return ProtoWireMessage(fields: fields)
    }

    private static func readVarint(bytes: [UInt8], offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1

            if shift == 63 && (byte & 0xFE) != 0 {
                return nil
            }
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
            if shift >= 64 {
                return nil
            }
        }
        return nil
    }

    func firstVarint(_ fieldNumber: Int) -> UInt64? {
        for field in fields where field.number == fieldNumber {
            if case .varint(let value) = field.value {
                return value
            }
        }
        return nil
    }

    func firstInt(_ fieldNumber: Int) -> Int? {
        guard let raw = firstVarint(fieldNumber) else {
            return nil
        }
        return Int(exactly: Int64(bitPattern: raw))
    }

    func firstBool(_ fieldNumber: Int) -> Bool? {
        firstVarint(fieldNumber).map { $0 != 0 }
    }

    func firstString(_ fieldNumber: Int) -> String? {
        for field in fields where field.number == fieldNumber {
            if case .lengthDelimited(let data) = field.value,
               let string = String(data: data, encoding: .utf8) {
                return string
            }
        }
        return nil
    }

    func allStrings(_ fieldNumber: Int) -> [String] {
        var strings: [String] = []
        for field in fields where field.number == fieldNumber {
            if case .lengthDelimited(let data) = field.value,
               let string = String(data: data, encoding: .utf8) {
                strings.append(string)
            }
        }
        return strings
    }

    func firstSubmessage(_ fieldNumber: Int) -> ProtoWireMessage? {
        for field in fields where field.number == fieldNumber {
            if case .lengthDelimited(let data) = field.value,
               let submessage = ProtoWireMessage.decode(data) {
                return submessage
            }
        }
        return nil
    }

    func allSubmessages(_ fieldNumber: Int) -> [ProtoWireMessage] {
        var results: [ProtoWireMessage] = []
        for field in fields where field.number == fieldNumber {
            if case .lengthDelimited(let data) = field.value,
               let submessage = ProtoWireMessage.decode(data) {
                results.append(submessage)
            }
        }
        return results
    }

    /// Traverses a nested protobuf field path, collecting all matching submessages at the terminal depth.
    func submessages(along path: [Int]) -> [ProtoWireMessage] {
        guard !path.isEmpty, path.count <= Self.maxDecodeDepth else {
            return path.isEmpty ? [self] : []
        }
        var current = [self]
        for fieldNumber in path {
            var next: [ProtoWireMessage] = []
            for message in current {
                next.append(contentsOf: message.allSubmessages(fieldNumber))
            }
            if next.isEmpty {
                return []
            }
            current = next
        }
        return current
    }
}

// MARK: - Parser Result Models

/// Decoded `StreamGenerateResponse` (`_.uv`) payload combining the UI `StreamingDelta` with auxiliary metadata.
nonisolated struct ParsedStreamFrame: Equatable, Sendable {
    let delta: StreamingDelta
    let generatedTitle: String?
    let modeId: String?
    let modelAttributionName: String?
    let isTemporaryChat: Bool?

    init(
        delta: StreamingDelta,
        generatedTitle: String? = nil,
        modeId: String? = nil,
        modelAttributionName: String? = nil,
        isTemporaryChat: Bool? = nil
    ) {
        self.delta = delta
        self.generatedTitle = generatedTitle
        self.modeId = modeId
        self.modelAttributionName = modelAttributionName
        self.isTemporaryChat = isTemporaryChat
    }
}

/// Categorized gRPC / Boq `wrb.fr` error codes returned by `batchexecute` and legacy `StreamGenerate`.
nonisolated enum BatchExecuteErrorKind: Equatable, Sendable {
    case conversationNotFound
    case permissionDenied
    case unauthenticated
    case other(code: Int)

    init(code: Int) {
        switch code {
        case GeminiBridgeSelectors.WireFormat.StatusCode.grpcNotFound.rawValue:
            self = .conversationNotFound
        case GeminiBridgeSelectors.WireFormat.StatusCode.grpcPermissionDenied.rawValue:
            self = .permissionDenied
        case GeminiBridgeSelectors.WireFormat.StatusCode.grpcUnauthenticated.rawValue:
            self = .unauthenticated
        default:
            self = .other(code: code)
        }
    }
}

/// Single unwrapped `wrb.fr` envelope frame extracted from a `batchexecute` or legacy Boq response.
nonisolated struct BatchExecuteEnvelopeFrame: Equatable, Sendable {
    let rpcId: String?
    let innerJSON: JSONValue?
    let errorCode: Int?
    let errorKind: BatchExecuteErrorKind?
    let requestIndex: String?
}

/// Item emitted by incremental streaming parsers (either a decoded frame or an inline RPC error).
nonisolated enum StreamParseOutput: Equatable, Sendable {
    case frame(ParsedStreamFrame)
    case rpcError(BatchExecuteErrorKind)
}

/// Parsed `otAQ7b` (`GetUserStatus`) payload including eligibility status, models, and challenge mapping.
nonisolated struct UserStatusResult: Equatable, Sendable {
    let statusCode: Int
    let models: [ModelOption]
    let challenge: ChallengeBannerState?

    var isUnauthenticated: Bool {
        statusCode == GeminiBridgeSelectors.WireFormat.StatusCode.accountUnauthenticated.rawValue
    }
}

/// Parsed `o30O0e` (`GetPeople`) profile details for the signed-in Google account.
nonisolated struct PeopleProfile: Equatable, Sendable {
    let email: String?
    let displayName: String?
    let shortName: String?
    let avatarURL: URL?
}

/// Snapshot of `WIZ_global_data` auth indicators and DOM markers observed on a Gemini page.
nonisolated struct BootAuthSnapshot: Equatable, Sendable {
    let xsrfTokenPresent: Bool
    let gaiaUserId: String?
    let email: String?
    let authUserIndex: Int?
    let isAnonymousSession: Bool
    let hasSignedOutDOMMarker: Bool
    let hasSignedInDOMMarker: Bool
    let domAccountLabel: String?
    let domAvatarURL: URL?
    let pageURL: URL?
    let buildLabel: String?
    let isTemporaryChat: Bool?

    init(
        xsrfTokenPresent: Bool = false,
        gaiaUserId: String? = nil,
        email: String? = nil,
        authUserIndex: Int? = nil,
        isAnonymousSession: Bool = false,
        hasSignedOutDOMMarker: Bool = false,
        hasSignedInDOMMarker: Bool = false,
        domAccountLabel: String? = nil,
        domAvatarURL: URL? = nil,
        pageURL: URL? = nil,
        buildLabel: String? = nil,
        isTemporaryChat: Bool? = nil
    ) {
        self.xsrfTokenPresent = xsrfTokenPresent
        self.gaiaUserId = gaiaUserId
        self.email = email
        self.authUserIndex = authUserIndex
        self.isAnonymousSession = isAnonymousSession
        self.hasSignedOutDOMMarker = hasSignedOutDOMMarker
        self.hasSignedInDOMMarker = hasSignedInDOMMarker
        self.domAccountLabel = domAccountLabel
        self.domAvatarURL = domAvatarURL
        self.pageURL = pageURL
        self.buildLabel = buildLabel
        self.isTemporaryChat = isTemporaryChat
    }
}

// MARK: - StreamingDeltaAccumulator

/// Merges incremental `StreamingDelta` chunks belonging to a single assistant turn so metadata-only
/// or terminal frames never erase previously accumulated markdown, thinking, images, or citations.
nonisolated struct StreamingDeltaAccumulator: Sendable {

    private var conversationId: String?
    private var responseId: String?
    private var choiceId: String?
    private var thinkingText: String?
    private var isThinkingComplete: Bool = false
    private var markdownSnapshot: String = ""
    private var inlineImages: [ImageAttachment] = []
    private var citations: [CitationLink] = []
    private var artifacts: [ArtifactCardInfo] = []
    private var isFinal: Bool = false

    mutating func reset() {
        conversationId = nil
        responseId = nil
        choiceId = nil
        thinkingText = nil
        isThinkingComplete = false
        markdownSnapshot = ""
        inlineImages = []
        citations = []
        artifacts = []
        isFinal = false
    }

    /// Merges the incoming delta with prior state for this turn and returns the cumulative `StreamingDelta`.
    mutating func merge(_ incoming: StreamingDelta) -> StreamingDelta {
        if let id = incoming.conversationId, !id.isEmpty {
            conversationId = id
        }
        if let id = incoming.responseId, !id.isEmpty {
            responseId = id
        }
        if let id = incoming.choiceId, !id.isEmpty {
            choiceId = id
        }
        if let thoughts = incoming.thinkingText, !thoughts.isEmpty {
            thinkingText = thoughts
        }
        if !incoming.markdownSnapshot.isEmpty {
            markdownSnapshot = incoming.markdownSnapshot
        }
        if !incoming.inlineImages.isEmpty {
            inlineImages = Self.mergeUnique(existing: inlineImages, incoming: incoming.inlineImages, key: { $0.url.absoluteString })
        }
        if !incoming.citations.isEmpty {
            citations = Self.mergeUnique(existing: citations, incoming: incoming.citations, key: { $0.url.absoluteString })
        }
        if !incoming.artifacts.isEmpty {
            artifacts = Self.mergeUnique(existing: artifacts, incoming: incoming.artifacts, key: { "\($0.kind.rawValue):\($0.id)" })
        }

        if incoming.isFinal {
            isFinal = true
            isThinkingComplete = true
        } else if incoming.isThinkingComplete {
            isThinkingComplete = true
        } else if !markdownSnapshot.isEmpty && incoming.thinkingText == nil {
            isThinkingComplete = true
        }

        return StreamingDelta(
            conversationId: conversationId,
            responseId: responseId,
            choiceId: choiceId,
            thinkingText: thinkingText,
            isThinkingComplete: isThinkingComplete,
            markdownSnapshot: markdownSnapshot,
            inlineImages: inlineImages,
            citations: citations,
            artifacts: artifacts,
            isFinal: isFinal
        )
    }

    private static func mergeUnique<T>(existing: [T], incoming: [T], key: (T) -> String) -> [T] {
        var result = existing
        var indexByKey: [String: Int] = [:]
        for (idx, item) in result.enumerated() {
            indexByKey[key(item)] = idx
        }
        for item in incoming {
            let itemKey = key(item)
            if let existingIndex = indexByKey[itemKey] {
                result[existingIndex] = item
            } else {
                indexByKey[itemKey] = result.count
                result.append(item)
            }
        }
        return result
    }
}

// MARK: - Incremental Stream Buffers

/// Stateful incremental parser for Transport A: WebChannel `/v1/processSession` length-prefixed
/// base64 protobuf frames (`<len>\n[[<seq>,["<base64-protobuf>"]]]`).
nonisolated struct WebChannelStreamBuffer: Sendable {

    private var buffer: String = ""
    private var consumedSnapshotUTF16Count: Int = 0

    /// Appends a pre-sliced delta chunk and returns all newly completed stream frames.
    mutating func appendDelta(_ chunk: String) -> [ParsedStreamFrame] {
        guard !chunk.isEmpty else {
            return []
        }
        buffer.append(chunk)
        return drainCompleteFrames()
    }

    /// Ingests a cumulative `XHR.responseText` snapshot, slicing only the unread suffix.
    mutating func ingestCumulativeSnapshot(_ fullResponseText: String) -> [ParsedStreamFrame] {
        let utf16 = fullResponseText.utf16
        guard utf16.count > consumedSnapshotUTF16Count else {
            return []
        }
        guard let startIndex = utf16.index(utf16.startIndex, offsetBy: consumedSnapshotUTF16Count, limitedBy: utf16.endIndex) else {
            return []
        }
        let delta = String(fullResponseText[startIndex...])
        consumedSnapshotUTF16Count = utf16.count
        return appendDelta(delta)
    }

    /// Flushes any trailing unframed line when the stream ends.
    mutating func finish() -> [ParsedStreamFrame] {
        var frames = drainCompleteFrames()
        let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if !remaining.isEmpty, remaining.hasPrefix("[") {
            frames.append(contentsOf: GeminiPayloadParser.decodeWebChannelFrameJSON(remaining))
        }
        return frames
    }

    private mutating func drainCompleteFrames() -> [ParsedStreamFrame] {
        var frames: [ParsedStreamFrame] = []
        let chunks = GeminiPayloadParser.extractLengthPrefixedChunks(from: &buffer)
        for chunk in chunks {
            frames.append(contentsOf: GeminiPayloadParser.decodeWebChannelFrameJSON(chunk))
        }
        return frames
    }
}

/// Stateful incremental parser for Transport B: SSE `/v1/conversations:streamGenerate?alt=sse`
/// (`data: <JSPB JSON array>`).
nonisolated struct SSEStreamBuffer: Sendable {

    private var remainder: String = ""

    /// Appends a raw SSE text chunk and emits parsed frames or inline RPC errors.
    mutating func append(_ chunk: String) -> [StreamParseOutput] {
        guard !chunk.isEmpty else {
            return []
        }
        remainder.append(chunk)

        var outputs: [StreamParseOutput] = []
        while let newlineIndex = remainder.firstIndex(of: "\n") {
            let rawLine = String(remainder[..<newlineIndex])
            remainder.removeSubrange(remainder.startIndex...newlineIndex)
            if let output = parseSSELine(rawLine) {
                outputs.append(output)
            }
        }
        return outputs
    }

    /// Flushes any final line lacking a trailing newline when the SSE stream closes.
    mutating func finish() -> [StreamParseOutput] {
        let trailing = remainder
        remainder = ""
        guard !trailing.isEmpty, let output = parseSSELine(trailing) else {
            return []
        }
        return [output]
    }

    private func parseSSELine(_ rawLine: String) -> StreamParseOutput? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix(":") else {
            return nil
        }
        let prefix = GeminiBridgeSelectors.WireFormat.sseDataPrefix
        guard line.hasPrefix(prefix) else {
            return nil
        }

        let payload = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, payload != "[DONE]" else {
            return nil
        }

        guard let json = JSONValue.parse(payload) else {
            GeminiPayloadParser.logParseError("SSE data line failed JSON decoding (len=\(payload.count))")
            return nil
        }

        if let errorKind = GeminiPayloadParser.extractInlineJSONError(from: json) {
            return .rpcError(errorKind)
        }

        guard let frame = GeminiPayloadParser.parseStreamGenerateResponse(json: json) else {
            GeminiPayloadParser.logParseError("SSE StreamGenerateResponse JSON shape unrecognized (len=\(payload.count))")
            return nil
        }
        return .frame(frame)
    }
}

/// Stateful incremental parser for Transport C: Legacy Boq
/// `/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate` (`)]}'\n` + length-prefixed `wrb.fr`).
nonisolated struct LegacyBoqStreamBuffer: Sendable {

    private var buffer: String = ""
    private var strippedXSSI: Bool = false

    /// Appends a raw text chunk from a legacy Boq stream and returns parsed frames or RPC errors.
    mutating func append(_ chunk: String) -> [StreamParseOutput] {
        guard !chunk.isEmpty else {
            return []
        }
        buffer.append(chunk)
        stripXSSIIfNeeded()
        return drainCompleteFrames()
    }

    /// Flushes any trailing unframed line when the stream ends.
    mutating func finish() -> [StreamParseOutput] {
        stripXSSIIfNeeded()
        var outputs = drainCompleteFrames()
        let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if !remaining.isEmpty, remaining.hasPrefix("[") {
            outputs.append(contentsOf: GeminiPayloadParser.decodeLegacyBoqChunk(remaining))
        }
        return outputs
    }

    private mutating func stripXSSIIfNeeded() {
        guard !strippedXSSI else {
            return
        }
        let prefix = GeminiBridgeSelectors.WireFormat.xssiPrefix
        if buffer.hasPrefix(prefix) {
            buffer.removeFirst(prefix.count)
            strippedXSSI = true
            return
        }
        if buffer.hasPrefix(")]}'\r\n") {
            buffer.removeFirst(6)
            strippedXSSI = true
            return
        }
        // Only mark XSSI absent once we have enough prefix characters to be sure.
        if buffer.count >= 6 {
            strippedXSSI = true
        }
    }

    private mutating func drainCompleteFrames() -> [StreamParseOutput] {
        var outputs: [StreamParseOutput] = []
        let chunks = GeminiPayloadParser.extractLengthPrefixedChunks(from: &buffer)
        for chunk in chunks {
            outputs.append(contentsOf: GeminiPayloadParser.decodeLegacyBoqChunk(chunk))
        }
        return outputs
    }
}

// MARK: - GeminiPayloadParser

/// Pure Swift (`nonisolated`, zero-WebKit) parser for all §5 verified Gemini web protocol payloads:
/// WebChannel `/v1/processSession` binary protobuf streams, SSE `streamGenerate`, legacy Boq
/// `StreamGenerate`, `batchexecute` RPCs (`MaZiqc`, `hNvQHb`, `otAQ7b`, `o30O0e`), and `WIZ_global_data` auth.
nonisolated enum GeminiPayloadParser {

    // MARK: - Logging

    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "GeminiBridge")

    fileprivate static func logParseError(_ message: String) {
        logger.error("GeminiPayloadParser: \(message, privacy: .public)")
    }

    // MARK: - Multi-Transport Stream Convenience APIs

    /// Parses a complete WebChannel `/v1/processSession` buffer into cumulative `StreamingDelta` values.
    static func parseWebChannelDeltas(_ rawText: String) -> [StreamingDelta] {
        var streamBuffer = WebChannelStreamBuffer()
        var frames = streamBuffer.appendDelta(rawText)
        frames.append(contentsOf: streamBuffer.finish())
        return frames.map(\.delta)
    }

    /// Parses a complete SSE `/v1/conversations:streamGenerate?alt=sse` buffer into `StreamingDelta` values.
    static func parseSSEDeltas(_ rawText: String) -> [StreamingDelta] {
        var streamBuffer = SSEStreamBuffer()
        var outputs = streamBuffer.append(rawText)
        outputs.append(contentsOf: streamBuffer.finish())
        return outputs.compactMap { output in
            if case .frame(let frame) = output {
                return frame.delta
            }
            return nil
        }
    }

    /// Parses a complete legacy Boq `StreamGenerate` buffer into `StreamingDelta` values.
    static func parseLegacyBoqDeltas(_ rawText: String) -> [StreamingDelta] {
        var streamBuffer = LegacyBoqStreamBuffer()
        var outputs = streamBuffer.append(rawText)
        outputs.append(contentsOf: streamBuffer.finish())
        return outputs.compactMap { output in
            if case .frame(let frame) = output {
                return frame.delta
            }
            return nil
        }
    }

    // MARK: - StreamGenerateResponse (Protobuf)

    /// Decodes a single base64-encoded WebChannel `ProcessSessionResponse` protobuf payload along
    /// `2 -> 7 -> 1 -> 4 -> 4` into `ParsedStreamFrame` entries.
    static func parseProcessSessionBase64(_ base64: String) -> [ParsedStreamFrame] {
        guard let rawBytes = decodeBase64Flexible(base64) else {
            logParseError("WebChannel base64 decode failed (len=\(base64.count))")
            return []
        }
        guard let rootMessage = ProtoWireMessage.decode(rawBytes) else {
            logParseError("WebChannel protobuf wire decode failed (bytes=\(rawBytes.count))")
            return []
        }
        return parseProcessSessionMessage(rootMessage)
    }

    /// Extracts embedded `StreamGenerateResponse` (`_.uv`) messages from a decoded `ProcessSessionResponse`.
    static func parseProcessSessionMessage(_ root: ProtoWireMessage) -> [ParsedStreamFrame] {
        let fullPath = GeminiBridgeSelectors.WireFormat.processSessionStreamResponsePath
        guard fullPath.count == 5 else {
            return []
        }
        let turnPayloadPath = Array(fullPath.prefix(3))
        let responseTailPath = Array(fullPath.suffix(2))

        let turnPayloads = root.submessages(along: turnPayloadPath)
        var frames: [ParsedStreamFrame] = []

        for turnPayload in turnPayloads {
            let turnComplete = (turnPayload.firstVarint(1) == 1)
            let responseMessages = turnPayload.submessages(along: responseTailPath)
            for responseMessage in responseMessages {
                if let frame = parseStreamGenerateResponse(proto: responseMessage, forceFinal: turnComplete) {
                    frames.append(frame)
                }
            }
        }
        return frames
    }

    /// Decodes a `StreamGenerateResponse` (`_.uv`) directly from a binary `ProtoWireMessage`.
    static func parseStreamGenerateResponse(
        proto message: ProtoWireMessage,
        forceFinal: Bool = false
    ) -> ParsedStreamFrame? {
        typealias Field = GeminiBridgeSelectors.WireFormat.StreamResponseField

        let idsMessage = message.firstSubmessage(Field.conversationIds.rawValue)
        let conversationId = nonEmptyTrimmed(idsMessage?.firstString(1))
        let responseId = nonEmptyTrimmed(idsMessage?.firstString(2))

        let candidates = message.allSubmessages(Field.candidates.rawValue)
        let primaryCandidate = candidates.first
        let parsedCandidate = primaryCandidate.map { parseCandidate(proto: $0) }

        let progressMessage = message.firstSubmessage(Field.progressStatus.rawValue)
        let liveThinkingHeader = nonEmptyTrimmed(progressMessage?.firstSubmessage(6)?.firstString(1))
        let liveThinkingActive = progressMessage?.firstBool(4)

        let generatedTitle = nonEmptyTrimmed(message.firstSubmessage(Field.titleGeneration.rawValue)?.firstString(1))
        let responseIsFinal = message.firstBool(Field.isFinal.rawValue) ?? false

        let structuredMessages = message.allSubmessages(Field.structuredContent.rawValue)
        let structuredResult = extractStructuredContent(proto: structuredMessages)

        let modeId = nonEmptyTrimmed(message.firstString(Field.modeId.rawValue))
        let modelAttributionName = nonEmptyTrimmed(message.firstString(Field.modelAttributionName.rawValue))
        let tempStateRaw = message.firstInt(Field.temporaryChatState.rawValue)
        let isTemporaryChat: Bool? = switch tempStateRaw {
        case 1: false
        case 2: true
        default: nil
        }

        let markdown = firstNonEmpty(parsedCandidate?.markdown, structuredResult.fallbackMarkdown) ?? ""
        let thinkingText = firstNonEmpty(parsedCandidate?.thinkingText, liveThinkingHeader)
        let isFinal = forceFinal || responseIsFinal || (parsedCandidate?.isComplete == true)
        let isThinkingComplete = resolveThinkingComplete(
            thinkingText: thinkingText,
            markdown: markdown,
            liveThinkingActive: liveThinkingActive,
            isFinal: isFinal
        )

        let images = deduplicateImages(structuredResult.images + (parsedCandidate?.images ?? []))
        let citations = parsedCandidate?.citations ?? []
        let artifacts = parsedCandidate?.artifacts ?? []

        // Require at least one recognizable `StreamGenerateResponse` signal before emitting a frame.
        let hasSignal = conversationId != nil
            || responseId != nil
            || parsedCandidate != nil
            || thinkingText != nil
            || !markdown.isEmpty
            || !images.isEmpty
            || !citations.isEmpty
            || !artifacts.isEmpty
            || generatedTitle != nil
            || isFinal
            || modeId != nil
            || isTemporaryChat != nil

        guard hasSignal else {
            return nil
        }

        let delta = StreamingDelta(
            conversationId: conversationId,
            responseId: responseId,
            choiceId: parsedCandidate?.choiceId,
            thinkingText: thinkingText,
            isThinkingComplete: isThinkingComplete,
            markdownSnapshot: markdown,
            inlineImages: images,
            citations: citations,
            artifacts: artifacts,
            isFinal: isFinal
        )

        return ParsedStreamFrame(
            delta: delta,
            generatedTitle: generatedTitle,
            modeId: modeId,
            modelAttributionName: modelAttributionName,
            isTemporaryChat: isTemporaryChat
        )
    }

    // MARK: - StreamGenerateResponse (JSPB JSON)

    /// Decodes a `StreamGenerateResponse` (`_.uv`) from a JSPB JSON array (SSE & legacy Boq).
    static func parseStreamGenerateResponse(
        json: JSONValue,
        forceFinal: Bool = false
    ) -> ParsedStreamFrame? {
        guard json.arrayValue != nil else {
            return nil
        }

        typealias Field = GeminiBridgeSelectors.WireFormat.StreamResponseField

        let idsNode = json[jspbIndex(Field.conversationIds)]
        let conversationId = idsNode?[0]?.nonEmptyStringValue
        let responseId = idsNode?[1]?.nonEmptyStringValue

        let candidatesArray = json[jspbIndex(Field.candidates)]?.arrayValue ?? []
        let primaryCandidate = candidatesArray.first.flatMap { parseCandidate(json: $0) }

        let progressNode = json[jspbIndex(Field.progressStatus)]
        let liveThinkingHeader = progressNode?[5]?[0]?.nonEmptyStringValue
        let liveThinkingActive = progressNode?[3]?.boolValue

        let generatedTitle = json[jspbIndex(Field.titleGeneration)]?[0]?.nonEmptyStringValue
        let responseIsFinal = json[jspbIndex(Field.isFinal)]?.boolValue ?? false

        let structuredNode = json[jspbIndex(Field.structuredContent)]
        let structuredResult = extractStructuredContent(json: structuredNode)

        let modeId = json[jspbIndex(Field.modeId)]?.nonEmptyStringValue
        let modelAttributionName = json[jspbIndex(Field.modelAttributionName)]?.nonEmptyStringValue
        let tempStateRaw = json[jspbIndex(Field.temporaryChatState)]?.intValue
        let isTemporaryChat: Bool? = switch tempStateRaw {
        case 1: false
        case 2: true
        default: nil
        }

        let markdown = firstNonEmpty(primaryCandidate?.markdown, structuredResult.fallbackMarkdown) ?? ""
        let thinkingText = firstNonEmpty(primaryCandidate?.thinkingText, liveThinkingHeader)
        let isFinal = forceFinal || responseIsFinal || (primaryCandidate?.isComplete == true)
        let isThinkingComplete = resolveThinkingComplete(
            thinkingText: thinkingText,
            markdown: markdown,
            liveThinkingActive: liveThinkingActive,
            isFinal: isFinal
        )

        let images = deduplicateImages(structuredResult.images + (primaryCandidate?.images ?? []))
        let citations = primaryCandidate?.citations ?? []
        let artifacts = primaryCandidate?.artifacts ?? []

        let hasSignal = conversationId != nil
            || responseId != nil
            || primaryCandidate != nil
            || thinkingText != nil
            || !markdown.isEmpty
            || !images.isEmpty
            || !citations.isEmpty
            || !artifacts.isEmpty
            || generatedTitle != nil
            || isFinal
            || modeId != nil
            || isTemporaryChat != nil

        guard hasSignal else {
            return nil
        }

        let delta = StreamingDelta(
            conversationId: conversationId,
            responseId: responseId,
            choiceId: primaryCandidate?.choiceId,
            thinkingText: thinkingText,
            isThinkingComplete: isThinkingComplete,
            markdownSnapshot: markdown,
            inlineImages: images,
            citations: citations,
            artifacts: artifacts,
            isFinal: isFinal
        )

        return ParsedStreamFrame(
            delta: delta,
            generatedTitle: generatedTitle,
            modeId: modeId,
            modelAttributionName: modelAttributionName,
            isTemporaryChat: isTemporaryChat
        )
    }

    // MARK: - BatchExecute Envelope & RPC Parsers

    /// Unwraps XSSI prefix `)]}'\n` and extracts all `wrb.fr` frames from a `batchexecute` response body.
    static func parseBatchExecuteEnvelope(_ rawText: String) -> [BatchExecuteEnvelopeFrame] {
        var remaining = stripXSSIPrefix(rawText)
        let chunks = extractLengthPrefixedChunks(from: &remaining)
        var frames: [BatchExecuteEnvelopeFrame] = []

        for chunk in chunks {
            frames.append(contentsOf: decodeWrbFrames(from: chunk))
        }

        let trailing = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty, trailing.hasPrefix("[") {
            frames.append(contentsOf: decodeWrbFrames(from: trailing))
        }
        return frames
    }

    /// Maps a `batchexecute` gRPC error kind to a structured `ChatTransportError`.
    static func transportError(
        for errorKind: BatchExecuteErrorKind,
        conversationId: String? = nil
    ) -> ChatTransportError {
        switch errorKind {
        case .conversationNotFound:
            return .conversationNotFound(id: conversationId ?? "")
        case .unauthenticated, .permissionDenied:
            let banner = ChallengeBannerState(
                kind: .reauthRequired,
                message: "Your Google session requires re-authentication.",
                challengeURL: URL(string: GeminiBridgeSelectors.Endpoints.signInURLString)
            )
            return .challengeRequired(banner)
        case .other(let code):
            return .networkError(message: "Gemini RPC failed with error code \(code).")
        }
    }

    /// Parses `MaZiqc` (`ListConversations`) inner JSON into `[ConversationSummary]`,
    /// omitting hidden and temporary conversations.
    static func parseListConversations(_ innerJSON: JSONValue) -> [ConversationSummary] {
        typealias ListIdx = GeminiBridgeSelectors.WireFormat.ListConversationsIndex
        typealias ItemIdx = GeminiBridgeSelectors.WireFormat.ConversationItemIndex

        guard let items = innerJSON[ListIdx.conversations.rawValue]?.arrayValue else {
            logParseError("MaZiqc payload missing conversations array at index \(ListIdx.conversations.rawValue)")
            return []
        }

        var summaries: [ConversationSummary] = []
        summaries.reserveCapacity(items.count)

        for item in items {
            guard let id = item[ItemIdx.id.rawValue]?.nonEmptyStringValue else {
                continue
            }
            if item[ItemIdx.isHidden.rawValue]?.boolValue == true {
                continue
            }
            if item[ItemIdx.isTemporary.rawValue]?.boolValue == true {
                continue
            }

            let title = item[ItemIdx.title.rawValue]?.nonEmptyStringValue ?? "Untitled"
            let isPinned = item[ItemIdx.isPinned.rawValue]?.boolValue ?? false
            let updatedAt = parseTimestamp(item[ItemIdx.updatedTimestamp.rawValue]) ?? Date(timeIntervalSince1970: 0)

            summaries.append(ConversationSummary(
                id: id,
                title: title,
                updatedAt: updatedAt,
                isPinned: isPinned
            ))
        }

        return summaries
    }

    /// Parses `hNvQHb` (`ListConversationTurns`) inner JSON into chronological `[ChatTurn]` entries.
    static func parseListConversationTurns(_ innerJSON: JSONValue) -> [ChatTurn] {
        typealias ListIdx = GeminiBridgeSelectors.WireFormat.ListTurnsIndex
        typealias TurnIdx = GeminiBridgeSelectors.WireFormat.TurnItemIndex

        guard let rawTurns = innerJSON[ListIdx.turns.rawValue]?.arrayValue else {
            logParseError("hNvQHb payload missing turns array at index \(ListIdx.turns.rawValue)")
            return []
        }

        struct IndexedTurn {
            let originalIndex: Int
            let hasExplicitTimestamp: Bool
            let turn: ChatTurn
        }

        var parsed: [IndexedTurn] = []
        parsed.reserveCapacity(rawTurns.count)

        for (index, rawTurn) in rawTurns.enumerated() {
            guard rawTurn.arrayValue != nil else {
                continue
            }

            let idsNode = rawTurn[TurnIdx.ids.rawValue]
            let conversationId = idsNode?[0]?.nonEmptyStringValue
            let responseId = idsNode?[1]?.nonEmptyStringValue

            let userRequestNode = rawTurn[TurnIdx.userRequest.rawValue]
            let userPrompt = extractUserPromptText(from: userRequestNode)
            let userAttachments = extractUserAttachments(from: userRequestNode)
            let modeId = userRequestNode?[4]?.nonEmptyStringValue

            let modelResponseNode = rawTurn[TurnIdx.modelResponse.rawValue]
            let candidateNodes = modelResponseNode?[0]?.arrayValue ?? []
            let selectedChoiceId = modelResponseNode?[3]?.nonEmptyStringValue
            let isFinal = modelResponseNode?[9]?.boolValue ?? true
            let structuredNode = modelResponseNode?[12]

            let parsedCandidates = candidateNodes.compactMap { parseCandidate(json: $0) }
            let selectedCandidate: ParsedCandidate?
            if let selectedChoiceId {
                selectedCandidate = parsedCandidates.first(where: { $0.choiceId == selectedChoiceId }) ?? parsedCandidates.first
            } else {
                selectedCandidate = parsedCandidates.first
            }

            let structuredResult = extractStructuredContent(json: structuredNode)
            let markdown = firstNonEmpty(selectedCandidate?.markdown, structuredResult.fallbackMarkdown) ?? ""
            let images = deduplicateImages(structuredResult.images + (selectedCandidate?.images ?? []))
            let artifacts = selectedCandidate?.artifacts ?? []
            let citations = selectedCandidate?.citations ?? []

            var parts: [MessagePart] = []
            if !markdown.isEmpty {
                parts.append(.markdown(markdown))
            }
            for image in images {
                parts.append(.inlineImage(image))
            }
            for artifact in artifacts {
                parts.append(.unsupportedArtifact(artifact))
            }

            let explicitDate = parseTimestamp(rawTurn[TurnIdx.timestamp.rawValue])
            let createdAt = explicitDate ?? Date(timeIntervalSince1970: 0)
            let turnId = responseId ?? "\(conversationId ?? "turn")-\(index)"

            let turn = ChatTurn(
                id: turnId,
                userPrompt: userPrompt,
                userAttachments: userAttachments,
                assistantParts: parts,
                thinkingText: selectedCandidate?.thinkingText,
                isThinkingComplete: isFinal,
                citations: citations,
                metadata: TurnResponseMetadata(
                    responseId: responseId,
                    choiceId: selectedCandidate?.choiceId ?? selectedChoiceId,
                    modelId: modeId,
                    thinkingDurationSeconds: nil
                ),
                createdAt: createdAt
            )
            parsed.append(IndexedTurn(
                originalIndex: index,
                hasExplicitTimestamp: explicitDate != nil,
                turn: turn
            ))
        }

        // Gemini frequently returns turns newest-first; sort ascending when explicit timestamps exist.
        if parsed.count > 1, parsed.allSatisfy(\.hasExplicitTimestamp) {
            let sorted = parsed.sorted { lhs, rhs in
                if lhs.turn.createdAt != rhs.turn.createdAt {
                    return lhs.turn.createdAt < rhs.turn.createdAt
                }
                return lhs.originalIndex < rhs.originalIndex
            }
            return sorted.map(\.turn)
        }

        return parsed.map(\.turn)
    }

    /// Parses `otAQ7b` (`GetUserStatus`) inner JSON into account status, available models, and optional challenge state.
    static func parseUserStatus(_ innerJSON: JSONValue) -> UserStatusResult? {
        typealias Idx = GeminiBridgeSelectors.WireFormat.GetUserStatusIndex
        guard innerJSON.arrayValue != nil else {
            logParseError("otAQ7b payload is not a JSON array")
            return nil
        }

        guard let statusCode = innerJSON[Idx.statusCode.rawValue]?.intValue else {
            logParseError("otAQ7b payload missing status code at index \(Idx.statusCode.rawValue)")
            return nil
        }

        var models: [ModelOption] = []
        if let rawModels = innerJSON[Idx.availableModels.rawValue]?.arrayValue {
            var seenIds: Set<String> = []
            for rawModel in rawModels {
                guard let id = rawModel[0]?.nonEmptyStringValue,
                      seenIds.insert(id).inserted else {
                    continue
                }
                let displayName = firstNonEmpty(
                    rawModel[11]?.nonEmptyStringValue,
                    rawModel[1]?.nonEmptyStringValue
                ) ?? id
                let subtitle = firstNonEmpty(
                    rawModel[12]?.nonEmptyStringValue,
                    rawModel[2]?.nonEmptyStringValue
                )
                let isThinking = inferThinkingCapable(name: displayName, subtitle: subtitle)
                models.append(ModelOption(
                    id: id,
                    displayName: displayName,
                    subtitle: subtitle,
                    isThinkingCapable: isThinking
                ))
            }
        }

        let challenge = challengeBanner(forUserStatusCode: statusCode)
        return UserStatusResult(statusCode: statusCode, models: models, challenge: challenge)
    }

    /// Maps `otAQ7b` (`GetUserStatus`) status codes `1016`/`1033`/`1040`/`1054`/`1057`/`1060` to `ChallengeBannerState`.
    static func challengeBanner(forUserStatusCode statusCode: Int) -> ChallengeBannerState? {
        typealias Code = GeminiBridgeSelectors.WireFormat.StatusCode
        let appURL = URL(string: GeminiBridgeSelectors.Endpoints.appURLString)
        let signInURL = URL(string: GeminiBridgeSelectors.Endpoints.signInURLString)

        switch statusCode {
        case Code.accountAvailable.rawValue:
            return nil
        case Code.accountUnauthenticated.rawValue:
            return ChallengeBannerState(
                kind: .reauthRequired,
                message: "Your Google session expired. Sign in to continue.",
                challengeURL: signInURL
            )
        case Code.accountUntrusted.rawValue:
            return ChallengeBannerState(
                kind: .captchaOrPolicy,
                message: "Google requires additional verification for this account.",
                challengeURL: appURL
            )
        case Code.tosPending.rawValue:
            return ChallengeBannerState(
                kind: .captchaOrPolicy,
                message: "Please review and accept Gemini Terms of Service to continue.",
                challengeURL: appURL
            )
        case Code.accountRejectedByGuardian.rawValue:
            return ChallengeBannerState(
                kind: .captchaOrPolicy,
                message: "Gemini access is restricted by account supervision settings.",
                challengeURL: appURL
            )
        case Code.guardianApprovalRequired.rawValue:
            return ChallengeBannerState(
                kind: .captchaOrPolicy,
                message: "Guardian approval is required to use Gemini with this account.",
                challengeURL: appURL
            )
        case Code.locationRejected.rawValue:
            return ChallengeBannerState(
                kind: .captchaOrPolicy,
                message: "Gemini is not currently available in this region.",
                challengeURL: appURL
            )
        default:
            return nil
        }
    }

    /// Parses `o30O0e` (`InternalPeopleService.GetPeople`) inner JSON into `PeopleProfile`.
    static func parsePeopleProfile(_ innerJSON: JSONValue) -> PeopleProfile? {
        guard let person = innerJSON[0]?[2], person.arrayValue != nil else {
            logParseError("o30O0e payload missing person entry at [0][2]")
            return nil
        }

        let displayName = person[2]?[0]?[0]?.nonEmptyStringValue
        let shortName = person[2]?[0]?[3]?.nonEmptyStringValue
        let photoString = person[3]?[0]?[0]?.nonEmptyStringValue
        let avatarURL = photoString.flatMap { URL(string: $0) }
        let email = person[9]?[0]?[0]?.nonEmptyStringValue

        guard email != nil || displayName != nil || shortName != nil || avatarURL != nil else {
            return nil
        }

        return PeopleProfile(
            email: email,
            displayName: displayName,
            shortName: shortName,
            avatarURL: avatarURL
        )
    }

    /// Parses a raw `WIZ_global_data` JSON object (and optional DOM snapshot dictionary) into `BootAuthSnapshot`.
    static func parseBootAuthSnapshot(
        wizJSON: JSONValue,
        domJSON: JSONValue? = nil,
        pageURL: URL? = nil
    ) -> BootAuthSnapshot {
        typealias Keys = GeminiBridgeSelectors.WizGlobalDataKeys

        let xsrfPresent: Bool
        if let explicitFlag = wizJSON["xsrfTokenPresent"]?.boolValue {
            xsrfPresent = explicitFlag
        } else {
            xsrfPresent = wizJSON[Keys.xsrfToken]?.nonEmptyStringValue != nil
        }

        let gaiaUserId = wizJSON[Keys.gaiaUserId]?.nonEmptyStringValue
        let email = wizJSON[Keys.userEmail]?.nonEmptyStringValue
        let rawAuthUser = wizJSON[Keys.authUserIndex]?.intValue
        let authUserIndex = rawAuthUser.flatMap { $0 >= 0 ? $0 : nil }
        let buildLabel = wizJSON[Keys.buildLabel]?.nonEmptyStringValue

        var isAnonymous = wizJSON[Keys.isAnonymousSession]?.boolValue ?? false
        if !isAnonymous {
            for auxKey in Keys.signedOutAuxiliaryKeys {
                if wizJSON[auxKey]?.boolValue == true {
                    isAnonymous = true
                    break
                }
            }
        }

        let hasSignedOutDOM = domJSON?["hasSignedOutMarker"]?.boolValue ?? false
        let hasSignedInDOM = domJSON?["hasSignedInMarker"]?.boolValue ?? false
        let domLabel = domJSON?["accountLabel"]?.nonEmptyStringValue
        let domAvatarURL = domJSON?["avatarURL"]?.nonEmptyStringValue.flatMap { URL(string: $0) }
        let isTemporaryChat = domJSON?["isTemporaryChat"]?.boolValue

        return BootAuthSnapshot(
            xsrfTokenPresent: xsrfPresent,
            gaiaUserId: gaiaUserId,
            email: email,
            authUserIndex: authUserIndex,
            isAnonymousSession: isAnonymous,
            hasSignedOutDOMMarker: hasSignedOutDOM,
            hasSignedInDOMMarker: hasSignedInDOM,
            domAccountLabel: domLabel,
            domAvatarURL: domAvatarURL,
            pageURL: pageURL,
            buildLabel: buildLabel,
            isTemporaryChat: isTemporaryChat
        )
    }

    /// Resolves `AuthState` strictly from `WIZ_global_data` boot globals, `o30O0e` profile, and RPC auth signals.
    ///
    /// Never fabricates an `AccountScope` when signed out or when neither Gaia ID (`S06Grb`) nor email is verified.
    static func resolveAuthState(
        boot: BootAuthSnapshot?,
        peopleProfile: PeopleProfile?,
        rpcPermissionDenied: Bool = false,
        userStatusCode: Int? = nil,
        existingAvailableAccounts: [AccountScope] = []
    ) -> AuthState {
        let isUnauthenticatedStatus = userStatusCode == GeminiBridgeSelectors.WireFormat.StatusCode.accountUnauthenticated.rawValue
        let gaiaId = nonEmptyTrimmed(boot?.gaiaUserId)
        let domParsed = parseAccountFromDOMLabel(boot?.domAccountLabel)
        let resolvedEmail = firstNonEmpty(
            peopleProfile?.email,
            boot?.email,
            domParsed.email
        )

        let hasVerifiedIdentity = gaiaId != nil || resolvedEmail != nil
        let hasAuthSession = (boot?.xsrfTokenPresent == true) || (gaiaId != nil) || (peopleProfile?.email != nil)

        if boot?.isAnonymousSession == true {
            return .signedOut
        }
        if isUnauthenticatedStatus && !hasAuthSession {
            return .signedOut
        }
        if rpcPermissionDenied && !hasAuthSession {
            return .signedOut
        }
        if let boot, !boot.xsrfTokenPresent, !hasVerifiedIdentity {
            return .signedOut
        }
        if let boot, boot.hasSignedOutDOMMarker, !boot.xsrfTokenPresent, gaiaId == nil {
            return .signedOut
        }

        // Strict §4 #2 rule: never fabricate a scope without a verified Gaia ID or email.
        guard hasVerifiedIdentity, hasAuthSession else {
            if isUnauthenticatedStatus || rpcPermissionDenied {
                return .signedOut
            }
            return .unknown
        }

        let urlAuthUser = boot?.pageURL.flatMap { extractAuthUserIndex(from: $0) }
        let resolvedAuthUser = urlAuthUser ?? boot?.authUserIndex ?? 0
        let resolvedDisplayName = firstNonEmpty(
            peopleProfile?.displayName,
            peopleProfile?.shortName,
            domParsed.displayName
        )
        let resolvedAvatar = peopleProfile?.avatarURL ?? boot?.domAvatarURL

        let activeScope = AccountScope(
            email: resolvedEmail ?? "",
            gaiaId: gaiaId,
            displayName: resolvedDisplayName,
            avatarURL: resolvedAvatar,
            authUserIndex: resolvedAuthUser
        )

        var merged = existingAvailableAccounts.filter {
            $0.scopeId != activeScope.scopeId && $0.authUserIndex != activeScope.authUserIndex
        }
        merged.append(activeScope)
        merged.sort { $0.authUserIndex < $1.authUserIndex }

        return .signedIn(active: activeScope, available: merged)
    }

    // MARK: - Internal Framing Helpers

    fileprivate static func extractLengthPrefixedChunks(from buffer: inout String) -> [String] {
        var chunks: [String] = []

        while true {
            trimLeadingNewlinesAndSpaces(&buffer)
            guard !buffer.isEmpty else {
                break
            }

            guard let newlineIdx = buffer.firstIndex(of: "\n") else {
                break
            }

            let firstLine = String(buffer[..<newlineIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let afterNewline = buffer.index(after: newlineIdx)

            if let expectedLength = Int(firstLine), expectedLength > 0 {
                let remaining = buffer[afterNewline...]
                let utf16 = remaining.utf16
                guard utf16.count >= expectedLength else {
                    break
                }

                if let endUTF16 = utf16.index(utf16.startIndex, offsetBy: expectedLength, limitedBy: utf16.endIndex) {
                    let candidate = String(remaining[..<endUTF16]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if isCompleteJSONFragment(candidate) {
                        chunks.append(candidate)
                        buffer = String(remaining[endUTF16...])
                        continue
                    }
                }

                // Fallback when a producer's length header excludes or includes trailing line endings differently.
                if let payloadLineEnd = remaining.firstIndex(of: "\n") {
                    let lineCandidate = String(remaining[..<payloadLineEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if isCompleteJSONFragment(lineCandidate) {
                        chunks.append(lineCandidate)
                        buffer = String(remaining[remaining.index(after: payloadLineEnd)...])
                        continue
                    }
                } else {
                    let restCandidate = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
                    if isCompleteJSONFragment(restCandidate) {
                        chunks.append(restCandidate)
                        buffer = ""
                        continue
                    }
                }

                // Consume the declared span to avoid stalling forever on malformed data.
                if let endUTF16 = utf16.index(utf16.startIndex, offsetBy: expectedLength, limitedBy: utf16.endIndex) {
                    let malformed = String(remaining[..<endUTF16]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !malformed.isEmpty {
                        chunks.append(malformed)
                    }
                    buffer = String(remaining[endUTF16...])
                    continue
                }
                break
            } else {
                // Non-length-prefixed line (e.g., direct JSON array line).
                if isCompleteJSONFragment(firstLine) {
                    chunks.append(firstLine)
                    buffer = String(buffer[afterNewline...])
                    continue
                }
                // Discard unrecognized non-JSON header lines (e.g. stray XSSI or blank digits) safely.
                if !firstLine.hasPrefix("[") && !firstLine.hasPrefix("{") {
                    buffer = String(buffer[afterNewline...])
                    continue
                }
                break
            }
        }

        return chunks
    }

    fileprivate static func decodeWebChannelFrameJSON(_ text: String) -> [ParsedStreamFrame] {
        guard let root = JSONValue.parse(text) else {
            logParseError("WebChannel frame JSON malformed (len=\(text.count))")
            return []
        }
        guard let entries = root.arrayValue else {
            logParseError("WebChannel frame JSON is not an array")
            return []
        }

        var frames: [ParsedStreamFrame] = []
        for entry in entries {
            guard let pair = entry.arrayValue, pair.count >= 2 else {
                continue
            }
            guard let payloadValues = pair[1].arrayValue else {
                continue
            }
            for item in payloadValues {
                guard let rawString = item.nonEmptyStringValue else {
                    continue
                }
                // Ignore standard WebChannel control frames ("noop", "c", "stop").
                if rawString == "noop" || rawString == "c" || rawString == "stop" {
                    break
                }
                frames.append(contentsOf: parseProcessSessionBase64(rawString))
            }
        }
        return frames
    }

    fileprivate static func decodeLegacyBoqChunk(_ chunk: String) -> [StreamParseOutput] {
        let envelopeFrames = decodeWrbFrames(from: chunk)
        var outputs: [StreamParseOutput] = []

        for envelope in envelopeFrames {
            if let errorKind = envelope.errorKind {
                outputs.append(.rpcError(errorKind))
                continue
            }
            guard let innerJSON = envelope.innerJSON else {
                continue
            }
            if let parsed = parseStreamGenerateResponse(json: innerJSON) {
                outputs.append(.frame(parsed))
            } else {
                logParseError("Legacy Boq StreamGenerate inner payload shape unrecognized")
            }
        }
        return outputs
    }

    fileprivate static func extractInlineJSONError(from json: JSONValue) -> BatchExecuteErrorKind? {
        guard let errorObj = json["error"]?.objectValue else {
            return nil
        }
        if let status = errorObj["status"]?.stringValue?.uppercased() {
            switch status {
            case "UNAUTHENTICATED":
                return .unauthenticated
            case "PERMISSION_DENIED":
                return .permissionDenied
            case "NOT_FOUND":
                return .conversationNotFound
            default:
                break
            }
        }
        if let code = errorObj["code"]?.intValue {
            switch code {
            case 401:
                return .unauthenticated
            case 403:
                return .permissionDenied
            case 404:
                return .conversationNotFound
            default:
                return BatchExecuteErrorKind(code: code)
            }
        }
        return nil
    }

    // MARK: - Private Candidate, Thinking, Citations, Images & Artifacts Decoding

    private struct ParsedCandidate {
        let choiceId: String?
        let markdown: String
        let thinkingText: String?
        let isComplete: Bool?
        let citations: [CitationLink]
        let images: [ImageAttachment]
        let artifacts: [ArtifactCardInfo]
    }

    private struct StructuredContentResult {
        let fallbackMarkdown: String?
        let images: [ImageAttachment]
    }

    private static func parseCandidate(proto candidate: ProtoWireMessage) -> ParsedCandidate {
        typealias Field = GeminiBridgeSelectors.WireFormat.CandidateField

        let choiceId = nonEmptyTrimmed(candidate.firstString(Field.choiceId.rawValue))

        let contentMessage = candidate.firstSubmessage(Field.content.rawValue)
        let primaryParts = contentMessage?.allStrings(1) ?? []
        let primaryMarkdown = primaryParts.isEmpty
            ? (candidate.firstString(Field.content.rawValue) ?? "")
            : primaryParts.joined()

        let alternateMarkdown = candidate.firstSubmessage(Field.alternateText.rawValue)?.firstString(1) ?? ""
        let markdown = primaryMarkdown.isEmpty ? alternateMarkdown : primaryMarkdown

        var isComplete: Bool?
        if let completionMsg = candidate.firstSubmessage(Field.completionState.rawValue),
           let stateCode = completionMsg.firstInt(1) {
            isComplete = (stateCode == 0 || stateCode == 2)
        }

        let thinkingText = extractThoughts(proto: candidate.firstSubmessage(Field.thoughts.rawValue))

        var citations: [CitationLink] = []
        if let inlineCitationsMsg = candidate.firstSubmessage(Field.inlineCitations.rawValue) {
            citations.append(contentsOf: extractCitations(protoContainer: inlineCitationsMsg, repeatedField: 1))
        }
        var artifacts: [ArtifactCardInfo] = []
        if let attachmentsMsg = candidate.firstSubmessage(Field.attachments.rawValue) {
            citations.append(contentsOf: extractCitations(protoContainer: attachmentsMsg, repeatedField: 13))
            citations.append(contentsOf: extractCitations(protoContainer: attachmentsMsg, repeatedField: 41))
            citations.append(contentsOf: extractCitations(protoContainer: attachmentsMsg, repeatedField: 45))

            if let dynamicView = attachmentsMsg.firstSubmessage(77) ?? attachmentsMsg.firstString(77).map({ _ in ProtoWireMessage(fields: []) }) {
                let dynamicTitle = nonEmptyTrimmed(dynamicView.firstString(1)) ?? "Interactive View"
                artifacts.append(ArtifactCardInfo(
                    id: "dynamic-view-\(choiceId ?? "0")",
                    kind: .extensionWidget,
                    title: dynamicTitle,
                    subtitle: "Interactive Gemini content"
                ))
            }
        }
        if let globalSourcesMsg = candidate.firstSubmessage(Field.globalSources.rawValue) {
            citations.append(contentsOf: extractCitations(protoContainer: globalSourcesMsg, repeatedField: 1))
        }

        let primaryArtifacts = candidate.allSubmessages(Field.artifacts.rawValue)
        let secondaryArtifacts = candidate.allSubmessages(Field.secondaryArtifacts.rawValue)
        for (idx, artifactMsg) in (primaryArtifacts + secondaryArtifacts).enumerated() {
            if let artifact = extractArtifact(proto: artifactMsg, index: idx) {
                artifacts.append(artifact)
            }
        }

        return ParsedCandidate(
            choiceId: choiceId,
            markdown: markdown,
            thinkingText: thinkingText,
            isComplete: isComplete,
            citations: deduplicateCitations(citations),
            images: [],
            artifacts: deduplicateArtifacts(artifacts)
        )
    }

    private static func parseCandidate(json candidate: JSONValue) -> ParsedCandidate? {
        guard candidate.arrayValue != nil else {
            return nil
        }
        typealias Field = GeminiBridgeSelectors.WireFormat.CandidateField

        let choiceId = candidate[jspbIndex(Field.choiceId)]?.nonEmptyStringValue

        let contentNode = candidate[jspbIndex(Field.content)]
        let primaryMarkdown: String
        if let parts = contentNode?.arrayValue {
            primaryMarkdown = parts.compactMap(\.stringValue).joined()
        } else if let direct = contentNode?.stringValue {
            primaryMarkdown = direct
        } else {
            primaryMarkdown = ""
        }
        let alternateMarkdown = candidate[jspbIndex(Field.alternateText)]?[0]?.stringValue ?? ""
        let markdown = primaryMarkdown.isEmpty ? alternateMarkdown : primaryMarkdown

        var isComplete: Bool?
        if let stateCode = candidate[jspbIndex(Field.completionState)]?[0]?.intValue {
            isComplete = (stateCode == 0 || stateCode == 2)
        }

        let thinkingText = extractThoughts(json: candidate[jspbIndex(Field.thoughts)])

        var citations: [CitationLink] = []
        if let inlineCitations = candidate[jspbIndex(Field.inlineCitations)]?[0] {
            citations.append(contentsOf: extractCitations(json: inlineCitations))
        }

        var artifacts: [ArtifactCardInfo] = []
        if let attachmentsNode = candidate[jspbIndex(Field.attachments)] {
            if let sources13 = attachmentsNode[12] {
                citations.append(contentsOf: extractCitations(json: sources13))
            }
            if let sources41 = attachmentsNode[40] {
                citations.append(contentsOf: extractCitations(json: sources41))
            }
            if let sources45 = attachmentsNode[44] {
                citations.append(contentsOf: extractCitations(json: sources45))
            }
            if let dynamicView = attachmentsNode[76], !dynamicView.isNull {
                let hasContent: Bool = switch dynamicView {
                case .string(let value): !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .array(let items): !items.isEmpty
                case .object(let dict): !dict.isEmpty
                default: false
                }
                if hasContent {
                    let title = firstReadableTitle(in: dynamicView) ?? "Interactive View"
                    artifacts.append(ArtifactCardInfo(
                        id: "dynamic-view-\(choiceId ?? "0")",
                        kind: .extensionWidget,
                        title: title,
                        subtitle: "Interactive Gemini content"
                    ))
                }
            }
        }

        if let globalSources = candidate[jspbIndex(Field.globalSources)] {
            citations.append(contentsOf: extractCitations(json: globalSources))
        }

        let rawPrimaryArtifacts = candidate[jspbIndex(Field.artifacts)]?.arrayValue ?? []
        let rawSecondaryArtifacts = candidate[jspbIndex(Field.secondaryArtifacts)]?.arrayValue ?? []
        for (idx, rawArtifact) in (rawPrimaryArtifacts + rawSecondaryArtifacts).enumerated() {
            if let artifact = extractArtifact(json: rawArtifact, index: idx) {
                artifacts.append(artifact)
            }
        }

        return ParsedCandidate(
            choiceId: choiceId,
            markdown: markdown,
            thinkingText: thinkingText,
            isComplete: isComplete,
            citations: deduplicateCitations(citations),
            images: [],
            artifacts: deduplicateArtifacts(artifacts)
        )
    }

    private static func extractThoughts(proto thoughtsMsg: ProtoWireMessage?) -> String? {
        guard let thoughtsMsg else {
            return nil
        }
        let summary = nonEmptyTrimmed(thoughtsMsg.firstString(1))
        let stepMessages = thoughtsMsg.allSubmessages(2)

        var stepBlocks: [String] = []
        for step in stepMessages {
            let body = firstNonEmpty(
                step.firstSubmessage(1)?.allStrings(1).joined(),
                step.firstString(1)
            )
            let header = nonEmptyTrimmed(step.firstString(6))
            if let header, let body {
                stepBlocks.append("**\(header)**\n\(body)")
            } else if let body {
                stepBlocks.append(body)
            } else if let header {
                stepBlocks.append(header)
            }
        }

        if !stepBlocks.isEmpty {
            return stepBlocks.joined(separator: "\n\n")
        }
        return summary
    }

    private static func extractThoughts(json thoughtsNode: JSONValue?) -> String? {
        guard let thoughtsNode, !thoughtsNode.isNull else {
            return nil
        }
        if let direct = thoughtsNode.nonEmptyStringValue {
            return direct
        }
        let summary = thoughtsNode[0]?.nonEmptyStringValue
        let rawSteps = thoughtsNode[1]?.arrayValue ?? []

        var stepBlocks: [String] = []
        for step in rawSteps {
            let body: String?
            if let nested = step[0]?[0]?.nonEmptyStringValue {
                body = nested
            } else if let arrayParts = step[0]?.arrayValue {
                let joined = arrayParts.compactMap(\.stringValue).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                body = joined.isEmpty ? nil : joined
            } else {
                body = step[0]?.nonEmptyStringValue
            }
            let header = step[5]?.nonEmptyStringValue

            if let header, let body {
                stepBlocks.append("**\(header)**\n\(body)")
            } else if let body {
                stepBlocks.append(body)
            } else if let header {
                stepBlocks.append(header)
            }
        }

        if !stepBlocks.isEmpty {
            return stepBlocks.joined(separator: "\n\n")
        }
        return summary
    }

    private static func extractStructuredContent(proto messages: [ProtoWireMessage]) -> StructuredContentResult {
        typealias NodeField = GeminiBridgeSelectors.WireFormat.StructuredNodeField

        var markdownSegments: [String] = []
        var images: [ImageAttachment] = []

        func inspectNode(_ node: ProtoWireMessage) {
            if let md = nonEmptyTrimmed(node.firstString(NodeField.markdownText.rawValue)) {
                markdownSegments.append(md)
            }
            for generatedContainer in node.allSubmessages(NodeField.generatedImages.rawValue) {
                for imageMsg in generatedContainer.allSubmessages(1) {
                    if let attachment = extractImage(proto: imageMsg, index: images.count, prefix: "gemini-generated") {
                        images.append(attachment)
                    }
                }
            }
            for webContainer in node.allSubmessages(NodeField.webImages.rawValue) {
                for imageMsg in webContainer.allSubmessages(1) {
                    if let attachment = extractImage(proto: imageMsg, index: images.count, prefix: "gemini-image") {
                        images.append(attachment)
                    }
                }
            }
        }

        for content in messages {
            inspectNode(content)
            for child in content.allSubmessages(1) {
                inspectNode(child)
            }
        }

        let fallback = markdownSegments.isEmpty ? nil : markdownSegments.joined(separator: "\n\n")
        return StructuredContentResult(fallbackMarkdown: fallback, images: deduplicateImages(images))
    }

    private static func extractStructuredContent(json structuredNode: JSONValue?) -> StructuredContentResult {
        guard let structuredNode, !structuredNode.isNull else {
            return StructuredContentResult(fallbackMarkdown: nil, images: [])
        }
        typealias NodeField = GeminiBridgeSelectors.WireFormat.StructuredNodeField

        var markdownSegments: [String] = []
        var images: [ImageAttachment] = []

        func inspectNode(_ node: JSONValue) {
            guard node.arrayValue != nil else {
                return
            }
            if let md = node[jspbIndex(NodeField.markdownText)]?.nonEmptyStringValue {
                markdownSegments.append(md)
            }
            if let generatedContainer = node[jspbIndex(NodeField.generatedImages)] {
                let items = generatedContainer[0]?.arrayValue ?? generatedContainer.arrayValue ?? []
                for item in items {
                    if let attachment = extractImage(json: item, index: images.count, prefix: "gemini-generated") {
                        images.append(attachment)
                    }
                }
            }
            if let webContainer = node[jspbIndex(NodeField.webImages)] {
                let items = webContainer[0]?.arrayValue ?? webContainer.arrayValue ?? []
                for item in items {
                    if let attachment = extractImage(json: item, index: images.count, prefix: "gemini-image") {
                        images.append(attachment)
                    }
                }
            }
        }

        if let outerEntries = structuredNode.arrayValue {
            for entry in outerEntries {
                inspectNode(entry)
                if let nestedNodes = entry[0]?.arrayValue {
                    for child in nestedNodes {
                        inspectNode(child)
                    }
                }
            }
        }

        let fallback = markdownSegments.isEmpty ? nil : markdownSegments.joined(separator: "\n\n")
        return StructuredContentResult(fallbackMarkdown: fallback, images: deduplicateImages(images))
    }

    private static func extractImage(
        proto imageMsg: ProtoWireMessage,
        index: Int,
        prefix: String
    ) -> ImageAttachment? {
        let innerMedia = imageMsg.firstSubmessage(1)
        let urlString = firstHTTPURLString([
            innerMedia?.firstString(1),
            imageMsg.firstString(1),
            innerMedia?.firstString(2),
            imageMsg.firstString(2)
        ])
        guard let urlString, let url = URL(string: urlString) else {
            return nil
        }

        let altText = firstNonURLString([
            imageMsg.firstString(2),
            imageMsg.firstString(4),
            innerMedia?.firstString(4),
            imageMsg.firstString(3)
        ])
        let width = positiveImageDimension(innerMedia?.firstInt(2) ?? imageMsg.firstInt(5))
        let height = positiveImageDimension(innerMedia?.firstInt(3) ?? imageMsg.firstInt(6))
        let filename = suggestedImageFilename(for: url, fallbackPrefix: prefix, index: index)

        return ImageAttachment(
            id: "\(prefix)-\(index)-\(url.absoluteString)",
            url: url,
            altText: altText,
            width: width,
            height: height,
            suggestedFilename: filename
        )
    }

    private static func extractImage(
        json imageNode: JSONValue,
        index: Int,
        prefix: String
    ) -> ImageAttachment? {
        let urlString = firstHTTPURLString([
            imageNode[0]?[0]?.stringValue,
            imageNode[0]?.stringValue,
            imageNode[0]?[1]?.stringValue,
            imageNode[1]?.stringValue,
            findFirstHTTPURL(in: imageNode, depth: 0)
        ])
        guard let urlString, let url = URL(string: urlString) else {
            return nil
        }

        let altText = firstNonURLString([
            imageNode[1]?.stringValue,
            imageNode[3]?.stringValue,
            imageNode[0]?[3]?.stringValue,
            imageNode[2]?.stringValue
        ])
        let width = positiveImageDimension(imageNode[0]?[1]?.intValue ?? imageNode[4]?.intValue)
        let height = positiveImageDimension(imageNode[0]?[2]?.intValue ?? imageNode[5]?.intValue)
        let filename = suggestedImageFilename(for: url, fallbackPrefix: prefix, index: index)

        return ImageAttachment(
            id: "\(prefix)-\(index)-\(url.absoluteString)",
            url: url,
            altText: altText,
            width: width,
            height: height,
            suggestedFilename: filename
        )
    }

    private static func extractCitations(protoContainer: ProtoWireMessage, repeatedField: Int) -> [CitationLink] {
        var links: [CitationLink] = []
        let submessages = protoContainer.allSubmessages(repeatedField)
        for (idx, item) in submessages.enumerated() {
            if let link = citationFromProto(item, index: idx) {
                links.append(link)
            } else {
                // Handle one extra wrapper layer (e.g. repeated list inside a single field message).
                for nested in item.allSubmessages(1) {
                    if let nestedLink = citationFromProto(nested, index: links.count) {
                        links.append(nestedLink)
                    }
                }
            }
        }
        return links
    }

    private static func citationFromProto(_ item: ProtoWireMessage, index: Int) -> CitationLink? {
        var allStrings: [String] = []
        for field in item.fields {
            if case .lengthDelimited(let data) = field.value {
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    allStrings.append(str)
                } else if let nested = ProtoWireMessage.decode(data) {
                    for subField in nested.fields {
                        if case .lengthDelimited(let subData) = subField.value,
                           let subStr = String(data: subData, encoding: .utf8),
                           !subStr.isEmpty {
                            allStrings.append(subStr)
                        }
                    }
                }
            }
        }
        guard let urlStr = firstHTTPURLString(allStrings.map(Optional.some)),
              let url = URL(string: urlStr) else {
            return nil
        }
        let title = firstNonURLString(allStrings.map(Optional.some)) ?? url.host ?? urlStr
        return CitationLink(
            id: "citation-\(index)-\(url.absoluteString)",
            title: title,
            url: url,
            domain: url.host
        )
    }

    private static func extractCitations(json node: JSONValue) -> [CitationLink] {
        guard let items = node.arrayValue else {
            return []
        }
        var links: [CitationLink] = []
        for (idx, item) in items.enumerated() {
            if let link = citationFromJSON(item, index: idx) {
                links.append(link)
            } else if let nestedItems = item.arrayValue {
                for nested in nestedItems {
                    if let nestedLink = citationFromJSON(nested, index: links.count) {
                        links.append(nestedLink)
                    }
                }
            }
        }
        return links
    }

    private static func citationFromJSON(_ item: JSONValue, index: Int) -> CitationLink? {
        guard item.arrayValue != nil || item.objectValue != nil else {
            return nil
        }
        let strings = collectLeafStrings(in: item, depth: 0, limit: 12)
        guard let urlStr = firstHTTPURLString(strings.map(Optional.some)),
              let url = URL(string: urlStr) else {
            return nil
        }
        let nonURLs = strings.filter { !isHTTPURL($0) && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let title = nonURLs.first ?? url.host ?? urlStr
        let explicitDomain = nonURLs.dropFirst().first(where: { $0.contains(".") && !$0.contains(" ") })
        return CitationLink(
            id: "citation-\(index)-\(url.absoluteString)",
            title: title,
            url: url,
            domain: explicitDomain ?? url.host
        )
    }

    private static func extractArtifact(proto artifactMsg: ProtoWireMessage, index: Int) -> ArtifactCardInfo? {
        guard !artifactMsg.fields.isEmpty else {
            return nil
        }
        var strings: [String] = []
        for field in artifactMsg.fields {
            if case .lengthDelimited(let data) = field.value {
                if let str = nonEmptyTrimmed(String(data: data, encoding: .utf8)) {
                    strings.append(str)
                } else if let nested = ProtoWireMessage.decode(data) {
                    for nestedField in nested.fields {
                        if case .lengthDelimited(let nestedData) = nestedField.value,
                           let nestedStr = nonEmptyTrimmed(String(data: nestedData, encoding: .utf8)) {
                            strings.append(nestedStr)
                        }
                    }
                }
            }
        }
        let id = firstNonEmpty(artifactMsg.firstString(1), "artifact-\(index)") ?? "artifact-\(index)"
        let kind = inferArtifactKind(from: strings, defaultKind: .canvas)
        let title = firstNonEmpty(
            artifactMsg.firstString(2),
            artifactMsg.firstString(3),
            strings.first(where: { $0 != id && !isHTTPURL($0) && !isLikelyOpaqueToken($0) }),
            defaultArtifactTitle(for: kind)
        ) ?? defaultArtifactTitle(for: kind)
        let subtitle = firstNonEmpty(
            artifactMsg.firstString(4),
            strings.first(where: { $0 != id && $0 != title && !isHTTPURL($0) && $0.count <= 80 })
        )

        return ArtifactCardInfo(id: id, kind: kind, title: title, subtitle: subtitle)
    }

    private static func extractArtifact(json artifactNode: JSONValue, index: Int) -> ArtifactCardInfo? {
        guard !artifactNode.isNull else {
            return nil
        }
        let strings = collectLeafStrings(in: artifactNode, depth: 0, limit: 16)
        guard !strings.isEmpty || (artifactNode.arrayValue?.isEmpty == false) else {
            return nil
        }

        let id = firstNonEmpty(artifactNode[0]?.nonEmptyStringValue, "artifact-\(index)") ?? "artifact-\(index)"
        let kind = inferArtifactKind(from: strings, defaultKind: .canvas)
        let title = firstNonEmpty(
            artifactNode[1]?.nonEmptyStringValue,
            artifactNode[2]?.nonEmptyStringValue,
            strings.first(where: { $0 != id && !isHTTPURL($0) && !isLikelyOpaqueToken($0) }),
            defaultArtifactTitle(for: kind)
        ) ?? defaultArtifactTitle(for: kind)
        let subtitle = firstNonEmpty(
            artifactNode[3]?.nonEmptyStringValue,
            strings.first(where: { $0 != id && $0 != title && !isHTTPURL($0) && $0.count <= 80 })
        )

        return ArtifactCardInfo(id: id, kind: kind, title: title, subtitle: subtitle)
    }

    private static func inferArtifactKind(from strings: [String], defaultKind: ArtifactKind) -> ArtifactKind {
        let joined = strings.joined(separator: " ").lowercased()
        if joined.contains("deep_research") || joined.contains("deep research") || joined.contains("research_plan") {
            return .deepResearch
        }
        if joined.contains("gem_editor") || joined.contains("custom_gem") || joined.contains("/gem/") {
            return .gem
        }
        if joined.contains("extension") || joined.contains("widget") || joined.contains("dynamic_view") {
            return .extensionWidget
        }
        if joined.contains("canvas") || joined.contains("immersive") || joined.contains("code") || joined.contains("document") {
            return .canvas
        }
        return defaultKind
    }

    private static func defaultArtifactTitle(for kind: ArtifactKind) -> String {
        switch kind {
        case .canvas: return "Canvas"
        case .deepResearch: return "Deep Research"
        case .gem: return "Gem"
        case .extensionWidget: return "Interactive Widget"
        case .unknown: return "Rich Content"
        }
    }

    private static func inferThinkingCapable(name: String, subtitle: String?) -> Bool {
        let combined = "\(name) \(subtitle ?? "")".lowercased()
        let markers = ["thinking", "pro", "reason", "deep", "ultra", "hydrogen", "neon"]
        return markers.contains { combined.contains($0) }
    }

    private static func resolveThinkingComplete(
        thinkingText: String?,
        markdown: String,
        liveThinkingActive: Bool?,
        isFinal: Bool
    ) -> Bool {
        if isFinal {
            return true
        }
        if liveThinkingActive == true {
            return false
        }
        if !markdown.isEmpty {
            return true
        }
        if let thinkingText, !thinkingText.isEmpty {
            return false
        }
        return false
    }

    private static func extractUserPromptText(from userRequestNode: JSONValue?) -> String {
        guard let userRequestNode else {
            return ""
        }
        if let lines = userRequestNode[0]?.arrayValue {
            let texts = lines.compactMap(\.stringValue)
            if !texts.isEmpty {
                return texts.joined(separator: "\n")
            }
        }
        if let direct = userRequestNode[0]?.stringValue {
            return direct
        }
        return ""
    }

    private static func extractUserAttachments(from userRequestNode: JSONValue?) -> [StagedAttachmentSummary] {
        guard let rawFiles = userRequestNode?[0]?[4]?.arrayValue else {
            return []
        }
        var attachments: [StagedAttachmentSummary] = []
        for fileNode in rawFiles {
            let strings = collectLeafStrings(in: fileNode, depth: 0, limit: 8)
            guard let filename = strings.first(where: { !isHTTPURL($0) && !$0.isEmpty }) else {
                continue
            }
            let mimeType = strings.first(where: { $0.contains("/") && !isHTTPURL($0) }) ?? "application/octet-stream"
            let isImage = mimeType.lowercased().hasPrefix("image/")
                || filename.lowercased().hasSuffix(".png")
                || filename.lowercased().hasSuffix(".jpg")
                || filename.lowercased().hasSuffix(".jpeg")
                || filename.lowercased().hasSuffix(".webp")
            attachments.append(StagedAttachmentSummary(
                filename: filename,
                mimeType: mimeType,
                byteCount: 0,
                isImage: isImage
            ))
        }
        return attachments
    }

    private static func decodeWrbFrames(from chunk: String) -> [BatchExecuteEnvelopeFrame] {
        guard let parsed = JSONValue.parse(chunk) else {
            logParseError("batchexecute envelope chunk failed JSON parse (len=\(chunk.count))")
            return []
        }
        guard let outerArray = parsed.arrayValue else {
            return []
        }

        let wrbMarker = GeminiBridgeSelectors.WireFormat.wrbFrameMarker
        var results: [BatchExecuteEnvelopeFrame] = []

        for element in outerArray {
            guard element[0]?.stringValue == wrbMarker else {
                continue
            }
            let rpcId = element[1]?.nonEmptyStringValue
            let innerJSON: JSONValue?
            if let innerString = element[2]?.stringValue, !innerString.isEmpty {
                if let decoded = JSONValue.parse(innerString) {
                    innerJSON = decoded
                } else {
                    logParseError("wrb.fr inner JSON failed decode for rpcId=\(rpcId ?? "nil") (len=\(innerString.count))")
                    innerJSON = nil
                }
            } else {
                innerJSON = nil
            }

            let errorCode = element[5]?[0]?.intValue ?? element[5]?.intValue
            let errorKind = errorCode.map { BatchExecuteErrorKind(code: $0) }
            let requestIndex = element[6]?.nonEmptyStringValue

            results.append(BatchExecuteEnvelopeFrame(
                rpcId: rpcId,
                innerJSON: innerJSON,
                errorCode: errorCode,
                errorKind: errorKind,
                requestIndex: requestIndex
            ))
        }
        return results
    }

    private static func stripXSSIPrefix(_ raw: String) -> String {
        let prefix = GeminiBridgeSelectors.WireFormat.xssiPrefix
        if raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count))
        }
        if raw.hasPrefix(")]}'\r\n") {
            return String(raw.dropFirst(6))
        }
        if raw.hasPrefix(")]}'") {
            if let nl = raw.firstIndex(of: "\n") {
                return String(raw[raw.index(after: nl)...])
            }
        }
        return raw
    }

    private static func parseTimestamp(_ node: JSONValue?) -> Date? {
        guard let node else {
            return nil
        }
        if let seconds = node[0]?.doubleValue {
            let nanos = node[1]?.doubleValue ?? 0
            return Date(timeIntervalSince1970: seconds + nanos / 1_000_000_000.0)
        }
        if let directSeconds = node.doubleValue, directSeconds > 0 {
            return Date(timeIntervalSince1970: directSeconds)
        }
        return nil
    }

    private static func extractAuthUserIndex(from url: URL) -> Int? {
        if let route = GeminiURLRoute.parse(url), let authUser = route.authUser {
            return authUser
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let queryKey = GeminiBridgeSelectors.Endpoints.authUserQueryParam.lowercased()
        if let queryVal = components.queryItems?.first(where: { $0.name.lowercased() == queryKey })?.value,
           let parsed = Int(queryVal),
           parsed >= 0 {
            return parsed
        }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true)
        if segments.count >= 2,
           segments[0].lowercased() == "u",
           let parsed = Int(segments[1]),
           parsed >= 0 {
            return parsed
        }
        return nil
    }

    private static func parseAccountFromDOMLabel(_ label: String?) -> (displayName: String?, email: String?) {
        guard let label = nonEmptyTrimmed(label) else {
            return (nil, nil)
        }
        // Typical format: "Google Account: Jane Doe (jane@example.com)" or "Jane Doe\njane@example.com"
        let cleaned = label
            .replacingOccurrences(of: "Google Account:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let openParen = cleaned.lastIndex(of: "("),
           let closeParen = cleaned.lastIndex(of: ")"),
           openParen < closeParen {
            let candidateEmail = String(cleaned[cleaned.index(after: openParen)..<closeParen])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if candidateEmail.contains("@") && candidateEmail.contains(".") {
                let name = String(cleaned[..<openParen]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (name.isEmpty ? nil : name, candidateEmail)
            }
        }

        let tokens = cleaned.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        if let foundEmail = tokens.first(where: { $0.contains("@") && $0.contains(".") }) {
            let trimmedEmail = foundEmail.trimmingCharacters(in: CharacterSet(charactersIn: "()<>.,;"))
            return (nil, trimmedEmail)
        }

        return (nil, nil)
    }

    private static func decodeBase64Flexible(_ raw: String) -> Data? {
        var sanitized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = sanitized.count % 4
        if remainder != 0 {
            sanitized.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: sanitized, options: [.ignoreUnknownCharacters])
    }

    private static func trimLeadingNewlinesAndSpaces(_ text: inout String) {
        while let first = text.first, first == "\n" || first == "\r" || first == " " || first == "\t" {
            text.removeFirst()
        }
    }

    private static func isCompleteJSONFragment(_ text: String) -> Bool {
        guard let first = text.first, first == "[" || first == "{" else {
            return false
        }
        return JSONValue.parse(text) != nil
    }

    private static func jspbIndex(_ field: GeminiBridgeSelectors.WireFormat.StreamResponseField) -> Int {
        field.rawValue - 1
    }

    private static func jspbIndex(_ field: GeminiBridgeSelectors.WireFormat.CandidateField) -> Int {
        field.rawValue - 1
    }

    private static func jspbIndex(_ field: GeminiBridgeSelectors.WireFormat.StructuredNodeField) -> Int {
        field.rawValue - 1
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value = nonEmptyTrimmed(value) {
                return value
            }
        }
        return nil
    }

    private static func isHTTPURL(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

    private static func firstHTTPURLString(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            if let value = nonEmptyTrimmed(candidate), isHTTPURL(value) {
                return value
            }
        }
        return nil
    }

    private static func firstNonURLString(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            if let value = nonEmptyTrimmed(candidate), !isHTTPURL(value) {
                return value
            }
        }
        return nil
    }

    private static func findFirstHTTPURL(in node: JSONValue, depth: Int) -> String? {
        guard depth < 6 else {
            return nil
        }
        switch node {
        case .string(let value):
            return isHTTPURL(value) ? value : nil
        case .array(let items):
            for item in items {
                if let found = findFirstHTTPURL(in: item, depth: depth + 1) {
                    return found
                }
            }
        case .object(let dict):
            for value in dict.values {
                if let found = findFirstHTTPURL(in: value, depth: depth + 1) {
                    return found
                }
            }
        default:
            break
        }
        return nil
    }

    private static func collectLeafStrings(in node: JSONValue, depth: Int, limit: Int) -> [String] {
        guard depth < 6, limit > 0 else {
            return []
        }
        var results: [String] = []
        func walk(_ current: JSONValue, currentDepth: Int) {
            guard currentDepth < 6, results.count < limit else {
                return
            }
            switch current {
            case .string(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    results.append(trimmed)
                }
            case .array(let items):
                for item in items where results.count < limit {
                    walk(item, currentDepth: currentDepth + 1)
                }
            case .object(let dict):
                for key in dict.keys.sorted() where results.count < limit {
                    if let val = dict[key] {
                        walk(val, currentDepth: currentDepth + 1)
                    }
                }
            default:
                break
            }
        }
        walk(node, currentDepth: depth)
        return results
    }

    private static func firstReadableTitle(in node: JSONValue) -> String? {
        let strings = collectLeafStrings(in: node, depth: 0, limit: 8)
        return strings.first(where: { !isHTTPURL($0) && !isLikelyOpaqueToken($0) && $0.count <= 120 })
    }

    private static func isLikelyOpaqueToken(_ value: String) -> Bool {
        guard value.count >= 24, !value.contains(" ") else {
            return false
        }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static func positiveImageDimension(_ value: Int?) -> Int? {
        guard let value, value > 0, value <= 32_768 else {
            return nil
        }
        return value
    }

    private static func suggestedImageFilename(for url: URL, fallbackPrefix: String, index: Int) -> String {
        let candidate = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty, candidate != "/", candidate.contains("."), candidate.count <= 80 {
            return candidate
        }
        return "\(fallbackPrefix)-\(index + 1).png"
    }

    private static func deduplicateImages(_ images: [ImageAttachment]) -> [ImageAttachment] {
        var seen: Set<String> = []
        return images.filter { seen.insert($0.url.absoluteString).inserted }
    }

    private static func deduplicateCitations(_ citations: [CitationLink]) -> [CitationLink] {
        var seen: Set<String> = []
        return citations.filter { seen.insert($0.url.absoluteString).inserted }
    }

    private static func deduplicateArtifacts(_ artifacts: [ArtifactCardInfo]) -> [ArtifactCardInfo] {
        var seen: Set<String> = []
        return artifacts.filter { seen.insert("\($0.kind.rawValue):\($0.id)").inserted }
    }
}
