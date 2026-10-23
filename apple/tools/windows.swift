import CoreGraphics
import Foundation
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
  let owner = w[kCGWindowOwnerName as String] as? String ?? ""
  if owner.contains(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Nearclip") {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String] ?? 0, owner, w[kCGWindowLayer as String] ?? 0, w[kCGWindowName as String] ?? "", b)
  }
}

