import NearclipKit
import SafariServices
import SwiftUI

struct SettingsView: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        let model = env.model
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section {
                    Toggle("Pause syncing", isOn: Binding(get: { settings.paused }, set: { model.setPaused($0) }))
                    Toggle("Copy incoming clips automatically", isOn: $settings.autoApply)
                    Toggle("Sync images", isOn: $settings.syncImages)
                } header: {
                    Text("Sync")
                } footer: {
                    Text("iPhone and iPad sync while Nearclip is open. Open the app to catch up.")
                }
                if model.remoteAvailable { RemoteSection(model: model) }
                CodeSection()
                Section {
                    Toggle(isOn: $settings.copyLatestOnOpen) {
                        Text("Copy the newest clip")
                        Text("From another device, if it arrived in the last 10 minutes.")
                    }
                    Toggle(isOn: $settings.sendOnOpen) {
                        Text("Send what you copied automatically")
                        Text("Otherwise use the Paste button.")
                    }
                    if settings.sendOnOpen {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } label: {
                            Label("Allow “Paste from Other Apps”", systemImage: "arrow.up.forward.app")
                        }
                    }
                } header: {
                    Text("When Nearclip opens")
                } footer: {
                    if settings.sendOnOpen {
                        Text("In Settings › Nearclip › Paste from Other Apps, choose Allow — otherwise iOS asks every time.")
                    }
                }
                Section {
                    Picker("Keep history for", selection: Binding(get: { settings.retentionDays }, set: { model.setRetention($0) })) {
                        Text("1 day").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("Forever").tag(0)
                    }
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                        .disabled(model.items.isEmpty)
                } header: {
                    Text("History")
                } footer: {
                    Text("Clearing deletes every clip on all of your devices.")
                }
                Section {
                    LabeledContent("Version", value: IOSSystem.appVersion)
                    Label("Direct device-to-device", systemImage: "arrow.left.arrow.right")
                    Label("End-to-end encrypted", systemImage: "lock.fill")
                    NavigationLink("Open-source licenses") { LicensesView() }
                        .accessibilityIdentifier("about.licenses")
                } header: {
                    Text("About")
                } footer: {
                    Text(verbatim: "Nearclip · © 2026 ivLis Studio · MIT License")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("sheet.done") }
            }
            .confirmationDialog(Text("Clear history on all devices?"), isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { model.clearHistory() }
            } message: {
                Text("This can't be undone.")
            }
            .sheet(isPresented: Binding(get: { model.tailnetLoginURL != nil }, set: { if !$0 { model.tailnetLoginURL = nil } })) {
                if let url = model.tailnetLoginURL { SafariView(url: url).ignoresSafeArea() }
            }
        }
    }
}

/// Remote connection through the embedded Tailscale node (DESIGN.md §4.7).
private struct RemoteSection: View {
    let model: AppModel

    var body: some View {
        Section {
            Toggle("Sync across networks", isOn: Binding(get: { model.settings.remoteEnabled }, set: { model.setRemoteEnabled($0) }))
                .accessibilityIdentifier("remote.toggle")
            if model.settings.remoteEnabled {
                let st = RemoteStatus(model)
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(st.color)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: st.title).font(.subheadline.weight(.medium))
                        if let d = st.detail { Text(verbatim: d).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    Spacer()
                    if st.busy { ProgressView() }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("remote.status")
                switch st.action {
                case .signIn:
                    Button { model.signInToTailscale() } label: {
                        Label("Sign in with Tailscale", systemImage: "person.badge.key.fill").font(.body.weight(.semibold))
                    }
                    .accessibilityIdentifier("remote.signin")
                case .retry:
                    Button("Try again") { model.retryRemote() }
                case .none:
                    EmptyView()
                }
                if st.canSignOut {
                    Button("Sign out of Tailscale", role: .destructive) { model.signOutOfTailscale() }
                }
            }
        } header: {
            Text("Remote connection")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keeps your devices connected on different networks — home, office or mobile data. Uses a free Tailscale account; clips stay end-to-end encrypted.")
                if model.settings.remoteEnabled, let hint = RemoteStatus(model).hint { Text(verbatim: hint) }
            }
        }
    }
}

/// In-app Safari for the Tailscale sign-in page; closes by itself once the node runs.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(Brand.iris)
        vc.dismissButtonStyle = .close
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

/// The software inside the embedded Tailscale node and its licenses (tailnet/notices/THIRD_PARTY_NOTICES.txt).
private struct LicensesView: View {
    @State private var notices: [OpenSourceNotice] = []

    var body: some View {
        List {
            Section {
                ForEach(OpenSourceNotice.mainComponents, id: \.name) { c in
                    LabeledContent {
                        Text(verbatim: c.license)
                    } label: {
                        Text(verbatim: c.name)
                        Text(verbatim: c.owner)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Remote connection (Tailscale)")
            } footer: {
                Text("Remote connection runs an embedded Tailscale node, which includes this open-source software.")
            }
            Section("License texts") {
                ForEach(notices) { n in
                    NavigationLink {
                        NoticeView(notice: n)
                    } label: {
                        Text(verbatim: n.id).font(.callout).lineLimit(2)
                    }
                }
            }
        }
        .navigationTitle("Open-source licenses")
        .navigationBarTitleDisplayMode(.inline)
        .task { notices = OpenSourceNotice.load() }
    }
}

private struct NoticeView: View {
    let notice: OpenSourceNotice

    var body: some View {
        ScrollView {
            Text(verbatim: notice.reflowed)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(Text(verbatim: notice.name))
        .navigationBarTitleDisplayMode(.inline)
    }
}

