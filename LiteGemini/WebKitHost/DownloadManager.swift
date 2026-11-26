import Foundation
import WebKit

/// A small value type describing one download notice shown in the main window.
struct DownloadNotice: Identifiable {
    /// Unique identity, so the view can restart its auto-dismiss timer
    let id = UUID()
    /// Already-localized message text
    let message: String
    /// File URL on success, used by "Show in Finder"; nil on error
    let fileURL: URL?
    /// True when the notice reports a failure
    let isError: Bool
}

/// Owns in-flight `WKDownload` objects, picks their destinations, and reports
/// results through `onNotice`. The download delegate is weak, so the owner must
/// keep the manager alive for the duration of the downloads.
final class DownloadManager: NSObject, WKDownloadDelegate {

    // MARK: - Stored State

    /// Directory downloads are saved into; a parameter so tests can pass a temporary directory
    let destinationDirectory: URL

    /// Destination URL chosen per in-flight download
    private var destinations: [ObjectIdentifier: URL] = [:]

    /// Callback the owner sets to receive result notices
    var onNotice: ((DownloadNotice) -> Void)?

    // MARK: - Initialization

    /// Creates a manager saving into the given directory (the user's Downloads folder by default)
    init(destinationDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) {
        self.destinationDirectory = destinationDirectory
    }

    // MARK: - Policy Helpers

    /// Policy for a navigation action: only anchor downloads (`<a download>`, the path Gemini
    /// uses) become downloads; everything else is allowed as before.
    static func downloadPolicy(for navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    /// Policy for a navigation response: download when a main-frame response cannot be
    /// shown (unshowable subframe content — ads, widgets — must not silently land in
    /// ~/Downloads), or when the server marks the response as an attachment in any frame;
    /// everything else is allowed as before.
    /// Takes plain values instead of a `WKNavigationResponse` so the logic is
    /// testable with hand-built `HTTPURLResponse` objects.
    static func downloadPolicy(for response: URLResponse, canShowMIMEType: Bool, isForMainFrame: Bool) -> WKNavigationResponsePolicy {
        if !canShowMIMEType && isForMainFrame {
            return .download
        }
        if let httpURLResponse = response as? HTTPURLResponse {
            let contentDisposition = httpURLResponse
                .value(forHTTPHeaderField: "Content-Disposition")?
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if contentDisposition?.hasPrefix("attachment") == true {
                return .download
            }
        }
        return .allow
    }

    // MARK: - Starting a Download

    /// Takes ownership of a download WebKit just created
    func begin(_ download: WKDownload) {
        download.delegate = self
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let fileName = suggestedFilename
            .split(separator: "/").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = fileName.isEmpty ? "download" : fileName

        let destination = uniqueDestination(forName: name)
        destinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let fileURL = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }

        // Make the Dock's Downloads stack bounce. Undocumented, but harmless if ignored.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.apple.DownloadFileFinished"),
            object: fileURL.path,
            deliverImmediately: true
        )

        onNotice?(DownloadNotice(
            message: String(localized: "Downloaded \(fileURL.lastPathComponent)"),
            fileURL: fileURL,
            isError: false
        ))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let fileURL = destinations.removeValue(forKey: ObjectIdentifier(download))
        // Remove the partial file, if any
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let nsError = error as NSError
        // Cancellation is not a failure the user needs to hear about
        guard nsError.code != NSURLErrorCancelled else { return }

        onNotice?(DownloadNotice(
            message: String(localized: "Download failed: \(error.localizedDescription)"),
            fileURL: nil,
            isError: true
        ))
    }

    // MARK: - Private Methods

    /// Returns a destination in `destinationDirectory` that does not collide with an
    /// existing file or a name already reserved by another in-flight download, appending
    /// " (1)", " (2)", … before the extension. After 1000 attempts, falls back to a
    /// UUID-based name. WebKit fails the download if the destination already exists.
    private func uniqueDestination(forName name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var candidate = destinationDirectory.appendingPathComponent(name)
        var counter = 1
        while isTaken(candidate) && counter <= 1000 {
            let numberedName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = destinationDirectory.appendingPathComponent(numberedName)
            counter += 1
        }
        if isTaken(candidate) {
            let uuidName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
            candidate = destinationDirectory.appendingPathComponent(uuidName)
        }
        return candidate
    }

    /// True when a file already exists at the URL, or another in-flight download has
    /// already reserved it: two downloads with the same name can start before either
    /// file exists on disk
    private func isTaken(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        return destinations.values.contains(url)
    }
}
