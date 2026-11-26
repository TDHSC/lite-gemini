import AppKit
import SwiftMath
import SwiftUI

// MARK: - MathRenderEntry

/// Cached CoreText-backed vector math image and baseline metrics produced by `SwiftMath`.
struct MathRenderEntry {
    let image: NSImage
    let size: CGSize
    let ascent: CGFloat
    let descent: CGFloat
}

// MARK: - MathRenderCache

/// Memoizes rendered LaTeX equations across `LazyVStack` scroll passes and normalizes common
/// LLM LaTeX macro aliases (`\implies`, `\iff`, `\to`, `\mathbb`, etc.) supported by `SwiftMath`.
@MainActor
final class MathRenderCache {

    static let shared = MathRenderCache()

    private struct CacheKey: Hashable {
        let latex: String
        let fontSizeTenths: Int
        let isDark: Bool
        let isDisplay: Bool
    }

    private enum CachedOutcome {
        case success(MathRenderEntry)
        case unsupported
    }

    private let maxEntries: Int
    private var storage: [CacheKey: CachedOutcome] = [:]
    private var insertionOrder: [CacheKey] = []

    init(maxEntries: Int = 256) {
        self.maxEntries = max(32, maxEntries)
    }

    func renderDisplay(latex: String, fontSize: CGFloat = 15.5, isDark: Bool) -> MathRenderEntry? {
        render(latex: latex, fontSize: fontSize, isDark: isDark, mode: .display)
    }

    func renderInline(latex: String, fontSize: CGFloat, isDark: Bool) -> MathRenderEntry? {
        render(latex: latex, fontSize: fontSize, isDark: isDark, mode: .text)
    }

    private func render(
        latex: String,
        fontSize: CGFloat,
        isDark: Bool,
        mode: MTMathUILabelMode
    ) -> MathRenderEntry? {
        let normalized = Self.normalizeLaTeX(latex)
        guard !normalized.isEmpty else {
            return nil
        }

        let key = CacheKey(
            latex: normalized,
            fontSizeTenths: Int((fontSize * 10).rounded()),
            isDark: isDark,
            isDisplay: mode == .display
        )

        if let cached = storage[key] {
            switch cached {
            case .success(let entry):
                return entry
            case .unsupported:
                return nil
            }
        }

        let textColor = isDark
            ? NSColor(calibratedWhite: 0.94, alpha: 1.0)
            : NSColor(calibratedWhite: 0.10, alpha: 1.0)

        var mathImage = MathImage(
            latex: normalized,
            fontSize: fontSize,
            textColor: textColor,
            labelMode: mode,
            textAlignment: .left
        )
        mathImage.font = .latinModernFont
        mathImage.contentInsets = MTEdgeInsets(
            top: mode == .display ? 4 : 1,
            left: mode == .display ? 2 : 1,
            bottom: mode == .display ? 4 : 1,
            right: mode == .display ? 2 : 1
        )

        let (error, nsImage, layoutInfo) = mathImage.asImage()
        let outcome: CachedOutcome
        if error == nil, let nsImage, nsImage.size.width > 0, nsImage.size.height > 0 {
            let entry = MathRenderEntry(
                image: nsImage,
                size: nsImage.size,
                ascent: layoutInfo?.ascent ?? (nsImage.size.height * 0.75),
                descent: layoutInfo?.descent ?? (nsImage.size.height * 0.25)
            )
            outcome = .success(entry)
        } else {
            outcome = .unsupported
        }

        if storage.count >= maxEntries, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            storage.removeValue(forKey: oldest)
        }
        storage[key] = outcome
        insertionOrder.append(key)

        if case .success(let entry) = outcome {
            return entry
        }
        return nil
    }

    /// Normalizes common LLM LaTeX shorthands into canonical TeX macros understood by `SwiftMath`.
    nonisolated static func normalizeLaTeX(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("$$"), s.hasSuffix("$$"), s.count >= 4 {
            s = String(s.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if s.hasPrefix("\\["), s.hasSuffix("\\]"), s.count >= 4 {
            s = String(s.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if s.hasPrefix("\\("), s.hasSuffix("\\)"), s.count >= 4 {
            s = String(s.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let replacements: [(String, String)] = [
            ("\\implies", "\\Rightarrow"),
            ("\\impliedby", "\\Leftarrow"),
            ("\\iff", "\\Leftrightarrow"),
            ("\\to", "\\rightarrow"),
            ("\\gets", "\\leftarrow"),
            ("\\mapsto", "\\mapsto"),
            ("\\land", "\\wedge"),
            ("\\lor", "\\vee"),
            ("\\lnot", "\\neg"),
            ("\\neq", "\\ne"),
            ("\\leq", "\\le"),
            ("\\geq", "\\ge"),
            ("\\ll", "<"),
            ("\\gg", ">"),
            ("\\approx", "\\approx"),
            ("\\varnothing", "\\emptyset"),
            ("\\dots", "\\ldots"),
            ("\\|\\,", "\\Vert "),
            ("\\|", "\\Vert")
        ]
        for (target, replacement) in replacements where s.contains(target) {
            s = s.replacingOccurrences(of: target, with: replacement)
        }
        return s
    }
}

// MARK: - MathBlockCardView

/// Renders a display `$$...$$` LaTeX block using native CoreText OpenType `MATH` typesetting
/// (`SwiftMath`), falling back seamlessly to monospaced source while streaming (`!isClosed`)
/// or when encountering unsupported custom TeX macros, with a hover Copy LaTeX button.
struct MathBlockCardView: View {

    let latex: String
    let isClosed: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var didCopy = false
    @State private var isHoveringCard = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        let isDark = colorScheme == .dark
        let rendered = isClosed
            ? MathRenderCache.shared.renderDisplay(latex: latex, fontSize: 15.5, isDark: isDark)
            : nil

        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: true) {
                if let rendered {
                    Image(nsImage: rendered.image)
                        .interpolation(.high)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(latex.isEmpty ? " " : latex)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.92))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if isHoveringCard || didCopy {
                Button(action: copyLaTeX) {
                    HStack(spacing: 4) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(didCopy ? Color.green : Color.secondary)
                        Text(didCopy ? "Copied" : "LaTeX")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(LiquidGlassColors.recessedCodeSurface.opacity(0.92))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(LiquidGlassColors.subtleHairline, lineWidth: LiquidGlassMetrics.hairlineWidth)
                    )
                }
                .buttonStyle(.plain)
                .padding(6)
                .transition(.opacity)
                .accessibilityLabel(didCopy ? Text("Copied") : Text("Copy LaTeX"))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LiquidGlassColors.recessedCodeSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LiquidGlassColors.subtleHairline, lineWidth: LiquidGlassMetrics.hairlineWidth)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringCard = hovering
            }
        }
        .contextMenu {
            Button("Copy LaTeX", action: copyLaTeX)
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Math expression: \(latex)"))
    }

    private func copyLaTeX() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latex, forType: .string)

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
}
