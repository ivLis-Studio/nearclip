// Presses a button of a running app through Accessibility, without moving the mouse:
//   axpress <pid> <identifier-or-title>…    (exit 0 pressed, 1 not found, 3 no Accessibility permission)
// Test helper for tools/acceptance/mac_code.py; the terminal needs Accessibility permission.
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]) else {
    print("usage: axpress <pid> <identifier-or-title>…")
    exit(2)
}
let wanted = Set(args.dropFirst(2))
let app = AXUIElementCreateApplication(pid)

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func find(_ e: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if depth > 40 { return nil }
    if attr(e, kAXRoleAttribute) as? String == kAXButtonRole {
        for key in ["AXIdentifier", kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = attr(e, key) as? String, wanted.contains(s) { return e }
        }
    }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        if let f = find(c, depth: depth + 1) { return f }
    }
    return nil
}

guard AXIsProcessTrusted() else {
    print("no Accessibility permission")
    exit(3)
}
for _ in 0..<20 {
    for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        if let b = find(w) {
            let r = AXUIElementPerformAction(b, kAXPressAction as CFString)
            print(r == .success ? "pressed" : "press failed \(r.rawValue)")
            exit(r == .success ? 0 : 1)
        }
    }
    usleep(250_000)
}
print("not found")
exit(1)

