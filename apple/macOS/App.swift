import AppKit
import NearclipKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private(set) var model: AppModel!
    private var settings: AppSettings!
    private var monitor: PasteboardMonitor!
    private var status: StatusItemController!
    private var panel: HistoryPanelController!
    private var toast: ToastController!
    private var windows: WindowManager!
    private let hotKey = HotKey()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Development hooks (screenshots, local multi-instance tests):
        //   NC_STATE_DIR, NC_PORT, NC_DEFAULTS_SUITE, NC_TICKET_FILE, NC_SHOW=panel|add|onboarding|settings:<page>
        let env = ProcessInfo.processInfo.environment
        settings = AppSettings(defaults: env["NC_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard)
        let dir = env["NC_STATE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Nearclip", isDirectory: true)
        let port = env["NC_PORT"].flatMap(UInt16.init) ?? 45821
        let node: NearclipNode
        do {
            node = try NearclipNode(config: .init(stateDirectory: dir, deviceName: MacSystem.computerName, platform: "mac",
                                                  model: MacSystem.model, appVersion: MacSystem.appVersion, port: port,
                                                  bonjour: true, secretStore: MacSystem.secretStore(dir)))
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Nearclip couldn't start")
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        model = AppModel(node: node, settings: settings)
        monitor = PasteboardMonitor(settings: settings)
        model.clipboard = monitor
        monitor.onCopy = { [weak self] content in
            guard let self else { return }
            switch content {
            case .text(let t): self.model.localCopy(text: t)
            case .image(let data, let mime, let w, let h): self.model.localCopy(image: data, mime: mime, width: w, height: h)
            }
        }
        monitor.onTooLarge = { [weak self] in
            self?.model.show(String(localized: "Too large to sync"), symbol: "exclamationmark.triangle.fill", tone: .warning)
        }
        windows = WindowManager(model: model, monitor: monitor)
        toast = ToastController(model: model)
        panel = HistoryPanelController(model: model, windows: windows, monitor: monitor)
        status = StatusItemController(model: model, panel: panel, windows: windows)
        windows.onShortcutChange = { [weak self] in self?.registerHotKey() }
        model.onReceive = { [weak self] sc in self?.toast.show(sc) }
        model.onActivity = { [weak self] in self?.status.pulse() }
        model.onPairPrompt = { [weak self] prompt in self?.windows.showPairPrompt(prompt) }
        hotKey.onPress = { [weak self] in self?.panel.toggle(anchor: nil) }
        registerHotKey()
        model.start()
        monitor.start()
        if let file = env["NC_TICKET_FILE"] {
            observeChanges { [weak self] in
                if let uri = self?.model.ticket?.uri { try? uri.write(toFile: file, atomically: true, encoding: .utf8) }
            }
        }
        if let show = env["NC_SHOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.debugShow(show) }
        } else if !settings.onboardingDone {
            windows.showOnboarding()
        }
    }

    private func debugShow(_ what: String) {
        switch what {
        case "panel": panel.show(anchor: status.anchorView)
        case "panel-centered": panel.show(anchor: nil)
        case "add": windows.showAddDevice()
        case "onboarding": windows.showOnboarding()
        default:
            if what.hasPrefix("settings") {
                let page = SettingsPage(rawValue: String(what.dropFirst("settings:".count))) ?? .general
                windows.showSettings(page)
            }
        }
    }

    private func registerHotKey() {
        _ = hotKey.register(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "nearclip" {
            windows.showAddDevice()
            if !model.join(link: url.absoluteString) {
                model.joinState = .failed("bad_uri")
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show(anchor: status.anchorView)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.node.stop()
    }
}

