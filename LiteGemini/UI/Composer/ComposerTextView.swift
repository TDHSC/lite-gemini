import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PasteboardClassificationResult

/// Outcome of inspecting clipboard, drag-and-drop, or file-panel items for composer staging.
nonisolated struct PasteboardClassificationResult: Equatable, Sendable {

    /// Parsed files and images ready to append to `ComposerDraftState.stagedAttachments`.
    let attachments: [StagedAttachment]

    /// `true` when at least one dropped or pasted item is a directory, requiring Classic Web Mode.
    let containsDirectory: Bool

    /// `true` when any attachment or directory payload was matched and plain-text paste should be bypassed.
    var hasAttachmentPayload: Bool {
        !attachments.isEmpty || containsDirectory
    }

    init(attachments: [StagedAttachment] = [], containsDirectory: Bool = false) {
        self.attachments = attachments
        self.containsDirectory = containsDirectory
    }
}

// MARK: - PasteboardAttachmentClassifier

/// Pure, testable classifier converting `NSPasteboard` payloads and file URLs into
/// `StagedAttachment` values or folder-fallback signals.
nonisolated enum PasteboardAttachmentClassifier {

    /// Pasteboard types treated as raw clipboard image payloads (e.g., macOS screenshots).
    private static let rawImagePasteboardTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.webP.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier)
    ]

    /// Returns `true` when `pasteboard` carries file URLs or raw image data supported by the composer.
    static func canReadSupportedAttachment(from pasteboard: NSPasteboard) -> Bool {
        if !extractFileURLs(from: pasteboard).isEmpty {
            return true
        }
        guard let types = pasteboard.types else {
            return false
        }
        return rawImagePasteboardTypes.contains { types.contains($0) }
    }

    /// Classifies the contents of an `NSPasteboard`, prioritizing file URLs before raw clipboard
    /// image data so Finder file copies never duplicate icon TIFFs as screenshots.
    static func classifyPasteboard(_ pasteboard: NSPasteboard) -> PasteboardClassificationResult {
        let fileURLs = extractFileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return classifyFileURLs(fileURLs)
        }

        let imageAttachments = extractRawClipboardImages(from: pasteboard)
        return PasteboardClassificationResult(
            attachments: imageAttachments,
            containsDirectory: false
        )
    }

    /// Classifies an array of local file URLs into staged attachments and directory detections.
    static func classifyFileURLs(_ urls: [URL]) -> PasteboardClassificationResult {
        var attachments: [StagedAttachment] = []
        var containsDirectory = false

        for url in urls where url.isFileURL {
            if isDirectoryURL(url) {
                containsDirectory = true
                continue
            }

            if let attachment = buildAttachment(fromFileURL: url) {
                attachments.append(attachment)
            }
        }

        return PasteboardClassificationResult(
            attachments: attachments,
            containsDirectory: containsDirectory
        )
    }

    /// Reads image pixel dimensions using `ImageIO`, accounting for EXIF orientation transforms.
    static func imagePixelDimensions(from data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              rawWidth > 0,
              rawHeight > 0 else {
            return nil
        }

        // EXIF orientations 5–8 rotate 90°/270°, swapping display width and height.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int,
           (5...8).contains(orientation) {
            return (width: rawHeight, height: rawWidth)
        }
        return (width: rawWidth, height: rawHeight)
    }

    /// Transcodes raw image bytes (such as macOS clipboard `.tiff`) into lossless PNG `Data`.
    static func convertImageDataToPNG(_ data: Data) -> Data? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let output = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(
                output as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            ) {
                CGImageDestinationAddImage(destination, cgImage, nil)
                if CGImageDestinationFinalize(destination) {
                    return output as Data
                }
            }
        }

        if let bitmap = NSBitmapImageRep(data: data),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            return pngData
        }

        return nil
    }

    /// Returns `true` when `url` represents a filesystem directory rather than a regular file.
    static func isDirectoryURL(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        if let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey]),
           let isDirectory = values.isDirectory {
            return isDirectory
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) {
            return isDir.boolValue
        }
        return url.hasDirectoryPath
    }

    // MARK: - Private Helpers

    private static func extractFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var collected: [URL] = []

        if let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            for url in objects where url.isFileURL {
                collected.append(url)
            }
        }

        if collected.isEmpty, let items = pasteboard.pasteboardItems {
            for item in items {
                if let urlString = item.string(forType: .fileURL),
                   let url = URL(string: urlString),
                   url.isFileURL {
                    collected.append(url)
                }
            }
        }

        return collected
    }

    private static func extractRawClipboardImages(from pasteboard: NSPasteboard) -> [StagedAttachment] {
        var attachments: [StagedAttachment] = []
        var imageIndex = 0

        let items = pasteboard.pasteboardItems ?? []
        if !items.isEmpty {
            for item in items {
                if let attachment = buildRawImageAttachment(from: item, index: imageIndex) {
                    attachments.append(attachment)
                    imageIndex += 1
                }
            }
        }

        if attachments.isEmpty {
            if let pngData = pasteboard.data(forType: .png), !pngData.isEmpty {
                let dimensions = imagePixelDimensions(from: pngData)
                attachments.append(
                    StagedAttachment(
                        filename: screenshotFilename(forIndex: 0),
                        mimeType: UTType.png.preferredMIMEType ?? "image/png",
                        data: pngData,
                        fileURL: nil,
                        isImage: true,
                        pixelWidth: dimensions?.width,
                        pixelHeight: dimensions?.height
                    )
                )
            } else if let tiffData = pasteboard.data(forType: .tiff),
                      !tiffData.isEmpty,
                      let pngData = convertImageDataToPNG(tiffData) {
                let dimensions = imagePixelDimensions(from: pngData)
                attachments.append(
                    StagedAttachment(
                        filename: screenshotFilename(forIndex: 0),
                        mimeType: UTType.png.preferredMIMEType ?? "image/png",
                        data: pngData,
                        fileURL: nil,
                        isImage: true,
                        pixelWidth: dimensions?.width,
                        pixelHeight: dimensions?.height
                    )
                )
            }
        }

        return attachments
    }

    private static func buildRawImageAttachment(from item: NSPasteboardItem, index: Int) -> StagedAttachment? {
        if let pngData = item.data(forType: .png), !pngData.isEmpty {
            let dimensions = imagePixelDimensions(from: pngData)
            return StagedAttachment(
                filename: screenshotFilename(forIndex: index),
                mimeType: UTType.png.preferredMIMEType ?? "image/png",
                data: pngData,
                fileURL: nil,
                isImage: true,
                pixelWidth: dimensions?.width,
                pixelHeight: dimensions?.height
            )
        }

        if let tiffData = item.data(forType: .tiff),
           !tiffData.isEmpty,
           let pngData = convertImageDataToPNG(tiffData) {
            let dimensions = imagePixelDimensions(from: pngData)
            return StagedAttachment(
                filename: screenshotFilename(forIndex: index),
                mimeType: UTType.png.preferredMIMEType ?? "image/png",
                data: pngData,
                fileURL: nil,
                isImage: true,
                pixelWidth: dimensions?.width,
                pixelHeight: dimensions?.height
            )
        }

        let extraTypes: [(UTType, String)] = [
            (.jpeg, "jpg"),
            (.gif, "gif"),
            (.webP, "webp"),
            (.heic, "heic")
        ]
        for (utType, ext) in extraTypes {
            let pbType = NSPasteboard.PasteboardType(utType.identifier)
            if let rawData = item.data(forType: pbType), !rawData.isEmpty {
                let dimensions = imagePixelDimensions(from: rawData)
                let filename = index == 0 ? "Image.\(ext)" : "Image \(index + 1).\(ext)"
                return StagedAttachment(
                    filename: filename,
                    mimeType: utType.preferredMIMEType ?? "image/\(ext)",
                    data: rawData,
                    fileURL: nil,
                    isImage: true,
                    pixelWidth: dimensions?.width,
                    pixelHeight: dimensions?.height
                )
            }
        }

        return nil
    }

    private static func buildAttachment(fromFileURL url: URL) -> StagedAttachment? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return nil
        }

        let resolvedType: UTType = {
            if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                return contentType
            }
            if !url.pathExtension.isEmpty, let byExt = UTType(filenameExtension: url.pathExtension) {
                return byExt
            }
            return .data
        }()

        let isImage = resolvedType.conforms(to: .image)
        let mimeType: String = {
            if let preferred = resolvedType.preferredMIMEType, !preferred.isEmpty {
                return preferred
            }
            if resolvedType.conforms(to: .text) || resolvedType.conforms(to: .sourceCode) {
                return "text/plain"
            }
            return "application/octet-stream"
        }()

        let dimensions = isImage ? imagePixelDimensions(from: data) : nil
        let filename = url.lastPathComponent.isEmpty ? "Attachment" : url.lastPathComponent

        return StagedAttachment(
            filename: filename,
            mimeType: mimeType,
            data: data,
            fileURL: url,
            isImage: isImage,
            pixelWidth: dimensions?.width,
            pixelHeight: dimensions?.height
        )
    }

    private static func screenshotFilename(forIndex index: Int) -> String {
        index == 0 ? "Screenshot.png" : "Screenshot \(index + 1).png"
    }
}

