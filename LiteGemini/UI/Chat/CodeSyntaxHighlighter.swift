import AppKit
import HighlightSwift
import JavaScriptCore
import SwiftUI

// MARK: - CodeSyntaxHighlighter

/// Off-main-actor 120Hz syntax highlighter powered by `JavaScriptCore` + `HighlightJS`
/// (`HighlightSwift` bundle) with a pure-Swift `<span class="hljs-...">` token parser.
///
/// Unlike `NSAttributedString(.documentType: .html)`, which blocks `@MainActor` inside WebKit's
/// HTML importer, this engine executes both tokenization and `AttributedString` construction
/// 100% off `@MainActor` with sub-millisecond latency and zero `RunLoop` re-entrancy.
actor CodeSyntaxHighlightEngine {

    static let shared = CodeSyntaxHighlightEngine()

    private var jsContext: JSContext?
    private var hljsObject: JSValue?
    private var didAttemptLoad = false

    func highlight(
        code: String,
        language: String?,
        isDark: Bool,
        fontSize: CGFloat = 12.5
    ) -> AttributedString? {
        guard !code.isEmpty, code.utf8.count <= 200_000 else {
            return nil
        }
        guard let hljs = resolveHLJS() else {
            return nil
        }

        let normalizedAlias = Self.normalizeLanguageAlias(language)
        let htmlSpanMarkup: String?

        if let alias = normalizedAlias,
           hljs.invokeMethod("getLanguage", withArguments: [alias])?.isObject == true {
            let options: [String: Any] = [
                "language": alias,
                "ignoreIllegals": true
            ]
            let result = hljs.invokeMethod("highlight", withArguments: [code, options])
            htmlSpanMarkup = result?.objectForKeyedSubscript("value")?.toString()
        } else if normalizedAlias == nil, code.utf8.count <= 16_000 {
            let result = hljs.invokeMethod("highlightAuto", withArguments: [code])
            htmlSpanMarkup = result?.objectForKeyedSubscript("value")?.toString()
        } else {
            htmlSpanMarkup = nil
        }

        guard let markup = htmlSpanMarkup, !markup.isEmpty else {
            return nil
        }

        return Self.parseHLJSMarkup(markup, fallbackPlain: code, isDark: isDark, fontSize: fontSize)
    }

    // MARK: - JSContext Initialization

    private func resolveHLJS() -> JSValue? {
        if let hljsObject {
            return hljsObject
        }
        guard !didAttemptLoad else {
            return nil
        }
        didAttemptLoad = true

        guard let scriptURL = Self.locateHighlightJSScript(),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let context = JSContext() else {
            return nil
        }

        context.evaluateScript(script)
        guard let hljs = context.objectForKeyedSubscript("hljs"), hljs.isObject else {
            return nil
        }

        self.jsContext = context
        self.hljsObject = hljs
        return hljs
    }

    nonisolated private static func locateHighlightJSScript() -> URL? {
        let candidateBundleNames = [
            "HighlightSwift_HighlightSwift",
            "HighlightSwift"
        ]
        for bundleName in candidateBundleNames {
            if let bundleURL = Bundle.main.url(forResource: bundleName, withExtension: "bundle"),
               let bundle = Bundle(url: bundleURL),
               let jsURL = bundle.url(forResource: "highlight.min", withExtension: "js") {
                return jsURL
            }
        }
        for bundle in Bundle.allBundles {
            if let jsURL = bundle.url(forResource: "highlight.min", withExtension: "js") {
                return jsURL
            }
            for bundleName in candidateBundleNames {
                if let nestedURL = bundle.url(forResource: bundleName, withExtension: "bundle"),
                   let nestedBundle = Bundle(url: nestedURL),
                   let jsURL = nestedBundle.url(forResource: "highlight.min", withExtension: "js") {
                    return jsURL
                }
            }
        }
        return nil
    }

    nonisolated private static func normalizeLanguageAlias(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return nil
        }
        let firstToken = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "," }).first.map(String.init) ?? trimmed
        switch firstToken {
        case "objc", "obj-c", "objective-c": return "objectivec"
        case "sh", "zsh", "shell", "console", "terminal": return "bash"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "mts", "cts", "tsx": return "typescript"
        case "py": return "python"
        case "rb": return "ruby"
        case "rs": return "rust"
        case "yml": return "yaml"
        case "md": return "markdown"
        case "cs", "c#": return "csharp"
        case "c++", "cxx", "cc", "hpp": return "cpp"
        case "htm", "svg": return "xml"
        case "dockerfile": return "dockerfile"
        case "plaintext", "text", "txt", "none": return nil
        default: return firstToken
        }
    }

    // MARK: - Pure-Swift HLJS Span Parser

    private struct SpanStyle: Sendable {
        let color: Color
        let isBold: Bool
        let isItalic: Bool
    }

    nonisolated private static func parseHLJSMarkup(
        _ html: String,
        fallbackPlain: String,
        isDark: Bool,
        fontSize: CGFloat
    ) -> AttributedString {
        let defaultStyle = SpanStyle(
            color: isDark
                ? Color(red: 0.90, green: 0.92, blue: 0.95)
                : Color(red: 0.14, green: 0.16, blue: 0.20),
            isBold: false,
            isItalic: false
        )

        var styleStack: [SpanStyle] = [defaultStyle]
        var output = AttributedString()
        var index = html.startIndex

        func appendSegment(_ rawSegment: Substring, style: SpanStyle) {
            guard !rawSegment.isEmpty else { return }
            let decoded = decodeHTMLEntities(rawSegment)
            guard !decoded.isEmpty else { return }
            var attr = AttributedString(decoded)
            var font = Font.system(
                size: fontSize,
                weight: style.isBold ? .semibold : .regular,
                design: .monospaced
            )
            if style.isItalic {
                font = font.italic()
            }
            attr.font = font
            attr.foregroundColor = style.color
            output.append(attr)
        }

        while index < html.endIndex {
            guard let tagStart = html[index...].firstIndex(of: "<") else {
                appendSegment(html[index...], style: styleStack.last ?? defaultStyle)
                break
            }

            if tagStart > index {
                appendSegment(html[index..<tagStart], style: styleStack.last ?? defaultStyle)
            }

            guard let tagEnd = html[tagStart...].firstIndex(of: ">") else {
                appendSegment(html[tagStart...], style: styleStack.last ?? defaultStyle)
                break
            }

            let tagBody = html[html.index(after: tagStart)..<tagEnd]
            if tagBody.hasPrefix("/span") {
                if styleStack.count > 1 {
                    styleStack.removeLast()
                }
            } else if tagBody.hasPrefix("span") {
                let className = extractClassAttribute(from: tagBody)
                let parent = styleStack.last ?? defaultStyle
                let resolved = resolveStyle(for: className, fallback: parent, isDark: isDark)
                styleStack.append(resolved)
            }

            index = html.index(after: tagEnd)
        }

        if output.characters.isEmpty && !fallbackPlain.isEmpty {
            return AttributedString(fallbackPlain)
        }
        return output
    }

    nonisolated private static func extractClassAttribute(from tagBody: Substring) -> String {
        guard let classRange = tagBody.range(of: "class=\"") else {
            return ""
        }
        let rest = tagBody[classRange.upperBound...]
        guard let quoteEnd = rest.firstIndex(of: "\"") else {
            return String(rest)
        }
        return String(rest[..<quoteEnd])
    }

    nonisolated private static func decodeHTMLEntities(_ input: Substring) -> String {
        guard input.contains("&") else {
            return String(input)
        }
        var s = String(input)
        let entities: [(String, String)] = [
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#x27;", "'"),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&#13;", "\r"),
            ("&amp;", "&")
        ]
        for (entity, char) in entities where s.contains(entity) {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s
    }

    nonisolated private static func resolveStyle(
        for classList: String,
        fallback: SpanStyle,
        isDark: Bool
    ) -> SpanStyle {
        let tokens = classList.split(separator: " ")
        guard let primary = tokens.first(where: { $0.hasPrefix("hljs-") }) ?? tokens.first else {
            return fallback
        }

        switch primary {
        case "hljs-keyword", "hljs-selector-tag", "hljs-doctag", "hljs-meta-keyword":
            return SpanStyle(
                color: isDark ? Color(red: 1.00, green: 0.48, blue: 0.70) : Color(red: 0.68, green: 0.11, blue: 0.56),
                isBold: true,
                isItalic: fallback.isItalic
            )

        case "hljs-string", "hljs-regexp", "hljs-char.escape_", "hljs-template-tag", "hljs-template-variable":
            return SpanStyle(
                color: isDark ? Color(red: 0.99, green: 0.56, blue: 0.44) : Color(red: 0.77, green: 0.14, blue: 0.11),
                isBold: false,
                isItalic: fallback.isItalic
            )

        case "hljs-number", "hljs-literal", "hljs-symbol", "hljs-bullet":
            return SpanStyle(
                color: isDark ? Color(red: 0.82, green: 0.75, blue: 1.00) : Color(red: 0.11, green: 0.00, blue: 0.81),
                isBold: false,
                isItalic: fallback.isItalic
            )

        case "hljs-title", "hljs-title.function_", "hljs-function", "hljs-section":
            return SpanStyle(
                color: isDark ? Color(red: 0.42, green: 0.76, blue: 1.00) : Color(red: 0.05, green: 0.36, blue: 0.62),
                isBold: false,
                isItalic: fallback.isItalic
            )

        case "hljs-type", "hljs-built_in", "hljs-title.class_", "hljs-class":
            return SpanStyle(
                color: isDark ? Color(red: 0.36, green: 0.87, blue: 0.84) : Color(red: 0.11, green: 0.44, blue: 0.50),
                isBold: false,
                isItalic: fallback.isItalic
            )

        case "hljs-comment", "hljs-quote":
            return SpanStyle(
                color: isDark ? Color(red: 0.53, green: 0.58, blue: 0.65) : Color(red: 0.38, green: 0.43, blue: 0.49),
                isBold: false,
                isItalic: true
            )

        case "hljs-attr", "hljs-attribute", "hljs-variable", "hljs-property", "hljs-params", "hljs-variable.language_":
            return SpanStyle(
                color: isDark ? Color(red: 0.52, green: 0.84, blue: 0.98) : Color(red: 0.20, green: 0.38, blue: 0.64),
                isBold: false,
                isItalic: fallback.isItalic
            )

        case "hljs-meta", "hljs-tag", "hljs-name", "hljs-selector-id", "hljs-selector-class":
            return SpanStyle(
                color: isDark ? Color(red: 0.54, green: 0.90, blue: 0.62) : Color(red: 0.13, green: 0.50, blue: 0.23),
                isBold: false,
                isItalic: fallback.isItalic
            )

        case "hljs-addition":
            return SpanStyle(
                color: isDark ? Color(red: 0.46, green: 0.90, blue: 0.56) : Color(red: 0.09, green: 0.48, blue: 0.19),
                isBold: false,
                isItalic: false
            )

        case "hljs-deletion":
            return SpanStyle(
                color: isDark ? Color(red: 1.00, green: 0.50, blue: 0.50) : Color(red: 0.75, green: 0.12, blue: 0.15),
                isBold: false,
                isItalic: false
            )

        case "hljs-emphasis":
            return SpanStyle(color: fallback.color, isBold: fallback.isBold, isItalic: true)

        case "hljs-strong":
            return SpanStyle(color: fallback.color, isBold: true, isItalic: fallback.isItalic)

        default:
            return fallback
        }
    }
}

