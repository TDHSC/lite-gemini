import AppKit
import SwiftUI

// MARK: - BtwPopoverPanelView

/// Floating `360pt`-wide (up to `460pt`-tall) Liquid Glass side-question panel backed by an
/// isolated ephemeral `BtwSessionStore`.
///
/// Renders `Btw` responses using `MarkdownBlockListView` (preserving native SwiftMath equations
/// and syntax-highlighted code blocks), displays staged quote chips, provides a compact CJK-safe
/// bottom prompt input (`↩` submit, `⇧↩` newline, `⎋` dismiss), and supports summarizing takeaways
/// back into the main conversation composer.
struct BtwPopoverPanelView: View {

    // MARK: - Layout Constants

    static let panelWidth: CGFloat = 360
    static let maxPanelHeight: CGFloat = 460
    static let panelCornerRadius: CGFloat = 18
    private static let bottomAnchorID = "lg-btw-bottom-anchor"

    // MARK: - Dependencies

    @Bindable var store: BtwSessionStore
    let mainTurns: [ChatTurn]
    var onSendNotesToMainChat: ((String) -> Void)? = nil
    var onClose: (() -> Void)? = nil

    // MARK: - Internal State

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var btwGlassNamespace

    @State private var measuredInputHeight: CGFloat = BtwPromptTextView.singleLineHeight
    @State private var isHoveringClear: Bool = false
    @State private var isHoveringSendNotes: Bool = false
    @State private var isHoveringClose: Bool = false
    @State private var isHoveringSubmit: Bool = false

    private var canClear: Bool {
        store.hasEntries || !store.stagedQuotes.isEmpty || !store.inputText.isEmpty || store.lastErrorMessage != nil
    }

    private var streamingScrollSignal: Int {
        guard let last = store.entries.last else {
            return 0
        }
        var hasher = Hasher()
        hasher.combine(store.entries.count)
        hasher.combine(last.id)
        hasher.combine(last.assistantMarkdown.utf8.count)
        hasher.combine(last.isStreaming)
        return hasher.finalize()
    }

    private var unattachedErrorMessage: String? {
        guard let message = store.lastErrorMessage, !message.isEmpty else {
            return nil
        }
        if store.entries.last?.errorMessage == message {
            return nil
        }
        return message
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Rectangle()
                .fill(LiquidGlassColors.subtleHairline)
                .frame(height: LiquidGlassMetrics.hairlineWidth)

            threadBody

            if store.isSummarizing {
                summarizingStatusBar
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let errorMessage = unattachedErrorMessage {
                inlineErrorBanner(message: errorMessage)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !store.stagedQuotes.isEmpty {
                stagedQuotesStrip
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Rectangle()
                .fill(LiquidGlassColors.subtleHairline)
                .frame(height: LiquidGlassMetrics.hairlineWidth)

            bottomPromptBar
        }
        .frame(width: Self.panelWidth)
        .frame(maxHeight: Self.maxPanelHeight)
        .glassCard(
            cornerRadius: Self.panelCornerRadius,
            variant: .regular
        )
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: store.stagedQuotes.count)
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: store.isSummarizing)
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: store.lastErrorMessage)
        .onExitCommand {
            handleDismiss()
        }
        .onChange(of: store.inputText) { _, newValue in
            if newValue.isEmpty {
                measuredInputHeight = BtwPromptTextView.singleLineHeight
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.tempActiveAccent)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(LiquidGlassColors.tempActiveTint)
                    )
                    .accessibilityHidden(true)

