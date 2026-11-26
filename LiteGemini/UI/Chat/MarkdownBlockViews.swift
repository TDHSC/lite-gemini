import AppKit
import SwiftUI

// MARK: - MarkdownContentView

/// Renders a Markdown string using memoized AST blocks from `MarkdownRenderCache`.
/// Completed turns resolve their `[MarkdownBlock]` in O(1) without re-parsing during 120Hz scrolling.
struct MarkdownContentView: View {

    let markdown: String
    let turnId: String
    var partIndex: Int = 0
    var baseFontSize: CGFloat = 13.5
    var foregroundOpacity: Double = 0.92
    var cache: MarkdownRenderCache = .shared

    var body: some View {
        let blocks = cache.blocks(for: markdown, turnId: turnId, partIndex: partIndex)
        MarkdownBlockListView(
            blocks: blocks,
            baseFontSize: baseFontSize,
            foregroundOpacity: foregroundOpacity,
            listDepth: 0
        )
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }
}

// MARK: - MarkdownBlockListView

/// Renders an ordered list of AST-backed `MarkdownBlock` nodes natively in SwiftUI.
struct MarkdownBlockListView: View {

    let blocks: [MarkdownBlock]
    var baseFontSize: CGFloat = 13.5
    var foregroundOpacity: Double = 0.92
    var listDepth: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: listDepth == 0 ? 10 : 6) {
            ForEach(blocks) { block in
                MarkdownBlockView(
                    block: block,
                    baseFontSize: baseFontSize,
                    foregroundOpacity: foregroundOpacity,
                    listDepth: listDepth
                )
            }
        }
    }
}

// MARK: - MarkdownBlockView

private struct MarkdownBlockView: View {

    let block: MarkdownBlock
    let baseFontSize: CGFloat
    let foregroundOpacity: Double
    let listDepth: Int

