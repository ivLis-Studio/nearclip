import ImageIO
import UIKit

@MainActor
final class Thumbs {
    static let shared = Thumbs()
    private let cache = NSCache<NSString, UIImage>()

    func image(id: String, url: URL, maxPixel: Int = 220) -> UIImage? {
        let key = "\(id)-\(maxPixel)" as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = UIImage(cgImage: cg)
        cache.setObject(img, forKey: key)
        return img
    }
}

