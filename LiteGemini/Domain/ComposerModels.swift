import Foundation

// MARK: - ComposerToolMode

/// Optional Gemini composer tool mode (`Canvas` or `Deep Research`) synced with `toolbox-drawer`.
nonisolated enum ComposerToolMode: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case canvas
    case deepResearch

    var id: String { rawValue }
}

// MARK: - StagedFolderEntry

/// Single file inside a staged codebase folder preserving its `webkitRelativePath` hierarchy.
nonisolated struct StagedFolderEntry: Equatable, Sendable {

    /// Slash-delimited path starting with the root folder name (e.g. `"my-app/src/index.ts"`).
    let relativePath: String
    let filename: String
    let mimeType: String
    let data: Data

    init(
        relativePath: String,
        filename: String,
        mimeType: String,
        data: Data
    ) {
        self.relativePath = relativePath
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

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
    let folderFileCount: Int?

    var isFolder: Bool {
        (folderFileCount ?? 0) > 0
    }

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        byteCount: Int,
        isImage: Bool,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        folderFileCount: Int? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.isImage = isImage
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.folderFileCount = folderFileCount
    }
}

// MARK: - StagedAttachment

/// In-memory file, image, or filtered directory bundle staged in the composer prior to upload.
nonisolated struct StagedAttachment: Identifiable, Equatable, Sendable {

    let id: UUID
    let filename: String
    let mimeType: String
    let data: Data
    let fileURL: URL?
    let isImage: Bool
    let pixelWidth: Int?
    let pixelHeight: Int?
    let folderEntries: [StagedFolderEntry]?

    var isFolder: Bool {
        !(folderEntries?.isEmpty ?? true)
    }

    var totalByteCount: Int {
        if let folderEntries, !folderEntries.isEmpty {
            return folderEntries.reduce(0) { $0 + $1.data.count }
        }
        return data.count
    }

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        data: Data,
        fileURL: URL? = nil,
        isImage: Bool,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        folderEntries: [StagedFolderEntry]? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.fileURL = fileURL
        self.isImage = isImage
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.folderEntries = folderEntries
    }

    /// Produces a metadata-only summary suitable for persisting inside `ConversationSnapshot` files.
    var summary: StagedAttachmentSummary {
        StagedAttachmentSummary(
            id: id,
            filename: filename,
            mimeType: mimeType,
            byteCount: totalByteCount,
            isImage: isImage,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            folderFileCount: folderEntries?.count
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
