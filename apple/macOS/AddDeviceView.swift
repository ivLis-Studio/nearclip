import AppKit
import NearclipKit
import SwiftUI

struct AddDeviceWindowContent: View {
    let model: AppModel

    var body: some View {
        AddDevicePane(model: model)
            .padding(.top, 26)
            .frame(width: 680, height: 470)
    }
}

/// QR code for phones on the left, nearby computers (code pairing) on the right.
struct AddDevicePane: View {
    let model: AppModel
    var compact = false
    @State private var showAddress = false
    @State private var host = ""
    @State private var port = "45821"
    @State private var link = ""

    var body: some View {
        HStack(spacing: 0) {
            qrColumn
                .frame(width: compact ? 270 : 300)
                .padding(.vertical, 16)
            Divider()
            nearbyColumn
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
        .onAppear { model.beginAddDevice() }
        .onDisappear { model.endAddDevice() }
        .sheet(isPresented: Binding(get: { model.joinState != .idle }, set: { if !$0 { model.joinState = .idle } })) {
            JoinProgressView(model: model)
        }
    }

    private var qrColumn: some View {
        VStack(spacing: 12) {
            Text("Scan to add a phone")
                .font(.system(size: 15, weight: .semibold))
            ZStack {
                if let t = model.ticket {
                    QRCodeView(text: t.uri, size: compact ? 190 : 210)
                        .transition(.opacity)
                        .id(t.uri)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: compact ? 190 : 210, height: compact ? 190 : 210)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .animation(.easeOut(duration: 0.25), value: model.ticket?.uri)
            Text("Use your phone's camera or the Nearclip app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 230)
            if let t = model.ticket {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(t.expiresAt.timeIntervalSince(ctx.date)))
                    Text("New code in \(String(format: "%d:%02d", left / 60, left % 60))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            if let addr = model.addresses.first, model.port > 0 {
                Text(verbatim: "\(addr) · \(String(localized: "port")) \(model.port)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            if let n = model.notice, n.tone == .success {
                Label(n.text, systemImage: n.symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Brand.online)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
                    .padding(.horizontal, 16)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.notice)
    }

    private var nearbyColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Nearby")
                    .font(.system(size: 15, weight: .semibold))
                Text("Computers and phones on this network that aren't yours yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.nearby.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices…")
                        .font(.callout.weight(.medium))
                    Text("Open Nearclip on your other device — it will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 230)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.nearby) { d in
                            NearbyRow(device: d) { model.pair(with: d) }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            DisclosureGroup(isExpanded: $showAddress) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("IP address", text: $host)
                            .textFieldStyle(.roundedBorder)
                        TextField("Port", text: $port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Button("Pair") {
                            if let p = UInt16(port), !host.isEmpty { model.pair(host: host.trimmingCharacters(in: .whitespaces), port: p) }
                        }
                        .disabled(host.isEmpty || UInt16(port) == nil)
                    }
                    HStack {
                        TextField("Or paste a nearclip:// link", text: $link)
                            .textFieldStyle(.roundedBorder)
                        Button("Join") {
                            if !model.join(link: link) { model.joinState = .failed("bad_uri") }
                        }
                        .disabled(link.isEmpty)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Connect by address")
                    .font(.callout)
            }
        }
    }
}

struct NearbyRow: View {
    let device: NearbyDevice
    let pair: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: DeviceStyle.symbol(platform: device.platform, model: nil))
                .font(.system(size: 15))
                .foregroundStyle(Brand.iris)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.iris.opacity(0.1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: device.name.isEmpty ? DeviceStyle.platformName(device.platform, model: nil) : device.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(verbatim: device.pairingMode ? String(localized: "Ready to pair") : DeviceStyle.platformName(device.platform, model: nil))
                    .font(.caption)
                    .foregroundStyle(device.pairingMode ? Brand.online : .secondary)
            }
            Spacer()
            Button("Pair", action: pair)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

/// Six digits, grouped "123 456".
struct CodeDigits: View {
    let code: String

    var body: some View {
        Text(verbatim: Format.groupedCode(code))
            .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
            .tracking(3)
            .foregroundStyle(Brand.iris)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.iris.opacity(0.1)))
            .accessibilityLabel(Text("Pairing code \(code.map(String.init).joined(separator: " "))"))
    }
}

struct JoinProgressView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            switch model.joinState {
            case .idle:
                EmptyView()
            case .connecting(let name):
                ProgressView().controlSize(.large).padding(.bottom, 4)
                Text("Connecting to ‘\(name)’…").font(.headline)
                Button("Cancel") { model.cancelJoin() }
                    .keyboardShortcut(.cancelAction)
            case .confirm(let code, let peer):
                Text("Confirm on ‘\(peer)’")
                    .font(.title3.weight(.semibold))
                Text("Make sure ‘\(peer)’ shows the same code, then choose Add there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                CodeDigits(code: code)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for confirmation…").font(.callout).foregroundStyle(.secondary)
                }
                Button("Cancel") { model.cancelJoin() }
                    .keyboardShortcut(.cancelAction)
            case .success(let name):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Brand.online)
                    .symbolEffect(.bounce, value: name)
                Text("You're connected")
                    .font(.title3.weight(.semibold))
                Text("This Mac now syncs with ‘\(name)’ and your other devices.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done") { model.joinState = .idle }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.iris)
                    .keyboardShortcut(.defaultAction)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Brand.warning)
                Text("Couldn't connect")
                    .font(.title3.weight(.semibold))
                Text(verbatim: AppModel.failureText(reason))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("OK") { model.joinState = .idle }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 380)
    }
}

/// Inviter side of code pairing.
struct PairPromptView: View {
    let model: AppModel
    let prompt: PairPrompt

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: DeviceStyle.symbol(platform: prompt.platform, model: nil))
                .font(.system(size: 26))
                .foregroundStyle(Brand.iris)
                .frame(width: 58, height: 58)
                .background(Circle().fill(Brand.iris.opacity(0.12)))
            Text("Add ‘\(prompt.name)’?")
                .font(.title3.weight(.semibold))
            Text("Make sure ‘\(prompt.name)’ shows this code.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            CodeDigits(code: prompt.code)
            HStack(spacing: 10) {
                Button {
                    model.answerPrompt(false)
                } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    model.answerPrompt(true)
                } label: {
                    Text("Add").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.iris)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(.horizontal, 26)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .frame(width: 360)
    }
}

