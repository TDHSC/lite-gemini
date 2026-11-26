import AppKit
import SwiftUI

// MARK: - ChatTurnRowView

/// Renders a single user prompt + assistant response pair inside `ConversationTimelineView`.
///
/// User turns appear as borderless tonal bubbles (`20pt` continuous corners with `6pt`
/// bottom-trailing corner, capped at ~82% container width) with compact attachment summary chips
/// above the bubble. Assistant turns render directly on the canvas with `MonochromeSparkShape`,
/// inline `ThinkingDisclosureView`, memoized `MarkdownContentView`, `InlineImageGalleryView`,
/// `ArtifactFallbackCardView`, and a unified single-row Turn Footer combining actions and citations.
struct ChatTurnRowView: View {

    let turn: ChatTurn
    let containerWidth: CGFloat
    let isLatestTurn: Bool
    let isStreaming: Bool
    let canEdit: Bool
    let canRegenerate: Bool
    var onEdit: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    var onOpenInWebMode: (() -> Void)? = nil
    var onSaveInlineImage: ((ImageAttachment) -> Void)? = nil

    @State private var isHoveringRow = false
    @State private var didCopyResponse = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var awaitingPulseOpacity: Double = 0.45

    private var userBubbleMaxWidth: CGFloat {
        max(200, containerWidth * 0.82)
    }

    private var trimmedUserPrompt: String {
        turn.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasThinkingContent: Bool {
        if let thinking = turn.thinkingText,
           !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    private var isAwaitingFirstVisibleContent: Bool {
        isStreaming && turn.assistantParts.isEmpty && !hasThinkingContent
    }

    private var renderedSegments: [RenderedAssistantSegment] {
        Self.buildSegments(from: turn.assistantParts)
    }

    private var shouldShowFooter: Bool {
        guard !isStreaming else {
            return false
        }
        return !turn.assistantMarkdown.isEmpty
            || !turn.citations.isEmpty
            || (isLatestTurn && (canEdit || canRegenerate))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            userTurnSection
            assistantTurnSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringRow = hovering
            }
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
        .task(id: isAwaitingFirstVisibleContent) {
            guard isAwaitingFirstVisibleContent else {
                awaitingPulseOpacity = 1.0
                return
            }
            awaitingPulseOpacity = 0.40
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                awaitingPulseOpacity = 0.95
            }
        }
    }

    // MARK: - User Turn

