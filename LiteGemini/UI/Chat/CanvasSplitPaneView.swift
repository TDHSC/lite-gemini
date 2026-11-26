import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - CanvasPaneTab

/// Active inspection tab inside `CanvasSplitPaneView`.
enum CanvasPaneTab: String, CaseIterable, Identifiable {
    case preview
    case reader
    case source

    var id: String { rawValue }
}

// MARK: - CanvasSplitPaneView

/// Liquid Glass side-by-side workspace pane (or compact narrow-window overlay) displaying
/// Gemini Canvas documents, syntax-highlighted code, sandboxed HTML/SVG live previews,
/// and completed Deep Research reports.
struct CanvasSplitPaneView: View {

    let artifact: ArtifactCardInfo
    var isCompactOverlay: Bool = false
    var onOpenInWebMode: (() -> Void)? = nil
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: CanvasPaneTab = .reader
    @State private var didInitializeTabForId: String?
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    private var availableTabs: [CanvasPaneTab] {
        if artifact.supportsLiveWebPreview {
            return [.preview, .source]
        }
        if artifact.isCodeWorkspace {
            return [.source]
        }
        return [.reader, .source]
    }

    private var defaultTab: CanvasPaneTab {
        if artifact.supportsLiveWebPreview {
            return .preview
        }
        if artifact.isCodeWorkspace {
            return .source
        }
        return .reader
    }

    private var rawSourceText: String {
        if let content = artifact.content, !content.isEmpty {
            return content
        }
        return artifact.htmlPreviewContent ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            paneHeaderBar

            Rectangle()
                .fill(LiquidGlassColors.subtleHairline)
                .frame(height: LiquidGlassMetrics.hairlineWidth)

            paneBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            ZStack {
                WindowBackdropView()
                Color.primary.opacity(colorScheme == .dark ? 0.025 : 0.015)
            }
        )
        .overlay(alignment: .leading) {
            if !isCompactOverlay {
                Rectangle()
                    .fill(LiquidGlassColors.subtleHairline)
                    .frame(width: LiquidGlassMetrics.hairlineWidth)
            }
        }
        .onAppear {
            syncInitialTabIfNeeded()
        }
        .onChange(of: artifact.id) { _, _ in
            syncInitialTabIfNeeded()
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
    }

    // MARK: - Header Bar

