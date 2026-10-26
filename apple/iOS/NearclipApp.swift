import NearclipKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct NearclipApp: App {
    /// Shared with "Send Verification Code" (SendCodeIntent), which can run while Nearclip is in the background.
    @State private var env = AppEnvironment.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView(env: env)
                .onOpenURL { env.open($0) }
                .tint(Brand.iris)
        }
        .onChange(of: phase) { _, p in env.phaseChanged(p) }
    }
}

enum IOSSystem {
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }

    static var machine: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    static var model: String { (isPad ? "iPad" : "iPhone") + " (" + machine + ")" }
    static var defaultName: String { UIDevice.current.name }
}

enum ClipboardKind { case text, link, image }

enum AppRoute: Hashable { case devices }

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol: String
    var tint: Color = Brand.iris
}

/// App-wide state that is specific to iOS (sheets, lifecycle, clipboard detection).
@MainActor
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settings = AppSettings()
    let model: AppModel
    let clipboard = IOSClipboard()
    private(set) var started = false
    var showAddDevice = false
    var path: [AppRoute] = []
    var showSettings = false
    var showOnboarding: Bool
    /// The system clipboard has something new that was not sent yet.
    var pendingClipboard: ClipboardKind?
    var toast: Toast?
    /// A verification code from another device, offered with "Copy it?" (PROTOCOL.md §6.7).
    private(set) var codeOffer: StoredClip?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var codeOfferTask: Task<Void, Never>?
    @ObservationIgnored private var lastForwarded: (code: String, at: Date)?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var bgTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let prompts = PromptPresenter()

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nearclip", isDirectory: true)
        // Remote connection: embedded Tailscale node. NC_TAILNET_CONTROL points it at a test control server.
        let env = ProcessInfo.processInfo.environment
        let tailnet = TailnetOptions(directory: dir.appendingPathComponent("tailnet", isDirectory: true),
                                     controlURL: env["NC_TAILNET_CONTROL"], testMode: env["NC_TAILNET_CONTROL"] != nil)
        func makeNode(_ store: SecretStore) throws -> NearclipNode {
            try NearclipNode(config: .init(stateDirectory: dir, deviceName: IOSSystem.defaultName, platform: "ios",
                                           model: IOSSystem.model, appVersion: IOSSystem.appVersion, port: 45821,
                                           bonjour: true, secretStore: store, tailnet: tailnet))
        }
        let node: NearclipNode
        if let n = try? makeNode(KeychainSecretStore()) {
            node = n
        } else {
            node = try! makeNode(FileSecretStore(directory: dir.appendingPathComponent("secrets")))
        }
        model = AppModel(node: node, settings: settings)
        showOnboarding = !settings.onboardingDone
        model.clipboard = clipboard
        model.onReceive = { [weak self] sc in
            guard let self else { return }
            self.show(Toast(text: String(localized: "Copied from \(self.model.sourceName(sc))"), symbol: "arrow.down.doc.fill"))
            self.clipboard.markSeen()
            self.pendingClipboard = nil
        }
        model.onReceivedQuietly = { [weak self] sc in
            guard let self else { return }
            let text = String(localized: "Image from \(self.model.sourceName(sc))") + " · " + String(localized: "Saved to history")
            self.show(Toast(text: text, symbol: "photo.fill"))
        }
        model.onTransferFailed = { [weak self] t in
            guard let self else { return }
            let text = String(localized: "Couldn't receive the image") + " · "
                + String(localized: "Copy it again on \(self.model.deviceName(t.from)).")
            self.show(Toast(text: text, symbol: "exclamationmark.triangle.fill", tint: Brand.warning))
        }
        model.onPairPrompt = { [weak self] prompt in
            guard let self else { return }
            self.prompts.present(model: self.model, prompt: prompt)
        }
        model.onCode = { [weak self] sc in self?.offerCode(sc) }
        if settings.onboardingDone { startEngine() }
    }

    func startEngine() {
        guard !started else { return }
        started = true
        model.start()
        // Launched in the background for a Shortcuts automation: the clipboard is left alone until Nearclip is opened.
        guard UIApplication.shared.applicationState != .background else { return }
        model.armCopyNewest()
        checkClipboard()
    }

    func phaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            pauseTask?.cancel()
            endBackgroundTask()
            guard started else { return }
            model.node.setPaused(settings.paused)
            model.node.nudge()
            model.refresh()
            model.armCopyNewest()
            checkClipboard()
        case .background:
            guard started else { return }
            // Finish in-flight transfers, then go quiet until the app is opened again.
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "nearclip-finish") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask() }
            }
            pauseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self else { return }
                self.model.node.setPaused(true)
                self.endBackgroundTask()
            }
        default:
            break
        }
    }

    private func endBackgroundTask() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        bgTask = .invalid
    }

    func open(_ url: URL) {
        guard url.scheme?.lowercased() == "nearclip" else { return }
        #if DEBUG
        // Test hook (apple/tools/ios_code.py): runs "Send Verification Code" on a message, as a Shortcuts automation does.
        if url.host == "debug-send-code",
           let message = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "message" })?.value {
            Task {
                var intent = SendCodeIntent()
                intent.message = message
                _ = try? await intent.perform()
            }
            return
        }
        #endif
        if !started {
            settings.onboardingDone = true
            showOnboarding = false
            startEngine()
        }
        showAddDevice = true
        if !model.join(link: url.absoluteString) { model.joinState = .failed("bad_uri") }
    }

    // MARK: Clipboard

    /// Notices new clipboard content without reading it (no system prompt).
    func checkClipboard() {
        let pb = UIPasteboard.general
        guard clipboard.isNew else { pendingClipboard = nil; return }
        let kind: ClipboardKind?
        if pb.hasImages { kind = .image } else if pb.hasURLs { kind = .link } else if pb.hasStrings { kind = .text } else { kind = nil }
        guard let kind else { pendingClipboard = nil; return }
        if settings.sendOnOpen && !settings.paused {
            sendFromPasteboard()
        } else {
            pendingClipboard = kind
        }
    }

    /// Reads the clipboard directly (iOS may ask for permission unless allowed in Settings).
    func sendFromPasteboard() {
        let pb = UIPasteboard.general
        if pb.hasImages, let img = pb.image {
            // The picture Nearclip put there itself, brought back by Universal Clipboard, is not a new copy; it is not
            // even announced. A new one is: the other devices show "Receiving…" while it is encoded (PROTOCOL.md §6.6).
            let cg = img.cgImage
            Task.detached(priority: .userInitiated) {
                let key = cg.flatMap { ContentKey.pixels(of: $0) }
                let start: (go: Bool, announced: String?) = await MainActor.run {
                    if let key, key == self.clipboard.lastKey { return (false, nil) }
                    self.clipboard.remember(key)
                    return (true, self.model.announceImage())
                }
                guard start.go else { return }
                let png = img.pngData()
                await MainActor.run {
                    if let png {
                        self.sendImage(png, size: img.size, announced: start.announced, explicit: false)
                    } else {
                        self.model.cancelImage(start.announced)
                    }
                }
            }
        } else if let s = pb.string, !s.isEmpty {
            sendText(s, explicit: false)
        }
        clipboard.markSeen()
        pendingClipboard = nil
    }

    /// Handles content from the system Paste button.
    func sendPasted(_ providers: [NSItemProvider]) {
        clipboard.markSeen()
        pendingClipboard = nil
        guard let p = providers.first else { return }
        if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let announced = model.announceImage()
            p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, let img = UIImage(data: data) else {
                    Task { @MainActor in self.model.cancelImage(announced) }
                    return
                }
                let key = img.cgImage.flatMap { ContentKey.pixels(of: $0) }
                let png = img.pngData() ?? data
                Task { @MainActor in
                    if let key, key == self.clipboard.lastKey {
                        self.model.cancelImage(announced)
                        self.showAlreadySynced()
                        return
                    }
                    self.clipboard.remember(key)
                    self.sendImage(png, size: img.size, announced: announced, explicit: true)
                }
            }
        } else if p.canLoadObject(ofClass: URL.self) && !p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in self.sendText(url.absoluteString, explicit: true) }
            }
        } else {
            _ = p.loadObject(ofClass: String.self) { s, _ in
                guard let s, !s.isEmpty else { return }
                Task { @MainActor in self.sendText(s, explicit: true) }
            }
        }
    }

    /// `explicit`: the user pressed Paste, so a clip that is already everywhere says so; sending on open stays quiet.
    private func sendText(_ text: String, explicit: Bool) {
        guard !settings.paused else {
            show(Toast(text: String(localized: "Syncing paused"), symbol: "pause.circle.fill", tint: Brand.warning))
            return
        }
        // The text Nearclip put on the clipboard itself (brought back by Universal Clipboard), or the newest clip: it is
        // on the other devices already.
        let key = ContentKey.text(text)
        let again = key == clipboard.lastKey
        clipboard.remember(key)
        guard !again, model.localCopy(text: text) else {
            if explicit { showAlreadySynced() }
            return
        }
        confirmSent()
    }

    private func sendImage(_ data: Data, size: CGSize, announced: String?, explicit: Bool) {
        guard !settings.paused else {
            model.cancelImage(announced)
            return
        }
        guard settings.syncImages else {
            model.cancelImage(announced)
            show(Toast(text: String(localized: "Image syncing is off"), symbol: "photo", tint: Brand.warning))
            return
        }
        guard model.localCopy(image: data, mime: "image/png", width: Int(size.width), height: Int(size.height), announced: announced) else {
            if explicit { showAlreadySynced() }
            return
        }
        confirmSent()
    }

    private func showAlreadySynced() {
        show(Toast(text: String(localized: "Already on your devices"), symbol: "checkmark.circle.fill", tint: Brand.online))
    }

    private func confirmSent() {
        let n = model.connectedCount
        if n == 0 {
            show(Toast(text: String(localized: "Saved — it syncs when your devices are nearby"), symbol: "clock.arrow.circlepath", tint: .secondary))
        } else {
            show(Toast(text: n == 1 ? String(localized: "Sent to 1 device") : String(localized: "Sent to \(n) devices"), symbol: "paperplane.fill"))
        }
    }

    func copy(_ item: ClipItem) {
        model.copy(item)
        clipboard.markSeen()
        pendingClipboard = nil
        show(Toast(text: String(localized: "Copied"), symbol: "checkmark.circle.fill", tint: Brand.online))
    }

    // MARK: Verification codes (PROTOCOL.md §6.7)

    private func offerCode(_ sc: StoredClip) {
        withAnimation(.spring(duration: 0.4)) { codeOffer = sc }
        codeOfferTask?.cancel()
        // Codes expire within minutes; so does the offer.
        codeOfferTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }
            self?.dismissCodeOffer()
        }
    }

    func copyOfferedCode() {
        guard let sc = codeOffer else { return }
        model.copyCode(sc)
        dismissCodeOffer()
        show(Toast(text: String(localized: "Copied"), symbol: "checkmark.circle.fill", tint: Brand.online))
    }

    func dismissCodeOffer() {
        codeOfferTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { codeOffer = nil }
    }

    /// "Send Verification Code" from a Shortcuts automation: sends a code found in a message to the other devices. It
    /// may run while Nearclip is in the background with syncing asleep: the connection wakes for it, waits up to 6 s for
    /// a device, sends, and goes back to sleep.
    func forwardCode(_ code: String) async {
        guard settings.onboardingDone, !settings.paused, !model.otherMembers.isEmpty else { return }
        if let last = lastForwarded, last.code == code, Date().timeIntervalSince(last.at) < 300 { return }
        lastForwarded = (code, Date())
        startEngine()
        pauseTask?.cancel()
        model.node.setPaused(false)
        model.node.nudge()
        for _ in 0..<30 where model.connectedCount == 0 {
            try? await Task.sleep(for: .milliseconds(200))
        }
        let sent = model.node.sendText(code, otp: true) != nil
        // A moment for the connections to deliver it before iOS suspends Nearclip again.
        if sent, model.connectedCount > 0 { try? await Task.sleep(for: .seconds(1.5)) }
        if UIApplication.shared.applicationState == .background { model.node.setPaused(true) }
    }

    func show(_ t: Toast) {
        withAnimation(.spring(duration: 0.35)) { toast = t }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
    }
}

