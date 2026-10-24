import AppKit
import Carbon.HIToolbox
import NearclipKit
import SwiftUI

final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class PanelState {
    var query = ""
    var filter: HistoryFilter = .all
    var selection: String?
    var focusToken = 0
    /// Clip shown in the full preview (Space with an empty search field).
    var previewId: String?
    /// Bumped whenever the panel opens so permission banners re-check the system state.
    var openToken = 0

    struct Section: Identifiable {
        var id: String
        var title: String
        var items: [ClipItem]
    }

    func sections(_ model: AppModel) -> [Section] {
        let items = model.items(filter: filter, query: query)
        if filter == .pinned || !query.isEmpty {
            return items.isEmpty ? [] : [Section(id: "results", title: filter == .pinned ? String(localized: "Pinned") : String(localized: "Results"), items: items)]
        }
        var out: [Section] = []
        let pinned = items.filter(\.pinned)
        if !pinned.isEmpty { out.append(Section(id: "pinned", title: String(localized: "Pinned"), items: pinned)) }
        var current: Section?
        for item in items where !item.pinned {
            let title = Format.daySection(item.clip.clip.ts)
            if current?.title != title {
                if let c = current { out.append(c) }
                current = Section(id: "day-\(title)", title: title, items: [])
            }
            current?.items.append(item)
        }
        if let c = current { out.append(c) }
        return out
    }

    func flat(_ model: AppModel) -> [ClipItem] { sections(model).flatMap(\.items) }
}

struct PanelActions {
    var copy: (ClipItem) -> Void
    var addDevice: () -> Void
    var settings: (SettingsPage) -> Void
    var close: () -> Void
}

@MainActor
final class HistoryPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let windows: WindowManager
    private let monitor: PasteboardMonitor
    let state = PanelState()
    private var panel: HistoryPanel!
    private var keyMonitor: Any?
    static let size = NSSize(width: 380, height: 540)

    init(model: AppModel, windows: WindowManager, monitor: PasteboardMonitor) {
        self.model = model
        self.windows = windows
        self.monitor = monitor
        super.init()
        let p = HistoryPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovable = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .utilityWindow
        p.delegate = self
        let actions = PanelActions(
            copy: { [weak self] item in self?.copy(item) },
            addDevice: { [weak self] in self?.hide(); self?.windows.showAddDevice() },
            settings: { [weak self] page in self?.hide(); self?.windows.showSettings(page) },
            close: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: HistoryView(model: model, state: state, actions: actions))
        p.contentView = Self.surface(for: host, cornerRadius: 18)
        panel = p
    }

    /// Liquid Glass on macOS 26+, vibrancy before that.
    static func surface(for content: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius - 4
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(anchor: NSView?) {
        if panel.isVisible { hide() } else { show(anchor: anchor) }
    }

    func show(anchor: NSView?) {
        state.query = ""
        state.previewId = nil
        state.openToken += 1
        state.selection = state.flat(model).first?.id
        position(anchor)
        panel.makeKeyAndOrderFront(nil)
        state.focusToken += 1
        installKeyMonitor()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeKeyMonitor()
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func position(_ anchor: NSView?) {
        let size = Self.size
        // The status item can be hidden (notch, menu bar managers); then fall back to a centred panel.
        if let anchor, let win = anchor.window, win.isVisible, win.occlusionState.contains(.visible),
           let screen = win.screen, win.frame.width > 0, NSIntersectsRect(win.frame, screen.frame) {
            let r = win.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let vf = screen.visibleFrame
            let x = min(max(r.midX - size.width / 2, vf.minX + 8), vf.maxX - size.width - 8)
            let y = max(min(r.minY, vf.maxY) - size.height - 6, vf.minY + 8)
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        } else {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            guard let vf = screen?.visibleFrame else { return }
            var y = vf.minY + vf.height * 0.6 - size.height / 2
            y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
            panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: y, width: size.width, height: size.height), display: false)
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func handle(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        #if DEBUG
        if ProcessInfo.processInfo.environment["NC_DEBUG_KEYS"] != nil {
            FileHandle.standardError.write(Data("key \(e.keyCode) flags \(flags.rawValue) query '\(state.query)'\n".utf8))
        }
        #endif
        switch Int(e.keyCode) {
        case kVK_DownArrow: move(1); return true
        case kVK_UpArrow: move(-1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let item = selectedItem { copy(item) }
            return true
        case kVK_Escape:
            if state.previewId != nil { state.previewId = nil } else if !state.query.isEmpty { state.query = "" } else { hide() }
            return true
        case kVK_Space where flags.isEmpty && state.query.isEmpty:
            if state.previewId != nil { state.previewId = nil } else { state.previewId = selectedItem?.id }
            return true
        case kVK_Delete where flags == .command:
            if let item = selectedItem { model.delete(item) }
            return true
        default:
            break
        }
        guard flags == .command, let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
        if let n = Int(ch), (1...9).contains(n) {
            let flat = state.flat(model)
            if n - 1 < flat.count { copy(flat[n - 1]) }
            return true
        }
        switch ch {
        case "p":
            if let item = selectedItem { model.togglePin(item) }
            return true
        case "f":
            state.focusToken += 1
            return true
        case ",":
            hide()
            windows.showSettings()
            return true
        default:
            return false
        }
    }

    private var selectedItem: ClipItem? {
        let flat = state.flat(model)
        return flat.first { $0.id == state.selection } ?? flat.first
    }

    private func move(_ delta: Int) {
        let flat = state.flat(model)
        guard !flat.isEmpty else { return }
        let i = flat.firstIndex { $0.id == state.selection } ?? -1
        let next = min(max(i + delta, 0), flat.count - 1)
        state.selection = flat[next].id
    }

    private func copy(_ item: ClipItem) {
        model.copy(item)
        hide()
        #if !APPSTORE // the Mac App Store build is sandboxed and cannot send ⌘V to another app
        if model.settings.pasteAfterChoosing && MacSystem.isAccessibilityTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { MacSystem.pasteIntoFrontApp() }
        }
        #endif
    }
}