                Text("Btw")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 4)

            LiquidGlassContainer(spacing: 4) {
                HStack(spacing: 4) {
                    Button {
                        store.clear()
                    } label: {
                        Text("Clear")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(
                                canClear
                                    ? Color.primary.opacity(isHoveringClear ? 0.96 : 0.78)
                                    : Color.primary.opacity(0.32)
                            )
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .glassCapsule(
                                variant: .clear,
                                tint: (canClear && isHoveringClear) ? LiquidGlassColors.hoverHighlight : nil,
                                interactive: canClear
                            )
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canClear || store.isSummarizing)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            isHoveringClear = hovering
                        }
                    }
                    .help(String(localized: "Clear side thread"))
                    .accessibilityLabel(Text("Clear"))

                    Button {
                        handleSendToMainChat()
                    } label: {
                        HStack(spacing: 4) {
                            if store.isSummarizing {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.78)
                                    .frame(width: 11, height: 11)
                            } else {
                                Image(systemName: "arrow.uturn.left")
                                    .font(.system(size: 9.5, weight: .semibold))
                            }

                            Text(store.isSummarizing ? "Summarizing…" : "Send to main chat")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(
                            (store.canSendToMainChat || store.isSummarizing)
                                ? Color.primary.opacity(isHoveringSendNotes ? 0.98 : 0.84)
                                : Color.primary.opacity(0.32)
                        )
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .glassCapsule(
                            variant: .clear,
                            tint: (store.canSendToMainChat && isHoveringSendNotes) ? LiquidGlassColors.hoverHighlight : nil,
                            interactive: store.canSendToMainChat
                        )
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canSendToMainChat)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            isHoveringSendNotes = hovering
                        }
                    }
                    .help(String(localized: "Summarize takeaways into main composer"))
                    .accessibilityLabel(Text("Send to main chat"))

                    Button {
                        handleDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(isHoveringClose ? 0.96 : 0.68))
                            .glassOrb(
                                size: 24,
                                variant: .clear,
                                tint: isHoveringClose ? LiquidGlassColors.hoverHighlight : nil,
                                interactive: true
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            isHoveringClose = hovering
                        }
                    }
                    .help(String(localized: "Close Btw (Esc)"))
                    .accessibilityLabel(Text("Close Btw"))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Thread Body

    @ViewBuilder
    private var threadBody: some View {
        if store.entries.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.tempActiveAccent.opacity(0.80))
                    .accessibilityHidden(true)

                Text("Ask a quick side question without cluttering the main chat.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.76))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Ephemeral • Uses main chat as background • Esc to close")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.entries) { entry in
                            BtwEntryRowView(entry: entry)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .onChange(of: streamingScrollSignal) { _, _ in
                    scrollProxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onAppear {
                    scrollProxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Status & Staged Quote Strips

    private var summarizingStatusBar: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.82)

            Text("Summarizing key takeaways for main chat…")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(LiquidGlassColors.tempActiveTint.opacity(0.55))
    }

    private func inlineErrorBanner(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.warningAccent)
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.86))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button {
                store.lastErrorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(LiquidGlassColors.warningGlassTint)
    }

    private var stagedQuotesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.stagedQuotes) { quote in
                    BtwStagedQuoteChipView(quote: quote) {
                        store.removeStagedQuote(id: quote.id)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(Color.primary.opacity(0.025))
    }

    // MARK: - Compact Bottom Prompt Input

    private var bottomPromptBar: some View {
        let isActive = store.canSubmitInput || store.isGenerating

        return HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if store.inputText.isEmpty {
                    Text("Ask a side question…")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .padding(.top, BtwPromptTextView.verticalTextInset)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .allowsHitTesting(false)
                }

                BtwPromptTextView(
                    text: $store.inputText,
                    measuredHeight: $measuredInputHeight,
                    focusTrigger: store.focusTrigger,
                    isEditable: !store.isSummarizing,
                    onSubmit: handleSubmit,
                    onEscape: handleDismiss
                )
                .frame(height: measuredInputHeight)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.leading, 4)
            .padding(.vertical, 3)

            Button {
                if store.isGenerating {
                    store.stopGenerating()
                } else {
                    handleSubmit()
                }
            } label: {
                ZStack {
                    if isActive {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        LiquidGlassColors.sendButtonBlue.opacity(isHoveringSubmit ? 0.96 : 0.88),
                                        LiquidGlassColors.sendButtonBlue.opacity(isHoveringSubmit ? 0.84 : 0.76)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }

                    Image(systemName: store.isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: store.isGenerating ? 10 : 12.5, weight: isActive ? .bold : .semibold))
                        .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.36))
                        .contentTransition(.symbolEffect(.replace))
                }
                .glassOrb(
                    size: 28,
                    variant: isActive ? .regular : .clear,
                    tint: isActive ? LiquidGlassColors.sendButtonBlue : nil,
                    interactive: isActive
                )
                .liquidGlassID("btw-primary-submit", in: btwGlassNamespace)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isActive)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHoveringSubmit = hovering
                }
            }
            .help(store.isGenerating ? String(localized: "Stop") : String(localized: "Send side question (↩)"))
            .accessibilityLabel(store.isGenerating ? Text("Stop") : Text("Send"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func handleSubmit() {
        guard store.canSubmitInput else {
            return
        }
        store.sendCurrentInput(mainTurns: mainTurns)
    }

    private func handleDismiss() {
        if let onClose {
            onClose()
        } else {
            store.close()
        }
    }

    private func handleSendToMainChat() {
        guard store.canSendToMainChat else {
            return
        }
        Task { @MainActor in
            if let notes = await store.summarizeForMainChat(),
               store.isPresented,
               !notes.isEmpty {
                onSendNotesToMainChat?(notes)
            }
        }
    }
}

// MARK: - BtwEntryRowView

private struct BtwEntryRowView: View {

    let entry: BtwSessionStore.Entry

    @State private var isHoveringAssistant: Bool = false
    @State private var didCopy: Bool = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // User side question (clean prompt + attached quotes only; never the packed 16K background)
            HStack(spacing: 0) {
                Spacer(minLength: 28)

                VStack(alignment: .trailing, spacing: 5) {
                    if !entry.quotes.isEmpty {
                        ForEach(entry.quotes) { quote in
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "arrowshape.turn.up.left")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2)

                                Text(quote.quotedText)
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .glassCard(
                                cornerRadius: 10,
                                variant: .clear,
                                tint: LiquidGlassColors.clearCardTint
                            )
                        }
                    }

                    Text(entry.userQuestion)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.94))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .glassCard(
                            cornerRadius: 14,
                            variant: .clear,
                            tint: LiquidGlassColors.userBubbleGlassTint
                        )
                }
            }

            // Assistant side response rendered with MarkdownBlockListView (math + syntax-highlighted code)
            HStack(alignment: .top, spacing: 8) {
                MonochromeSparkShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                LiquidGlassColors.tempActiveAccent.opacity(0.92),
                                Color.primary.opacity(0.48)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 12, height: 12)
                    .padding(.top, 3)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    if entry.isStreaming && entry.assistantMarkdown.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.78)
                            Text("Thinking…")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 1)
                    } else if !entry.assistantMarkdown.isEmpty {
                        let blocks = MarkdownRenderCache.shared.blocks(
                            for: entry.assistantMarkdown,
                            turnId: "btw-\(entry.id.uuidString)",
                            partIndex: 0
                        )
                        MarkdownBlockListView(
                            blocks: blocks,
                            baseFontSize: 12.5,
                            foregroundOpacity: 0.92,
                            listDepth: 0
                        )
                        .environment(\.openURL, OpenURLAction { url in
                            NSWorkspace.shared.open(url)
                            return .handled
                        })
                    }

                    if let errorMessage = entry.errorMessage, !errorMessage.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(LiquidGlassColors.warningAccent)
                            Text(errorMessage)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .glassCard(
                            cornerRadius: 10,
                            variant: .clear,
                            tint: LiquidGlassColors.warningGlassTint
                        )
                    }

                    if !entry.isStreaming && !entry.assistantMarkdown.isEmpty {
                        HStack(spacing: 4) {
                            Button(action: copyResponse) {
                                HStack(spacing: 3) {
                                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(didCopy ? Color.green : .secondary)
                                    Text(didCopy ? "Copied" : "Copy")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .glassCapsule(variant: .clear, interactive: true)
                                .contentShape(Capsule(style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .opacity(isHoveringAssistant || didCopy ? 1.0 : 0.65)
                            .accessibilityLabel(didCopy ? Text("Copied") : Text("Copy"))

                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHoveringAssistant = hovering
                }
            }
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
    }

    private func copyResponse() {
        let text = entry.assistantMarkdown
        guard !text.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        copyResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.14)) {
            didCopy = true
        }
        copyResetTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(1500))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            withAnimation(.easeInOut(duration: 0.16)) {
                didCopy = false
            }
        }
    }
}