    private var userTurnSection: some View {
        HStack(spacing: 0) {
            Spacer(minLength: max(24, containerWidth * 0.14))

            VStack(alignment: .trailing, spacing: 6) {
                if !turn.userAttachments.isEmpty {
                    userAttachmentChips
                }

                if !trimmedUserPrompt.isEmpty {
                    Text(turn.userPrompt)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.94))
                        .lineSpacing(3.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 20,
                                bottomLeadingRadius: 20,
                                bottomTrailingRadius: 6,
                                topTrailingRadius: 20,
                                style: .continuous
                            )
                            .fill(LiquidGlassColors.userBubbleFill)
                        )
                }
            }
            .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
        }
    }

    private var userAttachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(turn.userAttachments) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: attachment.isImage ? "photo" : "doc")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text(attachment.filename)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.86))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 160, alignment: .leading)

                        if attachment.byteCount > 0 {
                            Text(formattedByteCount(attachment.byteCount))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(LiquidGlassColors.userBubbleFill.opacity(0.85))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(LiquidGlassColors.subtleHairline, lineWidth: LiquidGlassMetrics.hairlineWidth)
                    )
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Assistant Turn

    private var assistantTurnSection: some View {
        HStack(alignment: .top, spacing: 10) {
            MonochromeSparkShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.88),
                            Color.primary.opacity(0.46)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 14, height: 14)
                .opacity(isAwaitingFirstVisibleContent ? awaitingPulseOpacity : 1.0)
                .padding(.top, 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                if hasThinkingContent, let thinkingText = turn.thinkingText {
                    ThinkingDisclosureView(
                        turnId: turn.id,
                        thinkingText: thinkingText,
                        isComplete: turn.isThinkingComplete || !isStreaming,
                        durationSeconds: turn.metadata.thinkingDurationSeconds
                    )
                } else if isAwaitingFirstVisibleContent {
                    Text("Thinking…")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .opacity(awaitingPulseOpacity)
                        .padding(.top, 1)
                }

                ForEach(renderedSegments) { segment in
                    switch segment {
                    case .markdown(let partIndex, let text):
                        MarkdownContentView(
                            markdown: text,
                            turnId: turn.id,
                            partIndex: partIndex
                        )

                    case .imageGallery(_, let images):
                        InlineImageGalleryView(
                            images: images,
                            onSave: onSaveInlineImage
                        )

                    case .artifact(let info):
                        ArtifactFallbackCardView(
                            artifact: info,
                            onOpenInWebMode: onOpenInWebMode
                        )
                    }
                }

                if shouldShowFooter {
                    unifiedTurnFooter
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Unified Single-Row Turn Footer

    private var unifiedTurnFooter: some View {
        HStack(spacing: 4) {
            if !turn.assistantMarkdown.isEmpty {
                TurnFooterIconButton(
                    systemName: didCopyResponse ? "checkmark" : "doc.on.doc",
                    tint: didCopyResponse ? Color.green : nil,
                    helpText: didCopyResponse ? String(localized: "Copied") : String(localized: "Copy"),
                    action: copyAssistantResponse
                )
            }

            if isLatestTurn && canRegenerate {
                TurnFooterIconButton(
                    systemName: "arrow.clockwise",
                    helpText: String(localized: "Regenerate"),
                    action: { onRegenerate?() }
                )
            }

            if isLatestTurn && canEdit {
                TurnFooterIconButton(
                    systemName: "pencil",
                    helpText: String(localized: "Edit"),
                    action: { onEdit?() }
                )
            }

            if !turn.citations.isEmpty {
                Rectangle()
                    .fill(LiquidGlassColors.subtleHairline)
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 4)

                CitationChipsStripView(citations: turn.citations)
            }

            Spacer(minLength: 0)
        }
        .opacity(isHoveringRow || didCopyResponse || !turn.citations.isEmpty ? 1.0 : 0.65)
    }

    // MARK: - Actions & Helpers

    private func copyAssistantResponse() {
        let markdown = turn.assistantMarkdown
        guard !markdown.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)

        copyResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.14)) {
            didCopyResponse = true
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
                didCopyResponse = false
            }
        }
    }

    private func formattedByteCount(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private static func buildSegments(from parts: [MessagePart]) -> [RenderedAssistantSegment] {
        var segments: [RenderedAssistantSegment] = []
        var pendingImages: [ImageAttachment] = []
        var markdownPartIndex = 0
        var galleryIndex = 0

        func flushImagesIfNeeded() {
            guard !pendingImages.isEmpty else {
                return
            }
            segments.append(.imageGallery(id: "gallery-\(galleryIndex)", images: pendingImages))
            pendingImages.removeAll()
            galleryIndex += 1
        }

        for part in parts {
            switch part {
            case .markdown(let text):
                flushImagesIfNeeded()
                guard !text.isEmpty else {
                    continue
                }
                segments.append(.markdown(partIndex: markdownPartIndex, text: text))
                markdownPartIndex += 1

            case .inlineImage(let attachment):
                pendingImages.append(attachment)

            case .unsupportedArtifact(let info):
                flushImagesIfNeeded()
                segments.append(.artifact(info))
            }
        }

        flushImagesIfNeeded()
        return segments
    }
}

// MARK: - RenderedAssistantSegment

private enum RenderedAssistantSegment: Identifiable {
    case markdown(partIndex: Int, text: String)
    case imageGallery(id: String, images: [ImageAttachment])
    case artifact(ArtifactCardInfo)

    var id: String {
        switch self {
        case .markdown(let partIndex, _):
            return "md-\(partIndex)"
        case .imageGallery(let id, _):
            return id
        case .artifact(let info):
            return "artifact-\(info.id)"
        }
    }
}

// MARK: - TurnFooterIconButton

private struct TurnFooterIconButton: View {

    let systemName: String
    var tint: Color? = nil
    let helpText: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tint ?? Color.primary.opacity(isHovering ? 0.92 : 0.62))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? LiquidGlassColors.hoverHighlight : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .help(helpText)
        .accessibilityLabel(Text(helpText))
    }
}

// MARK: - CitationChipsStripView

/// Compact horizontal strip of clickable grounding citation pills rendered inline on the turn footer.
private struct CitationChipsStripView: View {

    let citations: [CitationLink]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(citations) { citation in
                    CitationChipButton(citation: citation)
                }
            }
        }
        .frame(height: 24)
    }
}

private struct CitationChipButton: View {

    let citation: CitationLink

    @State private var isHovering = false

    private var labelText: String {
        if let domain = citation.resolvedDomain, !domain.isEmpty {
            return domain
        }
        return citation.title
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(citation.url)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(labelText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(isHovering ? 0.95 : 0.76))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovering ? LiquidGlassColors.hoverHighlight : Color.primary.opacity(0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(LiquidGlassColors.subtleHairline, lineWidth: LiquidGlassMetrics.hairlineWidth)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .help(citation.title.isEmpty ? citation.url.absoluteString : citation.title)
        .accessibilityLabel(Text(citation.title.isEmpty ? labelText : citation.title))
    }
}