@MainActor
final class IOSClipboard: ClipboardWriter {
    private let defaults = UserDefaults.standard
    /// What the pasteboard holds as far as Nearclip knows (ContentKey: the text, or an image's pixels), the key of that
    /// image's file, and the changeCount at which that was true. iOS does not tell an app in the background about
    /// changes, so a clip is only taken to be there while the changeCount says nothing changed since.
    private(set) var lastKey: String?
    private var lastFileKey: String?
    private var lastKeyChange = -1

    var isNew: Bool { UIPasteboard.general.changeCount != defaults.integer(forKey: "seenChangeCount") }

    func markSeen() { defaults.set(UIPasteboard.general.changeCount, forKey: "seenChangeCount") }

    /// The pasteboard holds this content now (it was just read from it).
    func remember(_ key: String?, file: String? = nil) {
        lastKey = key
        lastFileKey = file
        lastKeyChange = UIPasteboard.general.changeCount
    }

    @discardableResult
    func write(_ clip: Clip, blob: Data?) -> Bool {
        let unchanged = UIPasteboard.general.changeCount == lastKeyChange
        if clip.isImage, let blob {
            let file = ContentKey.of(clip)
            if unchanged, file != nil, file == lastFileKey { return false }
            let type = clip.mime == "image/jpeg" ? UTType.jpeg.identifier : UTType.png.identifier
            UIPasteboard.general.setItems([[type: blob]])
            remember(nil, file: file)
            // The pixels, so the same picture coming back from Universal Clipboard is recognised.
            let written = lastKeyChange
            Task.detached(priority: .utility) {
                let key = ContentKey.pixels(ofImageData: blob)
                await MainActor.run { [weak self] in
                    guard let self, self.lastKeyChange == written, self.lastKey == nil else { return }
                    self.lastKey = key
                }
            }
        } else if let text = clip.text {
            let key = ContentKey.text(text)
            if unchanged, key == lastKey { return false }
            UIPasteboard.general.string = text
            remember(key)
        } else {
            return false
        }
        markSeen()
        return true
    }
}

/// Presents the code-pairing prompt above whatever is on screen (sheets included).
@MainActor
final class PromptPresenter {
    private weak var presented: UIViewController?

    func present(model: AppModel, prompt: PairPrompt) {
        presented?.dismiss(animated: false)
        let host = UIHostingController(rootView: PairPromptSheet(model: model, prompt: prompt))
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
        }
        host.isModalInPresentation = true
        guard let top = Self.topViewController() else { return }
        top.present(host, animated: true)
        presented = host
        observeDismissal(model)
    }

    private func observeDismissal(_ model: AppModel) {
        withObservationTracking {
            _ = model.pairPrompt
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if model.pairPrompt == nil { self.presented?.dismiss(animated: true) } else { self.observeDismissal(model) }
            }
        }
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

