import AppKit
import SwiftUI

// MARK: - CodeBlockCardView

/// Recessed tonal code block card displaying an optional language header, one-click Copy action
/// with transient confirmation feedback, and horizontally scrollable selectable monospaced code.
struct CodeBlockCardView: View {

    let language: String?
    let code: String
    var isClosed: Bool = true

    @State private var didCopy = false
    @State private var isHoveringCopy = false
    @State private var copyResetTask: Task<Void, Never>?

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
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.92))
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
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
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
