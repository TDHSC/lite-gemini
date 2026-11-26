import AppKit
import SwiftUI

// MARK: - ShareExportTriggerStyle

/// Visual trigger sizing for `ShareExportMenuButton` across top bar and per-turn footers.
nonisolated enum ShareExportTriggerStyle: Equatable, Sendable {
    /// `28pt` circular Liquid Glass orb matching `ChatTurnRowView`'s action footer buttons.
    case turnFooterOrb
    /// `30pt` circular Liquid Glass orb matching `MainTopBarView`'s floating capsule height.
    case topBarOrb
    /// Compact labeled Liquid Glass capsule trigger.
    case capsule(label: String)
}

// MARK: - ShareExportMenuButton

/// Reusable Liquid Glass Share & Export menu button for full conversations (`MainTopBarView`)
/// or individual assistant turns (`ChatTurnRowView`).
struct ShareExportMenuButton: View {

    var style: ShareExportTriggerStyle = .turnFooterOrb
    var isBusy: Bool = false
    var isShareLinkAvailable: Bool = true
    var hasPythonCode: Bool = false
    var shareLinkLabel: String = String(localized: "Copy Public Share Link")
    var secondaryShareLinkLabel: String = String(localized: "Share This Response")
    var helpText: String = String(localized: "Share & Export")
    var onCreateShareLink: (() -> Void)? = nil
    var onCreateSecondaryShareLink: (() -> Void)? = nil
    var onExportMarkdown: (() -> Void)? = nil
    var onExportPDF: (() -> Void)? = nil
    var onExportGoogleDocs: (() -> Void)? = nil
    var onDraftGmail: (() -> Void)? = nil
    var onOpenGoogleColab: (() -> Void)? = nil

    @State private var isHovering = false

    private var hasShareSection: Bool {
        isShareLinkAvailable && (onCreateShareLink != nil || onCreateSecondaryShareLink != nil)
    }

    private var hasLocalExportSection: Bool {
        onExportMarkdown != nil || onExportPDF != nil
    }

    private var hasCloudExportSection: Bool {
        onExportGoogleDocs != nil
            || onDraftGmail != nil
            || (hasPythonCode && onOpenGoogleColab != nil)
    }

    private var hasAnyAction: Bool {
        hasShareSection || hasLocalExportSection || hasCloudExportSection
    }

    var body: some View {
        Menu {
            if hasShareSection {
                if let onCreateShareLink {
                    Button(action: onCreateShareLink) {
                        Label(shareLinkLabel, systemImage: "link")
                    }
                }

                if let onCreateSecondaryShareLink {
                    Button(action: onCreateSecondaryShareLink) {
                        Label(secondaryShareLinkLabel, systemImage: "link.badge.plus")
                    }
                }
            }

            if hasShareSection && hasLocalExportSection {
                Divider()
            }

            if hasLocalExportSection {
                if let onExportMarkdown {
                    Button(action: onExportMarkdown) {
                        Label("Export Markdown (.md)", systemImage: "doc.plaintext")
                    }
                }

                if let onExportPDF {
                    Button(action: onExportPDF) {
                        Label("Export PDF (.pdf)", systemImage: "doc.richtext")
                    }
                }
            }

            if (hasShareSection || hasLocalExportSection) && hasCloudExportSection {
                Divider()
            }

            if hasCloudExportSection {
                if let onExportGoogleDocs {
                    Button(action: onExportGoogleDocs) {
                        Label("Export to Google Docs", systemImage: "doc.text")
                    }
                }

                if let onDraftGmail {
                    Button(action: onDraftGmail) {
                        Label("Draft in Gmail", systemImage: "envelope")
                    }
                }

                if hasPythonCode, let onOpenGoogleColab {
                    Button(action: onOpenGoogleColab) {
                        Label("Open in Google Colab", systemImage: "terminal")
                    }
                }
            }
        } label: {
            triggerLabel
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isBusy || !hasAnyAction)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .help(helpText)
        .accessibilityLabel(Text(helpText))
    }

    // MARK: - Trigger Label

