import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit
import os

// MARK: - ConversationDocumentExporter

/// Native Markdown (`.md`) and paginated PDF (`.pdf`) document exporter for conversations and single turns.
///
/// Generates zero-network Markdown directly from `ChatTurn` models and renders clean, XSS-safe
/// typographic HTML inside an offscreen sandboxed `WKWebView` (`WKWebsiteDataStore.nonPersistent()`)
/// to produce crisp paginated PDF output via `WKWebView.pdf(configuration:)`.
@MainActor
enum ConversationDocumentExporter {

    private static let logger = Logger(
        subsystem: "io.github.tdhsc.LiteGemini",
        category: "ConversationDocumentExporter"
    )

    // MARK: - Markdown Formatting

    /// Formats an entire conversation (`1..N` turns) into a clean, portable Markdown document.
    nonisolated static func formatConversationMarkdown(
        title: String,
        conversationId: String?,
        turns: [ChatTurn]
    ) -> String {
        let resolvedTitle = resolvedDocumentTitle(title, fallback: turns.first?.userPrompt)
        var sections: [String] = ["# \(resolvedTitle)"]

        if let convId = conversationId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !convId.isEmpty {
            sections.append("> Conversation ID: `\(convId)`")
        }

        let formattedTurns = turns.map { formatTurnBodyMarkdown($0) }.filter { !$0.isEmpty }
        if !formattedTurns.isEmpty {
            sections.append(formattedTurns.joined(separator: "\n\n---\n\n"))
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    /// Formats a single prompt-and-response turn into a standalone Markdown document.
    nonisolated static func formatTurnMarkdown(
        title: String,
        turn: ChatTurn
    ) -> String {
        let resolvedTitle = resolvedDocumentTitle(title, fallback: turn.userPrompt)
        var sections: [String] = ["# \(resolvedTitle)"]

        let body = formatTurnBodyMarkdown(turn)
        if !body.isEmpty {
            sections.append(body)
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Save Panels

    /// Presents a native macOS `NSSavePanel` to save Markdown text to a `.md` file.
    static func saveMarkdownPanel(defaultFilename: String, markdown: String) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        var allowedTypes: [UTType] = []
        if let markdownType = UTType(filenameExtension: "md") {
            allowedTypes.append(markdownType)
        }
        allowedTypes.append(.plainText)
        panel.allowedContentTypes = allowedTypes
        panel.nameFieldStringValue = sanitizedFilename(
            from: defaultFilename,
            fallback: "Gemini Chat",
            fileExtension: "md"
        )

        let payload = Data(markdown.utf8)
        let completion: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let targetURL = panel.url else {
                return
            }
            do {
                try payload.write(to: targetURL, options: [.atomic])
            } catch {
                Self.logger.error("Failed to write exported Markdown: \(error.localizedDescription, privacy: .public)")
            }
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    /// Renders `turns` into a styled offscreen sandboxed `WKWebView`, generates paginated PDF bytes,
    /// and presents an `NSSavePanel` to write the `.pdf` document to disk.
    static func exportPDFPanel(
        title: String,
        conversationId: String?,
        turns: [ChatTurn]
    ) async {
        do {
            let pdfData = try await renderPDFData(
                title: title,
                conversationId: conversationId,
                turns: turns
            )
            guard !pdfData.isEmpty else {
                return
            }

            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = sanitizedFilename(
                from: resolvedDocumentTitle(title, fallback: turns.first?.userPrompt),
                fallback: "Gemini Chat",
                fileExtension: "pdf"
            )

            await presentSavePanel(panel, data: pdfData)
        } catch {
            Self.logger.error("Failed to export conversation PDF: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Convenience wrapper exporting a single `ChatTurn` to PDF via `exportPDFPanel`.
    static func exportTurnPDFPanel(title: String, turn: ChatTurn) async {
        await exportPDFPanel(title: title, conversationId: nil, turns: [turn])
    }

    // MARK: - Offscreen Sandboxed PDF Rendering

    /// Generates paginated PDF bytes from `turns` inside an isolated cookie-free `WKWebView`.
    static func renderPDFData(
        title: String,
        conversationId: String?,
        turns: [ChatTurn]
    ) async throws -> Data {
        let html = renderPrintableHTML(
            title: title,
            conversationId: conversationId,
            turns: turns
        )

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        // Standard US Letter page width (`612pt`) offscreen viewport; `WKPDFConfiguration.rect == nil`
        // tells WebKit to capture the complete document height.
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 612, height: 792),
            configuration: config
        )
        let loaderDelegate = OffscreenHTMLNavigationDelegate()
        webView.navigationDelegate = loaderDelegate

        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }

        try await loaderDelegate.loadHTML(html, in: webView)

        let pdfConfiguration = WKPDFConfiguration()
        return try await webView.pdf(configuration: pdfConfiguration)
    }

    /// Builds a self-contained, XSS-safe printable HTML document from `ChatTurn` models.
    nonisolated static func renderPrintableHTML(
        title: String,
        conversationId: String?,
        turns: [ChatTurn]
    ) -> String {
        let resolvedTitle = resolvedDocumentTitle(title, fallback: turns.first?.userPrompt)
        let escapedTitle = escapeHTML(resolvedTitle)

        let timestampFormatter = DateFormatter()
        timestampFormatter.dateStyle = .medium
        timestampFormatter.timeStyle = .short
        let exportedDateString = escapeHTML(timestampFormatter.string(from: Date()))

        var metaParts: [String] = ["Exported \(exportedDateString)"]
        if let convId = conversationId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !convId.isEmpty {
            metaParts.append("ID: <code>\(escapeHTML(convId))</code>")
        }

        var turnsHTML = ""
        for (index, turn) in turns.enumerated() {
            turnsHTML += renderTurnHTML(turn, turnNumber: index + 1)
        }

        if turnsHTML.isEmpty {
            turnsHTML = "<p class=\"empty-note\">No messages in this conversation.</p>"
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>\(escapedTitle)</title>
        <style>
          @page {
            size: auto;
            margin: 18mm 16mm;
          }
          * {
            box-sizing: border-box;
          }
          html, body {
            margin: 0;
            padding: 0;
            background: #ffffff;
            color: #181a1f;
            font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Helvetica Neue", sans-serif;
            font-size: 13px;
            line-height: 1.62;
            -webkit-font-smoothing: antialiased;
          }
          .document {
            max-width: 580pt;
            margin: 0 auto;
            padding: 20pt 18pt 28pt;
          }
          .doc-header {
            border-bottom: 1px solid #e4e6ec;
            padding-bottom: 12pt;
            margin-bottom: 18pt;
          }
          .doc-title {
            margin: 0 0 6pt 0;
            font-size: 20px;
            font-weight: 700;
            letter-spacing: -0.02em;
            color: #111318;
            line-height: 1.28;
          }
          .doc-meta {
            font-size: 11px;
            color: #666c78;
          }
          .doc-meta code {
            font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
            font-size: 10.5px;
            background: #f2f4f8;
            padding: 1px 5px;
            border-radius: 4px;
            color: #3a404c;
          }
          .turn {
            margin-bottom: 20pt;
            padding-bottom: 16pt;
            border-bottom: 1px solid #edf0f5;
          }
          .turn:last-child {
            border-bottom: none;
            margin-bottom: 0;
          }
          .prompt-block {
            background: #f5f7fb;
            border: 1px solid #e6eaf2;
            border-radius: 10px;
            padding: 10pt 12pt;
            margin-bottom: 12pt;
            break-inside: avoid;
          }
          .role-label {
            font-size: 10.5px;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: #5b6372;
            margin-bottom: 5pt;
          }
          .role-label.assistant {
            color: #1a64e6;
          }
          .prompt-text {
            margin: 0;
            white-space: pre-wrap;
            word-break: break-word;
            color: #15181e;
            font-size: 13px;
            line-height: 1.56;
          }
          .attachments {
            margin-top: 7pt;
            display: flex;
            flex-wrap: wrap;
            gap: 5pt;
          }
          .attachment-pill {
            display: inline-block;
            font-size: 10.5px;
            color: #464e5d;
            background: #ebeff7;
            border: 1px solid #dce2ee;
            border-radius: 999px;
            padding: 2px 8px;
          }
          .assistant-block {
            padding: 2pt 2pt 0;
          }
          h1, h2, h3, h4, h5, h6 {
            color: #111318;
            margin: 14pt 0 6pt;
            line-height: 1.32;
            page-break-after: avoid;
            break-after: avoid;
          }
          h1 { font-size: 17px; font-weight: 700; }
          h2 { font-size: 15px; font-weight: 650; }
          h3 { font-size: 13.8px; font-weight: 650; }
          h4, h5, h6 { font-size: 13px; font-weight: 600; }
          p {
            margin: 0 0 8pt;
            word-break: break-word;
          }
          ul, ol {
            margin: 4pt 0 10pt;
            padding-left: 18pt;
          }
          li {
            margin-bottom: 4pt;
          }
          blockquote {
            margin: 8pt 0 10pt;
            padding: 4pt 0 4pt 11pt;
            border-left: 3px solid #cfd6e4;
            color: #48505f;
          }
          code {
            font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
            font-size: 11.5px;
            background: #f3f5f9;
            padding: 1px 4px;
            border-radius: 4px;
            color: #1f2430;
          }
          .code-card {
            margin: 10pt 0;
            border: 1px solid #e1e5ee;
            border-radius: 8px;
            overflow: hidden;
            background: #f8f9fc;
            break-inside: avoid;
          }
          .code-header {
            background: #eff2f7;
            border-bottom: 1px solid #e1e5ee;
            padding: 4pt 10pt;
            font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
            font-size: 10.5px;
            font-weight: 600;
            color: #5a6272;
          }
          pre {
            margin: 0;
            padding: 9pt 10pt;
            overflow-x: auto;
            white-space: pre-wrap;
            word-break: break-word;
            font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
            font-size: 11.2px;
            line-height: 1.52;
            color: #181c24;
          }
          pre code {
            background: none;
            padding: 0;
            border-radius: 0;
            font-size: inherit;
          }
          table {
            width: 100%;
            border-collapse: collapse;
            margin: 10pt 0;
            font-size: 12px;
            break-inside: avoid;
          }
          th, td {
            border: 1px solid #dde2ec;
            padding: 6pt 8pt;
            vertical-align: top;
          }
          th {
            background: #f3f5fa;
            font-weight: 600;
            color: #161920;
          }
          tr:nth-child(even) td {
            background: #fafbfd;
          }
          .math-block {
            margin: 10pt 0;
            padding: 8pt 12pt;
            background: #f6f8fd;
            border: 1px solid #dfe6f5;
            border-radius: 8px;
            font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
            font-size: 11.5px;
            white-space: pre-wrap;
            word-break: break-word;
            break-inside: avoid;
          }
          .inline-math {
            font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
            font-size: 11.5px;
            background: #eef3fd;
            padding: 1px 4px;
            border-radius: 4px;
            color: #1d3c78;
          }
          hr {
            border: none;
            border-top: 1px solid #e4e7ef;
            margin: 12pt 0;
          }
          a {
            color: #135ce0;
            text-decoration: underline;
          }
          .artifact-card {
            margin: 10pt 0;
            border: 1px solid #dfe4ef;
            border-radius: 8px;
            padding: 9pt 11pt;
            background: #fafbfe;
            break-inside: avoid;
          }
          .artifact-title {
            font-weight: 600;
            font-size: 12.5px;
            margin-bottom: 4pt;
            color: #151820;
          }
          .citations {
            margin-top: 10pt;
            padding-top: 7pt;
            border-top: 1px dashed #e2e6ef;
            font-size: 11px;
            color: #596070;
          }
          .citations-title {
            font-weight: 600;
            margin-bottom: 4pt;
          }
          .citations ul {
            margin: 0;
            padding-left: 14pt;
          }
          .citations li {
            margin-bottom: 2pt;
          }
          .empty-note {
            color: #6b7280;
            font-style: italic;
          }
        </style>
        </head>
        <body>
          <main class="document">
            <header class="doc-header">
              <h1 class="doc-title">\(escapedTitle)</h1>
              <div class="doc-meta">\(metaParts.joined(separator: " &middot; "))</div>
            </header>
            \(turnsHTML)
          </main>
        </body>
        </html>
        """
    }

    /// Sanitizes an arbitrary conversation title into a safe filename ending with `.<fileExtension>`.
    nonisolated static func sanitizedFilename(
        from rawTitle: String,
        fallback: String = "Gemini Chat",
        fileExtension: String
    ) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\\*?\"<>|\n\r\t")
        let stripped = rawTitle
            .components(separatedBy: disallowed)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let collapsed = stripped
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        let base: String
        if collapsed.isEmpty {
            base = fallback
        } else if collapsed.count > 80 {
            base = String(collapsed.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            base = collapsed
        }

        let suffix = ".\(fileExtension.lowercased())"
        return base.lowercased().hasSuffix(suffix) ? base : "\(base)\(suffix)"
    }

    // MARK: - Private Markdown Helpers

    private nonisolated static func formatTurnBodyMarkdown(_ turn: ChatTurn) -> String {
        var blocks: [String] = []

        let trimmedPrompt = turn.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty || !turn.userAttachments.isEmpty {
            var userSection = "**User**"
            if !turn.userAttachments.isEmpty {
                let attachmentNames = turn.userAttachments.map(\.filename).joined(separator: ", ")
                userSection += "\n\n_Attachments: \(attachmentNames)_"
            }
            if !trimmedPrompt.isEmpty {
                userSection += "\n\n\(trimmedPrompt)"
            }
            blocks.append(userSection)
        }

        var assistantSegments: [String] = []
        for part in turn.assistantParts {
            switch part {
            case .markdown(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    assistantSegments.append(trimmed)
                }

            case .inlineImage(let image):
                let alt = (image.altText?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? image.suggestedFilename
                assistantSegments.append("![\(alt)](\(image.url.absoluteString))")

            case .unsupportedArtifact(let card):
                if let content = card.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !content.isEmpty {
                    if card.isCodeWorkspace {
                        let lang = card.normalizedLanguage ?? ""
                        assistantSegments.append("### \(card.title)\n\n```\(lang)\n\(content)\n```")
                    } else {
                        assistantSegments.append("### \(card.title)\n\n\(content)")
                    }
                } else {
                    assistantSegments.append("> Artifact: \(card.title)")
                }
            }
        }

        if !assistantSegments.isEmpty {
            blocks.append("**Gemini**\n\n" + assistantSegments.joined(separator: "\n\n"))
        }

        if !turn.citations.isEmpty {
            let citationLines = turn.citations.map { citation -> String in
                let label = citation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (citation.resolvedDomain ?? citation.url.absoluteString)
                    : citation.title
                return "- [\(label)](\(citation.url.absoluteString))"
            }
            blocks.append("**Sources**\n\n" + citationLines.joined(separator: "\n"))
        }

        return blocks.joined(separator: "\n\n")
    }

    private nonisolated static func resolvedDocumentTitle(_ title: String, fallback: String?) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if let fallback {
            let firstLine = fallback
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? ""
            if !firstLine.isEmpty {
                return firstLine.count > 72 ? String(firstLine.prefix(72)) + "…" : firstLine
            }
        }
        return "Gemini Conversation"
    }

    // MARK: - Private HTML Builders

    private nonisolated static func renderTurnHTML(_ turn: ChatTurn, turnNumber: Int) -> String {
        var html = "<section class=\"turn\" data-turn=\"\(turnNumber)\">"

        let trimmedPrompt = turn.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty || !turn.userAttachments.isEmpty {
            html += "<div class=\"prompt-block\">"
            html += "<div class=\"role-label\">User</div>"
            if !trimmedPrompt.isEmpty {
                html += "<p class=\"prompt-text\">\(escapeHTML(trimmedPrompt))</p>"
            }
            if !turn.userAttachments.isEmpty {
                html += "<div class=\"attachments\">"
                for attachment in turn.userAttachments {
                    html += "<span class=\"attachment-pill\">\(escapeHTML(attachment.filename))</span>"
                }
                html += "</div>"
            }
            html += "</div>"
        }

        var assistantBodyHTML = ""
        for part in turn.assistantParts {
            switch part {
            case .markdown(let markdown):
                let blocks = IncrementalMarkdownParser.parse(markdown)
                assistantBodyHTML += renderMarkdownBlocksHTML(blocks)

            case .inlineImage(let image):
                let label = (image.altText?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? image.suggestedFilename
                if let href = sanitizedLinkHref(image.url) {
                    assistantBodyHTML += "<p><a href=\"\(escapeHTML(href))\">[Image: \(escapeHTML(label))]</a></p>"
                } else {
                    assistantBodyHTML += "<p>[Image: \(escapeHTML(label))]</p>"
                }

            case .unsupportedArtifact(let card):
                assistantBodyHTML += renderArtifactHTML(card)
            }
        }

        if !assistantBodyHTML.isEmpty || !turn.citations.isEmpty {
            html += "<div class=\"assistant-block\">"
            html += "<div class=\"role-label assistant\">Gemini</div>"
            html += assistantBodyHTML

            if !turn.citations.isEmpty {
                html += "<div class=\"citations\"><div class=\"citations-title\">Sources</div><ul>"
                for citation in turn.citations {
                    let displayTitle = citation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? (citation.resolvedDomain ?? citation.url.absoluteString)
                        : citation.title
                    if let href = sanitizedLinkHref(citation.url) {
                        html += "<li><a href=\"\(escapeHTML(href))\">\(escapeHTML(displayTitle))</a></li>"
                    } else {
                        html += "<li>\(escapeHTML(displayTitle))</li>"
                    }
                }
                html += "</ul></div>"
            }
            html += "</div>"
        }

        html += "</section>"
        return html
    }

    private nonisolated static func renderArtifactHTML(_ card: ArtifactCardInfo) -> String {
        var html = "<div class=\"artifact-card\">"
        html += "<div class=\"artifact-title\">\(escapeHTML(card.title))</div>"
        if let content = card.content?.trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            if card.isCodeWorkspace {
                let langLabel = escapeHTML(card.normalizedLanguage ?? "code")
                html += """
                <div class="code-card">
                  <div class="code-header">\(langLabel)</div>
                  <pre><code>\(escapeHTML(content))</code></pre>
                </div>
                """
            } else {
                let blocks = IncrementalMarkdownParser.parse(content)
                html += renderMarkdownBlocksHTML(blocks)
            }
        } else if let subtitle = card.subtitle, !subtitle.isEmpty {
            html += "<p>\(escapeHTML(subtitle))</p>"
        }
        html += "</div>"
        return html
    }

    private nonisolated static func renderMarkdownBlocksHTML(_ blocks: [MarkdownBlock]) -> String {
        var html = ""
        for block in blocks {
            switch block.kind {
            case .heading(let level, let runs):
                let clampedLevel = min(max(level, 1), 6)
                html += "<h\(clampedLevel)>\(renderInlineRunsHTML(runs))</h\(clampedLevel)>"

            case .paragraph(let runs):
                html += "<p>\(renderInlineRunsHTML(runs))</p>"

            case .list(let ordered, let startIndex, let items):
                let tag = ordered ? "ol" : "ul"
                let startAttr = (ordered && startIndex != 1) ? " start=\"\(startIndex)\"" : ""
                html += "<\(tag)\(startAttr)>"
                for item in items {
                    let prefix: String
                    switch item.taskState {
                    case .checked:
                        prefix = "&#9745; "
                    case .unchecked:
                        prefix = "&#9744; "
                    case .none:
                        prefix = ""
                    }
                    html += "<li>\(prefix)\(renderMarkdownBlocksHTML(item.blocks))</li>"
                }
                html += "</\(tag)>"

            case .blockquote(let innerBlocks):
                html += "<blockquote>\(renderMarkdownBlocksHTML(innerBlocks))</blockquote>"

            case .codeBlock(let language, let code, _):
                let langLabel = escapeHTML(
                    (language?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                        $0.isEmpty ? nil : $0
                    } ?? "Code"
                )
                html += """
                <div class="code-card">
                  <div class="code-header">\(langLabel)</div>
                  <pre><code>\(escapeHTML(code))</code></pre>
                </div>
                """

            case .table(let headers, let alignments, let rows):
                html += renderTableHTML(headers: headers, alignments: alignments, rows: rows)

            case .mathBlock(let latex, _):
                html += "<div class=\"math-block\">\(escapeHTML(latex))</div>"

            case .thematicBreak:
                html += "<hr>"
            }
        }
        return html
    }

    private nonisolated static func renderTableHTML(
        headers: [[MarkdownInlineRun]],
        alignments: [MarkdownTableAlignment],
        rows: [[[MarkdownInlineRun]]]
    ) -> String {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else {
            return ""
        }

        func alignmentStyle(for column: Int) -> String {
            let align = column < alignments.count ? alignments[column] : .left
            switch align {
            case .left:
                return "text-align:left;"
            case .center:
                return "text-align:center;"
            case .right:
                return "text-align:right;"
            }
        }

        var html = "<table>"
        if !headers.isEmpty {
            html += "<thead><tr>"
            for col in 0..<columnCount {
                let runs = col < headers.count ? headers[col] : []
                html += "<th style=\"\(alignmentStyle(for: col))\">\(renderInlineRunsHTML(runs))</th>"
            }
            html += "</tr></thead>"
        }

        if !rows.isEmpty {
            html += "<tbody>"
            for row in rows {
                html += "<tr>"
                for col in 0..<columnCount {
                    let runs = col < row.count ? row[col] : []
                    html += "<td style=\"\(alignmentStyle(for: col))\">\(renderInlineRunsHTML(runs))</td>"
                }
                html += "</tr>"
            }
            html += "</tbody>"
        }

        html += "</table>"
        return html
    }

    private nonisolated static func renderInlineRunsHTML(_ runs: [MarkdownInlineRun]) -> String {
        var html = ""
        for run in runs {
            var segment: String
            switch run.kind {
            case .text:
                segment = escapeHTML(run.text).replacingOccurrences(of: "\n", with: "<br>")
            case .inlineCode:
                segment = "<code>\(escapeHTML(run.text))</code>"
            case .inlineMath:
                segment = "<span class=\"inline-math\">\(escapeHTML(run.text))</span>"
            }

            if run.style.contains(.bold) {
                segment = "<strong>\(segment)</strong>"
            }
            if run.style.contains(.italic) {
                segment = "<em>\(segment)</em>"
            }
            if run.style.contains(.strikethrough) {
                segment = "<del>\(segment)</del>"
            }
            if let linkURL = run.linkURL, let safeHref = sanitizedLinkHref(linkURL) {
                segment = "<a href=\"\(escapeHTML(safeHref))\">\(segment)</a>"
            }

            html += segment
        }
        return html
    }

    private nonisolated static func escapeHTML(_ text: String) -> String {
        var escaped = String()
        escaped.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&":
                escaped.append("&amp;")
            case "<":
                escaped.append("&lt;")
            case ">":
                escaped.append("&gt;")
            case "\"":
                escaped.append("&quot;")
            case "'":
                escaped.append("&#39;")
            default:
                escaped.append(ch)
            }
        }
        return escaped
    }

    private nonisolated static func sanitizedLinkHref(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" || scheme == "mailto" else {
            return nil
        }
        return url.absoluteString
    }

    // MARK: - Private Panel Helper

    private static func presentSavePanel(_ panel: NSSavePanel, data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let completion: @MainActor (NSApplication.ModalResponse) -> Void = { response in
                if response == .OK, let targetURL = panel.url {
                    do {
                        try data.write(to: targetURL, options: [.atomic])
                    } catch {
                        Self.logger.error("Failed to write exported PDF: \(error.localizedDescription, privacy: .public)")
                    }
                }
                continuation.resume()
            }

            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
    }
}

// MARK: - OffscreenHTMLNavigationDelegate

/// `@MainActor` navigation delegate that awaits static HTML load completion inside an offscreen
/// sandboxed `WKWebView` while blocking all external network navigation requests.
@MainActor
private final class OffscreenHTMLNavigationDelegate: NSObject, WKNavigationDelegate {

    private var continuation: CheckedContinuation<Void, any Error>?

    func loadHTML(_ html: String, in webView: WKWebView) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "applewebdata" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeOnce(with: .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        resumeOnce(with: .failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        resumeOnce(with: .failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resumeOnce(
            with: .failure(
                NSError(
                    domain: "ConversationDocumentExporter",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Offscreen PDF renderer terminated unexpectedly."]
                )
            )
        )
    }

    private func resumeOnce(with result: Result<Void, any Error>) {
        guard let pending = continuation else {
            return
        }
        continuation = nil
        pending.resume(with: result)
    }
}
