import NearclipKit
import SwiftUI

struct DeviceSyncSettings: View {
    let model: AppModel
    let member: MemberRecord
    @State private var policy = SyncPolicy()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Send to this device", isOn: $policy.send)
                    Toggle("Receive from this device", isOn: $policy.receive)
                } header: { Text("Direction") }
                Section {
                    Toggle("Include images", isOn: $policy.images)
                    Toggle("Include verification codes", isOn: $policy.codes)
                } header: { Text("Content") } footer: {
                    Text("Applies to live copies and history sync. Verification codes expire after 3 minutes.")
                }
            }
            .navigationTitle(member.name)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { policy = model.node.policy(for: member.id) }
        .onChange(of: policy) { _, p in model.node.setPolicy(p, for: member.id); model.onPolicyChanged?() }
        #if os(macOS)
        .frame(width: 420, height: 320)
        #endif
    }
}