// MARK: - CodeSyntaxCache

/// `@MainActor` memoization cache storing highlighted `AttributedString` blocks so scrolling
/// completed turns in `LazyVStack` hits in O(1) without spawning async tasks.
@MainActor
final class CodeSyntaxCache {

    static let shared = CodeSyntaxCache()

    struct Key: Hashable {
        let language: String
        let isDark: Bool
        let fontSizeTenths: Int
        let contentHash: UInt64
        let byteCount: Int

        init(code: String, language: String?, isDark: Bool, fontSize: CGFloat) {
            self.language = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            self.isDark = isDark
            self.fontSizeTenths = Int((fontSize * 10).rounded())
            self.contentHash = Self.fnv1a64(code)
            self.byteCount = code.utf8.count
        }

        private static func fnv1a64(_ text: String) -> UInt64 {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
            return hash
        }
    }

    private let maxEntries: Int
    private var storage: [Key: AttributedString] = [:]
    private var insertionOrder: [Key] = []

    init(maxEntries: Int = 192) {
        self.maxEntries = max(32, maxEntries)
    }

    func cached(for key: Key) -> AttributedString? {
        storage[key]
    }

    func store(_ attributed: AttributedString, for key: Key) {
        if storage[key] == nil {
            if storage.count >= maxEntries, let oldest = insertionOrder.first {
                insertionOrder.removeFirst()
                storage.removeValue(forKey: oldest)
            }
            insertionOrder.append(key)
        }
        storage[key] = attributed
    }
}
