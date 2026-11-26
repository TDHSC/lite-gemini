import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - AdaptiveComposerView

/// Shared 3-state concentric morphing Liquid Glass composer (`26pt` outer corner radius,
/// `8pt` inset around `36×36pt` circular action buttons) reused identically by Main Window
/// and Quick Mode.
///
/// Uses a custom `Layout` (`AdaptiveComposerLayout`) so `ComposerTextView` (`NSTextView`)
/// preserves constant SwiftUI structural identity across `.compactPill` ↔ `.expandedCard`
/// morphs, guaranteeing zero focus loss or CJK IME interruption when typing or attaching files.
struct AdaptiveComposerView: View {

    // MARK: - Layout Constants

    static let controlButtonSize: CGFloat = 36
    static let horizontalControlSpacing: CGFloat = 8
    static let expandedTextHorizontalInset: CGFloat = 6
    static let expandedTextTopPadding: CGFloat = 4
    static let expandedRowSpacing: CGFloat = 8

    // MARK: - Dependencies & Configuration

    @ObservedObject var store: ChatSessionStore
    @ObservedObject var draft: ComposerDraftState

    /// Non-`nil` in Quick Mode to display the persisted `Temp` switch inside `ModelPickerPopover`.
    var quickModeTempBinding: Binding<Bool>?

    /// Monotonically incremented trigger that programmatically focuses the underlying `NSTextView`.
    var focusTrigger: Int

    /// Invoked when the user chooses to upload a folder in Classic Web Mode.
    var onOpenFolderInWebMode: (() -> Void)?

    /// Invoked when `Esc` is pressed with no active IME composition, popover, edit mode, or banner.
    var onEscapeUnhandled: (() -> Void)?

    // MARK: - Internal View State

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var composerWidth: CGFloat = 548
    @State private var modelButtonWidth: CGFloat = 86
    @State private var measuredTextHeight: CGFloat = ComposerTextView.singleLineHeight
    @State private var wrapsSingleRow: Bool = false
    @State private var isScrolledDown: Bool = false
    @State private var isModelPopoverPresented: Bool = false
    @State private var isHoveringPlus: Bool = false
    @State private var isHoveringModel: Bool = false
    @State private var isHoveringPrimary: Bool = false
    @State private var isTextViewDropTargeted: Bool = false
    @State private var isOuterDropTargeted: Bool = false
    @State private var isTextViewFocused: Bool = false
    @State private var editFocusTrigger: Int = 0

    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var composerGlassNamespace

    // MARK: - Initializers

    init(
        store: ChatSessionStore,
        draft: ComposerDraftState,
        quickModeTempBinding: Binding<Bool>? = nil,
        focusTrigger: Int = 0,
        onOpenFolderInWebMode: (() -> Void)? = nil,
        onEscapeUnhandled: (() -> Void)? = nil
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self._draft = ObservedObject(wrappedValue: draft)
        self.quickModeTempBinding = quickModeTempBinding
        self.focusTrigger = focusTrigger
        self.onOpenFolderInWebMode = onOpenFolderInWebMode
        self.onEscapeUnhandled = onEscapeUnhandled
    }

    init(
        store: ChatSessionStore,
        quickModeTempBinding: Binding<Bool>? = nil,
        focusTrigger: Int = 0,
        onOpenFolderInWebMode: (() -> Void)? = nil,
        onEscapeUnhandled: (() -> Void)? = nil
    ) {
        self.init(
            store: store,
            draft: store.draft,
            quickModeTempBinding: quickModeTempBinding,
            focusTrigger: focusTrigger,
            onOpenFolderInWebMode: onOpenFolderInWebMode,
            onEscapeUnhandled: onEscapeUnhandled
        )
    }

    // MARK: - Derived State

    private var hasTopExtras: Bool {
        draft.isEditing
            || draft.showsFolderWebFallbackBanner
            || draft.activeToolMode != nil
            || !draft.stagedAttachments.isEmpty
            || !draft.quotes.isEmpty
            || draft.isQuoteCapAlertVisible
    }

