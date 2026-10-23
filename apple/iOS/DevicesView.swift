import NearclipKit
import SwiftUI

struct DevicesView: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmRemove: MemberRecord?
    @State private var confirmLeave = false

    var body: some View {
        let model = env.model
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        deviceIcon(DeviceStyle.symbol(platform: "ios", model: model.me?.model), online: true)
                        TextField("Name", text: $name)
                            .font(.body.weight(.medium))
                            .submitLabel(.done)
                            .onSubmit { model.rename(name) }
                    }
                } header: {
                    Text(verbatim: model.thisDeviceLabel)
                } footer: {
                    Text("Your other devices see this name.")
                }
                Section {
                    if model.otherMembers.isEmpty {
                        Text("No other devices yet. Add your computer to start syncing.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.otherMembers) { m in
                        let online = model.isOnline(m.id)
                        HStack(spacing: 12) {
                            deviceIcon(DeviceStyle.symbol(platform: m.platform, model: m.model), online: online)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: m.name).font(.body.weight(.medium))
                                HStack(spacing: 5) {
                                    Circle().fill(online ? Brand.online : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                                    Text(verbatim: online ? String(localized: "Connected") : Format.lastSeen(model.lastSeen[m.id]))
                                    Text(verbatim: "· " + DeviceStyle.platformName(m.platform, model: m.model))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { confirmRemove = m }
                        }
                        .contextMenu {
                            Button("Remove…", systemImage: "minus.circle", role: .destructive) { confirmRemove = m }
                        }
                    }
                    NavigationLink {
                        AddDevicePage(env: env)
                    } label: {
                        Label("Add Device", systemImage: "plus.circle.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Brand.iris)
                    }
                } header: {
                    Text("My devices")
                }
                Section {
                    Button("Leave My Devices", role: .destructive) { confirmLeave = true }
                        .disabled(model.otherMembers.isEmpty)
                } footer: {
                    Text("This device stops syncing and starts over with a new, empty group. History stays on this device.")
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("sheet.done") }
            }
            .onAppear { name = model.deviceName }
            .onDisappear { model.rename(name) }
            .confirmationDialog(Text("Remove ‘\(confirmRemove?.name ?? "")’?"), isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) { if let m = confirmRemove { model.remove(m) } }
            } message: {
                Text("It will stop syncing with your devices.")
            }
            .confirmationDialog(Text("Leave your devices?"), isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave", role: .destructive) { model.leaveGroup() }
            } message: {
                Text("Your other devices will no longer sync with this one. You can add it again at any time.")
            }
        }
    }

    private func deviceIcon(_ symbol: String, online: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17))
            .foregroundStyle(online ? Brand.iris : Color.secondary)
            .frame(width: 38, height: 38)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.iris.opacity(online ? 0.13 : 0.06)))
    }
}

