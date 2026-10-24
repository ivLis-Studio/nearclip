import AppKit
import ImageIO

/// Downsampled image thumbnails for history rows and toasts.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    func image(id: String, url: URL, maxPixel: Int = 200) -> NSImage? {
        if let img = cached(id: id, maxPixel: maxPixel) { return img }
        guard let cg = Self.make(url: url, maxPixel: maxPixel) else { return nil }
        return keep(cg, id: id, maxPixel: maxPixel)
    }

    /// The same, made off the main thread: decoding a large PNG takes about 0.1 s.
    func load(id: String, url: URL, maxPixel: Int = 200) async -> NSImage? {
        if let img = cached(id: id, maxPixel: maxPixel) { return img }
        let cg = await Task.detached(priority: .userInitiated) { Self.make(url: url, maxPixel: maxPixel) }.value
        guard let cg else { return nil }
        return keep(cg, id: id, maxPixel: maxPixel)
    }

    func cached(id: String, maxPixel: Int = 200) -> NSImage? {
        cache.object(forKey: "\(id)-\(maxPixel)" as NSString)
    }

    private func keep(_ cg: CGImage, id: String, maxPixel: Int) -> NSImage {
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: "\(id)-\(maxPixel)" as NSString)
        return img
    }

    nonisolated private static func make(url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
