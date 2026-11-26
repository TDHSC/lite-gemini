import AppKit
import SwiftUI

// MARK: - CodeBlockCardView

/// Recessed tonal code block card displaying an optional language header, one-click Copy action
/// with transient confirmation feedback, and horizontally scrollable selectable monospaced code.
struct CodeBlockCardView: View {

    let language: String?
    let code: String
    var isClosed: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var didCopy = false
    @State private var isHoveringCopy = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var highlightedText: AttributedString?
    @State private var highlightedKey: CodeSyntaxCache.Key?

    private static let codeFontSize: CGFloat = 12.5

    private var headerTitle: String {
        if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            return language
        }
        return String(localized: "Code")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            Rectangle()
                .fill(LiquidGlassColors.subtleHairline)
                .frame(height: LiquidGlassMetrics.hairlineWidth)

            ScrollView(.horizontal, showsIndicators: true) {
                codeTextView(for: currentCacheKey)
                    .lineSpacing(3.5)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LiquidGlassColors.recessedCodeSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LiquidGlassColors.subtleHairline, lineWidth: LiquidGlassMetrics.hairlineWidth)
        )
        .task(id: currentCacheKey) {
            await refreshSyntaxHighlight(for: currentCacheKey)
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
    }

    private var currentCacheKey: CodeSyntaxCache.Key {
        CodeSyntaxCache.Key(
            code: code,
            language: language,
            isDark: colorScheme == .dark,
            fontSize: Self.codeFontSize
        )
    }

    @ViewBuilder
    private func codeTextView(for key: CodeSyntaxCache.Key) -> some View {
        if let cached = CodeSyntaxCache.shared.cached(for: key) {
            Text(cached)
        } else if highlightedKey == key, let highlightedText {
            Text(highlightedText)
        } else {
            Text(code.isEmpty ? " " : code)
                .font(.system(size: Self.codeFontSize, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.92))
        }
    }

    private func refreshSyntaxHighlight(for key: CodeSyntaxCache.Key) async {
        guard !code.isEmpty else {
            highlightedText = nil
            highlightedKey = nil
            return
        }
        if let cached = CodeSyntaxCache.shared.cached(for: key) {
            highlightedText = cached
            highlightedKey = key
            return
        }

        if !isClosed {
            do {
                try await Task.sleep(for: .milliseconds(90))
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }

        let source = code
        let lang = language
        let isDark = colorScheme == .dark
        if let result = await CodeSyntaxHighlightEngine.shared.highlight(
            code: source,
            language: lang,
            isDark: isDark,
            fontSize: Self.codeFontSize
        ) {
            guard !Task.isCancelled else { return }
            CodeSyntaxCache.shared.store(result, for: key)
            highlightedText = result
            highlightedKey = key
        }
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !isClosed {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.75)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 8)

            Button(action: copyCode) {
                HStack(spacing: 4) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(didCopy ? Color.green : Color.primary.opacity(isHoveringCopy ? 0.92 : 0.68))

                    Text(didCopy ? "Copied" : "Copy")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(didCopy ? Color.primary.opacity(0.90) : Color.primary.opacity(isHoveringCopy ? 0.92 : 0.72))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minHeight: 28)
                .background(
                    Capsule(style: .continuous)
                        .fill(isHoveringCopy ? LiquidGlassColors.hoverHighlight : Color.clear)
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.14)) {
                    isHoveringCopy = hovering
                }
            }
            .accessibilityLabel(didCopy ? Text("Copied") : Text("Copy Code"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)

        copyResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) {
            didCopy = true
        }
        copyResetTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(1600))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            withAnimation(.easeInOut(duration: 0.18)) {
                didCopy = false
            }
        }
    }
}
