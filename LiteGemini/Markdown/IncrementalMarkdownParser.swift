import Foundation
import Markdown

// MARK: - MarkdownInlineKind

/// Semantic classification of an inline text run inside a parsed Markdown block.
nonisolated enum MarkdownInlineKind: Equatable, Hashable, Sendable {
    /// Normal prose (may carry bold, italic, strikethrough, or link attributes).
    case text
    /// Inline monospaced code span delimited by backticks.
    case inlineCode
    /// Inline math expression preserved verbatim from `$...$` delimiters.
    case inlineMath
}

// MARK: - MarkdownInlineStyle

/// Cumulative inline text styles active on a `MarkdownInlineRun`.
nonisolated struct MarkdownInlineStyle: OptionSet, Equatable, Hashable, Sendable {

    let rawValue: UInt8

    static let bold = MarkdownInlineStyle(rawValue: 1 << 0)
    static let italic = MarkdownInlineStyle(rawValue: 1 << 1)
    static let strikethrough = MarkdownInlineStyle(rawValue: 1 << 2)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

// MARK: - MarkdownInlineRun

/// Single styled segment inside a heading, paragraph, or table cell.
nonisolated struct MarkdownInlineRun: Equatable, Hashable, Sendable {

    let text: String
    let kind: MarkdownInlineKind
    let style: MarkdownInlineStyle
    let linkURL: URL?

    init(
        text: String,
        kind: MarkdownInlineKind = .text,
        style: MarkdownInlineStyle = [],
        linkURL: URL? = nil
    ) {
        self.text = text
        self.kind = kind
        self.style = style
        self.linkURL = linkURL
    }
}

extension Array where Element == MarkdownInlineRun {

    /// Concatenated plain text across all inline runs.
    nonisolated var plainText: String {
        map(\.text).joined()
    }
}

// MARK: - MarkdownTableAlignment

/// Horizontal column alignment parsed from a GFM pipe table delimiter row.
nonisolated enum MarkdownTableAlignment: Equatable, Hashable, Sendable {
    case left
    case center
    case right
}

// MARK: - MarkdownTaskState

/// Task list item checkbox state (`- [ ]` vs `- [x]`).
nonisolated enum MarkdownTaskState: Equatable, Hashable, Sendable {
    case unchecked
    case checked
}

// MARK: - MarkdownListItem

/// Single item inside an ordered or unordered list, supporting nested blocks and task checkboxes.
nonisolated struct MarkdownListItem: Equatable, Hashable, Sendable, Identifiable {

    let id: String
    let taskState: MarkdownTaskState?
    let blocks: [MarkdownBlock]

    init(id: String, taskState: MarkdownTaskState? = nil, blocks: [MarkdownBlock]) {
        self.id = id
        self.taskState = taskState
        self.blocks = blocks
    }
}

// MARK: - MarkdownBlockKind

/// AST-backed block element rendered natively by `MarkdownBlockViews`.
nonisolated enum MarkdownBlockKind: Equatable, Hashable, Sendable {
    case heading(level: Int, runs: [MarkdownInlineRun])
    case paragraph(runs: [MarkdownInlineRun])
    case list(ordered: Bool, startIndex: Int, items: [MarkdownListItem])
    case blockquote(blocks: [MarkdownBlock])
    case codeBlock(language: String?, code: String, isClosed: Bool)
    case table(
        headers: [[MarkdownInlineRun]],
        alignments: [MarkdownTableAlignment],
        rows: [[[MarkdownInlineRun]]]
    )
    case mathBlock(latex: String, isClosed: Bool)
    case thematicBreak
}

// MARK: - MarkdownBlock

/// Stable, identifiable block node produced by `IncrementalMarkdownParser`.
nonisolated struct MarkdownBlock: Equatable, Hashable, Sendable, Identifiable {

    let id: String
    let kind: MarkdownBlockKind

    init(id: String, kind: MarkdownBlockKind) {
        self.id = id
        self.kind = kind
    }
}

// MARK: - MarkdownCacheKey

/// Composite `(turnId, contentHash)` identity used to memoize parsed Markdown blocks per turn.
nonisolated struct MarkdownCacheKey: Equatable, Hashable, Sendable {
    let turnId: String
    let contentHash: UInt64
}

// MARK: - IncrementalMarkdownParser

/// Pure, stateless AST-backed Markdown parser built on `swift-markdown`.
///
/// Protects `$...$` inline math and `$$...$$` display math from CommonMark `_` / `*` emphasis
/// mangling prior to AST construction, tolerates unclosed streaming code fences and display math
/// blocks, and converts the resulting AST into `Sendable` `MarkdownBlock` value models.
nonisolated enum IncrementalMarkdownParser {

    // Private-Use Area sentinels cannot collide with ordinary prose and survive `cmark-gfm` verbatim.
    private static let sentinelStart: Character = "\u{E000}"
    private static let sentinelEnd: Character = "\u{E001}"
    private static let blockMathPrefix = "LGMATHBLOCK"
    private static let inlineMathPrefix = "LGMATHINLINE"

    private struct MathBlockPlaceholder {
        let latex: String
        let isClosed: Bool
    }

    private struct PreprocessedSource {
        let markdown: String
        let blockMath: [MathBlockPlaceholder]
        let inlineMath: [String]
        let hasUnclosedCodeFence: Bool
    }

    // MARK: - Public Entry Points

    /// Parses raw Markdown (complete or actively streaming) into stable `[MarkdownBlock]` models.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        guard !markdown.isEmpty else {
            return []
        }

        let preprocessed = preprocess(markdown)
        let document = Document(
            parsing: preprocessed.markdown,
            options: [.disableSourcePosOpts, .disableSmartOpts]
        )

        var blocks = convertBlockChildren(
            document.children,
            pathPrefix: "b",
            blockMath: preprocessed.blockMath,
            inlineMath: preprocessed.inlineMath
        )

        if preprocessed.hasUnclosedCodeFence {
            markTrailingCodeBlockUnclosed(in: &blocks)
        }

        return blocks
    }

    /// Computes a deterministic 64-bit FNV-1a hash over the UTF-8 bytes of `markdown`.
    static func contentHash(for markdown: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in markdown.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    // MARK: - Phase 1: Math Protection & Fence Tracking

    private static func preprocess(_ raw: String) -> PreprocessedSource {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var outputLines: [String] = []
        outputLines.reserveCapacity(lines.count)

        var blockMath: [MathBlockPlaceholder] = []
        var inlineMath: [String] = []

        var activeFence: (char: Character, length: Int)? = nil
        var activeMathBlock: (prefix: String, blockquoteDepth: Int, lines: [String])? = nil

        for line in lines {
            if var mathState = activeMathBlock {
                let (strippedPrefix, content) = stripBlockquotePrefix(from: line, maxDepth: mathState.blockquoteDepth)
                let trimmed = content.trimmingCharacters(in: .whitespaces)

                if let closingRange = content.range(of: "$$") {
                    let beforeClosing = String(content[..<closingRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    if !beforeClosing.isEmpty {
                        mathState.lines.append(beforeClosing)
                    }
                    let latex = mathState.lines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let tokenIndex = blockMath.count
                    blockMath.append(MathBlockPlaceholder(latex: latex, isClosed: true))
                    appendBlockMathToken(
                        tokenIndex,
                        prefix: mathState.prefix,
                        to: &outputLines
                    )
                    let remainder = String(content[closingRange.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                    if !remainder.isEmpty {
                        outputLines.append(strippedPrefix + protectInlineMath(in: remainder, inlineMath: &inlineMath))
                    }
                    activeMathBlock = nil
                } else {
                    if trimmed.isEmpty && mathState.lines.isEmpty {
                        activeMathBlock = mathState
                    } else {
                        mathState.lines.append(content)
                        activeMathBlock = mathState
                    }
                }
                continue
            }

            if let fence = activeFence {
                outputLines.append(line)
                if isClosingCodeFence(line, char: fence.char, minLength: fence.length) {
                    activeFence = nil
                }
                continue
            }

            if let openedFence = detectOpeningCodeFence(line) {
                activeFence = openedFence
                outputLines.append(line)
                continue
            }

            let (prefix, content) = stripContainerPrefix(from: line)
            if content.hasPrefix("$$") {
                let afterOpening = String(content.dropFirst(2))
                if let closingRange = afterOpening.range(of: "$$") {
                    let afterClosing = afterOpening[closingRange.upperBound...]
                        .trimmingCharacters(in: .whitespaces)
                    if afterClosing.isEmpty {
                        let latex = String(afterOpening[..<closingRange.lowerBound])
                            .trimmingCharacters(in: .whitespaces)
                        if !latex.isEmpty {
                            let tokenIndex = blockMath.count
                            blockMath.append(MathBlockPlaceholder(latex: latex, isClosed: true))
                            appendBlockMathToken(tokenIndex, prefix: prefix, to: &outputLines)
                            continue
                        }
                    }
                } else {
                    let firstBody = afterOpening.trimmingCharacters(in: .whitespaces)
                    let blockquoteDepth = prefix.reduce(0) { $0 + ($1 == ">" ? 1 : 0) }
                    activeMathBlock = (
                        prefix: prefix,
                        blockquoteDepth: blockquoteDepth,
                        lines: firstBody.isEmpty ? [] : [firstBody]
                    )
                    continue
                }
            }

            outputLines.append(protectInlineMath(in: line, inlineMath: &inlineMath))
        }

        if let openMath = activeMathBlock {
            let latex = openMath.lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tokenIndex = blockMath.count
            blockMath.append(MathBlockPlaceholder(latex: latex, isClosed: false))
            appendBlockMathToken(tokenIndex, prefix: openMath.prefix, to: &outputLines)
        }

        return PreprocessedSource(
            markdown: outputLines.joined(separator: "\n"),
            blockMath: blockMath,
            inlineMath: inlineMath,
            hasUnclosedCodeFence: activeFence != nil
        )
    }

    private static func appendBlockMathToken(
        _ index: Int,
        prefix: String,
        to outputLines: inout [String]
    ) {
        let token = "\(sentinelStart)\(blockMathPrefix)\(index)\(sentinelEnd)"
        let separatorPrefix = prefix.trimmingCharacters(in: .whitespaces).isEmpty ? "" : prefix
        if let last = outputLines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
            outputLines.append(separatorPrefix)
        }
        outputLines.append(prefix + token)
        outputLines.append(separatorPrefix)
    }

    /// Splits leading indentation and blockquote `>` markers from line content so block math and
    /// code fences nested inside blockquotes or list items preserve their parent container.
    private static func stripContainerPrefix(from line: String) -> (prefix: String, content: String) {
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch == " " || ch == "\t" || ch == ">" {
                index = line.index(after: index)
            } else {
                break
            }
        }
        return (String(line[..<index]), String(line[index...]))
    }

    /// Strips at most `maxDepth` leading blockquote `>` prefixes while preserving LaTeX body indentation.
    private static func stripBlockquotePrefix(from line: String, maxDepth: Int) -> (prefix: String, content: String) {
        guard maxDepth > 0 else {
            return ("", line)
        }
        var index = line.startIndex
        var strippedDepth = 0
        while index < line.endIndex && strippedDepth < maxDepth {
            var probe = index
            while probe < line.endIndex && (line[probe] == " " || line[probe] == "\t") {
                probe = line.index(after: probe)
            }
            guard probe < line.endIndex && line[probe] == ">" else {
                break
            }
            strippedDepth += 1
            index = line.index(after: probe)
            if index < line.endIndex && line[index] == " " {
                index = line.index(after: index)
            }
        }
        return (String(line[..<index]), String(line[index...]))
    }

    private static func detectOpeningCodeFence(_ line: String) -> (char: Character, length: Int)? {
        let (_, content) = stripContainerPrefix(from: line)
        guard let first = content.first, first == "`" || first == "~" else {
            return nil
        }

        var count = 0
        var idx = content.startIndex
        while idx < content.endIndex && content[idx] == first {
            count += 1
            idx = content.index(after: idx)
        }
        guard count >= 3 else {
            return nil
        }

        // CommonMark forbids backticks inside the info string of a backtick code fence.
        if first == "`", content[idx...].contains("`") {
            return nil
        }
        return (char: first, length: count)
    }

    private static func isClosingCodeFence(_ line: String, char: Character, minLength: Int) -> Bool {
        let (_, content) = stripContainerPrefix(from: line)
        var count = 0
        var idx = content.startIndex
        while idx < content.endIndex && content[idx] == char {
            count += 1
            idx = content.index(after: idx)
        }
        guard count >= minLength else {
            return false
        }
        return content[idx...].trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Replaces valid inline `$...$` and mid-line `$$...$$` spans with PUA sentinels while
    /// skipping backslash escapes, inline code backtick spans, and currency patterns like `$5 to $10`.
    private static func protectInlineMath(in line: String, inlineMath: inout [String]) -> String {
        guard line.contains("$") else {
            return line
        }

        let chars = Array(line)
        let count = chars.count
        var result = String()
        result.reserveCapacity(line.count)

        var i = 0
        while i < count {
            let ch = chars[i]

            if ch == "\\" {
                result.append(ch)
                if i + 1 < count {
                    result.append(chars[i + 1])
                    i += 2
                } else {
                    i += 1
                }
                continue
            }

            // Preserve inline code spans verbatim so `$var` inside backticks is untouched.
            if ch == "`" {
                var tickCount = 0
                while i + tickCount < count && chars[i + tickCount] == "`" {
                    tickCount += 1
                }

                if let closeEnd = findClosingBackticks(in: chars, from: i + tickCount, tickCount: tickCount) {
                    result.append(contentsOf: chars[i..<closeEnd])
                    i = closeEnd
                } else {
                    result.append(contentsOf: chars[i..<(i + tickCount)])
                    i += tickCount
                }
                continue
            }

            if ch == "$" {
                // Mid-line `$$...$$`
                if i + 1 < count && chars[i + 1] == "$" {
                    if let closeStart = findClosingDoubleDollar(in: chars, from: i + 2) {
                        let latex = String(chars[(i + 2)..<closeStart])
                            .trimmingCharacters(in: .whitespaces)
                        if !latex.isEmpty {
                            let idx = inlineMath.count
                            inlineMath.append(latex)
                            result.append("\(sentinelStart)\(inlineMathPrefix)\(idx)\(sentinelEnd)")
                            i = closeStart + 2
                            continue
                        }
                    }
                    result.append("$$")
                    i += 2
                    continue
                }

                // Single-dollar inline math `$...$`
                if i + 1 < count,
                   !chars[i + 1].isWhitespace,
                   chars[i + 1] != "$",
                   let closeIdx = findClosingSingleDollar(in: chars, from: i + 1) {
                    let latex = String(chars[(i + 1)..<closeIdx])
                    if !latex.isEmpty {
                        let idx = inlineMath.count
                        inlineMath.append(latex)
                        result.append("\(sentinelStart)\(inlineMathPrefix)\(idx)\(sentinelEnd)")
                        i = closeIdx + 1
                        continue
                    }
                }
            }

            result.append(ch)
            i += 1
        }

        return result
    }

    private static func findClosingBackticks(in chars: [Character], from start: Int, tickCount: Int) -> Int? {
        let count = chars.count
        var j = start
        while j < count {
            if chars[j] == "`" {
                var run = 0
                while j + run < count && chars[j + run] == "`" {
                    run += 1
                }
                if run == tickCount {
                    return j + run
                }
                j += run
            } else {
                j += 1
            }
        }
        return nil
    }

    private static func findClosingDoubleDollar(in chars: [Character], from start: Int) -> Int? {
        let count = chars.count
        var j = start
        while j + 1 < count {
            if chars[j] == "\\" {
                j += 2
                continue
            }
            if chars[j] == "$" && chars[j + 1] == "$" {
                return j
            }
            j += 1
        }
        return nil
    }

    private static func findClosingSingleDollar(in chars: [Character], from start: Int) -> Int? {
        let count = chars.count
        var j = start
        while j < count {
            if chars[j] == "\\" {
                j += 2
                continue
            }
            if chars[j] == "$" {
                let followedByDollar = (j + 1 < count && chars[j + 1] == "$")
                let precededByWhitespace = chars[j - 1].isWhitespace
                let followedByASCIIDigit = (j + 1 < count && chars[j + 1].isASCII && chars[j + 1].isNumber)
                if !followedByDollar && !precededByWhitespace && !followedByASCIIDigit {
                    return j
                }
                // An unescaped `$` that cannot close the span proves the opening `$` was not math
                // (e.g., currency `$5` preceding a later `$n_1$` span on the same line).
                return nil
            }
            j += 1
        }
        return nil
    }

    // MARK: - Phase 2: AST Conversion

    private static func convertBlockChildren(
        _ children: MarkupChildren,
        pathPrefix: String,
        blockMath: [MathBlockPlaceholder],
        inlineMath: [String]
    ) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var blockIndex = 0

        for child in children {
            let blockPath = "\(pathPrefix)-\(blockIndex)"
            if let converted = convertBlock(
                child,
                path: blockPath,
                blockMath: blockMath,
                inlineMath: inlineMath
            ) {
                result.append(converted)
                blockIndex += 1
            }
        }
        return result
    }

    private static func convertBlock(
        _ markup: any Markup,
        path: String,
        blockMath: [MathBlockPlaceholder],
        inlineMath: [String]
    ) -> MarkdownBlock? {
        switch markup {
        case let heading as Heading:
            let runs = collectInlineRuns(from: heading.children, style: [], linkURL: nil, inlineMath: inlineMath)
            return MarkdownBlock(
                id: "\(path)-h\(heading.level)",
                kind: .heading(level: heading.level, runs: runs)
            )

        case let paragraph as Paragraph:
            if let placeholderIndex = standaloneBlockMathIndex(in: paragraph),
               blockMath.indices.contains(placeholderIndex) {
                let entry = blockMath[placeholderIndex]
                return MarkdownBlock(
                    id: "\(path)-math",
                    kind: .mathBlock(latex: entry.latex, isClosed: entry.isClosed)
                )
            }
            let runs = collectInlineRuns(from: paragraph.children, style: [], linkURL: nil, inlineMath: inlineMath)
            guard !runs.isEmpty else {
                return nil
            }
            return MarkdownBlock(
                id: "\(path)-p",
                kind: .paragraph(runs: runs)
            )

        case let orderedList as OrderedList:
            let items = convertListItems(
                orderedList.listItems,
                pathPrefix: "\(path)-ol",
                blockMath: blockMath,
                inlineMath: inlineMath
            )
            return MarkdownBlock(
                id: "\(path)-ol",
                kind: .list(ordered: true, startIndex: Int(orderedList.startIndex), items: items)
            )

        case let unorderedList as UnorderedList:
            let items = convertListItems(
                unorderedList.listItems,
                pathPrefix: "\(path)-ul",
                blockMath: blockMath,
                inlineMath: inlineMath
            )
            return MarkdownBlock(
                id: "\(path)-ul",
                kind: .list(ordered: false, startIndex: 1, items: items)
            )

        case let blockQuote as BlockQuote:
            let innerBlocks = convertBlockChildren(
                blockQuote.children,
                pathPrefix: "\(path)-bq",
                blockMath: blockMath,
                inlineMath: inlineMath
            )
            return MarkdownBlock(
                id: "\(path)-bq",
                kind: .blockquote(blocks: innerBlocks)
            )

        case let codeBlock as CodeBlock:
            let cleanedLanguage = codeBlock.language?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let language = (cleanedLanguage?.isEmpty == false) ? cleanedLanguage : nil
            let trimmedCode = trimSingleTrailingNewline(codeBlock.code)
            return MarkdownBlock(
                id: "\(path)-code",
                kind: .codeBlock(language: language, code: trimmedCode, isClosed: true)
            )

        case let table as Table:
            return convertTable(table, path: path, inlineMath: inlineMath)

        case is ThematicBreak:
            return MarkdownBlock(id: "\(path)-hr", kind: .thematicBreak)

        case let htmlBlock as HTMLBlock:
            let trimmed = htmlBlock.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            return MarkdownBlock(
                id: "\(path)-html",
                kind: .paragraph(runs: [MarkdownInlineRun(text: trimmed, kind: .text)])
            )

        default:
            let fallbackText = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallbackText.isEmpty else {
                return nil
            }
            return MarkdownBlock(
                id: "\(path)-raw",
                kind: .paragraph(runs: [MarkdownInlineRun(text: fallbackText, kind: .text)])
            )
        }
    }

    private static func convertListItems<S: Sequence>(
        _ items: S,
        pathPrefix: String,
        blockMath: [MathBlockPlaceholder],
        inlineMath: [String]
    ) -> [MarkdownListItem] where S.Element == ListItem {
        var converted: [MarkdownListItem] = []
        for (idx, item) in items.enumerated() {
            let itemId = "\(pathPrefix)-i\(idx)"
            let taskState: MarkdownTaskState?
            switch item.checkbox {
            case .checked:
                taskState = .checked
            case .unchecked:
                taskState = .unchecked
            case .none:
                taskState = nil
            }
            let itemBlocks = convertBlockChildren(
                item.children,
                pathPrefix: itemId,
                blockMath: blockMath,
                inlineMath: inlineMath
            )
            converted.append(MarkdownListItem(id: itemId, taskState: taskState, blocks: itemBlocks))
        }
        return converted
    }

    private static func convertTable(
        _ table: Table,
        path: String,
        inlineMath: [String]
    ) -> MarkdownBlock {
        let headers: [[MarkdownInlineRun]] = Array(table.head.cells).map { cell in
            collectInlineRuns(from: cell.children, style: [.bold], linkURL: nil, inlineMath: inlineMath)
        }

        let alignments: [MarkdownTableAlignment] = table.columnAlignments.map { alignment in
            switch alignment {
            case .center:
                return .center
            case .right:
                return .right
            case .left, .none:
                return .left
            }
        }

        let rows: [[[MarkdownInlineRun]]] = Array(table.body.rows).map { row in
            Array(row.cells).map { cell in
                collectInlineRuns(from: cell.children, style: [], linkURL: nil, inlineMath: inlineMath)
            }
        }

        return MarkdownBlock(
            id: "\(path)-table",
            kind: .table(headers: headers, alignments: alignments, rows: rows)
        )
    }

    private static func standaloneBlockMathIndex(in paragraph: Paragraph) -> Int? {
        guard paragraph.childCount == 1,
              let textNode = paragraph.child(at: 0) as? Markdown.Text else {
            return nil
        }

        let trimmed = textNode.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == sentinelStart, trimmed.last == sentinelEnd else {
            return nil
        }

        let inner = String(trimmed.dropFirst().dropLast())
        guard inner.hasPrefix(blockMathPrefix) else {
            return nil
        }
        return Int(inner.dropFirst(blockMathPrefix.count))
    }

    // MARK: - Inline Conversion

    private static func collectInlineRuns(
        from children: MarkupChildren,
        style: MarkdownInlineStyle,
        linkURL: URL?,
        inlineMath: [String]
    ) -> [MarkdownInlineRun] {
        var runs: [MarkdownInlineRun] = []

        for child in children {
            switch child {
            case let textNode as Markdown.Text:
                appendExpandedTextRuns(
                    textNode.string,
                    style: style,
                    linkURL: linkURL,
                    inlineMath: inlineMath,
                    to: &runs
                )

            case let strong as Strong:
                var nextStyle = style
                nextStyle.insert(.bold)
                runs.append(contentsOf: collectInlineRuns(
                    from: strong.children,
                    style: nextStyle,
                    linkURL: linkURL,
                    inlineMath: inlineMath
                ))

            case let emphasis as Emphasis:
                var nextStyle = style
                nextStyle.insert(.italic)
                runs.append(contentsOf: collectInlineRuns(
                    from: emphasis.children,
                    style: nextStyle,
                    linkURL: linkURL,
                    inlineMath: inlineMath
                ))

            case let strikethrough as Strikethrough:
                var nextStyle = style
                nextStyle.insert(.strikethrough)
                runs.append(contentsOf: collectInlineRuns(
                    from: strikethrough.children,
                    style: nextStyle,
                    linkURL: linkURL,
                    inlineMath: inlineMath
                ))

            case let inlineCode as InlineCode:
                runs.append(MarkdownInlineRun(
                    text: inlineCode.code,
                    kind: .inlineCode,
                    style: style,
                    linkURL: linkURL
                ))

            case let link as Link:
                let resolvedURL = link.destination.flatMap { URL(string: $0) } ?? linkURL
                let childRuns = collectInlineRuns(
                    from: link.children,
                    style: style,
                    linkURL: resolvedURL,
                    inlineMath: inlineMath
                )
                if childRuns.isEmpty, let dest = link.destination, !dest.isEmpty {
                    runs.append(MarkdownInlineRun(
                        text: dest,
                        kind: .text,
                        style: style,
                        linkURL: resolvedURL
                    ))
                } else {
                    runs.append(contentsOf: childRuns)
                }

            case let image as Markdown.Image:
                let altRuns = collectInlineRuns(
                    from: image.children,
                    style: style,
                    linkURL: image.source.flatMap { URL(string: $0) } ?? linkURL,
                    inlineMath: inlineMath
                )
                if !altRuns.isEmpty {
                    runs.append(contentsOf: altRuns)
                } else if let title = image.title, !title.isEmpty {
                    runs.append(MarkdownInlineRun(
                        text: title,
                        kind: .text,
                        style: style,
                        linkURL: image.source.flatMap { URL(string: $0) } ?? linkURL
                    ))
                }

            case is SoftBreak:
                runs.append(MarkdownInlineRun(text: " ", kind: .text, style: style, linkURL: linkURL))

            case is LineBreak:
                runs.append(MarkdownInlineRun(text: "\n", kind: .text, style: style, linkURL: linkURL))

            case let inlineHTML as InlineHTML:
                let lower = inlineHTML.rawHTML
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if lower == "<br>" || lower == "<br/>" || lower == "<br />" {
                    runs.append(MarkdownInlineRun(text: "\n", kind: .text, style: style, linkURL: linkURL))
                } else {
                    runs.append(MarkdownInlineRun(text: inlineHTML.rawHTML, kind: .text, style: style, linkURL: linkURL))
                }

            default:
                let nested = collectInlineRuns(
                    from: child.children,
                    style: style,
                    linkURL: linkURL,
                    inlineMath: inlineMath
                )
                runs.append(contentsOf: nested)
            }
        }

        return coalesceAdjacentTextRuns(runs)
    }

    private static func appendExpandedTextRuns(
        _ raw: String,
        style: MarkdownInlineStyle,
        linkURL: URL?,
        inlineMath: [String],
        to runs: inout [MarkdownInlineRun]
    ) {
        guard raw.contains(sentinelStart) else {
            if !raw.isEmpty {
                runs.append(MarkdownInlineRun(text: raw, kind: .text, style: style, linkURL: linkURL))
            }
            return
        }

        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            guard let startIdx = raw[cursor...].firstIndex(of: sentinelStart),
                  let endIdx = raw[raw.index(after: startIdx)...].firstIndex(of: sentinelEnd) else {
                let tail = String(raw[cursor...])
                if !tail.isEmpty {
                    runs.append(MarkdownInlineRun(text: tail, kind: .text, style: style, linkURL: linkURL))
                }
                break
            }

            if startIdx > cursor {
                runs.append(MarkdownInlineRun(
                    text: String(raw[cursor..<startIdx]),
                    kind: .text,
                    style: style,
                    linkURL: linkURL
                ))
            }

            let tokenPayload = String(raw[raw.index(after: startIdx)..<endIdx])
            if tokenPayload.hasPrefix(inlineMathPrefix),
               let idx = Int(tokenPayload.dropFirst(inlineMathPrefix.count)),
               inlineMath.indices.contains(idx) {
                runs.append(MarkdownInlineRun(
                    text: inlineMath[idx],
                    kind: .inlineMath,
                    style: style,
                    linkURL: linkURL
                ))
            }

            cursor = raw.index(after: endIdx)
        }
    }

    private static func coalesceAdjacentTextRuns(_ runs: [MarkdownInlineRun]) -> [MarkdownInlineRun] {
        guard runs.count > 1 else {
            return runs
        }
        var merged: [MarkdownInlineRun] = []
        merged.reserveCapacity(runs.count)

        for run in runs {
            if let last = merged.last,
               last.kind == .text,
               run.kind == .text,
               last.style == run.style,
               last.linkURL == run.linkURL {
                merged[merged.count - 1] = MarkdownInlineRun(
                    text: last.text + run.text,
                    kind: .text,
                    style: last.style,
                    linkURL: last.linkURL
                )
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    private static func trimSingleTrailingNewline(_ code: String) -> String {
        guard code.hasSuffix("\n") else {
            return code
        }
        return String(code.dropLast())
    }

    @discardableResult
    private static func markTrailingCodeBlockUnclosed(in blocks: inout [MarkdownBlock]) -> Bool {
        guard !blocks.isEmpty else {
            return false
        }

        let lastIndex = blocks.count - 1
        switch blocks[lastIndex].kind {
        case .codeBlock(let language, let code, _):
            blocks[lastIndex] = MarkdownBlock(
                id: blocks[lastIndex].id,
                kind: .codeBlock(language: language, code: code, isClosed: false)
            )
            return true

        case .blockquote(var innerBlocks):
            if markTrailingCodeBlockUnclosed(in: &innerBlocks) {
                blocks[lastIndex] = MarkdownBlock(
                    id: blocks[lastIndex].id,
                    kind: .blockquote(blocks: innerBlocks)
                )
                return true
            }
            return false

        case .list(let ordered, let startIndex, var items):
            guard !items.isEmpty else {
                return false
            }
            var lastItemBlocks = items[items.count - 1].blocks
            if markTrailingCodeBlockUnclosed(in: &lastItemBlocks) {
                let lastItem = items[items.count - 1]
                items[items.count - 1] = MarkdownListItem(
                    id: lastItem.id,
                    taskState: lastItem.taskState,
                    blocks: lastItemBlocks
                )
                blocks[lastIndex] = MarkdownBlock(
                    id: blocks[lastIndex].id,
                    kind: .list(ordered: ordered, startIndex: startIndex, items: items)
                )
                return true
            }
            return false

        default:
            return false
        }
    }
}

// MARK: - MarkdownRenderCache

/// `@MainActor` LRU memoization cache mapping `(turnId, partIndex)` + `contentHash` to parsed
/// `[MarkdownBlock]` arrays.
///
/// Completed turns hit the cache in O(1) with zero AST re-parsing during 120Hz scrolling, while
/// an actively streaming tail turn overwrites its single slot in place as its markdown snapshot grows.
@MainActor
final class MarkdownRenderCache {

    /// Shared process-wide render cache used by `MarkdownBlockViews` and `ChatTurnRowView`.
    static let shared = MarkdownRenderCache()

    private struct SlotKey: Equatable, Hashable {
        let turnId: String
        let partIndex: Int
    }

    private struct CacheEntry {
        let contentHash: UInt64
        let sourceSnapshot: String
        let blocks: [MarkdownBlock]
        var lastAccessTick: UInt64
    }

    /// Maximum number of `(turnId, partIndex)` slots retained in memory.
    let maxEntries: Int

    private var entries: [SlotKey: CacheEntry] = [:]
    private var accessClock: UInt64 = 0

    /// Cumulative number of memoized cache hits (exposed for performance harness verification).
    private(set) var cacheHits: Int = 0
    /// Cumulative number of AST parses triggered by cache misses.
    private(set) var cacheMisses: Int = 0

    /// Number of currently cached turn-part entries.
    var entryCount: Int {
        entries.count
    }

    init(maxEntries: Int = 512) {
        self.maxEntries = max(1, maxEntries)
    }

    /// Returns cached `[MarkdownBlock]` for `(turnId, contentHash)` or parses and stores them on a miss.
    func blocks(for markdown: String, turnId: String, partIndex: Int = 0) -> [MarkdownBlock] {
        guard !markdown.isEmpty else {
            return []
        }

        let slot = SlotKey(turnId: turnId, partIndex: partIndex)
        let hash = IncrementalMarkdownParser.contentHash(for: markdown)
        accessClock &+= 1

        if var existing = entries[slot],
           existing.contentHash == hash,
           existing.sourceSnapshot == markdown {
            existing.lastAccessTick = accessClock
            entries[slot] = existing
            cacheHits += 1
            return existing.blocks
        }

        let parsed = IncrementalMarkdownParser.parse(markdown)
        cacheMisses += 1

        entries[slot] = CacheEntry(
            contentHash: hash,
            sourceSnapshot: markdown,
            blocks: parsed,
            lastAccessTick: accessClock
        )

        if entries.count > maxEntries {
            evictLeastRecentlyUsed()
        }

        return parsed
    }

    /// Returns the cached `(turnId, contentHash)` key for a turn slot, if present.
    func cachedKey(forTurnId turnId: String, partIndex: Int = 0) -> MarkdownCacheKey? {
        guard let entry = entries[SlotKey(turnId: turnId, partIndex: partIndex)] else {
            return nil
        }
        return MarkdownCacheKey(turnId: turnId, contentHash: entry.contentHash)
    }

    /// Evicts all cached parts associated with a specific turn identifier.
    func invalidate(turnId: String) {
        entries = entries.filter { $0.key.turnId != turnId }
    }

    /// Clears all cached entries and resets hit/miss counters.
    func clear() {
        entries.removeAll()
        accessClock = 0
        cacheHits = 0
        cacheMisses = 0
    }

    private func evictLeastRecentlyUsed() {
        guard let oldestKey = entries.min(by: { $0.value.lastAccessTick < $1.value.lastAccessTick })?.key else {
            return
        }
        entries.removeValue(forKey: oldestKey)
    }
}
