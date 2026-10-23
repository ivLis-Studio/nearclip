import AVFoundation
import NearclipKit
import SwiftUI

/// Sheet from the home screen.
struct AddDeviceView: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AddDevicePage(env: env)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("sheet.done") }
                }
        }
    }
}

struct AddDevicePage: View {
    let env: AppEnvironment
    @State private var scanning = false
    @State private var showAddress = false
    @State private var host = ""
    @State private var port = "45821"

    var body: some View {
        let model = env.model
        List {
            Section {
                Button {
                    scanning = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 50, height: 50)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.iris))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Scan QR Code").font(.headline).foregroundStyle(.primary)
                            Text("Point the camera at the code on your computer.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                PasteButton(payloadType: String.self) { strings in
                    guard let link = strings.first else { return }
                    Task { @MainActor in
                        if !model.join(link: link) { model.joinState = .failed("bad_uri") }
                    }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .frame(maxWidth: .infinity, alignment: .leading)
            } footer: {
                Text("Copied a nearclip:// link instead? Paste it to connect.")
            }

            Section {
                VStack(spacing: 12) {
                    if let t = model.ticket {
                        QRCodeView(text: t.uri, size: 220)
                            .id(t.uri)
                            .transition(.opacity)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let left = max(0, Int(t.expiresAt.timeIntervalSince(ctx.date)))
                            Text("New code in \(String(format: "%d:%02d", left / 60, left % 60))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView().frame(height: 220)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .animation(.easeOut, value: model.ticket?.uri)
            } header: {
                Text("Show my code")
            } footer: {
                Text("Another phone or a computer with a camera can scan this code.")
            }

            Section {
                if model.nearby.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for devices on this Wi-Fi…").foregroundStyle(.secondary)
                    }
                }
                ForEach(model.nearby) { d in
                    HStack(spacing: 12) {
                        Image(systemName: DeviceStyle.symbol(platform: d.platform, model: nil))
                            .font(.system(size: 17))
                            .foregroundStyle(Brand.iris)
                            .frame(width: 38, height: 38)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.iris.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: d.name).font(.body.weight(.medium)).lineLimit(1)
                            Text(verbatim: d.pairingMode ? String(localized: "Ready to pair") : DeviceStyle.platformName(d.platform, model: nil))
                                .font(.caption)
                                .foregroundStyle(d.pairingMode ? Brand.online : .secondary)
                        }
                        Spacer()
                        Button("Pair") { model.pair(with: d) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }
                }
                DisclosureGroup("Connect by address", isExpanded: $showAddress) {
                    TextField("IP address", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    Button("Pair") {
                        if let p = UInt16(port), !host.isEmpty { model.pair(host: host.trimmingCharacters(in: .whitespaces), port: p) }
                    }
                    .disabled(host.isEmpty || UInt16(port) == nil)
                }
            } header: {
                Text("Nearby")
            } footer: {
                Text("Pairing with a nearby device shows the same code on both screens.")
            }
        }
        .navigationTitle("Add Device")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.beginAddDevice() }
        .onDisappear { model.endAddDevice() }
        .fullScreenCover(isPresented: $scanning) {
            QRScannerScreen { link in
                scanning = false
                if !model.join(link: link) { model.joinState = .failed("bad_uri") }
            } onClose: {
                scanning = false
            }
        }
        .sheet(isPresented: Binding(get: { model.joinState != .idle }, set: { if !$0 { model.joinState = .idle } })) {
            JoinProgressSheet(model: model)
                .presentationDetents([.medium])
                .interactiveDismissDisabled(model.joinState.isBusy)
        }
    }
}

struct JoinProgressSheet: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            switch model.joinState {
            case .idle:
                EmptyView()
            case .connecting(let name):
                ProgressView().controlSize(.large)
                Text("Connecting to ‘\(name)’…").font(.headline)
                Button("Cancel") { model.cancelJoin() }
            case .confirm(let code, let peer):
                Text("Confirm on ‘\(peer)’").font(.title3.weight(.semibold))
                Text("Make sure ‘\(peer)’ shows the same code, then choose Add there.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                CodeDigitsView(code: code)
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for confirmation…").font(.subheadline).foregroundStyle(.secondary)
                }
                Button("Cancel") { model.cancelJoin() }
            case .success(let name):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Brand.online)
                    .symbolEffect(.bounce, value: name)
                Text("You're connected").font(.title2.weight(.bold))
                    .accessibilityIdentifier("join.success")
                Text("This device now syncs with ‘\(name)’ and your other devices.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    model.joinState = .idle
                } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
                .accessibilityIdentifier("join.done")
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Brand.warning)
                Text("Couldn't connect").font(.title3.weight(.semibold))
                Text(verbatim: AppModel.failureText(reason))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("OK") { model.joinState = .idle }
                    .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sensoryFeedback(.success, trigger: model.joinState) { _, new in
            if case .success = new { return true } else { return false }
        }
    }
}

struct CodeDigitsView: View {
    let code: String

    var body: some View {
        Text(verbatim: Format.groupedCode(code))
            .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
            .tracking(4)
            .foregroundStyle(Brand.iris)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.iris.opacity(0.1)))
            .accessibilityLabel(Text("Pairing code \(code.map(String.init).joined(separator: " "))"))
    }
}

/// Inviter side of code pairing (presented above any sheet).
struct PairPromptSheet: View {
    let model: AppModel
    let prompt: PairPrompt

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: DeviceStyle.symbol(platform: prompt.platform, model: nil))
                .font(.system(size: 28))
                .foregroundStyle(Brand.iris)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Brand.iris.opacity(0.12)))
            Text("Add ‘\(prompt.name)’?").font(.title2.weight(.bold))
            Text("Make sure ‘\(prompt.name)’ shows this code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            CodeDigitsView(code: prompt.code)
            HStack(spacing: 12) {
                Button {
                    model.answerPrompt(false)
                } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    model.answerPrompt(true)
                } label: {
                    Text("Add").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(24)
        .tint(Brand.iris)
    }
}

// MARK: - Scanner

struct QRScannerScreen: View {
    let onCode: (String) -> Void
    let onClose: () -> Void
    @State private var status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    private let hasCamera = AVCaptureDevice.default(for: .video) != nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if hasCamera && status == .authorized {
                CameraPreview(onCode: onCode).ignoresSafeArea()
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 250, height: 250)
                    .shadow(color: .black.opacity(0.4), radius: 10)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: hasCamera ? "camera.fill" : "camera.badge.ellipsis")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(hasCamera ? "Nearclip needs the camera to scan the code." : "This device has no camera.")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if hasCamera && status == .denied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    PasteButton(payloadType: String.self) { strings in
                        if let s = strings.first { Task { @MainActor in onCode(s) } }
                    }
                    .buttonBorderShape(.capsule)
                    Text("…or paste a nearclip:// link.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(32)
            }
            VStack {
                HStack {
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                    .accessibilityLabel(Text("Close"))
                }
                .padding()
                Spacer()
                Text("Scan the code shown on your computer")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .padding(.bottom, 40)
            }
        }
        .task {
            if status == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                status = granted ? .authorized : .denied
            }
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let session = AVCaptureSession()
        if let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
        }
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        let s = coordinator.session
        DispatchQueue.global(qos: .userInitiated).async { s?.stopRunning() }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        var session: AVCaptureSession?
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, s.lowercased().hasPrefix("nearclip://") else { return }
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode(s)
        }
    }
}

