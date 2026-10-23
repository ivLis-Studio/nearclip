import AppKit
import ApplicationServices
import IOKit.ps
import NearclipKit
import ServiceManagement

enum MacSystem {
    static var computerName: String { Host.current().localizedName ?? "Mac" }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static var hasInternalBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType { return true }
        }
        return false
    }

    /// "MacBook (Mac15,7)" or "Mac (Mac14,13)" — the prefix drives the laptop/desktop glyph on other devices.
    static var model: String { (hasInternalBattery ? "MacBook" : "Mac") + " (" + hardwareModel + ")" }

    static var teamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Team-signed builds keep the group key in the Keychain; ad-hoc builds (whose signature changes on every
    /// build, which would make the Keychain prompt each time) use a 0600 file in Application Support.
    static func secretStore(_ dir: URL) -> SecretStore {
        teamIdentifier != nil ? KeychainSecretStore() : FileSecretStore(directory: dir.appendingPathComponent("secrets"))
    }

    // MARK: Permissions

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    enum ClipboardAccess { case allowed, ask, denied, notAsked }

    static var clipboardAccess: ClipboardAccess {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: return .allowed
            case .alwaysDeny: return .denied
            case .ask: return .ask
            default: return .notAsked
            }
        }
        return .allowed
    }

    /// Reads the clipboard once so macOS shows its permission prompt.
    static func triggerClipboardPrompt() {
        _ = NSPasteboard.general.string(forType: .string)
    }

    /// Sends ⌘V to the frontmost app (needs Accessibility).
    static func pasteIntoFrontApp() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: Login item

    static var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func setOpensAtLogin(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            return false
        }
    }
}

