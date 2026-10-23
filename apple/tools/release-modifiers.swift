import CoreGraphics
import Foundation
let src = CGEventSource(stateID: .hidSystemState)
print("before:", CGEventSource.flagsState(.hidSystemState).rawValue, CGEventSource.flagsState(.combinedSessionState).rawValue)
// Release Command (55), Control (59), Option (58), Shift (56) with cleared flags.
for key in [55, 54, 59, 62, 58, 61, 56, 60] as [CGKeyCode] {
  if let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) {
    e.flags = []
    e.post(tap: .cghidEventTap)
    usleep(10000)
  }
}
usleep(100000)
print("after:", CGEventSource.flagsState(.hidSystemState).rawValue, CGEventSource.flagsState(.combinedSessionState).rawValue)

