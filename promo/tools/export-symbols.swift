// Exports the SF Symbols the promo stage draws (macOS and iOS chrome, the Apple apps' own symbols) as black masks.
//   swift promo/tools/export-symbols.swift promo/assets/symbols
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "promo/assets/symbols")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let symbols = [
    // Nearclip's own (HistoryView, HomeView, ClipPresentation, toasts)
    "text.alignleft", "link", "photo", "magnifyingglass", "ellipsis.circle", "laptopcomputer", "iphone", "desktopcomputer",
    "pc", "plus", "pause.fill", "pin.fill", "pin", "square.stack", "doc.on.clipboard", "doc.on.clipboard.fill", "gearshape",
    "dot.radiowaves.left.and.right", "chevron.right", "chevron.left", "checkmark.circle.fill", "arrow.down.doc.fill",
    "paperplane.fill", "doc.on.doc", "square.and.arrow.up", "xmark.circle.fill", "globe",
    // OS chrome around it
    "wifi", "battery.100percent", "cellularbars", "switch.2", "command", "control", "option", "shift", "keyboard",
    "lock.fill", "lock.shield.fill", "qrcode", "qrcode.viewfinder", "checkmark", "network", "house.fill", "building.2.fill",
    "antenna.radiowaves.left.and.right", "personalhotspot", "square.and.pencil", "list.bullet", "textformat",
    "checklist", "paperclip", "camera.fill", "folder", "ellipsis", "sidebar.left", "trash", "mappin.and.ellipse",
    "map.fill", "text.cursor", "arrow.uturn.backward", "arrow.right", "photo.on.rectangle", "macwindow",
    "rectangle.on.rectangle", "arrow.left.arrow.right", "icloud.slash", "bolt.horizontal.fill", "server.rack",
    "xmark", "heart.fill", "square.and.arrow.down", "location.fill", "calendar", "clock",
]
var missing: [String] = []
for name in symbols {
    let config = NSImage.SymbolConfiguration(pointSize: 160, weight: .medium, scale: .large)
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        missing.append(name)
        continue
    }
    let size = NSSize(width: ceil(image.size.width) + 8, height: ceil(image.size.height) + 8)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let tinted = NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        NSColor.black.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: NSRect(x: 4, y: 4, width: image.size.width, height: image.size.height))
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: out.appendingPathComponent(name + ".png"))
    }
}
print("exported \(symbols.count - missing.count) symbols to \(out.path)" + (missing.isEmpty ? "" : "; missing: \(missing.joined(separator: ", "))"))
