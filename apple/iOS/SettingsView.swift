import NearclipKit
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
                    Label("Local network only", systemImage: "wifi")
                    Label("End-to-end encrypted", systemImage: "lock.fill")
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
        }
    }
}

