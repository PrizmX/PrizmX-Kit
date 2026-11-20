import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Lightweight SwiftUI remote image view backed by a dedicated `URLCache`.
/// Only valid, successfully decoded images are cached; failed loads are never
/// cached so subsequent appearances automatically retry.
public struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var loadedImage: Image?

    public init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        self._loadedImage = State(initialValue: url.flatMap(ImageLoader.cachedImage(for:)))
    }

    public var body: some View {
        Group {
            if let loadedImage {
                content(loadedImage)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else {
            loadedImage = nil
            return
        }
        if let cached = ImageLoader.cachedImage(for: url) {
            loadedImage = cached
            return
        }
        loadedImage = nil
        if let fetched = await ImageLoader.fetchImage(from: url) {
            loadedImage = fetched
        }
    }
}

/// Public controls for the shared remote image cache used by `CachedAsyncImage`.
public enum RemoteImageCache {
    public static var diskUsageBytes: Int {
        ImageLoader.cache.currentDiskUsage
    }

    public static func clear() {
        ImageLoader.cache.removeAllCachedResponses()
    }
}

private enum ImageLoader {
    static let cache = URLCache(
        memoryCapacity: 20 * 1024 * 1024,
        diskCapacity: 100 * 1024 * 1024,
        diskPath: "PrizmXImageCache"
    )

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    static func cachedImage(for url: URL) -> Image? {
        let request = URLRequest(url: url)
        guard let cached = cache.cachedResponse(for: request),
              let image = decodeImage(from: cached.data)
        else {
            return nil
        }
        return image
    }

    static func fetchImage(from url: URL) async -> Image? {
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return decodeImage(from: data)
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = decodeImage(from: data)
            else {
                cache.removeCachedResponse(for: request)
                return nil
            }
            cache.storeCachedResponse(
                CachedURLResponse(response: response, data: data, storagePolicy: .allowed),
                for: request
            )
            return image
        } catch {
            return nil
        }
    }

    private static func decodeImage(from data: Data) -> Image? {
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        return nil
        #endif
    }
}
