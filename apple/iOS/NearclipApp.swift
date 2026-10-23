import NearclipKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct NearclipApp: App {
    @State private var env = AppEnvironment()
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
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var bgTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let prompts = PromptPresenter()

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nearclip", isDirectory: true)
        func makeNode(_ store: SecretStore) throws -> NearclipNode {
            try NearclipNode(config: .init(stateDirectory: dir, deviceName: IOSSystem.defaultName, platform: "ios",
                                           model: IOSSystem.model, appVersion: IOSSystem.appVersion, port: 45821,
                                           bonjour: true, secretStore: store))
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
        model.onPairPrompt = { [weak self] prompt in
            guard let self else { return }
            self.prompts.present(model: self.model, prompt: prompt)
        }
        if settings.onboardingDone { startEngine() }
    }

    func startEngine() {
        guard !started else { return }
        started = true
        model.start()
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
        if pb.hasImages, let img = pb.image, let png = img.pngData() {
            sendImage(png, size: img.size)
        } else if let s = pb.string, !s.isEmpty {
            sendText(s)
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
            p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, let img = UIImage(data: data) else { return }
                let png = img.pngData() ?? data
                Task { @MainActor in self.sendImage(png, size: img.size) }
            }
        } else if p.canLoadObject(ofClass: URL.self) && !p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in self.sendText(url.absoluteString) }
            }
        } else {
            _ = p.loadObject(ofClass: String.self) { s, _ in
                guard let s, !s.isEmpty else { return }
                Task { @MainActor in self.sendText(s) }
            }
        }
    }

    private func sendText(_ text: String) {
        guard !settings.paused else {
            show(Toast(text: String(localized: "Syncing paused"), symbol: "pause.circle.fill", tint: Brand.warning))
            return
        }
        model.localCopy(text: text)
        confirmSent()
    }

    private func sendImage(_ data: Data, size: CGSize) {
        guard !settings.paused else { return }
        guard settings.syncImages else {
            show(Toast(text: String(localized: "Image syncing is off"), symbol: "photo", tint: Brand.warning))
            return
        }
        model.localCopy(image: data, mime: "image/png", width: Int(size.width), height: Int(size.height))
        confirmSent()
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

    var isNew: Bool { UIPasteboard.general.changeCount != defaults.integer(forKey: "seenChangeCount") }

    func markSeen() { defaults.set(UIPasteboard.general.changeCount, forKey: "seenChangeCount") }

    func write(_ clip: Clip, blob: Data?) {
        if clip.isImage, let blob {
            let type = clip.mime == "image/jpeg" ? UTType.jpeg.identifier : UTType.png.identifier
            UIPasteboard.general.setItems([[type: blob]])
        } else if let text = clip.text {
            UIPasteboard.general.string = text
        }
        markSeen()
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