    private var paneHeaderBar: some View {
        HStack(spacing: 10) {
            if isCompactOverlay {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .glassOrb(size: 28, variant: .clear, interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close Canvas"))
            }

            Image(systemName: artifact.kind == .deepResearch ? "text.magnifyingglass" : "doc.richtext")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.sendButtonBlue)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let subtitle = artifact.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if availableTabs.count > 1 {
                tabSwitcherCapsule
            }

            LiquidGlassContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button(action: copySource) {
                        HStack(spacing: 4) {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(didCopy ? Color.green : Color.primary.opacity(0.84))
                            if !isCompactOverlay {
                                Text(didCopy ? "Copied" : "Copy")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Color.primary.opacity(0.86))
                                    .lineLimit(1)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, isCompactOverlay ? 8 : 9)
                        .frame(height: 28)
                        .glassCapsule(variant: .clear, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Copy"))
                    .accessibilityLabel(didCopy ? Text("Copied") : Text("Copy"))

                    Button(action: exportArtifactToFile) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.84))
                            .frame(width: 28, height: 28)
                            .glassOrb(size: 28, variant: .clear, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Export File…"))
                    .accessibilityLabel(Text("Export File…"))

                    if let onOpenInWebMode {
                        Button(action: onOpenInWebMode) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.80))
                                .frame(width: 28, height: 28)
                                .glassOrb(size: 28, variant: .clear, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Open in Web ↗"))
                        .accessibilityLabel(Text("Open in Web ↗"))
                    }

                    if !isCompactOverlay {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .glassOrb(size: 28, variant: .clear, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Close"))
                        .accessibilityLabel(Text("Close Canvas"))
                    }
                }
            }
        }
        .padding(.leading, isCompactOverlay ? 80 : 14)
        .padding(.trailing, 14)
        .frame(height: LiquidGlassMetrics.topBarHeight)
        .background {
            if !isCompactOverlay {
                WindowDragArea()
            }
        }
    }

    private var tabSwitcherCapsule: some View {
        HStack(spacing: 2) {
            ForEach(availableTabs) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tabTitle(for: tab))
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10) : Color.clear)
                        )
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassCapsule(variant: .clear, interactive: true)
    }

    private func tabTitle(for tab: CanvasPaneTab) -> LocalizedStringKey {
        switch tab {
        case .preview:
            return "Preview"
        case .reader:
            return "Reader"
        case .source:
            return artifact.isCodeWorkspace || artifact.supportsLiveWebPreview ? "Code" : "Markdown"
        }
    }

    // MARK: - Pane Body

    @ViewBuilder
    private var paneBody: some View {
        switch selectedTab {
        case .preview:
            SandboxedHTMLPreviewView(
                htmlOrSVG: artifact.htmlPreviewContent ?? rawSourceText,
                language: artifact.normalizedLanguage,
                isDark: colorScheme == .dark
            )

        case .reader:
            ScrollView(.vertical, showsIndicators: true) {
                MarkdownContentView(
                    markdown: rawSourceText,
                    turnId: "canvas-\(artifact.id)",
                    partIndex: 0,
                    baseFontSize: 14
                )
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .source:
            ScrollView(.vertical, showsIndicators: true) {
                CodeBlockCardView(
                    language: artifact.normalizedLanguage ?? (artifact.isCodeWorkspace ? nil : "markdown"),
                    code: rawSourceText,
                    isClosed: true
                )
                .padding(16)
            }
        }
    }

    // MARK: - Actions

    private func syncInitialTabIfNeeded() {
        if didInitializeTabForId != artifact.id || !availableTabs.contains(selectedTab) {
            didInitializeTabForId = artifact.id
            selectedTab = defaultTab
        }
    }

    private func copySource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawSourceText, forType: .string)

        copyResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.14)) {
            didCopy = true
        }
        copyResetTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                didCopy = false
            }
        }
    }

    private func exportArtifactToFile() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let sanitizedTitle = artifact.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = sanitizedTitle.isEmpty ? "Canvas" : sanitizedTitle
        let ext = artifact.suggestedFileExtension
        panel.nameFieldStringValue = baseName.lowercased().hasSuffix(".\(ext)") ? baseName : "\(baseName).\(ext)"

        let textToSave = rawSourceText
        let writeBlock: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let targetURL = panel.url else { return }
            try? Data(textToSave.utf8).write(to: targetURL, options: [.atomic])
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: writeBlock)
        } else {
            panel.begin(completionHandler: writeBlock)
        }
    }
}

// MARK: - SandboxedHTMLPreviewView

/// Strictly isolated, cookie-free `WKWebView` (`WKWebsiteDataStore.nonPersistent()`) rendering
/// HTML, CSS, JavaScript, and raw SVG Canvas previews locally while blocking external navigations.
struct SandboxedHTMLPreviewView: NSViewRepresentable {

    let htmlOrSVG: String
    let language: String?
    let isDark: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        let document = Self.wrapDocument(raw: htmlOrSVG, language: language, isDark: isDark)
        context.coordinator.lastLoadedHTML = document
        webView.loadHTMLString(document, baseURL: URL(string: "about:blank"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let document = Self.wrapDocument(raw: htmlOrSVG, language: language, isDark: isDark)
        guard context.coordinator.lastLoadedHTML != document else {
            return
        }
        context.coordinator.lastLoadedHTML = document
        webView.loadHTMLString(document, baseURL: URL(string: "about:blank"))
    }

    private static func wrapDocument(raw: String, language: String?, isDark: Bool) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") {
            return raw
        }

        let bg = isDark ? "#16171a" : "#ffffff"
        let fg = isDark ? "#eceef2" : "#181a1f"
        let isSVG = language == "svg" || lower.hasPrefix("<svg")

        if isSVG {
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              html, body {
                margin: 0; padding: 16px; min-height: 100%;
                background: \(bg); color: \(fg);
                display: flex; align-items: center; justify-content: center;
                box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, sans-serif;
              }
              svg { max-width: 100%; height: auto; }
            </style>
            </head>
            <body>\(raw)</body>
            </html>
            """
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html, body {
            margin: 0; padding: 16px;
            background: \(bg); color: \(fg);
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
          }
        </style>
        </head>
        <body>\(raw)</body>
        </html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {

        var lastLoadedHTML: String = ""

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
            if scheme == "applewebdata" || scheme == "about" || scheme == "data" || scheme == "blob" {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               (scheme == "https" || scheme == "http") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