    var body: some View {
        switch block.kind {
        case .heading(let level, let runs):
            headingView(level: level, runs: runs)

        case .paragraph(let runs):
            MarkdownRichRunsTextView(
                runs: runs,
                fontSize: baseFontSize,
                baseWeight: .regular
            )
            .foregroundStyle(Color.primary.opacity(foregroundOpacity))
            .lineSpacing(4)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)

        case .list(let ordered, let startIndex, let items):
            listView(ordered: ordered, startIndex: startIndex, items: items)

        case .blockquote(let innerBlocks):
            blockquoteView(blocks: innerBlocks)

        case .codeBlock(let language, let code, let isClosed):
            CodeBlockCardView(language: language, code: code, isClosed: isClosed)

        case .table(let headers, let alignments, let rows):
            MarkdownTableView(
                headers: headers,
                alignments: alignments,
                rows: rows,
                baseFontSize: max(12, baseFontSize - 0.5),
                foregroundOpacity: foregroundOpacity
            )

        case .mathBlock(let latex, let isClosed):
            MathBlockCardView(latex: latex, isClosed: isClosed)

        case .thematicBreak:
            Rectangle()
                .fill(LiquidGlassColors.subtleHairline)
                .frame(height: 1)
                .padding(.vertical, 6)
        }
    }

    // MARK: - Block Builders

    private func headingView(level: Int, runs: [MarkdownInlineRun]) -> some View {
        let (size, weight, topPadding): (CGFloat, Font.Weight, CGFloat) = switch level {
        case 1:
            (baseFontSize + 6.5, .bold, 8)
        case 2:
            (baseFontSize + 3.5, .semibold, 7)
        case 3:
            (baseFontSize + 1.5, .semibold, 5)
        case 4:
            (baseFontSize + 0.5, .semibold, 4)
        default:
            (baseFontSize, .semibold, 3)
        }

        return MarkdownRichRunsTextView(
            runs: runs,
            fontSize: size,
            baseWeight: weight
        )
        .foregroundStyle(Color.primary.opacity(level >= 5 ? foregroundOpacity * 0.86 : 0.96))
        .lineSpacing(3)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, topPadding)
    }

    private func listView(ordered: Bool, startIndex: Int, items: [MarkdownListItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    listMarker(
                        ordered: ordered,
                        number: startIndex + offset,
                        taskState: item.taskState
                    )

                    MarkdownBlockListView(
                        blocks: item.blocks,
                        baseFontSize: baseFontSize,
                        foregroundOpacity: foregroundOpacity,
                        listDepth: listDepth + 1
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, listDepth == 0 ? 2 : 12)
    }

    @ViewBuilder
    private func listMarker(ordered: Bool, number: Int, taskState: MarkdownTaskState?) -> some View {
        if let taskState {
            Image(systemName: taskState == .checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(taskState == .checked ? LiquidGlassColors.sendButtonBlue : Color.secondary)
                .frame(minWidth: 16, alignment: .center)
        } else if ordered {
            Text(verbatim: "\(number).")
                .font(.system(size: baseFontSize - 0.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
        } else {
            let bullet: String = switch listDepth % 3 {
            case 0: "•"
            case 1: "◦"
            default: "▪"
            }
            Text(bullet)
                .font(.system(size: baseFontSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
        }
    }

    private func blockquoteView(blocks: [MarkdownBlock]) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.22))
                .frame(width: 2.5)

            MarkdownBlockListView(
                blocks: blocks,
                baseFontSize: baseFontSize,
                foregroundOpacity: foregroundOpacity * 0.85,
                listDepth: listDepth + 1
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - MarkdownAttributedStringBuilder

enum MarkdownAttributedStringBuilder {

    /// Builds a styled SwiftUI `AttributedString` from parsed inline runs, preserving inline code,
    /// inline math spans, links, and combined emphasis/strong/strikethrough traits.
    static func build(
        from runs: [MarkdownInlineRun],
        fontSize: CGFloat,
        baseWeight: Font.Weight,
        colorScheme: ColorScheme
    ) -> AttributedString {
        var result = AttributedString()

        for run in runs {
            var segment: AttributedString
            switch run.kind {
            case .text:
                segment = AttributedString(run.text)
                segment.font = resolvedProseFont(size: fontSize, baseWeight: baseWeight, style: run.style)

            case .inlineCode:
                segment = AttributedString("\u{2009}\(run.text)\u{2009}")
                segment.font = .system(
                    size: max(11, fontSize - 1),
                    weight: run.style.contains(.bold) ? .semibold : .regular,
                    design: .monospaced
                )
                segment.backgroundColor = Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.07)

            case .inlineMath:
                segment = AttributedString("\u{2009}\(run.text)\u{2009}")
                segment.font = .system(
                    size: max(11.5, fontSize - 0.5),
                    weight: run.style.contains(.bold) ? .semibold : .regular,
                    design: .monospaced
                )
                segment.backgroundColor = LiquidGlassColors.sendButtonBlue.opacity(colorScheme == .dark ? 0.15 : 0.08)
            }

            if run.style.contains(.strikethrough) {
                segment.strikethroughStyle = .single
            }

            if let linkURL = run.linkURL {
                segment.link = linkURL
                segment.foregroundColor = LiquidGlassColors.sendButtonBlue
                segment.underlineStyle = .single
            }

            result.append(segment)
        }

        return result
    }

    private static func resolvedProseFont(
        size: CGFloat,
        baseWeight: Font.Weight,
        style: MarkdownInlineStyle
    ) -> Font {
        let weight: Font.Weight = style.contains(.bold) ? .semibold : baseWeight
        var font = Font.system(size: size, weight: weight)
        if style.contains(.italic) {
            font = font.italic()
        }
        return font
    }
}

// MARK: - MarkdownTableView

private struct MarkdownTableView: View {

    let headers: [[MarkdownInlineRun]]
    let alignments: [MarkdownTableAlignment]
    let rows: [[[MarkdownInlineRun]]]
    let baseFontSize: CGFloat
    let foregroundOpacity: Double

    @Environment(\.colorScheme) private var colorScheme

    private var columnCount: Int {
        max(
            headers.count,
            rows.map(\.count).max() ?? 0
        )
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                if !headers.isEmpty {
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { col in
                            let runs = col < headers.count ? headers[col] : []
                            tableCell(runs: runs, column: col, isHeader: true)
                        }
                    }
                    .background(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.045))
                }

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    Rectangle()
                        .fill(LiquidGlassColors.subtleHairline)
                        .frame(height: LiquidGlassMetrics.hairlineWidth)
                        .gridCellUnsizedAxes(.horizontal)

                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { col in
                            let runs = col < row.count ? row[col] : []
                            tableCell(runs: runs, column: col, isHeader: false)
                        }
                    }
                    .background(
                        rowIndex.isMultiple(of: 2)
                            ? Color.clear
                            : Color.primary.opacity(colorScheme == .dark ? 0.025 : 0.018)
                    )
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LiquidGlassColors.recessedCodeSurface.opacity(0.65))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LiquidGlassColors.subtleHairline, lineWidth: LiquidGlassMetrics.hairlineWidth)
        )
    }

    private func tableCell(runs: [MarkdownInlineRun], column: Int, isHeader: Bool) -> some View {
        let alignment = column < alignments.count ? alignments[column] : .left
        let textAlignment: TextAlignment
        let frameAlignment: Alignment
        switch alignment {
        case .left:
            textAlignment = .leading
            frameAlignment = .leading
        case .center:
            textAlignment = .center
            frameAlignment = .center
        case .right:
            textAlignment = .trailing
            frameAlignment = .trailing
        }

        return MarkdownRichRunsTextView(
            runs: runs,
            fontSize: baseFontSize,
            baseWeight: isHeader ? .semibold : .regular
        )
        .foregroundStyle(Color.primary.opacity(isHeader ? 0.95 : foregroundOpacity))
        .multilineTextAlignment(textAlignment)
        .lineSpacing(3)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: 72, maxWidth: 280, alignment: frameAlignment)
        .padding(.horizontal, 11)
        .padding(.vertical, isHeader ? 8 : 7)
    }
}