    @ViewBuilder
    private var triggerLabel: some View {
        switch style {
        case .turnFooterOrb:
            orbTrigger(size: 28, iconSize: 11.5)

        case .topBarOrb:
            orbTrigger(size: LiquidGlassMetrics.topBarCapsuleHeight, iconSize: 12)

        case .capsule(let label):
            HStack(spacing: 5) {
                triggerIcon(size: 11.5)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(isHovering ? 0.96 : 0.84))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: LiquidGlassMetrics.topBarCapsuleHeight)
            .glassCapsule(
                variant: .clear,
                tint: isHovering ? LiquidGlassColors.hoverHighlight : nil,
                interactive: true
            )
            .contentShape(Capsule(style: .continuous))
        }
    }

    private func orbTrigger(size: CGFloat, iconSize: CGFloat) -> some View {
        triggerIcon(size: iconSize)
            .glassOrb(
                size: size,
                variant: .clear,
                tint: isHovering ? LiquidGlassColors.hoverHighlight : nil,
                interactive: true
            )
            .contentShape(Circle())
    }

    @ViewBuilder
    private func triggerIcon(size: CGFloat) -> some View {
        if isBusy {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.75)
        } else {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Color.primary.opacity(isHovering ? 0.94 : 0.72))
        }
    }

    // MARK: - Python Detection Helper

    /// Returns `true` when `markdown` contains at least one fenced Python code block (`python` / `py`).
    nonisolated static func containsPythonCode(in markdown: String) -> Bool {
        guard markdown.contains("```") || markdown.contains("~~~") else {
            return false
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let remainder: Substring
            if trimmed.hasPrefix("```") {
                remainder = trimmed.drop(while: { $0 == "`" })
            } else if trimmed.hasPrefix("~~~") {
                remainder = trimmed.drop(while: { $0 == "~" })
            } else {
                continue
            }

            let infoToken = remainder
                .trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "{" })
                .first?
                .lowercased()

            if infoToken == "python" || infoToken == "py" || infoToken == "python3" {
                return true
            }
        }
        return false
    }
}

// MARK: - ShareLinkBannerPillView

/// Floating Liquid Glass confirmation pill presenting a newly created public Gemini share URL
/// with one-click `Copy` and `Open in Browser` actions.
struct ShareLinkBannerPillView: View {

    let url: URL
    var autoDismissDuration: Duration? = .seconds(8)
    let onDismiss: () -> Void
    var onCopy: ((URL) -> Void)? = nil
    var onOpenInBrowser: ((URL) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHoveringPill = false
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    private var displayURLText: String {
        let absolute = url.absoluteString
        if absolute.hasPrefix("https://") {
            return String(absolute.dropFirst("https://".count))
        }
        if absolute.hasPrefix("http://") {
            return String(absolute.dropFirst("http://".count))
        }
        return absolute
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LiquidGlassColors.sendButtonBlue)
                .accessibilityHidden(true)

            Text(verbatim: displayURLText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.90))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .leading)
                .help(url.absoluteString)

            LiquidGlassContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button(action: copyURL) {
                        HStack(spacing: 4) {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(didCopy ? Color.green : Color.primary.opacity(0.86))
                                .contentTransition(.symbolEffect(.replace))

                            Text(didCopy ? "Copied" : "Copy")
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .controlSize(.small)
                    .liquidGlassButtonStyle(prominent: false)
                    .accessibilityLabel(didCopy ? Text("Copied") : Text("Copy Share Link"))

                    Button(action: openInBrowser) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10.5, weight: .semibold))

                            Text("Open in Browser")
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .controlSize(.small)
                    .liquidGlassButtonStyle(prominent: true, tint: LiquidGlassColors.sendButtonBlue)
                    .accessibilityLabel(Text("Open in Browser"))
                }
            }
            .layoutPriority(1)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Dismiss"))
            .accessibilityLabel(Text("Dismiss"))
        }
        .environment(\.colorScheme, colorScheme)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .glassCapsule(variant: .clear, tint: LiquidGlassColors.clearCardTint)
        .onHover { hovering in
            isHoveringPill = hovering
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
        .task(id: url) {
            guard let autoDismissDuration else {
                return
            }
            var remaining = autoDismissDuration
            let tick: Duration = .milliseconds(100)
            while remaining > .zero {
                do {
                    try await Task.sleep(for: tick)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                if !isHoveringPill {
                    remaining -= tick
                }
            }
            guard !Task.isCancelled else {
                return
            }
            onDismiss()
        }
    }

    // MARK: - Actions

    private func copyURL() {
        if let onCopy {
            onCopy(url)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }

        copyResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.14)) {
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

    private func openInBrowser() {
        if let onOpenInBrowser {
            onOpenInBrowser(url)
        } else {
            NSWorkspace.shared.open(url)
        }
        onDismiss()
    }
}