// MARK: - ComposerWrapCalculator

/// Pure hysteresis evaluator deciding whether single-line composer text should expand to a
/// multi-row card without oscillating around the narrow single-row slot width.
nonisolated struct ComposerWrapCalculator: Equatable, Sendable {

    /// Margin subtracted from `singleRowAvailableWidth` before expanding out of `.compactPill`.
    let expandMargin: CGFloat

    /// Larger margin subtracted from `singleRowAvailableWidth` before collapsing back to `.compactPill`.
    let collapseMargin: CGFloat

    /// Default composer hysteresis configuration (`16pt` deadband).
    static let `default` = ComposerWrapCalculator(expandMargin: 4, collapseMargin: 20)

    init(expandMargin: CGFloat = 4, collapseMargin: CGFloat = 20) {
        self.expandMargin = max(0, expandMargin)
        self.collapseMargin = max(collapseMargin, self.expandMargin + 1)
    }

    /// Computes the next wrapped state using an invariant single-row slot width and hysteresis deadband.
    func shouldWrap(
        currentlyWrapped: Bool,
        text: String,
        measuredSingleLineWidth: CGFloat,
        singleRowAvailableWidth: CGFloat
    ) -> Bool {
        if text.isEmpty {
            return false
        }
        if text.contains("\n") || text.contains("\r") {
            return true
        }
        guard singleRowAvailableWidth > 0 else {
            return currentlyWrapped
        }

        let expandThreshold = max(0, singleRowAvailableWidth - expandMargin)
        let collapseThreshold = max(0, singleRowAvailableWidth - collapseMargin)

        if currentlyWrapped {
            return measuredSingleLineWidth >= collapseThreshold
        }
        return measuredSingleLineWidth > expandThreshold
    }

    /// Measures the natural single-line width of `text` rendered in `font` and applies hysteresis.
    func evaluate(
        currentlyWrapped: Bool,
        text: String,
        font: NSFont,
        singleRowAvailableWidth: CGFloat
    ) -> Bool {
        if text.isEmpty {
            return false
        }
        if text.contains("\n") || text.contains("\r") {
            return true
        }
        let width = Self.measureSingleLineWidth(for: text, font: font)
        return shouldWrap(
            currentlyWrapped: currentlyWrapped,
            text: text,
            measuredSingleLineWidth: width,
            singleRowAvailableWidth: singleRowAvailableWidth
        )
    }

    /// Computes the unconstrained single-line rendered width of `text` for a given `NSFont`.
    static func measureSingleLineWidth(for text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else {
            return 0
        }
        let size = (text as NSString).size(withAttributes: [.font: font])
        return ceil(size.width)
    }
}

