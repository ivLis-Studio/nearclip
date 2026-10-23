import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
  let owner = w[kCGWindowOwnerName as String] as? String ?? ""
  if owner == (CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Nearclip") {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String] ?? 0, "layer", w[kCGWindowLayer as String] ?? 0, "onscreen", w[kCGWindowIsOnscreen as String] ?? false, "alpha", w[kCGWindowAlpha as String] ?? 0, b)
  }
}

