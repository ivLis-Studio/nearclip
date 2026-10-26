import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NearclipKit

/// The same thing copied again is recognised as the same thing (DESIGN.md §4.3).
final class ContentKeyTests: XCTestCase {
    func testTextIgnoresLineEndingsCompositionAndTrailingWhitespace() {
        let key = ContentKey.text("첫 줄\n둘째 줄")
        XCTAssertEqual(key, ContentKey.text("첫 줄\r\n둘째 줄"))
        XCTAssertEqual(key, ContentKey.text("첫 줄\r둘째 줄"))
        XCTAssertEqual(key, ContentKey.text("첫 줄\n둘째 줄\r\n"))
        XCTAssertEqual(key, ContentKey.text("첫 줄\n둘째 줄 \t "))
        // Decomposed Hangul (as macOS file names carry it) is the same text.
        XCTAssertEqual(key, ContentKey.text("첫 줄\n둘째 줄".decomposedStringWithCanonicalMapping))
        XCTAssertTrue(key.hasPrefix("t:"))
    }

    func testDifferentTextStaysDifferent() {
        XCTAssertNotEqual(ContentKey.text("hello"), ContentKey.text("Hello"))
        XCTAssertNotEqual(ContentKey.text("hello"), ContentKey.text(" hello"))
        XCTAssertNotEqual(ContentKey.text("a\nb"), ContentKey.text("a\n\nb"))
        XCTAssertNotEqual(ContentKey.text("a\r\n\r\nb"), ContentKey.text("a\nb"))
        XCTAssertNotEqual(ContentKey.text("1234"), ContentKey.text("12345"))
    }

    /// The same keys as the Windows and Android apps compute (not required, but easy to keep).
    func testSameTextKeyAsTheOtherApps() {
        XCTAssertEqual(ContentKey.text("hello\r\n"), "t:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    private func image(_ w: Int, _ h: Int, change: (Int, Int)? = nil) -> CGImage {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                px[i] = UInt8(x & 0xff); px[i + 1] = UInt8(y & 0xff); px[i + 2] = UInt8((x ^ y) & 0xff); px[i + 3] = 255
            }
        }
        if let (x, y) = change { px[(y * w + x) * 4 + 1] ^= 1 }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func encode(_ image: CGImage, as type: UTType) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testTheSamePictureAsPNGAndAsTIFFIsOneImage() throws {
        let img = image(300, 200)
        let png = encode(img, as: .png), tiff = encode(img, as: .tiff)
        XCTAssertNotEqual(png, tiff)
        let key = try XCTUnwrap(ContentKey.pixels(ofImageData: png))
        XCTAssertTrue(key.hasPrefix("p:"))
        XCTAssertEqual(key, ContentKey.pixels(ofImageData: tiff))
        XCTAssertEqual(key, ContentKey.pixels(of: img))
        XCTAssertNotEqual(key, ContentKey.pixels(ofImageData: encode(image(300, 200, change: (299, 150)), as: .png)))
        XCTAssertNotEqual(key, ContentKey.pixels(of: image(200, 300)))
        XCTAssertNil(ContentKey.pixels(ofImageData: Data("not an image".utf8)))
    }

    func testClipsFromHistory() {
        let text = Clip(id: "id", ts: 1, src: "src", kind: "text", text: "a\r\nb")
        XCTAssertEqual(ContentKey.of(text), ContentKey.text("a\nb"))
        let image = Clip(id: "id", ts: 1, src: "src", kind: "image", mime: "image/png", size: 3, sha: "ABCDEF")
        XCTAssertEqual(ContentKey.of(image), "f:abcdef")
        XCTAssertNil(ContentKey.of(Clip(id: "id", ts: 1, src: "src", kind: "image")))
        XCTAssertEqual(ContentKey.file(Data("abc".utf8)), "f:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