// MARK: - ComposerNSTextView

/// AppKit `NSTextView` subclass powering Lite Gemini's native composer with synchronous CJK IME
/// `hasMarkedText()` routing, `Shift+Return` newlines, empty-composer `↑` edit, `Esc` context
/// cancellation, and clipboard/drag-and-drop attachment interception.
class ComposerNSTextView: NSTextView {

    // MARK: - Callbacks

    /// Invoked when the user presses plain `Return` while no IME composition is active.
    var onSubmit: (() -> Void)?

    /// Invoked when the user presses `↑` in an empty composer while no IME composition is active.
    var onEditLastTurn: (() -> Void)?

    /// Invoked when the user presses `Esc` while no IME composition is active.
    var onCancelContext: (() -> Void)?

    /// Invoked when pasted or dropped files/images are classified into `StagedAttachment` items.
    var onAttachmentsAdded: (([StagedAttachment]) -> Void)?

    /// Invoked when a directory is pasted or dropped onto the composer.
    var onDirectoryDropped: (() -> Void)?

    /// Invoked as a supported attachment drag enters or leaves the text view.
    var onDragTargetingChanged: ((Bool) -> Void)?

    /// Injectable modifier-flags provider allowing deterministic headless `Shift+Return` testing.
    var currentModifierFlagsProvider: () -> NSEvent.ModifierFlags = {
        NSApp?.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureComposerBehavior()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureComposerBehavior()
    }

