import AppKit
import NearclipKit
import SwiftUI

/// "Copied from iPhone" — a small, non-activating capsule under the menu bar.
@MainActor
final class ToastController {
    private let model: AppModel
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    init(model: AppModel) { self.model = model }

    func show(_ sc: StoredClip) {
        guard model.settings.showToasts else { return }
        let view = ToastView(symbol: model.sourceSymbol(sc), source: model.sourceName(sc), clip: sc,
                             thumbnail: sc.clip.isImage ? Thumbnails.shared.image(id: sc.id, url: model.node.blobURL(for: sc.id)) : nil)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let p = panel ?? makePanel()
        host.frame = NSRect(origin: .zero, size: size)
        let surface = HistoryPanelController.surface(for: host, cornerRadius: 16)
        surface.frame = host.frame
        p.contentView = surface
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let origin = NSPoint(x: vf.maxX - size.width - 14, y: vf.maxY - size.height - 10)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }
        panel = p
        scheduleHide(after: 2.5)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hide() {
        guard let p = panel else { return }
        if NSMouseInRect(NSEvent.mouseLocation, p.frame, false) {
            scheduleHide(after: 1)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { p.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isReleasedWhenClosed = false
        return p
    }
}

struct ToastView: View {
    let symbol: String
    let source: String
    let clip: StoredClip
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Brand.iris))
            VStack(alignment: .leading, spacing: 2) {
                Text("Copied from \(source)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: preview)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 230, alignment: .leading)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var preview: String {
        if clip.clip.isImage {
            let w = clip.clip.w ?? 0, h = clip.clip.h ?? 0
            return w > 0 ? String(localized: "Image · \(w)×\(h)") : String(localized: "Image")
        }
        return Format.preview(clip.clip.text ?? "", maxLines: 1)
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

