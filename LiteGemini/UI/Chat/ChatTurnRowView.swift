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
    var onRegenerateVariant: ((RegenerateVariant, String?) -> Void)? = nil
    var isQuickMode: Bool = false
    var isTemporaryChat: Bool = false
    var availableModels: [ModelOption] = []
    var selectedModelId: String? = nil
    var isBranchingThisTurn: Bool = false
    var isShareExportBusy: Bool = false
    var speechController: TurnSpeechController? = nil
    var onSynthesizeSpeechChunk: (@MainActor (String, String) async -> Data?)? = nil
    var onBranchFromTurn: (() -> Void)? = nil
    var onShareThisTurn: (() -> Void)? = nil
    var onShareEntireChat: (() -> Void)? = nil
    var onExportTurnMarkdown: (() -> Void)? = nil
    var onExportTurnPDF: (() -> Void)? = nil
    var onExportGoogleDocs: (() -> Void)? = nil
    var onDraftGmail: (() -> Void)? = nil
    var onOpenGoogleColab: (() -> Void)? = nil
    var onOpenArtifact: ((ArtifactCardInfo) -> Void)? = nil
    var onConfirmResearchPlan: ((ArtifactCardInfo) -> Void)? = nil
    var onEditResearchPlan: (() -> Void)? = nil
    var onOpenInWebMode: (() -> Void)? = nil
    var onSaveInlineImage: ((ImageAttachment) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var turnFooterGlassNamespace

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
            || (!isQuickMode && !isTemporaryChat && onBranchFromTurn != nil)
    }

    private var isSpeechActiveOnThisTurn: Bool {
        guard let speechController else {
            return false
        }
        return speechController.activeTurnId == TurnSpeechController.stableTurnUUID(for: turn.id)
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
                if let quotedPassages = turn.quotedPassages, !quotedPassages.isEmpty {
                    userQuotedPassageChips(quotedPassages)
                }

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
                        .glassCard(
                            cornerRadius: 18,
                            variant: .clear,
                            tint: LiquidGlassColors.userBubbleGlassTint
                        )
                }
            }
            .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
        }
    }

    private func userQuotedPassageChips(_ quotes: [QuotedPassage]) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(quotes) { quote in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .accessibilityHidden(true)

                    Text(quote.quotedText)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassCard(
                    cornerRadius: 12,
                    variant: .clear,
                    tint: LiquidGlassColors.clearCardTint
                )
            }
        }
    }

    private var userAttachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LiquidGlassContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(turn.userAttachments) { attachment in
                        HStack(spacing: 5) {
                            Image(systemName: attachment.isFolder ? "folder.fill" : (attachment.isImage ? "photo" : "doc"))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(attachment.isFolder ? LiquidGlassColors.sendButtonBlue : .secondary)

                            Text(attachment.filename)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.88))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 160, alignment: .leading)

                            if let fileCount = attachment.folderFileCount, fileCount > 0 {
                                Text("\(fileCount) files")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                            } else if attachment.byteCount > 0 {
                                Text(formattedByteCount(attachment.byteCount))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .glassCapsule(variant: .clear, interactive: true)
                    }
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
                            isQuickMode: isQuickMode,
                            onOpenArtifact: onOpenArtifact,
                            onConfirmResearchPlan: onConfirmResearchPlan,
                            onEditResearchPlan: onEditResearchPlan,
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
        let markdown = turn.assistantMarkdown
        let hasMarkdown = !markdown.isEmpty
        let allowsExtendedActions = !isQuickMode && !isTemporaryChat && !isStreaming

        return HStack(spacing: 4) {
            LiquidGlassContainer(spacing: 6) {
                HStack(spacing: 4) {
                    if hasMarkdown {
                        TurnFooterIconButton(
                            systemName: didCopyResponse ? "checkmark" : "doc.on.doc",
                            tint: didCopyResponse ? Color.green : nil,
                            helpText: didCopyResponse ? String(localized: "Copied") : String(localized: "Copy"),
                            action: copyAssistantResponse
                        )
                        .liquidGlassID("turn-footer-copy", in: turnFooterGlassNamespace)
                        .liquidGlassTransitionMaterialize()

                        if let speechController, let onSynthesizeSpeechChunk {
                            TurnSpeechControlView(
                                turnId: TurnSpeechController.stableTurnUUID(for: turn.id),
                                markdown: markdown,
                                controller: speechController,
                                synthesizeChunk: onSynthesizeSpeechChunk
                            )
                            .liquidGlassID("turn-footer-speech", in: turnFooterGlassNamespace)
                            .liquidGlassTransitionMaterialize()
                        }
                    }

                    if isLatestTurn && canRegenerate {
                        TurnRegenerateSplitButton(
                            hasArtifacts: turn.hasArtifacts,
                            availableModels: availableModels,
                            selectedModelId: selectedModelId,
                            onTryAgain: {
                                if let onRegenerateVariant {
                                    onRegenerateVariant(.tryAgain, nil)
                                } else {
                                    onRegenerate?()
                                }
                            },
                            onSelectVariant: { variant, modelId in
                                if let onRegenerateVariant {
                                    onRegenerateVariant(variant, modelId)
                                } else if variant == .tryAgain && modelId == nil {
                                    onRegenerate?()
                                }
                            }
                        )
                        .liquidGlassID("turn-footer-regenerate", in: turnFooterGlassNamespace)
                        .liquidGlassTransitionMaterialize()
                    }

                    if isLatestTurn && canEdit {
                        TurnFooterIconButton(
                            systemName: "pencil",
                            helpText: String(localized: "Edit"),
                            action: { onEdit?() }
                        )
                        .liquidGlassID("turn-footer-edit", in: turnFooterGlassNamespace)
                        .liquidGlassTransitionMaterialize()
                    }

                    if allowsExtendedActions, let onBranchFromTurn {
                        TurnFooterIconButton(
                            systemName: "arrow.triangle.branch",
                            isBusy: isBranchingThisTurn,
                            helpText: String(localized: "Branch in new chat"),
                            action: onBranchFromTurn
                        )
                        .liquidGlassID("turn-footer-branch", in: turnFooterGlassNamespace)
                        .liquidGlassTransitionMaterialize()
                    }

                    if allowsExtendedActions && hasMarkdown {
                        ShareExportMenuButton(
                            style: .turnFooterOrb,
                            isBusy: isShareExportBusy,
                            isShareLinkAvailable: onShareThisTurn != nil || onShareEntireChat != nil,
                            hasPythonCode: ShareExportMenuButton.containsPythonCode(in: markdown),
                            shareLinkLabel: String(localized: "Share This Response"),
                            secondaryShareLinkLabel: String(localized: "Share Entire Chat"),
                            onCreateShareLink: onShareThisTurn,
                            onCreateSecondaryShareLink: onShareEntireChat,
                            onExportMarkdown: onExportTurnMarkdown,
                            onExportPDF: onExportTurnPDF,
                            onExportGoogleDocs: onExportGoogleDocs,
                            onDraftGmail: onDraftGmail,
                            onOpenGoogleColab: onOpenGoogleColab
                        )
                        .liquidGlassID("turn-footer-share", in: turnFooterGlassNamespace)
                        .liquidGlassTransitionMaterialize()
                    }
                }
            }
            .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: canRegenerate)
            .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: canEdit)

            if !turn.citations.isEmpty {
                Rectangle()
                    .fill(LiquidGlassColors.subtleHairline)
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 4)

                CitationChipsStripView(citations: turn.citations)
            }

            Spacer(minLength: 0)
        }
        .opacity(isHoveringRow || didCopyResponse || isSpeechActiveOnThisTurn || isBranchingThisTurn || !turn.citations.isEmpty ? 1.0 : 0.72)
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
    var isBusy: Bool = false
    let helpText: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.72)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 11.5, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(tint ?? Color.primary.opacity(isHovering ? 0.94 : 0.68))
                }
            }
            .glassOrb(
                size: 28,
                variant: .clear,
                tint: isHovering ? LiquidGlassColors.hoverHighlight : nil,
                interactive: !isBusy
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .help(helpText)
        .accessibilityLabel(Text(helpText))
    }
}