    private func configureComposerBehavior() {
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        allowsUndo = true
        drawsBackground = false
        backgroundColor = .clear
        isHorizontallyResizable = false
        isVerticallyResizable = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        textContainerInset = NSSize(width: 0, height: ComposerTextView.verticalTextInset)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true

        registerForDraggedTypes([
            .fileURL,
            .png,
            .tiff,
            .string
        ])
    }

    // MARK: - Key Command & IME Routing

    override func doCommand(by commandSelector: Selector) {
        let composing = hasMarkedText()

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if composing {
                super.doCommand(by: commandSelector)
                return
            }

            let modifiers = currentModifierFlagsProvider().intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }

            onSubmit?()
            return
        }

        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            if !composing && string.isEmpty {
                onEditLastTurn?()
                return
            }
            super.doCommand(by: commandSelector)
            return
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if composing {
                super.doCommand(by: commandSelector)
                return
            }

            onCancelContext?()
            return
        }

        super.doCommand(by: commandSelector)
    }

    // MARK: - Pasteboard Handling

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        // Ensure Cmd+V stays enabled when the clipboard carries only screenshot/image or file payloads.
        if item.action == #selector(paste(_:)),
           isEditable,
           PasteboardAttachmentClassifier.canReadSupportedAttachment(from: .general) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        handlePaste(from: .general) {
            super.paste(sender)
        }
    }

    /// Processes pasteboard contents, intercepting files/images/directories and falling back to
    /// `fallbackToSuper` for plain text. Returns `true` when attachment payload was intercepted.
    @discardableResult
    func handlePaste(from pasteboard: NSPasteboard, fallbackToSuper: (() -> Void)? = nil) -> Bool {
        let result = PasteboardAttachmentClassifier.classifyPasteboard(pasteboard)
        if result.hasAttachmentPayload {
            dispatchClassification(result)
            return true
        }
        fallbackToSuper?()
        return false
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if PasteboardAttachmentClassifier.canReadSupportedAttachment(from: sender.draggingPasteboard) {
            onDragTargetingChanged?(true)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if PasteboardAttachmentClassifier.canReadSupportedAttachment(from: sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragTargetingChanged?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if PasteboardAttachmentClassifier.canReadSupportedAttachment(from: sender.draggingPasteboard) {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDragTargetingChanged?(false)
        let result = PasteboardAttachmentClassifier.classifyPasteboard(sender.draggingPasteboard)
        if result.hasAttachmentPayload {
            dispatchClassification(result)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        onDragTargetingChanged?(false)
        super.concludeDragOperation(sender)
    }

    // MARK: - Private Dispatch

    private func dispatchClassification(_ result: PasteboardClassificationResult) {
        if result.containsDirectory {
            onDirectoryDropped?()
        }
        if !result.attachments.isEmpty {
            onAttachmentsAdded?(result.attachments)
        }
    }
}

// MARK: - ComposerTextView

/// SwiftUI `NSViewRepresentable` wrapping `ComposerNSTextView` inside a borderless `NSScrollView`
/// with 1-to-7 line auto-sizing, scroll-offset tracking for top fade masks, single-row wrap
/// hysteresis reporting, and programmatic focus triggers.
struct ComposerTextView: NSViewRepresentable {

    // MARK: - Layout Constants

    /// Single-line text editor height (`~22pt`).
    static let singleLineHeight: CGFloat = 22
    /// Maximum visible text editor height before internal vertical scrolling (`7 lines × 22pt`).
    static let maxVisibleHeight: CGFloat = 154
    /// Top and bottom text container inset centering a single 14pt line inside `22pt`.
    static let verticalTextInset: CGFloat = 2
    /// Inter-line spacing matching `22pt` vertical cadence across Latin and CJK glyphs.
    static let lineSpacing: CGFloat = 4
    /// Native composer body font shared with hysteresis width calculation.
    static let composerFont: NSFont = .systemFont(ofSize: 14, weight: .regular)

    // MARK: - Properties

    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @Binding var wrapsSingleRow: Bool
    @Binding var isScrolledDown: Bool

    let singleRowAvailableWidth: CGFloat
    let focusTrigger: Int
    let isEditable: Bool
    let onSubmit: () -> Void
    let onEditLastTurn: () -> Void
    let onCancelContext: () -> Void
    let onAttachmentsAdded: ([StagedAttachment]) -> Void
    let onDirectoryDropped: () -> Void
    let onDragTargetingChanged: (Bool) -> Void

    // MARK: - NSViewRepresentable

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
        scrollView.contentView.postsBoundsChangedNotifications = true

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

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = Self.lineSpacing

        textView.font = Self.composerFont
        textView.defaultParagraphStyle = paragraphStyle
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.typingAttributes = [
            .font: Self.composerFont,
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
        context.coordinator.registerScrollObserver(for: scrollView)

        if focusTrigger > 0 {
            context.coordinator.lastHandledFocusTrigger = focusTrigger
            context.coordinator.focusTextViewAsync()
        }

        context.coordinator.scheduleMetricsSync()
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

        // Preserve active IME marked text unless the draft was externally cleared (e.g., on send/cancel).
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
            coordinator.focusTextViewAsync()
        }

        coordinator.scheduleMetricsSync()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.unregisterScrollObserver()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: ComposerTextView
        weak var scrollView: NSScrollView?
        weak var textView: ComposerNSTextView?
        var lastHandledFocusTrigger: Int = 0
        var lastReportedText: String
        private var isMetricsSyncScheduled = false

        init(parent: ComposerTextView) {
            self.parent = parent
            self.lastReportedText = parent.text
        }

        func bindCallbacks(on textView: ComposerNSTextView) {
            textView.onSubmit = { [weak self] in
                self?.parent.onSubmit()
            }
            textView.onEditLastTurn = { [weak self] in
                self?.parent.onEditLastTurn()
            }
            textView.onCancelContext = { [weak self] in
                self?.parent.onCancelContext()
            }
            textView.onAttachmentsAdded = { [weak self] attachments in
                self?.parent.onAttachmentsAdded(attachments)
            }
            textView.onDirectoryDropped = { [weak self] in
                self?.parent.onDirectoryDropped()
            }
            textView.onDragTargetingChanged = { [weak self] targeted in
                self?.parent.onDragTargetingChanged(targeted)
            }
        }

        func registerScrollObserver(for scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewFrameDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: scrollView
            )
            scrollView.postsFrameChangedNotifications = true
        }

        func unregisterScrollObserver() {
            NotificationCenter.default.removeObserver(self)
        }

        func focusTextViewAsync() {
            DispatchQueue.main.async { [weak self] in
                guard let textView = self?.textView,
                      let window = textView.window else {
                    return
                }
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            }
        }

        // MARK: - NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView else {
                return
            }

            let updatedText = textView.string
            lastReportedText = updatedText
            if parent.text != updatedText {
                parent.text = updatedText
            }

            syncMetricsImmediately()
        }

        // MARK: - Notifications

        @objc
        func clipViewBoundsDidChange(_ notification: Notification) {
            updateScrollFadeState()
        }

        @objc
        func scrollViewFrameDidChange(_ notification: Notification) {
            scheduleMetricsSync()
        }

        // MARK: - Layout & Scroll Measurement

        func scheduleMetricsSync() {
            guard !isMetricsSyncScheduled else {
                return
            }
            isMetricsSyncScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.isMetricsSyncScheduled = false
                self.syncMetricsImmediately()
            }
        }

        private func syncMetricsImmediately() {
            guard let textView, let scrollView else {
                return
            }

            let liveText = textView.string
            let nextWrapped = ComposerWrapCalculator.default.evaluate(
                currentlyWrapped: parent.wrapsSingleRow,
                text: liveText,
                font: ComposerTextView.composerFont,
                singleRowAvailableWidth: parent.singleRowAvailableWidth
            )
            if parent.wrapsSingleRow != nextWrapped {
                parent.wrapsSingleRow = nextWrapped
            }

            let nextHeight = computeVisibleHeight(for: textView)
            if abs(parent.measuredHeight - nextHeight) > 0.5 {
                parent.measuredHeight = nextHeight
            }

            if nextHeight < ComposerTextView.maxVisibleHeight,
               scrollView.contentView.bounds.origin.y > 0 {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }

            updateScrollFadeState()
        }

        private func computeVisibleHeight(for textView: ComposerNSTextView) -> CGFloat {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return ComposerTextView.singleLineHeight
            }

            let availableContainerWidth = scrollView?.contentSize.width ?? textView.bounds.width
            if availableContainerWidth > 1 {
                if abs(textView.frame.width - availableContainerWidth) > 0.5 {
                    textView.frame.size.width = availableContainerWidth
                }
                if abs(textContainer.containerSize.width - availableContainerWidth) > 0.5 {
                    textContainer.containerSize = NSSize(
                        width: availableContainerWidth,
                        height: CGFloat.greatestFiniteMagnitude
                    )
                }
            }

            layoutManager.ensureLayout(for: textContainer)
            var usedHeight = layoutManager.usedRect(for: textContainer).height
            if usedHeight < 1 {
                usedHeight = layoutManager.defaultLineHeight(for: ComposerTextView.composerFont)
            }

            let extraRect = layoutManager.extraLineFragmentRect
            if extraRect.height > 0 && extraRect.maxY > usedHeight {
                usedHeight = extraRect.maxY
            }

            let rawTotal = ceil(usedHeight + textView.textContainerInset.height * 2)
            return min(
                max(rawTotal, ComposerTextView.singleLineHeight),
                ComposerTextView.maxVisibleHeight
            )
        }

        private func updateScrollFadeState() {
            guard let scrollView else {
                return
            }
            let scrolledDown = scrollView.contentView.bounds.origin.y > 2
            if parent.isScrolledDown != scrolledDown {
                parent.isScrolledDown = scrolledDown
            }
        }
    }
}
