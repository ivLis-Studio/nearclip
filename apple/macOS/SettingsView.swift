import AppKit
import NearclipKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @Bindable var nav: SettingsNavigation
    let windows: WindowManager

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $nav.page) { page in
                Label {
                    Text(page.title)
                } icon: {
                    Image(systemName: page.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(page.tint.gradient))
                }
                .tag(page)
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch nav.page ?? .general {
                case .general: GeneralSettings(model: model, windows: windows)
                case .devices: DevicesSettings(model: model, windows: windows)
                case .privacy: PrivacySettings(model: model)
                case .history: HistorySettings(model: model)
                case .about: AboutSettings()
                }
            }
            .navigationTitle(Text((nav.page ?? .general).title))
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let model: AppModel
    let windows: WindowManager
    @State private var name = ""
    @State private var opensAtLogin = MacSystem.opensAtLogin
    @State private var loginError = false
    @State private var axTrusted = MacSystem.isAccessibilityTrusted

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                TextField("Name", text: $name)
                    .onSubmit { model.rename(name) }
            } header: {
                Text("This Mac")
            } footer: {
                Text("Your other devices see this name.").foregroundStyle(.secondary)
            }
            Section("Sync") {
                Toggle("Pause syncing", isOn: Binding(get: { settings.paused }, set: { model.setPaused($0) }))
                Toggle("Copy incoming clips automatically", isOn: $settings.autoApply)
                Toggle("Sync images", isOn: $settings.syncImages)
            }
            Section("Mac") {
                Toggle("Open at login", isOn: Binding(get: { opensAtLogin }, set: { on in
                    if MacSystem.setOpensAtLogin(on) { opensAtLogin = on } else { loginError = true }
                }))
                LabeledContent("Show history") {
                    ShortcutRecorder(keyCode: $settings.hotKeyCode, modifiers: $settings.hotKeyModifiers) {
                        windows.onShortcutChange?()
                    }
                }
                Toggle("Show a notification when a clip arrives", isOn: $settings.showToasts)
                Toggle(isOn: $settings.pasteAfterChoosing) {
                    Text("Paste after choosing from history")
                    Text("Nearclip presses ⌘V for you in the app you were using.")
                }
                if settings.pasteAfterChoosing && !axTrusted {
                    HStack {
                        Label("Needs Accessibility permission", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Brand.warning)
                        Spacer()
                        Button("Grant…") {
                            MacSystem.requestAccessibility()
                            MacSystem.openPrivacyPane("Privacy_Accessibility")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = model.deviceName; axTrusted = MacSystem.isAccessibilityTrusted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = MacSystem.isAccessibilityTrusted
            opensAtLogin = MacSystem.opensAtLogin
        }
        .onDisappear { model.rename(name) }
        .alert("Couldn't change the login item", isPresented: $loginError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Move Nearclip to the Applications folder and try again.")
        }
    }
}

// MARK: - Devices

struct DeviceRow: View {
    let model: AppModel
    let member: MemberRecord
    var isSelf = false

    var body: some View {
        let online = isSelf || model.isOnline(member.id)
        HStack(spacing: 12) {
            Image(systemName: DeviceStyle.symbol(platform: member.platform, model: member.model))
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(online ? Brand.iris : Color.secondary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.iris.opacity(online ? 0.12 : 0.05)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: member.name.isEmpty ? DeviceStyle.platformName(member.platform, model: member.model) : member.name)
                        .font(.system(size: 13, weight: .medium))
                    if isSelf {
                        Text("This Mac")
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                HStack(spacing: 5) {
                    if !isSelf {
                        Circle().fill(online ? Brand.online : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                        Text(verbatim: online ? String(localized: "Connected") : Format.lastSeen(model.lastSeen[member.id]))
                    } else {
                        Text(verbatim: DeviceStyle.platformName(member.platform, model: member.model))
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !isSelf {
                Text(verbatim: DeviceStyle.platformName(member.platform, model: member.model))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct DevicesSettings: View {
    let model: AppModel
    let windows: WindowManager
    @State private var confirmRemove: MemberRecord?
    @State private var confirmLeave = false

    var body: some View {
        Form {
            Section("This Mac") {
                if let me = model.me { DeviceRow(model: model, member: me, isSelf: true) }
                LabeledContent("Address") {
                    Text(verbatim: model.addresses.first.map { "\($0) · \(model.port)" } ?? "—")
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if model.otherMembers.isEmpty {
                    HStack {
                        Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(.tertiary)
                        Text("No other devices yet. Add your phone or another computer to start syncing.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(model.otherMembers) { m in
                    DeviceRow(model: model, member: m)
                        .contextMenu {
                            Button("Remove…", role: .destructive) { confirmRemove = m }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { confirmRemove = m }
                        }
                }
            } header: {
                Text("My devices")
            } footer: {
                HStack {
                    Spacer()
                    Button {
                        windows.showAddDevice()
                    } label: {
                        Label("Add Device…", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.iris)
                }
                .padding(.top, 6)
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Leave my devices")
                        Text("This Mac stops syncing and starts over with a new, empty group. History stays on this Mac.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Leave…", role: .destructive) { confirmLeave = true }
                        .disabled(model.otherMembers.isEmpty)
                }
            } header: {
                Text("Advanced")
            }
        }
        .formStyle(.grouped)
        .alert(item: $confirmRemove) { m in
            Alert(title: Text("Remove ‘\(m.name)’?"),
                  message: Text("It will stop syncing with your devices."),
                  primaryButton: .destructive(Text("Remove")) { model.remove(m) },
                  secondaryButton: .cancel())
        }
        .alert("Leave your devices?", isPresented: $confirmLeave) {
            Button("Leave", role: .destructive) { model.leaveGroup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your other devices will no longer sync with this Mac. You can add it again at any time.")
        }
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    let model: AppModel
    @State private var access = MacSystem.clipboardAccess

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: accessSymbol)
                        .font(.system(size: 20))
                        .foregroundStyle(accessColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(accessTitle).font(.system(size: 13, weight: .semibold))
                        Text("macOS asks before apps read the clipboard. Choose Always Allow for Nearclip in System Settings › Privacy & Security › Paste from Other Apps so your copies sync automatically.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open System Settings") { MacSystem.openPrivacyPane("Privacy_Pasteboard") }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Clipboard access")
            }
            Section {
                Toggle(isOn: .constant(true)) {
                    Text("Skip passwords and private items")
                    Text("Items that password managers mark as private are never recorded or synced.")
                }
                .disabled(true)
            } header: {
                Text("Password managers")
            }
            Section {
                ForEach(settings.ignoredApps, id: \.self) { bundleId in
                    HStack(spacing: 10) {
                        AppIconView(bundleId: bundleId)
                        Text(verbatim: AppIconView.name(for: bundleId))
                        Spacer()
                        Button {
                            settings.ignoredApps.removeAll { $0 == bundleId }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove"))
                    }
                }
                Button {
                    addApp()
                } label: {
                    Label("Add App…", systemImage: "plus")
                }
            } header: {
                Text("Ignore copies from these apps")
            }
            Section {
                Label {
                    Text("Your devices talk to each other directly on your local network. Everything is end-to-end encrypted with keys that only your devices hold — there is no server and no account.")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lock.shield.fill").foregroundStyle(Brand.iris)
                }
            } header: {
                Text("Encryption")
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            access = MacSystem.clipboardAccess
        }
        .onAppear { access = MacSystem.clipboardAccess }
    }

    private var accessTitle: String {
        switch access {
        case .allowed: return String(localized: "Nearclip can read what you copy")
        case .denied: return String(localized: "Clipboard access is blocked")
        case .ask: return String(localized: "macOS asks every time")
        case .notAsked: return String(localized: "Not set up yet")
        }
    }

    private var accessSymbol: String {
        switch access {
        case .allowed: return "checkmark.circle.fill"
        case .denied: return "xmark.octagon.fill"
        default: return "exclamationmark.circle.fill"
        }
    }

    private var accessColor: Color {
        switch access {
        case .allowed: return Brand.online
        case .denied: return .red
        default: return Brand.warning
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !model.settings.ignoredApps.contains(id) {
                model.settings.ignoredApps.append(id)
            }
        }
    }
}

struct AppIconView: View {
    let bundleId: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed").frame(width: 20, height: 20).foregroundStyle(.tertiary)
        }
    }

    static func name(for bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return bundleId }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - History

private struct HistorySettings: View {
    let model: AppModel
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Picker("Keep history for", selection: Binding(get: { model.settings.retentionDays }, set: { model.setRetention($0) })) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("Forever").tag(0)
                }
                LabeledContent("Clips") {
                    Text(verbatim: "\(model.items.count)").foregroundStyle(.secondary)
                }
                LabeledContent("Pinned") {
                    Text(verbatim: "\(model.items.filter(\.pinned).count)").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Pinned clips are kept until you unpin them. History keeps at most 1,000 clips.").foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear history")
                        Text("Deletes every clip on all of your devices.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear…", role: .destructive) { confirmClear = true }
                        .disabled(model.items.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Clear history on all devices?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image("BrandMark")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            Text(verbatim: "Nearclip").font(.system(size: 26, weight: .bold))
            Text("Copy here. Paste there.").font(.title3).foregroundStyle(.secondary)
            Text(verbatim: String(localized: "Version \(MacSystem.appVersion)"))
                .font(.callout)
                .foregroundStyle(.tertiary)
            HStack(spacing: 18) {
                Label("Local network only", systemImage: "wifi")
                Label("End-to-end encrypted", systemImage: "lock.fill")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            Spacer()
            Text(verbatim: "© 2026 ivLis Studio · MIT License")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
    }
}

