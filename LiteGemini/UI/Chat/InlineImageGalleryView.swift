import AppKit
import SwiftUI
import WebKit

// MARK: - AuthenticatedImageLoader

/// `@MainActor` image loader and in-memory cache that copies session cookies from
/// `WKWebsiteDataStore.default().httpCookieStore` into an ephemeral `URLSession` so
/// Google-authenticated inline and generated Gemini images load seamlessly.
@MainActor
final class AuthenticatedImageLoader {

    static let shared = AuthenticatedImageLoader()

    private let imageCache: NSCache<NSURL, NSImage>
    private var inFlightTasks: [URL: Task<NSImage, Error>] = [:]

    private init() {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 1024 * 1024
        self.imageCache = cache
    }

    /// Returns a cached image immediately when present, or fetches it using WebKit session cookies.
    func loadImage(from url: URL) async throws -> NSImage {
        let cacheKey = url as NSURL
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        if let existingTask = inFlightTasks[url] {
            return try await existingTask.value
        }

        let task = Task<NSImage, Error> { @MainActor in
            defer {
                self.inFlightTasks.removeValue(forKey: url)
            }

            if url.scheme?.lowercased() == "data" {
                let data = try Data(contentsOf: url)
                guard let image = NSImage(data: data) else {
                    throw URLError(.cannotDecodeContentData)
                }
                self.storeInCache(image, dataByteCount: data.count, for: cacheKey)
                return image
            }

            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            let data = try await Self.fetchImageData(from: url, cookies: cookies)
            guard let image = NSImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            self.storeInCache(image, dataByteCount: data.count, for: cacheKey)
            return image
        }

        inFlightTasks[url] = task
        return try await task.value
    }

    /// Returns a previously cached image synchronously if already decoded.
    func cachedImage(for url: URL) -> NSImage? {
        imageCache.object(forKey: url as NSURL)
    }

    private func storeInCache(_ image: NSImage, dataByteCount: Int, for key: NSURL) {
        imageCache.setObject(image, forKey: key, cost: max(1, dataByteCount))
    }

    private static func fetchImageData(from url: URL, cookies: [HTTPCookie]) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 30

        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        if let cookieStorage = configuration.httpCookieStorage {
            for cookie in cookies {
                cookieStorage.setCookie(cookie)
            }
        } else {
            let matchingCookies = cookies.filter { cookieMatchesURL($0, url: url) }
            let headers = HTTPCookie.requestHeaderFields(with: matchingCookies)
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }

        let session = URLSession(configuration: configuration)
        defer {
            session.finishTasksAndInvalidate()
        }

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func cookieMatchesURL(_ cookie: HTTPCookie, url: URL) -> Bool {
        if let expires = cookie.expiresDate, expires < Date() {
            return false
        }
        if cookie.isSecure && url.scheme?.lowercased() != "https" {
            return false
        }
        guard let host = url.host?.lowercased() else {
            return false
        }
        let domain = cookie.domain.lowercased()
        let bareDomain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard host == bareDomain || host.hasSuffix(".\(bareDomain)") else {
            return false
        }
        let path = url.path.isEmpty ? "/" : url.path
        return path.hasPrefix(cookie.path)
    }
}

// MARK: - InlineImageGalleryView

/// Renders inline and generated assistant images with WebKit cookie-authenticated loading,
/// a crisp `1pt` translucent inset outline, click-to-preview sheet, and one-click Save button.
struct InlineImageGalleryView: View {

    let images: [ImageAttachment]
    var onSave: ((ImageAttachment) -> Void)? = nil

    @State private var previewAttachment: ImageAttachment?

    var body: some View {
        Group {
            if images.count == 1, let single = images.first {
                InlineImageTileView(
                    attachment: single,
                    maxWidth: 380,
                    maxHeight: 300,
                    onPreview: { previewAttachment = single },
                    onSave: { handleSave(single) }
                )
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 10, alignment: .leading)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(images) { attachment in
                        InlineImageTileView(
                            attachment: attachment,
                            maxWidth: 240,
                            maxHeight: 200,
                            onPreview: { previewAttachment = attachment },
                            onSave: { handleSave(attachment) }
                        )
                    }
                }
            }
        }
        .sheet(item: $previewAttachment) { attachment in
            InlineImagePreviewSheet(
                attachment: attachment,
                onSave: { handleSave(attachment) },
                onDismiss: { previewAttachment = nil }
            )
        }
    }

    private func handleSave(_ attachment: ImageAttachment) {
        if let onSave {
            onSave(attachment)
        } else {
            NSWorkspace.shared.open(attachment.url)
        }
    }
}

