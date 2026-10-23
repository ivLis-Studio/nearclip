import CoreGraphics
import Foundation
let src = CGEventSource(stateID: .hidSystemState)
func key(_ code: CGKeyCode) {
  let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!; d.post(tap: .cghidEventTap)
  usleep(20000)
  let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!; u.post(tap: .cghidEventTap)
  usleep(150000)
}
for a in CommandLine.arguments.dropFirst() { key(CGKeyCode(Int(a)!)) }
print("keys sent")

