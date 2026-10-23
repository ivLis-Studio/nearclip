import AppKit
import NearclipKit

@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let model: AppModel
    private let panel: HistoryPanelController
    private let windows: WindowManager
    private var pulseWork: DispatchWorkItem?

    var anchorView: NSView? { item.button }

    init(model: AppModel, panel: HistoryPanelController, windows: WindowManager) {
        self.model = model
        self.panel = panel
        self.windows = windows
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let b = item.button {
            let img = NSImage(named: "MenuBarIcon")
            img?.isTemplate = true
            b.image = img
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.setAccessibilityLabel("Nearclip")
        }
        observeChanges { [weak self] in self?.updateAppearance() }
    }

    private func updateAppearance() {
        guard let b = item.button else { return }
        let paused = model.settings.paused
        b.appearsDisabled = paused
        b.toolTip = "Nearclip — " + model.statusLine
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panel.toggle(anchor: sender)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "", state: NSControl.StateValue = .off) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            i.state = state
            menu.addItem(i)
        }
        let header = NSMenuItem(title: model.statusLine, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        add(String(localized: "Open History"), #selector(openPanel))
        add(String(localized: "Add Device…"), #selector(addDevice))
        add(String(localized: "Pause Syncing"), #selector(togglePause), state: model.settings.paused ? .on : .off)
        menu.addItem(.separator())
        add(String(localized: "Settings…"), #selector(openSettings), ",")
        add(String(localized: "Quit Nearclip"), #selector(quit), "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openPanel() { panel.show(anchor: item.button) }
    @objc private func addDevice() { windows.showAddDevice() }
    @objc private func togglePause() { model.setPaused(!model.settings.paused) }
    @objc private func openSettings() { windows.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Brief accent tint when a clip is sent or received.
    func pulse() {
        guard let b = item.button, !model.settings.paused else { return }
        pulseWork?.cancel()
        b.contentTintColor = NSColor(named: "Iris")
        let work = DispatchWorkItem { [weak b] in b?.contentTintColor = nil }
        pulseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
}