    /// Current concentric visual state: `.compactPill` (52pt single row) or `.expandedCard` (multi-row).
    var layoutMode: ComposerLayoutMode {
        (hasTopExtras || wrapsSingleRow) ? .expandedCard : .compactPill
    }

    /// Invariant width of the State A single-row text slot used for non-oscillating wrap hysteresis.
    private var singleRowAvailableWidth: CGFloat {
        let fixedChromeWidth: CGFloat = (LiquidGlassMetrics.composerInsetPadding * 2)
            + (Self.controlButtonSize * 2)
            + (Self.horizontalControlSpacing * 3)
            + modelButtonWidth
        return max(60, composerWidth - fixedChromeWidth)
    }

    private var resolvedTextHeight: CGFloat {
        if layoutMode == .compactPill {
            return ComposerTextView.singleLineHeight
        }
        return min(
            max(measuredTextHeight, ComposerTextView.singleLineHeight),
            ComposerTextView.maxVisibleHeight
        )
    }

    private var isDropTargeted: Bool {
        isTextViewDropTargeted || isOuterDropTargeted
    }

    /// Clear optical glass when idle (`!focused` and empty draft), transitioning to frosted `.regular`
    /// glass as soon as the user focuses, types, stages attachments, or opens the model picker.
    private var isComposerFrosted: Bool {
        isTextViewFocused || !draft.text.isEmpty || hasTopExtras || isModelPopoverPresented
    }

    private var selectedModelTitle: String {
        if let selectedId = store.selectedModelId,
           let matched = store.availableModels.first(where: { $0.id == selectedId }) {
            return matched.displayName
        }
        if let first = store.availableModels.first {
            return first.displayName
        }
        return String(localized: "Model")
    }