// MARK: - BtwStagedQuoteChipView

private struct BtwStagedQuoteChipView: View {

    let quote: BtwQuoteItem
    let onRemove: () -> Void

    @State private var isHoveringRemove: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(quote.quotedText)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.80))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 210, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(isHoveringRemove ? 0.94 : 0.60))
                    .frame(width: 16, height: 16)
                    .background(
                        Circle()
                            .fill(isHoveringRemove ? LiquidGlassColors.hoverHighlight : Color.clear)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHoveringRemove = hovering
                }
            }
            .accessibilityLabel(Text("Remove quote"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .glassCapsule(
            variant: .clear,
            tint: LiquidGlassColors.clearCardTint,
            interactive: true
        )
    }
}

// MARK: - BtwPromptTextView

/// Compact `NSTextView` wrapper reusing `ComposerNSTextView`'s CJK IME-safe `Return` submit,
/// `Shift+Return` newline, and `Esc` dismiss handling inside `BtwPopoverPanelView`.
private struct BtwPromptTextView: NSViewRepresentable {

    static let singleLineHeight: CGFloat = 20
    static let maxVisibleHeight: CGFloat = 80
    static let verticalTextInset: CGFloat = 2
    static let promptFont: NSFont = .systemFont(ofSize: 13, weight: .regular)

    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let focusTrigger: Int
    let isEditable: Bool
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = ComposerNSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.minSize = NSSize(width: 0, height: Self.singleLineHeight)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: Self.verticalTextInset)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3

        textView.font = Self.promptFont
        textView.defaultParagraphStyle = paragraphStyle
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.typingAttributes = [
            .font: Self.promptFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.string = text

        scrollView.documentView = textView

        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView
        context.coordinator.bindCallbacks(on: textView)

        if focusTrigger > 0 {
            context.coordinator.lastHandledFocusTrigger = focusTrigger
            context.coordinator.focusIfWindowIsKeyAsync()
        }

        context.coordinator.scheduleHeightSync()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        guard let textView = coordinator.textView else {
            return
        }

        coordinator.bindCallbacks(on: textView)

        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }

        let isComposing = textView.hasMarkedText()
        if textView.string != text {
            if !isComposing {
                textView.string = text
                let endLocation = (text as NSString).length
                textView.setSelectedRange(NSRange(location: endLocation, length: 0))
            } else if text.isEmpty && !coordinator.lastReportedText.isEmpty {
                textView.unmarkText()
                textView.string = ""
            }
            coordinator.lastReportedText = text
        }

        if focusTrigger != coordinator.lastHandledFocusTrigger {
            coordinator.lastHandledFocusTrigger = focusTrigger
            coordinator.focusIfWindowIsKeyAsync()
        }

        coordinator.scheduleHeightSync()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: BtwPromptTextView
        weak var scrollView: NSScrollView?
        weak var textView: ComposerNSTextView?
        var lastHandledFocusTrigger: Int = 0
        var lastReportedText: String
        private var isHeightSyncScheduled: Bool = false

        init(parent: BtwPromptTextView) {
            self.parent = parent
            self.lastReportedText = parent.text
        }

        func bindCallbacks(on textView: ComposerNSTextView) {
            textView.onSubmit = { [weak self] in
                self?.parent.onSubmit()
            }
            textView.onCancelContext = { [weak self] in
                self?.parent.onEscape()
            }
            textView.onEditLastTurn = nil
            textView.onAttachmentsAdded = nil
            textView.onDirectoryDropped = nil
        }

        func focusIfWindowIsKeyAsync() {
            DispatchQueue.main.async { [weak self] in
                guard let textView = self?.textView,
                      let window = textView.window,
                      window.isKeyWindow else {
                    return
                }
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else {
                return
            }
            let updatedText = textView.string
            lastReportedText = updatedText
            if parent.text != updatedText {
                parent.text = updatedText
            }
            syncHeightImmediately()
        }

        func scheduleHeightSync() {
            guard !isHeightSyncScheduled else {
                return
            }
            isHeightSyncScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.isHeightSyncScheduled = false
                self.syncHeightImmediately()
            }
        }

        private func syncHeightImmediately() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return
            }

            let availableWidth = scrollView?.contentSize.width ?? textView.bounds.width
            if availableWidth > 1 {
                if abs(textView.frame.width - availableWidth) > 0.5 {
                    textView.frame.size.width = availableWidth
                }
                if abs(textContainer.containerSize.width - availableWidth) > 0.5 {
                    textContainer.containerSize = NSSize(
                        width: availableWidth,
                        height: CGFloat.greatestFiniteMagnitude
                    )
                }
            }

            layoutManager.ensureLayout(for: textContainer)
            var usedHeight = layoutManager.usedRect(for: textContainer).height
            if usedHeight < 1 {
                usedHeight = layoutManager.defaultLineHeight(for: BtwPromptTextView.promptFont)
            }
            let extraRect = layoutManager.extraLineFragmentRect
            if extraRect.height > 0 && extraRect.maxY > usedHeight {
                usedHeight = extraRect.maxY
            }

            let rawTotal = ceil(usedHeight + textView.textContainerInset.height * 2)
            let clamped = min(
                max(rawTotal, BtwPromptTextView.singleLineHeight),
                BtwPromptTextView.maxVisibleHeight
            )
            if abs(parent.measuredHeight - clamped) > 0.5 {
                parent.measuredHeight = clamped
            }
        }
    }
}
