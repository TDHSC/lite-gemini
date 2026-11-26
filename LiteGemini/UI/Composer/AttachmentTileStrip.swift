import AppKit
import Foundation
import SwiftUI

// MARK: - AttachmentTileStrip

/// Horizontal strip of `68×68pt` rounded-`14pt` (`26pt` outer − `12pt` inset) concentric
/// preview tiles for staged composer images and files, each with a `20×20pt` dark frosted
/// remove button.
struct AttachmentTileStrip: View {

    // MARK: - Constants

    static let tileSize: CGFloat = 68
    static let tileCornerRadius: CGFloat = LiquidGlassMetrics.concentricInnerRadius(
        outer: LiquidGlassMetrics.composerOuterCornerRadius,
        padding: 12
    )
    static let removeButtonSize: CGFloat = 20

    // MARK: - Properties

    let attachments: [StagedAttachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentTileView(
                        attachment: attachment,
                        onRemove: {
                            onRemove(attachment.id)
                        }
                    )
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled(false)
    }
}

// MARK: - AttachmentTileView

/// Single `68×68pt` concentric attachment preview tile supporting image thumbnails and
/// compact icon + extension cards for non-image files.
private struct AttachmentTileView: View {

    let attachment: StagedAttachment
    let onRemove: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHoveringRemove = false

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AttachmentTileStrip.tileCornerRadius, style: .continuous)
    }

    private var insetOutlineColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            tileContent
                .frame(width: AttachmentTileStrip.tileSize, height: AttachmentTileStrip.tileSize)
                .clipShape(tileShape)
                .overlay {
                    tileShape.strokeBorder(insetOutlineColor, lineWidth: 1)
                }

            removeButton
                .padding(4)
        }
        .frame(width: AttachmentTileStrip.tileSize, height: AttachmentTileStrip.tileSize)
        .help(attachment.filename)
    }

    // MARK: - Tile Content

    @ViewBuilder
    private var tileContent: some View {
        if attachment.isImage, let image = AttachmentThumbnailCache.image(for: attachment) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: AttachmentTileStrip.tileSize, height: AttachmentTileStrip.tileSize)
                .accessibilityLabel(Text(attachment.filename))
        } else {
            fileTileContent
        }
    }

    private var fileTileContent: some View {
        let descriptor = FileTileDescriptor(filename: attachment.filename, mimeType: attachment.mimeType)

        return VStack(spacing: 3) {
            Spacer(minLength: 4)

            Image(systemName: descriptor.symbolName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.76))

            if !descriptor.extensionBadge.isEmpty {
                Text(descriptor.extensionBadge)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.82))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .lineLimit(1)
            }

            Text(attachment.filename)
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.bottom, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LiquidGlassColors.recessedCodeSurface)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(attachment.filename))
    }

    // MARK: - Remove Button

    private var removeButton: some View {
        Button(action: onRemove) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)

                Circle()
                    .fill(Color.black.opacity(isHoveringRemove ? 0.78 : 0.58))

                Circle()
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: LiquidGlassMetrics.hairlineWidth)

                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.96))
            }
            .frame(
                width: AttachmentTileStrip.removeButtonSize,
                height: AttachmentTileStrip.removeButtonSize
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHoveringRemove = hovering
            }
        }
        .help(String(localized: "Remove attachment"))
        .accessibilityLabel(
            Text(String(localized: "Remove \(attachment.filename)"))
        )
    }
}

// MARK: - AttachmentThumbnailCache

/// Bounded in-memory cache of decoded `NSImage` previews keyed by `StagedAttachment.id` so
/// typing in the composer does not re-decode raw image bytes on every keystroke.
@MainActor
private enum AttachmentThumbnailCache {

    private static let cache: NSCache<NSUUID, NSImage> = {
        let store = NSCache<NSUUID, NSImage>()
        store.countLimit = 32
        return store
    }()

    static func image(for attachment: StagedAttachment) -> NSImage? {
        let key = attachment.id as NSUUID
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let decoded = NSImage(data: attachment.data) else {
            return nil
        }
        cache.setObject(decoded, forKey: key)
        return decoded
    }
}

// MARK: - FileTileDescriptor

/// Maps non-image attachment filenames and MIME types to an SF Symbol and compact extension label.
private nonisolated struct FileTileDescriptor {

    let symbolName: String
    let extensionBadge: String

    init(filename: String, mimeType: String) {
        let rawExt = (filename as NSString).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let upperExt = rawExt.uppercased()
        self.extensionBadge = upperExt.count > 6 ? String(upperExt.prefix(6)) : upperExt

        let lowerExt = rawExt.lowercased()
        let lowerMime = mimeType.lowercased()

        if lowerExt == "pdf" || lowerMime == "application/pdf" {
            self.symbolName = "doc.richtext"
        } else if [
            "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "c", "cpp", "h", "hpp",
            "java", "kt", "rb", "sh", "zsh", "json", "yaml", "yml", "toml", "xml", "html", "css", "sql"
        ].contains(lowerExt) {
            self.symbolName = "chevron.left.forwardslash.chevron.right"
        } else if ["csv", "tsv", "xls", "xlsx", "numbers"].contains(lowerExt) {
            self.symbolName = "tablecells"
        } else if ["zip", "tar", "gz", "tgz", "7z", "rar"].contains(lowerExt) {
            self.symbolName = "doc.zipper"
        } else if lowerMime.hasPrefix("audio/") || ["mp3", "wav", "m4a", "flac", "aac"].contains(lowerExt) {
            self.symbolName = "waveform"
        } else if lowerMime.hasPrefix("video/") || ["mp4", "mov", "mkv", "webm"].contains(lowerExt) {
            self.symbolName = "film"
        } else if lowerMime.hasPrefix("text/") || ["md", "markdown", "txt", "rtf", "log"].contains(lowerExt) {
            self.symbolName = "doc.text"
        } else {
            self.symbolName = "doc"
        }
    }
}