    private var syncedQuickModeTempBinding: Binding<Bool>? {
        guard let binding = quickModeTempBinding else {
            return nil
        }
        return Binding<Bool>(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                if !store.hasTurns {
                    Task {
                        await store.setTemporaryChat(newValue)
                    }
                }
            }
        )
    }

    // MARK: - Body

    var body: some View {
        LiquidGlassContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: hasTopExtras ? 8 : 0) {
                if hasTopExtras {
                    topExtrasSection
                        .padding(.top, 4)
                        .padding(.horizontal, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                AdaptiveComposerLayout(
                    isExpanded: layoutMode == .expandedCard,
                    controlRowHeight: Self.controlButtonSize,
                    horizontalSpacing: Self.horizontalControlSpacing,
                    expandedTextHorizontalInset: Self.expandedTextHorizontalInset,
                    expandedTextTopPadding: hasTopExtras ? 0 : Self.expandedTextTopPadding,
                    expandedRowSpacing: Self.expandedRowSpacing
                ) {
                    plusAttachmentControl
                    textInputRegion
                    modelPickerTrigger
                    primaryActionButton
                }
            }
            .padding(LiquidGlassMetrics.composerInsetPadding)
            .glassCard(
                cornerRadius: LiquidGlassMetrics.composerOuterCornerRadius,
                variant: isComposerFrosted ? .regular : .clear,
                tint: isDropTargeted ? LiquidGlassColors.sendButtonBlue.opacity(0.08) : nil,
                interactive: true
            )
            .liquidGlassID("composer-shell", in: composerGlassNamespace)
            .liquidGlassTransitionMatchedGeometry()
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(
                        cornerRadius: LiquidGlassMetrics.composerOuterCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(
                        LiquidGlassColors.sendButtonBlue.opacity(0.65),
                        lineWidth: 1.5
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .preference(key: ComposerWidthPreferenceKey.self, value: geometry.size.width)
            }
        )
        .onPreferenceChange(ComposerWidthPreferenceKey.self) { width in
            if let width, abs(width - composerWidth) > 0.5 {
                composerWidth = width
                recomputeWrapState(for: draft.text)
            }
        }
        .onPreferenceChange(ModelButtonWidthPreferenceKey.self) { width in
            if let width, abs(width - modelButtonWidth) > 0.5 {
                modelButtonWidth = width
                recomputeWrapState(for: draft.text)
            }
        }
        .onChange(of: draft.text) { _, newValue in
            recomputeWrapState(for: newValue)
            if newValue.isEmpty {
                measuredTextHeight = ComposerTextView.singleLineHeight
                isScrolledDown = false
            }
        }
        .onChange(of: draft.isEditing) { _, isEditing in
            if isEditing {
                editFocusTrigger += 1
            }
        }
        .onDrop(
            of: [.fileURL, .png, .tiff, .image],
            isTargeted: $isOuterDropTargeted,
            perform: handleOuterDrop(providers:)
        )
        .animation(LiquidGlassMotion.morph(reduceMotion: reduceMotion), value: layoutMode)
        .animation(LiquidGlassMotion.morph(reduceMotion: reduceMotion), value: isComposerFrosted)
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: draft.stagedAttachments.count)
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: draft.quotes.count)
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: draft.isQuoteCapAlertVisible)
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: draft.isEditing)
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: draft.showsFolderWebFallbackBanner)
        .animation(LiquidGlassMotion.materialize(reduceMotion: reduceMotion), value: draft.activeToolMode)
        .animation(LiquidGlassMotion.morph(reduceMotion: reduceMotion), value: store.isStreaming)
    }

    // MARK: - Top Extras (Editing Banner, Tool Chip, Quotes, Folder Fallback Banner, Attachment Tiles)

    private var topExtrasSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.isEditing {
                editingBanner
            }

            if let toolMode = draft.activeToolMode {
                activeToolModeChip(for: toolMode)
            }

            if !draft.quotes.isEmpty || draft.isQuoteCapAlertVisible {
                ComposerQuoteBannerListView(
                    items: draft.quoteBannerItems,
                    showsMaxCapBanner: draft.isQuoteCapAlertVisible,
                    onRemove: { id in
                        draft.removeQuote(id: id)
                    },
                    onDismissMaxCapBanner: {
                        draft.dismissQuoteCapAlert()
                    }
                )
            }

            if draft.showsFolderWebFallbackBanner {
                folderFallbackBanner
            }

            if !draft.stagedAttachments.isEmpty {
                AttachmentTileStrip(
                    attachments: draft.stagedAttachments,
                    onRemove: { id in
                        draft.removeAttachment(id: id)
                    }
                )
            }
        }
    }

    private func activeToolModeChip(for toolMode: ComposerToolMode) -> some View {
        let iconName = toolMode == .canvas ? "doc.richtext" : "text.magnifyingglass"
        let labelText = toolMode == .canvas
            ? String(localized: "Canvas")
            : String(localized: "Deep Research")

        return HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.sendButtonBlue)

            Text(labelText)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.sendButtonBlue)
                .lineLimit(1)

            Button {
                Task {
                    await store.setToolMode(nil)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove \(labelText)"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .glassCapsule(
            variant: .clear,
            tint: LiquidGlassColors.sendButtonBlue.opacity(0.14),
            interactive: true
        )
    }

    private var editingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.sendButtonBlue)

            Text("Editing previous message")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                store.cancelEditing()
            } label: {
                Text("Cancel")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.84))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .glassCapsule(variant: .clear, interactive: true)
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LiquidGlassColors.sendButtonBlue.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LiquidGlassColors.sendButtonBlue.opacity(0.18),
                    lineWidth: LiquidGlassMetrics.hairlineWidth
                )
        )
    }

    private var folderFallbackBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.warningAccent)

            Text("Folder uploads require Classic Web Mode.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 6)

            if let onOpenFolderInWebMode {
                Button {
                    draft.showsFolderWebFallbackBanner = false
                    onOpenFolderInWebMode()
                } label: {
                    Text("Open in Web ↗")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .controlSize(.small)
                .liquidGlassButtonStyle(prominent: true, tint: LiquidGlassColors.sendButtonBlue)
            }

            Button {
                draft.showsFolderWebFallbackBanner = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LiquidGlassColors.warningGlassTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LiquidGlassColors.warningAccent.opacity(0.22),
                    lineWidth: LiquidGlassMetrics.hairlineWidth
                )
        )
    }

    // MARK: - Text Input Region

    private var textInputRegion: some View {
        ZStack(alignment: .topLeading) {
            if draft.text.isEmpty {
                Text("Ask anything…")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .padding(.top, ComposerTextView.verticalTextInset)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsHitTesting(false)
            }

            ComposerTextView(
                text: $draft.text,
                measuredHeight: $measuredTextHeight,
                wrapsSingleRow: $wrapsSingleRow,
                isScrolledDown: $isScrolledDown,
                singleRowAvailableWidth: singleRowAvailableWidth,
                focusTrigger: focusTrigger + editFocusTrigger,
                isEditable: true,
                onSubmit: handleSubmitAction,
                onEditLastTurn: handleEditLastTurnAction,
                onCancelContext: handleCancelContextAction,
                onAttachmentsAdded: handleAttachmentsAdded,
                onDirectoryDropped: handleDirectoryDropped,
                onDragTargetingChanged: { targeted in
                    isTextViewDropTargeted = targeted
                },
                onFocusChanged: { focused in
                    isTextViewFocused = focused
                }
            )
            .frame(height: resolvedTextHeight)
        }
        .frame(height: resolvedTextHeight, alignment: .topLeading)
        .mask {
            if isScrolledDown {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 16)

                    Rectangle()
                        .fill(.black)
                }
            } else {
                Rectangle()
                    .fill(.black)
            }
        }
    }

    // MARK: - Controls

    private var plusAttachmentControl: some View {
        Menu {
            Button {
                presentAttachmentOpenPanel()
            } label: {
                Label("Add Files or Photos…", systemImage: "paperclip")
            }

            Button {
                presentFolderOpenPanel()
            } label: {
                Label("Upload Code Folder…", systemImage: "folder.badge.plus")
            }

            Divider()

            Button {
                let next: ComposerToolMode? = draft.activeToolMode == .canvas ? nil : .canvas
                Task {
                    await store.setToolMode(next)
                }
            } label: {
                Label(
                    "Canvas",
                    systemImage: draft.activeToolMode == .canvas ? "checkmark.circle.fill" : "doc.richtext"
                )
            }

            Button {
                let next: ComposerToolMode? = draft.activeToolMode == .deepResearch ? nil : .deepResearch
                Task {
                    await store.setToolMode(next)
                }
            } label: {
                Label(
                    "Deep Research",
                    systemImage: draft.activeToolMode == .deepResearch ? "checkmark.circle.fill" : "text.magnifyingglass"
                )
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.primary.opacity(isHoveringPlus ? 0.96 : 0.80))
                .glassOrb(
                    size: Self.controlButtonSize,
                    variant: .clear,
                    tint: isHoveringPlus ? LiquidGlassColors.hoverHighlight : nil,
                    interactive: true
                )
                .liquidGlassID("composer-plus", in: composerGlassNamespace)
                .contentShape(Circle())
        }
        // `.button` + `.plain` prevents macOS borderless `NSPopUpButton` from collapsing the 36pt circle and stripping accessibility labels.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: Self.controlButtonSize, height: Self.controlButtonSize)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringPlus = hovering
            }
        }
        .help(String(localized: "Add Files or Photos…"))
        .accessibilityLabel(Text("Add attachment"))
    }

    private var modelPickerTrigger: some View {
        let modelTitleMaxWidth: CGFloat = composerWidth < 420 ? 96 : 128

        return Button {
            isModelPopoverPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(selectedModelTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(
                        Color.primary.opacity(isHoveringModel || isModelPopoverPresented ? 0.96 : 0.80)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: modelTitleMaxWidth, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isHoveringModel || isModelPopoverPresented
                            ? LiquidGlassColors.hoverHighlight
                            : Color.clear
                    )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .preference(key: ModelButtonWidthPreferenceKey.self, value: geometry.size.width)
            }
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringModel = hovering
            }
        }
        .help(String(localized: "Select Model"))
        .accessibilityLabel(Text("Model"))
        .accessibilityValue(Text(selectedModelTitle))
        .popover(isPresented: $isModelPopoverPresented, arrowEdge: .top) {
            ModelPickerPopover(
                models: store.availableModels,
                selectedModelId: store.selectedModelId,
                isLoading: store.isSyncing && store.availableModels.isEmpty,
                quickModeTempBinding: syncedQuickModeTempBinding,
                onSelectModel: { option in
                    Task {
                        await store.selectModel(id: option.id)
                    }
                },
                onDismiss: {
                    isModelPopoverPresented = false
                }
            )
            .environment(\.colorScheme, colorScheme)
        }
    }

    private var primaryActionButton: some View {
        let isStreaming = store.isStreaming
        let canSubmit = draft.canSubmit
        let isActive = canSubmit || isStreaming

        return Button {
            if isStreaming {
                Task {
                    await store.stop()
                }
            } else {
                handleSubmitAction()
            }
        } label: {
            ZStack {
                if isActive {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    LiquidGlassColors.sendButtonBlue.opacity(isHoveringPrimary ? 0.96 : 0.88),
                                    LiquidGlassColors.sendButtonBlue.opacity(isHoveringPrimary ? 0.84 : 0.76)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

                Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: isStreaming ? 11.5 : 14.5, weight: (isStreaming || canSubmit) ? .bold : .semibold))
                    .foregroundStyle((isStreaming || canSubmit) ? Color.white : Color.primary.opacity(0.36))
                    .contentTransition(.symbolEffect(.replace))
            }
            .glassOrb(
                size: Self.controlButtonSize,
                variant: isActive ? .regular : .clear,
                tint: isActive ? LiquidGlassColors.sendButtonBlue : nil,
                interactive: isActive
            )
            .liquidGlassID("composer-primary", in: composerGlassNamespace)
            .scaleEffect(isActive && isHoveringPrimary ? 1.03 : 1.0)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isActive)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringPrimary = hovering
            }
        }
        .help(primaryButtonHelp(isStreaming: isStreaming))
        .accessibilityLabel(primaryButtonAccessibilityLabel(isStreaming: isStreaming))
    }

    private func primaryButtonHelp(isStreaming: Bool) -> String {
        if isStreaming {
            return String(localized: "Stop")
        }
        if draft.isEditing {
            return String(localized: "Update Message")
        }
        return String(localized: "Send Message")
    }

    private func primaryButtonAccessibilityLabel(isStreaming: Bool) -> Text {
        if isStreaming {
            return Text("Stop")
        }
        if draft.isEditing {
            return Text("Update Message")
        }
        return Text("Send Message")
    }

    // MARK: - Actions

    private func recomputeWrapState(for text: String) {
        let nextWrapped = ComposerWrapCalculator.default.evaluate(
            currentlyWrapped: wrapsSingleRow,
            text: text,
            font: ComposerTextView.composerFont,
            singleRowAvailableWidth: singleRowAvailableWidth
        )
        if wrapsSingleRow != nextWrapped {
            wrapsSingleRow = nextWrapped
        }
    }

    private func handleSubmitAction() {
        if !draft.isEditing,
           store.onTriggerBtwSlashCommand != nil,
           BtwPromptBuilder.parseSlashCommand(draft.text).matched {
            Task {
                await store.send()
            }
            return
        }
        guard !store.isStreaming, draft.canSubmit else {
            return
        }
        Task {
            await store.send()
        }
    }

    private func handleEditLastTurnAction() {
        guard store.canEditLastTurn else {
            return
        }
        store.beginEditingLastTurn()
    }

    private func handleCancelContextAction() {
        if isModelPopoverPresented {
            isModelPopoverPresented = false
            return
        }
        if draft.isEditing {
            store.cancelEditing()
            return
        }
        if draft.isQuoteCapAlertVisible {
            draft.dismissQuoteCapAlert()
            return
        }
        if draft.showsFolderWebFallbackBanner {
            draft.showsFolderWebFallbackBanner = false
            return
        }
        onEscapeUnhandled?()
    }

    private func handleAttachmentsAdded(_ attachments: [StagedAttachment]) {
        draft.addAttachments(attachments)
    }

    private func handleDirectoryDropped() {
        draft.showsFolderWebFallbackBanner = true
    }

    private func presentAttachmentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        panel.prompt = String(localized: "Attach")
        panel.title = String(localized: "Add Files or Photos")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else {
                return
            }
            let urls = panel.urls
            Task.detached {
                let result = PasteboardAttachmentClassifier.classifyFileURLs(urls)
                await MainActor.run {
                    if result.containsDirectory {
                        draft.showsFolderWebFallbackBanner = true
                    }
                    if !result.attachments.isEmpty {
                        draft.addAttachments(result.attachments)
                    }
                }
            }
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            panel.begin(completionHandler: handleResponse)
        }
    }

    private func presentFolderOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.resolvesAliases = true
        panel.prompt = String(localized: "Attach")
        panel.title = String(localized: "Upload Code Folder")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folderURL = panel.url else {
                return
            }
            Task.detached {
                let scanned = FolderAttachmentScanner.scanDirectory(folderURL)
                await MainActor.run {
                    if let scanned {
                        draft.showsFolderWebFallbackBanner = false
                        draft.addAttachments([scanned])
                    } else {
                        draft.showsFolderWebFallbackBanner = true
                    }
                }
            }
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            panel.begin(completionHandler: handleResponse)
        }
    }

    // MARK: - Outer Card Drop Support

    private func handleOuterDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            for provider in fileProviders {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let extractedURL: URL? = {
                        if let url = item as? URL {
                            return url
                        }
                        if let data = item as? Data {
                            return URL(dataRepresentation: data, relativeTo: nil)
                        }
                        if let string = item as? String {
                            return URL(string: string)
                        }
                        return nil
                    }()

                    guard let url = extractedURL else {
                        return
                    }
                    let result = PasteboardAttachmentClassifier.classifyFileURLs([url])
                    Task { @MainActor in
                        if result.containsDirectory {
                            draft.showsFolderWebFallbackBanner = true
                        }
                        if !result.attachments.isEmpty {
                            draft.addAttachments(result.attachments)
                        }
                    }
                }
            }
            return true
        }

        let imageProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.png.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.tiff.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !imageProviders.isEmpty else {
            return false
        }

        for provider in imageProviders {
            let preferredType: UTType = {
                if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
                    return .png
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.tiff.identifier) {
                    return .tiff
                }
                return .image
            }()

            provider.loadDataRepresentation(forTypeIdentifier: preferredType.identifier) { data, _ in
                guard let data, !data.isEmpty else {
                    return
                }
                let finalData: Data? = (preferredType == .png)
                    ? data
                    : PasteboardAttachmentClassifier.convertImageDataToPNG(data)
                guard let pngData = finalData, !pngData.isEmpty else {
                    return
                }
                let dimensions = PasteboardAttachmentClassifier.imagePixelDimensions(from: pngData)
                let attachment = StagedAttachment(
                    filename: "Screenshot.png",
                    mimeType: UTType.png.preferredMIMEType ?? "image/png",
                    data: pngData,
                    fileURL: nil,
                    isImage: true,
                    pixelWidth: dimensions?.width,
                    pixelHeight: dimensions?.height
                )
                Task { @MainActor in
                    draft.addAttachment(attachment)
                }
            }
        }
        return true
    }
}

