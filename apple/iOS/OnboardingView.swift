import SwiftUI

struct OnboardingView: View {
    let env: AppEnvironment
    @State private var step = 0
    @State private var scanning = false
    @State private var showCodeGuide = false
    private let last = 3

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                welcome.tag(0)
                network.tag(1)
                codes.tag(2)
                devices.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeOut, value: step)
            HStack(spacing: 6) {
                ForEach(0...last, id: \.self) { i in
                    Capsule().fill(i == step ? Brand.iris : Color.primary.opacity(0.15))
                        .frame(width: i == step ? 20 : 7, height: 7)
                }
            }
            .animation(.snappy, value: step)
            .padding(.bottom, 18)
            .accessibilityHidden(true)
            Button {
                advance()
            } label: {
                Text(step == 0 ? "Get Started" : (step < last ? "Continue" : "Scan QR Code"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("onboarding.next")
            if step == last {
                Button("Not Now") { finish() }
                    .padding(.top, 10)
                    .accessibilityIdentifier("onboarding.later")
            }
        }
        .padding(.bottom, 20)
        .tint(Brand.iris)
        .sheet(isPresented: $showCodeGuide) { CodeGuideSheet() }
        .fullScreenCover(isPresented: $scanning) {
            QRScannerScreen { link in
                scanning = false
                finish()
                env.open(URL(string: link) ?? URL(string: "nearclip://invalid")!)
            } onClose: {
                scanning = false
            }
        }
    }

    private func advance() {
        switch step {
        case 0: withAnimation { step = 1 }
        case 1:
            env.startEngine()
            withAnimation { step = 2 }
        case 2:
            withAnimation { step = 3 }
        default:
            scanning = true
        }
    }

    private func finish() {
        env.startEngine()
        env.settings.onboardingDone = true
        env.showOnboarding = false
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("BrandMark")
                .resizable()
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: Brand.iris.opacity(0.3), radius: 18, y: 8)
            Text("Copy here.\nPaste there.")
                .font(.system(size: 36, weight: .bold))
                .multilineTextAlignment(.center)
            Text("Nearclip keeps the clipboard of your devices in sync over your Wi-Fi. Nothing leaves your network.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 18) {
                feature("wifi", "Local network only", "Your devices talk to each other directly — no servers, no accounts.")
                feature("lock.fill", "End-to-end encrypted", "Only your paired devices can read what you copy.")
                feature("rectangle.on.rectangle", "Mac, Windows, Android and iPhone", "Text and images, with a shared history on every device.")
            }
            .padding(.top, 12)
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private var network: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(Brand.iris)
                .frame(width: 112, height: 112)
                .background(Circle().fill(Brand.iris.opacity(0.12)))
            Text("Find your devices")
                .font(.system(size: 30, weight: .bold))
                .accessibilityIdentifier("onboarding.network.title")
            Text("Nearclip looks for your computers and phones on this Wi-Fi. When iOS asks, choose Allow.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 18) {
                feature("iphone.and.arrow.forward", "Syncs while Nearclip is open", "iOS pauses apps in the background. Open Nearclip to send and receive — it catches up instantly.")
                feature("doc.on.clipboard", "Copy, then tap Paste", "The Paste button sends what you copied without any permission prompts.")
            }
            .padding(.top, 12)
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    /// Verification codes from text messages (PROTOCOL.md §6.7): iOS has no permission to grant, so this shows how.
    private var codes: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "number")
                .font(.system(size: 50, weight: .semibold))
                .foregroundStyle(Brand.iris)
                .frame(width: 112, height: 112)
                .background(Circle().fill(Brand.iris.opacity(0.12)))
            Text("Verification codes, too")
                .font(.system(size: 30, weight: .bold))
                .accessibilityIdentifier("onboarding.codes.title")
            Text("A code that comes in a text message can show up on your computer, ready to copy.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 18) {
                feature("message.badge.filled.fill", "From your text messages", "A Shortcuts automation sends just the code. Set it up once.")
                feature("lock.fill", "Your messages stay here", "Only the code leaves this iPhone, and your computer asks before copying it.")
            }
            .padding(.top, 12)
            Button("Show Me How") { showCodeGuide = true }
                .font(.headline)
                .padding(.top, 4)
                .accessibilityIdentifier("onboarding.codes.guide")
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private var devices: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(Brand.iris)
                .frame(width: 112, height: 112)
                .background(Circle().fill(Brand.iris.opacity(0.12)))
            Text("Add your computer")
                .font(.system(size: 30, weight: .bold))
            Text("Open Nearclip on your Mac or Windows PC, choose Add Device, and scan the code it shows.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Brand.iris)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.iris.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

