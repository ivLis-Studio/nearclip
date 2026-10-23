import AppKit
import SwiftUI

struct OnboardingView: View {
    let model: AppModel
    let windows: WindowManager
    @State private var step = 0
    @State private var access = MacSystem.clipboardAccess
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: welcome.transition(slide)
                case 1: permissions.transition(slide)
                default: devices.transition(slide)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Capsule()
                            .fill(i == step ? Brand.iris : Color.primary.opacity(0.15))
                            .frame(width: i == step ? 18 : 7, height: 7)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: step)
                .accessibilityHidden(true)
                Spacer()
                if step > 0 {
                    Button("Back") { withAnimation(.easeOut(duration: 0.25)) { step -= 1 } }
                        .controlSize(.large)
                }
                Button {
                    advance()
                } label: {
                    Text(step == 0 ? "Get Started" : (step == 1 ? "Continue" : "Done"))
                        .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.iris)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 640)
        .onReceive(poll) { _ in if step == 1 { access = MacSystem.clipboardAccess } }
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity))
    }

    private func advance() {
        if step < 2 {
            withAnimation(.easeOut(duration: 0.25)) { step += 1 }
        } else {
            model.settings.onboardingDone = true
            windows.closeOnboarding()
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 20)
            Image("BrandMark")
                .resizable()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Brand.iris.opacity(0.25), radius: 16, y: 6)
            Text("Copy here. Paste there.")
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
            Text("Nearclip keeps the clipboard of your devices in sync over your Wi-Fi. Nothing leaves your network.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(symbol: "wifi", title: "Local network only",
                           detail: "Your devices talk to each other directly — no servers, no accounts.")
                FeatureRow(symbol: "lock.fill", title: "End-to-end encrypted",
                           detail: "Only your paired devices can read what you copy.")
                FeatureRow(symbol: "rectangle.on.rectangle", title: "Mac, Windows, Android and iPhone",
                           detail: "Text and images, with a shared history on every device.")
            }
            .padding(.top, 14)
            .frame(maxWidth: 440)
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 40)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Two quick permissions")
                .font(.system(size: 26, weight: .bold))
            Text("Nearclip only asks for what it needs to sync.")
                .foregroundStyle(.secondary)
            PermissionCard(symbol: "doc.on.clipboard", title: "Clipboard access",
                           detail: "macOS asks before apps read the clipboard. Choose “Always Allow” so what you copy syncs automatically.") {
                switch access {
                case .allowed:
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.online)
                case .denied:
                    Button("Open System Settings") { MacSystem.openPrivacyPane("Privacy_Pasteboard") }
                case .ask:
                    Button("Choose Always Allow…") { MacSystem.openPrivacyPane("Privacy_Pasteboard") }
                case .notAsked:
                    Button("Allow…") {
                        MacSystem.triggerClipboardPrompt()
                        access = MacSystem.clipboardAccess
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.iris)
                }
            }
            PermissionCard(symbol: "network", title: "Local network",
                           detail: "Lets Nearclip find your devices on this Wi-Fi. macOS may ask once — choose Allow.") {
                Label("Asked when needed", systemImage: "info.circle").foregroundStyle(.secondary)
            }
            PermissionCard(symbol: "keyboard", title: "Shortcut",
                           detail: "Press \(ShortcutFormat.string(keyCode: model.settings.hotKeyCode, modifiers: model.settings.hotKeyModifiers)) anywhere to open your history. You can change it in Settings.") {
                EmptyView()
            }
            Spacer()
        }
        .padding(.horizontal, 44)
        .padding(.top, 48)
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add your devices")
                .font(.system(size: 26, weight: .bold))
                .padding(.horizontal, 44)
            Text("Install Nearclip on your other devices, then scan the code or pick them below.")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 44)
            AddDevicePane(model: model, compact: true)
                .padding(.horizontal, 10)
        }
        .padding(.top, 40)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Brand.iris)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.iris.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionCard<Trailing: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Brand.iris)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.iris.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

