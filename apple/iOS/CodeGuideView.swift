import SwiftUI

/// "A verification code arrived from MacBook Pro. Copy it?" with the code in large digits, Copy and Not Now
/// (PROTOCOL.md §6.7). Codes are never copied on their own.
struct CodeOfferBanner: View {
    let title: String
    let code: String
    let symbol: String
    let onCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Brand.iris))
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: code)
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .tracking(3)
                        .accessibilityLabel(Text(verbatim: code.map(String.init).joined(separator: " ")))
                        .accessibilityIdentifier("codeOffer.code")
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button(action: onCopy) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("codeOffer.copy")
                Button(action: onDismiss) {
                    Text("Not Now").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("codeOffer.dismiss")
            }
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
        }
        .padding(14)
        .frame(maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .sensoryFeedback(.impact(weight: .light), trigger: code)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codeOffer")
    }
}

/// Settings › Verification codes: what it does and the Shortcuts automation that sends codes from text messages.
struct CodeSection: View {
    var body: some View {
        Section {
            NavigationLink {
                CodeGuideView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "number.square.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Brand.iris)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send codes from text messages").foregroundStyle(.primary)
                        Text("Set up a Shortcuts automation once.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("codes.guide")
        } header: {
            Text("Verification codes")
        } footer: {
            Text("Codes from your other devices show “Copy it?” here — nothing is pasted on its own.")
        }
    }
}

/// How to send codes from text messages: a Shortcuts automation on Message that runs Nearclip's "Send Verification
/// Code". iOS lets no app read other apps' messages or notifications, and KakaoTalk has no automation trigger.
struct CodeGuideView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "number.square.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Brand.iris)
                        Text("Codes from texts, on your computer")
                            .font(.title2.weight(.bold))
                            .accessibilityIdentifier("codes.guide.title")
                        Text("When a text message brings a verification code, Nearclip sends just the code to your other devices. They ask “Copy it?” — your messages stay on this iPhone.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        step(1, "Open Shortcuts, go to Automation and tap +.")
                        step(2, "Choose Message. Leave Sender and Message Contains empty — Nearclip finds the code itself.")
                        step(3, "Choose Run Immediately, turn off Notify When Run, then tap Next.")
                        step(4, "Tap New Blank Automation, add the Nearclip action “Send Verification Code”.")
                        step(5, "Tap Message in the action and choose Shortcut Input. Tap Done.")
                    }
                    Label("KakaoTalk codes can't be read on iPhone — iOS gives apps no way to see them.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        if let url = URL(string: "shortcuts://") { openURL(url) }
                    } label: {
                        Text("Open Shortcuts").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .accessibilityIdentifier("codes.guide.open")
                }
                .padding(24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .tint(Brand.iris)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(verbatim: "\(n)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Brand.iris)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Brand.iris.opacity(0.12)))
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
    }
}

/// The guide on its own, from onboarding.
struct CodeGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CodeGuideView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("codes.guide.done") }
                }
        }
    }
}
