import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// What a clip holds, so that the same thing put on the clipboard again is not taken for a new copy (DESIGN.md §4.3):
/// a screenshot tool that sets its picture twice, or another sync app (Universal Clipboard, a phone link) that puts back
/// what Nearclip just delivered. Text compares with line endings, Unicode composition and trailing whitespace evened
/// out; an image by its pixels, so the same picture as PNG and as TIFF is one image. A clip in history, known only by
/// its file, compares by the file's SHA-256. Keys are only compared on the device that made them.
public enum ContentKey {
    private static let trailing: Set<Unicode.Scalar> = [" ", "\t", "\n", "\u{0B}", "\u{0C}"]
    /// Larger images are not compared (drawing them again would take too much memory).
    static let maxPixels = 50_000_000

    /// Line endings as `\n`, composed Unicode (NFC), no trailing spaces, tabs or line breaks.
    public static func normalizeText(_ text: String) -> String {
        var lines = String.UnicodeScalarView()
        var afterCR = false
        for u in text.unicodeScalars {
            if u == "\r" {
                lines.append("\n")
                afterCR = true
                continue
            }
            if u == "\n" && afterCR {
                afterCR = false
                continue
            }
            afterCR = false
            lines.append(u)
        }
        var scalars = String(lines).precomposedStringWithCanonicalMapping.unicodeScalars
        while let last = scalars.last, trailing.contains(last) { scalars.removeLast() }
        return String(scalars)
    }

    public static func text(_ text: String) -> String {
        "t:" + Hex.encode(Data(SHA256.hash(data: Data(normalizeText(text).utf8))))
    }

    /// The image drawn as 8-bit sRGB with premultiplied alpha, so a fully transparent pixel is transparent black
    /// whatever colour it carried.
    public static func pixels(of image: CGImage) -> String? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w * h <= maxPixels, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let rowBytes = w * 4
        var data = Data(count: rowBytes * h)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var hasher = SHA256()
        let size: [UInt32] = [UInt32(w).littleEndian, UInt32(h).littleEndian]
        size.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
        return "p:" + Hex.encode(Data(hasher.finalize()))
    }

    /// The pixels of PNG, JPEG, TIFF or HEIC data (its first image).
    public static func pixels(ofImageData data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return pixels(of: image)
    }

    /// A clip in history: its text, or its image file's SHA-256 (nil when neither is known).
    public static func of(_ clip: Clip) -> String? {
        if clip.isText { return text(clip.text ?? "") }
        if let sha = clip.sha, !sha.isEmpty { return "f:" + sha.lowercased() }
        return nil
    }

    /// The key of an image file in history, from its bytes.
    public static func file(_ data: Data) -> String {
        "f:" + Hex.encode(Data(SHA256.hash(data: data)))
    }
}
