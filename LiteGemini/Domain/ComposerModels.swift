import Foundation

// MARK: - StagedAttachmentSummary

/// Lightweight, disk-serializable metadata describing a user attachment without raw payload bytes.
nonisolated struct StagedAttachmentSummary: Codable, Equatable, Hashable, Identifiable, Sendable {

    let id: UUID
    let filename: String
    let mimeType: String
    let byteCount: Int
    let isImage: Bool
    let pixelWidth: Int?
    let pixelHeight: Int?

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        byteCount: Int,
        isImage: Bool,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.isImage = isImage
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

// MARK: - StagedAttachment

/// In-memory file or image staged in the composer prior to upload through the session bridge.
nonisolated struct StagedAttachment: Identifiable, Equatable, Sendable {

    let id: UUID
    let filename: String
    let mimeType: String
    let data: Data
    let fileURL: URL?
    let isImage: Bool
    let pixelWidth: Int?
    let pixelHeight: Int?

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        data: Data,
        fileURL: URL? = nil,
        isImage: Bool,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.fileURL = fileURL
        self.isImage = isImage
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Produces a metadata-only summary suitable for persisting inside `ConversationSnapshot` files.
    var summary: StagedAttachmentSummary {
        StagedAttachmentSummary(
            id: id,
            filename: filename,
            mimeType: mimeType,
            byteCount: data.count,
            isImage: isImage,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}

// MARK: - ComposerLayoutMode

/// Visual geometry state of the adaptive morphing composer.
nonisolated enum ComposerLayoutMode: String, Codable, Equatable, Hashable, Sendable {
    /// Single-row compact 52pt pill used when text fits on one line and no attachments are staged.
    case compactPill
    /// Multi-row 26pt-radius card used for multi-line text or staged attachments.
    case expandedCard
}