// MARK: - AdaptiveComposerLayout

/// Custom SwiftUI `Layout` repositioning the 4 core composer controls between State A (single-row
/// compact pill) and State B/C (multi-row expanded card) without changing SwiftUI structural
/// identity so AppKit's `NSTextView` is never torn down or unfocused during morph transitions.
private nonisolated struct AdaptiveComposerLayout: Layout {

    let isExpanded: Bool
    let controlRowHeight: CGFloat
    let horizontalSpacing: CGFloat
    let expandedTextHorizontalInset: CGFloat
    let expandedTextTopPadding: CGFloat
    let expandedRowSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 4 else {
            return .zero
        }

        let containerWidth = proposal.width ?? 480
        let plusSize = subviews[0].sizeThatFits(.unspecified)
        let modelSize = subviews[2].sizeThatFits(.unspecified)
        let primarySize = subviews[3].sizeThatFits(.unspecified)

        if !isExpanded {
            let minTextSlotWidth: CGFloat = containerWidth >= 280 ? 116 : 48
            let maxModelWidth = max(
                64,
                containerWidth - plusSize.width - primarySize.width - horizontalSpacing * 3 - minTextSlotWidth
            )
            let clampedModelWidth = min(modelSize.width, maxModelWidth)
            let textSlotWidth = max(
                48,
                containerWidth - plusSize.width - clampedModelWidth - primarySize.width - horizontalSpacing * 3
            )
            let textSize = subviews[1].sizeThatFits(ProposedViewSize(width: textSlotWidth, height: nil))
            let rowHeight = max(controlRowHeight, textSize.height)
            return CGSize(width: containerWidth, height: rowHeight)
        }

        let fullTextWidth = max(40, containerWidth - expandedTextHorizontalInset * 2)
        let textSize = subviews[1].sizeThatFits(ProposedViewSize(width: fullTextWidth, height: nil))
        let totalHeight = expandedTextTopPadding + textSize.height + expandedRowSpacing + controlRowHeight
        return CGSize(width: containerWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 4 else {
            return
        }

        let plusSize = subviews[0].sizeThatFits(.unspecified)
        let modelSize = subviews[2].sizeThatFits(.unspecified)
        let primarySize = subviews[3].sizeThatFits(.unspecified)

        if !isExpanded {
            let midY = bounds.midY

            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: midY),
                anchor: .leading,
                proposal: ProposedViewSize(plusSize)
            )

            subviews[3].place(
                at: CGPoint(x: bounds.maxX, y: midY),
                anchor: .trailing,
                proposal: ProposedViewSize(primarySize)
            )

            let minTextSlotWidth: CGFloat = bounds.width >= 280 ? 116 : 48
            let maxModelWidth = max(
                64,
                bounds.width - plusSize.width - primarySize.width - horizontalSpacing * 3 - minTextSlotWidth
            )
            let clampedModelSize = CGSize(
                width: min(modelSize.width, maxModelWidth),
                height: modelSize.height
            )
            let modelMaxX = bounds.maxX - primarySize.width - horizontalSpacing
            subviews[2].place(
                at: CGPoint(x: modelMaxX, y: midY),
                anchor: .trailing,
                proposal: ProposedViewSize(clampedModelSize)
            )

            let textMinX = bounds.minX + plusSize.width + horizontalSpacing
            let textMaxX = modelMaxX - clampedModelSize.width - horizontalSpacing
            let textWidth = max(48, textMaxX - textMinX)
            let textSize = subviews[1].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))

            subviews[1].place(
                at: CGPoint(x: textMinX, y: midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: textWidth, height: textSize.height)
            )
        } else {
            let textMinX = bounds.minX + expandedTextHorizontalInset
            let textWidth = max(40, bounds.width - expandedTextHorizontalInset * 2)
            let textSize = subviews[1].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
            let textTopY = bounds.minY + expandedTextTopPadding

            subviews[1].place(
                at: CGPoint(x: textMinX, y: textTopY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: textWidth, height: textSize.height)
            )

            let bottomRowMidY = bounds.maxY - controlRowHeight / 2

            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bottomRowMidY),
                anchor: .leading,
                proposal: ProposedViewSize(plusSize)
            )

            subviews[3].place(
                at: CGPoint(x: bounds.maxX, y: bottomRowMidY),
                anchor: .trailing,
                proposal: ProposedViewSize(primarySize)
            )

            let modelMaxX = bounds.maxX - primarySize.width - horizontalSpacing
            subviews[2].place(
                at: CGPoint(x: modelMaxX, y: bottomRowMidY),
                anchor: .trailing,
                proposal: ProposedViewSize(modelSize)
            )
        }
    }
}

// MARK: - Preference Keys

private nonisolated struct ComposerWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() {
            value = next
        }
    }
}

private nonisolated struct ModelButtonWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() {
            value = next
        }
    }
}