// MARK: - InlineImageTileView

private struct InlineImageTileView: View {

    let attachment: ImageAttachment
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let onPreview: () -> Void
    let onSave: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var loadedImage: NSImage?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var reloadToken = UUID()
    @State private var isHovering = false
    @State private var isHoveringSave = false

    private var insetOutlineColor: Color {
        (colorScheme == .dark ? Color.white : Color.black).opacity(0.10)
    }

    private var aspectRatio: CGFloat? {
        guard let width = attachment.width, let height = attachment.height, width > 0, height > 0 else {
            return nil
        }
        return CGFloat(width) / CGFloat(height)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            contentSurface
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(insetOutlineColor, lineWidth: 1)
                )

            if loadedImage != nil {
                saveOverlayButton
                    .padding(8)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .task(id: "\(attachment.url.absoluteString)-\(reloadToken.uuidString)") {
            await loadImage()
        }
    }

    @ViewBuilder
    private var contentSurface: some View {
        if let loadedImage {
            Button(action: onPreview) {
                Image(nsImage: loadedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(attachment.altText ?? attachment.suggestedFilename))
            .accessibilityHint(Text("Preview Image"))
            .accessibilityAction(named: Text("Save Image")) {
                onSave()
            }
        } else if loadFailed {
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Unable to load image")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)

                Button {
                    reloadToken = UUID()
                } label: {
                    Text("Reload")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(minHeight: 28)
                        .glassCapsule(interactive: true)
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .frame(width: min(maxWidth, 240), height: 140)
            .background(LiquidGlassColors.recessedCodeSurface)
        } else {
            ZStack {
                LiquidGlassColors.recessedCodeSurface
                ProgressView()
                    .controlSize(.small)
            }
            .frame(width: placeholderWidth, height: placeholderHeight)
        }
    }

    private var saveOverlayButton: some View {
        Button(action: onSave) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("Save")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.primary.opacity(isHoveringSave ? 0.98 : 0.88))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minWidth: 28, minHeight: 28)
            .glassCapsule(interactive: true)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringSave = hovering
            }
        }
        .accessibilityLabel(Text("Save Image"))
    }

    private var placeholderWidth: CGFloat {
        min(maxWidth, 260)
    }

    private var placeholderHeight: CGFloat {
        if let ratio = aspectRatio, ratio > 0 {
            return min(maxHeight, max(110, placeholderWidth / ratio))
        }
        return 160
    }

    private func loadImage() async {
        if let cached = AuthenticatedImageLoader.shared.cachedImage(for: attachment.url) {
            loadedImage = cached
            loadFailed = false
            isLoading = false
            return
        }

        isLoading = true
        loadFailed = false
        do {
            let image = try await AuthenticatedImageLoader.shared.loadImage(from: attachment.url)
            guard !Task.isCancelled else {
                return
            }
            loadedImage = image
            isLoading = false
        } catch {
            guard !Task.isCancelled else {
                return
            }
            loadFailed = true
            isLoading = false
        }
    }
}

// MARK: - InlineImagePreviewSheet

private struct InlineImagePreviewSheet: View {

    let attachment: ImageAttachment
    let onSave: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedImage: NSImage?

    private var insetOutlineColor: Color {
        (colorScheme == .dark ? Color.white : Color.black).opacity(0.10)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(attachment.altText?.isEmpty == false ? (attachment.altText ?? attachment.suggestedFilename) : attachment.suggestedFilename)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 12)

                Button(action: onSave) {
                    Label("Save", systemImage: "arrow.down.to.line")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassCapsule(interactive: true)
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text("Done")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(LiquidGlassColors.sendButtonBlue)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Rectangle()
                .fill(LiquidGlassColors.subtleHairline)
                .frame(height: LiquidGlassMetrics.hairlineWidth)

            ZStack {
                LiquidGlassColors.recessedCodeSurface

                if let loadedImage {
                    Image(nsImage: loadedImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(insetOutlineColor, lineWidth: 1)
                        )
                        .padding(18)
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 340, idealWidth: 680, maxWidth: 960, minHeight: 300, idealHeight: 520, maxHeight: 740)
        }
        .background(LiquidGlassColors.canvasBackground)
        .task(id: attachment.url) {
            if let cached = AuthenticatedImageLoader.shared.cachedImage(for: attachment.url) {
                loadedImage = cached
            } else {
                loadedImage = try? await AuthenticatedImageLoader.shared.loadImage(from: attachment.url)
            }
        }
    }
}
