// Lists the on-screen windows of one process: winlist <pid> → "<id> <layer> <x> <y> <w> <h> <title>" per line.
// apple/tools/appstore_mac_shots.py uses it to capture the app's windows with screencapture -l.
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments.dropFirst().first ?? "") ?? -1
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
for w in CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? [] {
    guard (w[kCGWindowOwnerPID as String] as? Int32) == pid else { continue }
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let title = w[kCGWindowName as String] as? String ?? ""
    print(id, layer, Int(b["X"] ?? 0), Int(b["Y"] ?? 0), Int(b["Width"] ?? 0), Int(b["Height"] ?? 0), title)
}