// MARK: - TurnRegenerateSplitButton

/// Combined Liquid Glass regenerate capsule pairing instant `↻` retry with a compact `▾` menu
/// for tone/length/no-tool variants and model switching.
private struct TurnRegenerateSplitButton: View {

    let hasArtifacts: Bool
    let availableModels: [ModelOption]
    let selectedModelId: String?
    let onTryAgain: () -> Void
    let onSelectVariant: (RegenerateVariant, String?) -> Void

    @State private var isHoveringRetry = false
    @State private var isHoveringMenu = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTryAgain) {
                ZStack {
                    Capsule(style: .continuous)
                        .fill(isHoveringRetry ? LiquidGlassColors.hoverHighlight : Color.clear)

                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(isHoveringRetry ? 0.96 : 0.70))
                }
                .frame(width: 26, height: 22)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.14)) {
                    isHoveringRetry = hovering
                }
            }
            .help(String(localized: "Regenerate"))
            .accessibilityLabel(Text("Regenerate"))

            Rectangle()
                .fill(LiquidGlassColors.subtleHairline)
                .frame(width: 1, height: 12)

            Menu {
                Button {
                    onSelectVariant(.tryAgain, nil)
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }

                Divider()

                Button {
                    onSelectVariant(.shorter, nil)
                } label: {
                    Label("Shorter", systemImage: "arrow.down.right.and.arrow.up.left")
                }

                Button {
                    onSelectVariant(.longer, nil)
                } label: {
                    Label("Longer", systemImage: "arrow.up.left.and.arrow.down.right")
                }

                Button {
                    onSelectVariant(.simpler, nil)
                } label: {
                    Label("Simpler", systemImage: "sparkles")
                }

                Button {
                    onSelectVariant(.casual, nil)
                } label: {
                    Label("More casual", systemImage: "face.smiling")
                }

                Button {
                    onSelectVariant(.professional, nil)
                } label: {
                    Label("More professional", systemImage: "briefcase")
                }

                if hasArtifacts {
                    Divider()

                    Button {
                        onSelectVariant(.retryWithoutTools, nil)
                    } label: {
                        Label("Retry without tools", systemImage: "wrench.and.screwdriver")
                    }
                }

                if availableModels.count > 1 {
                    Divider()

                    Menu("Switch model & retry") {
                        ForEach(availableModels) { option in
                            Button {
                                onSelectVariant(.tryAgain, option.id)
                            } label: {
                                if option.id == selectedModelId {
                                    Label(option.displayName, systemImage: "checkmark")
                                } else {
                                    Text(option.displayName)
                                }
                            }
                        }
                    }
                }
            } label: {
                ZStack {
                    Capsule(style: .continuous)
                        .fill(isHoveringMenu ? LiquidGlassColors.hoverHighlight : Color.clear)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(isHoveringMenu ? 0.94 : 0.64))
                }
                .frame(width: 20, height: 22)
                .contentShape(Capsule(style: .continuous))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 20, height: 22)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.14)) {
                    isHoveringMenu = hovering
                }
            }
            .help(String(localized: "Regenerate options"))
            .accessibilityLabel(Text("Regenerate options"))
        }
        .padding(.horizontal, 3)
        .frame(height: 28)
        .glassCapsule(variant: .clear, interactive: true)
    }
}

// MARK: - CitationChipsStripView

/// Compact horizontal strip of clickable grounding citation pills rendered inline on the turn footer.
private struct CitationChipsStripView: View {

    let citations: [CitationLink]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LiquidGlassContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(citations) { citation in
                        CitationChipButton(citation: citation)
                    }
                }
            }
        }
        .frame(height: 28)
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
                    .foregroundStyle(Color.primary.opacity(isHovering ? 0.96 : 0.80))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .glassCapsule(
                variant: .clear,
                tint: isHovering ? LiquidGlassColors.hoverHighlight : nil,
                interactive: true
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
