import AppKit
import NearclipKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, devices, privacy, history, about
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .devices: return "Devices"
        case .privacy: return "Privacy"
        case .history: return "History"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .devices: return "laptopcomputer.and.iphone"
        case .privacy: return "hand.raised"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .devices: return Brand.iris
        case .privacy: return .blue
        case .history: return .orange
        case .about: return .secondary
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var page: SettingsPage? = .general
}

@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    let model: AppModel
    let monitor: PasteboardMonitor
    var onShortcutChange: (() -> Void)?
    let nav = SettingsNavigation()
    private var settingsWindow: NSWindow?
    private var addWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var promptPanel: NSPanel?

    init(model: AppModel, monitor: PasteboardMonitor) {
        self.model = model
        self.monitor = monitor
        super.init()
        observeChanges { [weak self] in
            guard let self else { return }
            if self.model.pairPrompt == nil, let p = self.promptPanel { p.orderOut(nil); self.promptPanel = nil }
        }
    }

    func showSettings(_ page: SettingsPage = .general) {
        nav.page = page
        if settingsWindow == nil {
            let view = SettingsView(model: model, nav: nav, windows: self)
            let w = makeWindow(view, title: String(localized: "Nearclip Settings"), size: NSSize(width: 760, height: 540), resizable: true)
            w.setFrameAutosaveName("NearclipSettings")
            settingsWindow = w
        }
        present(settingsWindow!)
    }

    func showAddDevice() {
        if addWindow == nil {
            let view = AddDeviceWindowContent(model: model)
            addWindow = makeWindow(view, title: String(localized: "Add Device"), size: NSSize(width: 680, height: 470), resizable: false)
        }
        present(addWindow!)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(model: model, windows: self)
            let w = makeWindow(view, title: "", size: NSSize(width: 600, height: 640), resizable: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            onboardingWindow = w
        }
        present(onboardingWindow!)
    }

    func closeOnboarding() {
        onboardingWindow?.close()
    }

    func showPairPrompt(_ prompt: PairPrompt) {
        promptPanel?.orderOut(nil)
        let host = NSHostingController(rootView: PairPromptView(model: model, prompt: prompt))
        let p = NSPanel(contentViewController: host)
        p.styleMask = [.titled, .fullSizeContentView]
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        // Menu bar apps are usually inactive; the request must still be seen.
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.center()
        promptPanel = p
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
        NSSound(named: "Glass")?.play()
    }

    private func makeWindow<V: View>(_ view: V, title: String, size: NSSize, resizable: Bool) -> NSWindow {
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = title
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { mask.insert(.resizable) }
        w.styleMask = mask
        w.setContentSize(size)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        return w
    }

    private func present(_ w: NSWindow) {
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}

struct ShortcutRecorder: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    var onChange: () -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(verbatim: recording ? String(localized: "Type a shortcut…") : ShortcutFormat.string(keyCode: keyCode, modifiers: modifiers))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .frame(minWidth: 120)
        }
        .buttonStyle(.bordered)
        .tint(recording ? Brand.iris : nil)
        .onDisappear { stop() }
        .accessibilityLabel(Text("Shortcut"))
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if Int(e.keyCode) == 53 { stop(); return nil }
            let mods = ShortcutFormat.carbonModifiers(from: e.modifierFlags)
            guard mods & (256 | 4096 | 2048) != 0 else { NSSound.beep(); return nil }
            keyCode = Int(e.keyCode)
            modifiers = mods
            stop()
            onChange()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

