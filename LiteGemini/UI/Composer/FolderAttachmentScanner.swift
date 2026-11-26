import Foundation
import UniformTypeIdentifiers

// MARK: - FolderAttachmentScanner

/// Pure, thread-safe directory scanner that collects source and document files from a local
/// folder for native Gemini codebase upload while pruning VCS metadata, dependency caches,
/// build artifacts, and binary blobs.
nonisolated enum FolderAttachmentScanner {

    /// Maximum number of files collected from a single folder to stay within Gemini's upload limits.
    static let maxFilesPerFolder: Int = 500
    /// Maximum size of any single file inside a scanned folder (`2 MiB`).
    static let maxSingleFileBytes: Int = 2 * 1024 * 1024
    /// Maximum cumulative byte budget across all files in a scanned folder (`32 MiB`).
    static let maxTotalFolderBytes: Int = 32 * 1024 * 1024

    /// Directory names pruned during traversal so large dependency or build trees never stall scanning.
    private static let ignoredDirectoryNames: Set<String> = [
        ".git", ".hg", ".svn", ".bzr",
        "node_modules", "bower_components", ".pnpm-store",
        ".build", "build", "dist", "out", "target", "DerivedData",
        "Pods", "Carthage", ".swiftpm",
        ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular",
        "__pycache__", ".venv", "venv", "env", ".tox", ".mypy_cache", ".pytest_cache", ".ruff_cache",
        "vendor", ".bundle", ".gradle", ".idea", ".vscode", ".cursor", "coverage", "xcuserdata"
    ]

    /// Exact filenames skipped during codebase traversal.
    private static let ignoredExactFilenames: Set<String> = [
        ".DS_Store", "Thumbs.db", "Desktop.ini",
        "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "Cargo.lock", "Podfile.lock"
    ]

    /// Binary or archive extensions skipped when collecting text/code/document files from a folder.
    private static let ignoredFileExtensions: Set<String> = [
        "o", "a", "lo", "la", "so", "dylib", "dll", "exe", "bin", "out", "app", "dSYM",
        "class", "pyc", "pyo", "pyd", "jar", "war", "ear", "wasm",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg", "ipa", "apk",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico", "icns", "psd",
        "mp3", "wav", "m4a", "flac", "aac", "ogg",
        "mp4", "mov", "avi", "mkv", "webm",
        "ttf", "otf", "woff", "woff2", "eot",
        "sqlite", "sqlite3", "db", "realm"
    ]

    /// Walks `directoryURL` and packages readable source/text files into a folder `StagedAttachment`.
    /// Returns `nil` when `directoryURL` is not a directory or contains zero eligible files.
    static func scanDirectory(_ directoryURL: URL) -> StagedAttachment? {
        let resolvedRoot = directoryURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedRoot.path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }

        let rawFolderName = resolvedRoot.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = rawFolderName.isEmpty ? "Codebase" : rawFolderName
        let rootPathComponents = resolvedRoot.standardizedFileURL.pathComponents

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .nameKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }

        var entries: [StagedFolderEntry] = []
        var cumulativeBytes = 0

        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: resourceKeys)
            let name = values?.name ?? item.lastPathComponent

            if values?.isSymbolicLink == true {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if values?.isDirectory == true {
                if ignoredDirectoryNames.contains(name) || (name.hasPrefix(".") && name != ".github") {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else {
                continue
            }

            if ignoredExactFilenames.contains(name) {
                continue
            }

            let ext = item.pathExtension.lowercased()
            if !ext.isEmpty && ignoredFileExtensions.contains(ext) {
                continue
            }

            if let fileSize = values?.fileSize,
               (fileSize <= 0 || fileSize > maxSingleFileBytes) {
                continue
            }

            guard let data = try? Data(contentsOf: item, options: [.mappedIfSafe]),
                  !data.isEmpty,
                  data.count <= maxSingleFileBytes else {
                continue
            }

            // Skip binary files containing null bytes in their leading 4 KiB header (except PDFs).
            if ext != "pdf" && looksLikeBinaryData(data) {
                continue
            }

            if cumulativeBytes + data.count > maxTotalFolderBytes {
                break
            }

            let itemComponents = item.standardizedFileURL.pathComponents
            let relativeSubcomponents: [String]
            if itemComponents.count > rootPathComponents.count,
               Array(itemComponents.prefix(rootPathComponents.count)) == rootPathComponents {
                relativeSubcomponents = Array(itemComponents.dropFirst(rootPathComponents.count))
            } else {
                relativeSubcomponents = [name]
            }

            let relativePath = ([folderName] + relativeSubcomponents).joined(separator: "/")
            let mimeType = resolvedMIMEType(forExtension: ext)

            entries.append(
                StagedFolderEntry(
                    relativePath: relativePath,
                    filename: name,
                    mimeType: mimeType,
                    data: data
                )
            )
            cumulativeBytes += data.count

            if entries.count >= maxFilesPerFolder {
                break
            }
        }

        guard !entries.isEmpty else {
            return nil
        }

        entries.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }

        return StagedAttachment(
            filename: folderName,
            mimeType: "inode/directory",
            data: Data(),
            fileURL: resolvedRoot,
            isImage: false,
            folderEntries: entries
        )
    }

    /// Formats a folder's entries into a single structured plain-text repository bundle used as an
    /// automatic fallback on accounts where Gemini's `Import code` menu item is unavailable.
    static func buildConsolidatedTextBundle(
        folderName: String,
        entries: [StagedFolderEntry]
    ) -> (filename: String, mimeType: String, data: Data) {
        var builder = "# Repository Folder: \(folderName)\n"
        builder += "# Files included: \(entries.count)\n\n"
        builder += "## Directory Tree\n"
        for entry in entries {
            builder += "- \(entry.relativePath)\n"
        }
        builder += "\n"

        for entry in entries {
            builder += "================================================================================\n"
            builder += "FILE: \(entry.relativePath)\n"
            builder += "================================================================================\n"
            if let text = String(data: entry.data, encoding: .utf8) {
                builder += text
                if !text.hasSuffix("\n") {
                    builder += "\n"
                }
            } else {
                builder += "[Non-UTF8 file: \(entry.data.count) bytes]\n"
            }
            builder += "\n"
        }

        let safeBase = folderName.replacingOccurrences(of: "/", with: "-")
        return (
            filename: "\(safeBase)-codebase.txt",
            mimeType: "text/plain",
            data: Data(builder.utf8)
        )
    }

    // MARK: - Helpers

    private static func looksLikeBinaryData(_ data: Data) -> Bool {
        let sampleCount = min(data.count, 4096)
        return data.prefix(sampleCount).contains(0)
    }

    private static func resolvedMIMEType(forExtension ext: String) -> String {
        guard !ext.isEmpty else {
            return "text/plain"
        }
        if let utType = UTType(filenameExtension: ext),
           let mime = utType.preferredMIMEType {
            return mime
        }
        return "text/plain"
    }
}