// MARK: - MarkdownRichRunsTextView

/// Renders inline runs as a fast single `AttributedString` when no inline LaTeX is present, or
/// seamlessly interpolates baseline-aligned CoreText `SwiftMath` inline glyphs when `.inlineMath`
/// segments occur.
struct MarkdownRichRunsTextView: View {

    let runs: [MarkdownInlineRun]
    let fontSize: CGFloat
    let baseWeight: Font.Weight

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if runs.contains(where: { $0.kind == .inlineMath }) {
            composedMathText
        } else {
            Text(
                MarkdownAttributedStringBuilder.build(
                    from: runs,
                    fontSize: fontSize,
                    baseWeight: baseWeight,
                    colorScheme: colorScheme
                )
            )
        }
    }

    private var composedMathText: Text {
        let isDark = colorScheme == .dark
        var combined = Text(verbatim: "")
        var pendingPlainRuns: [MarkdownInlineRun] = []

        func flushPending() {
            guard !pendingPlainRuns.isEmpty else { return }
            let attr = MarkdownAttributedStringBuilder.build(
                from: pendingPlainRuns,
                fontSize: fontSize,
                baseWeight: baseWeight,
                colorScheme: colorScheme
            )
            combined = Text("\(combined)\(Text(attr))")
            pendingPlainRuns.removeAll(keepingCapacity: true)
        }

        for run in runs {
            if run.kind == .inlineMath,
               let entry = MathRenderCache.shared.renderInline(
                   latex: run.text,
                   fontSize: fontSize + 0.5,
                   isDark: isDark
               ) {
                flushPending()
                let mathSegment = Text(Image(nsImage: entry.image))
                    .baselineOffset(-entry.descent)
                combined = Text("\(combined)\(mathSegment)")
            } else {
                pendingPlainRuns.append(run)
            }
        }
        flushPending()
        return combined
    }
}
