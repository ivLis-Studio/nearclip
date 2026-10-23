import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum QRCode {
    /// High error-correction QR (room for the logo in the centre), dark iris modules on white.
    static func cgImage(_ string: String, moduleSize: CGFloat = 12) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        let colored = output.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(red: 0.17, green: 0.20, blue: 0.55),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])
        let scaled = colored.samplingNearest().transformed(by: CGAffineTransform(scaleX: moduleSize, y: moduleSize))
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(scaled, from: scaled.extent)
    }
}

/// QR code with quiet zone, rounded white card and the app glyph in the middle.
struct QRCodeView: View {
    let text: String
    var size: CGFloat = 220

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            if let cg = QRCode.cgImage(text) {
                Image(decorative: cg, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.07)
                    .accessibilityLabel(Text("Pairing QR code"))
            }
            RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
                .fill(.white)
                .frame(width: size * 0.25, height: size * 0.25)
            Image("BrandMark")
                .resizable()
                .frame(width: size * 0.2, height: size * 0.2)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.045, style: .continuous))
        }
        .frame(width: size, height: size)
    }
}

