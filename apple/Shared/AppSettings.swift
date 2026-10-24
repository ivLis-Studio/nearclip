import Foundation
import Observation

/// User preferences (DESIGN.md §4.6), persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var autoApply: Bool { didSet { defaults.set(autoApply, forKey: "autoApply") } }
    var syncImages: Bool { didSet { defaults.set(syncImages, forKey: "syncImages") } }
    var showToasts: Bool { didSet { defaults.set(showToasts, forKey: "showToasts") } }
    var pasteAfterChoosing: Bool { didSet { defaults.set(pasteAfterChoosing, forKey: "pasteAfterChoosing") } }
    var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "retentionDays") } }
    var paused: Bool { didSet { defaults.set(paused, forKey: "paused") } }
    var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }
    var sendOnOpen: Bool { didSet { defaults.set(sendOnOpen, forKey: "sendOnOpen") } }
    var copyLatestOnOpen: Bool { didSet { defaults.set(copyLatestOnOpen, forKey: "copyLatestOnOpen") } }
    var hotKeyCode: Int { didSet { defaults.set(hotKeyCode, forKey: "hotKeyCode") } }
    var hotKeyModifiers: Int { didSet { defaults.set(hotKeyModifiers, forKey: "hotKeyModifiers") } }
    var ignoredApps: [String] { didSet { defaults.set(ignoredApps, forKey: "ignoredApps") } }
    /// Remote connection (embedded Tailscale, DESIGN.md §4.7).
    var remoteEnabled: Bool { didSet { defaults.set(remoteEnabled, forKey: "remoteEnabled") } }

    static let defaultIgnoredApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "org.keepassxc.keepassxc", "com.apple.keychainaccess", "com.apple.Passwords",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if os(iOS)
        // Reading the clipboard programmatically makes iOS ask every time unless the user allowed it in Settings,
        // so automatic sending on open is opt-in on iOS (the Paste button never asks).
        let sendOnOpenDefault = false
        #else
        let sendOnOpenDefault = true
        #endif
        defaults.register(defaults: [
            "autoApply": true, "syncImages": true, "showToasts": true, "pasteAfterChoosing": false,
            "retentionDays": 30, "paused": false, "onboardingDone": false, "sendOnOpen": sendOnOpenDefault,
            "copyLatestOnOpen": true, "hotKeyCode": 9, "hotKeyModifiers": 4352, // ⌃⌘V (controlKey | cmdKey)
            "ignoredApps": Self.defaultIgnoredApps, "remoteEnabled": false,
        ])
        autoApply = defaults.bool(forKey: "autoApply")
        syncImages = defaults.bool(forKey: "syncImages")
        showToasts = defaults.bool(forKey: "showToasts")
        pasteAfterChoosing = defaults.bool(forKey: "pasteAfterChoosing")
        retentionDays = defaults.integer(forKey: "retentionDays")
        paused = defaults.bool(forKey: "paused")
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        sendOnOpen = defaults.bool(forKey: "sendOnOpen")
        copyLatestOnOpen = defaults.bool(forKey: "copyLatestOnOpen")
        hotKeyCode = defaults.integer(forKey: "hotKeyCode")
        hotKeyModifiers = defaults.integer(forKey: "hotKeyModifiers")
        ignoredApps = defaults.stringArray(forKey: "ignoredApps") ?? Self.defaultIgnoredApps
        remoteEnabled = defaults.bool(forKey: "remoteEnabled")
    }
}

