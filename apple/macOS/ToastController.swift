import AppKit
import NearclipKit
import SwiftUI

/// The small, non-activating capsule under the menu bar. "Copied from iPhone" when a clip arrives; for a large image,
/// "Receiving an image from iPhone…" with a progress bar first (PROTOCOL.md §6.6), which turns into "Copied from iPhone"
/// in place when the image is in. A verification code from a phone (§6.7) asks "Copy it?" with Copy and Not Now.
@MainActor
final class ToastController {
    private enum Shown: Equatable {
        case copied(StoredClip)
        case received(StoredClip)
        case transfer(IncomingTransfer)
        case failed(IncomingTransfer)
        case code(StoredClip)
    }

    private let model: AppModel
    private var panel: NSPanel?
    private var host: FirstClickHostingView<ToastView>?
    private var hideWork: DispatchWorkItem?
    private var shown: Shown?
    /// A transfer the user clicked away: its progress no longer brings the capsule back (its arrival still does).
    private var dismissedTransfer: String?
    /// Bumped on every show and hide, so a fade-out that finishes after a newer show leaves the panel up.
    private var token = 0
    /// Bumped when the capsule appears from hidden, so it shows the new content at once instead of animating from
    /// whatever it showed last.
    private var epoch = 0
    var onClick: (() -> Void)?

    init(model: AppModel) { self.model = model }

    /// A clip from another device was copied to the clipboard.
    func show(_ sc: StoredClip) { present(.copied(sc), hideAfter: 2.5) }

    /// An image that was shown arriving is in history but was not copied (auto-copy off, or an older clip).
    func received(_ sc: StoredClip) { present(.received(sc), hideAfter: 2.5) }

    /// The image shown arriving did not make it.
    func failed(_ t: IncomingTransfer) { present(.failed(t), hideAfter: 3.5) }

    /// A verification code from another device: "A verification code arrived from Junseo's iPhone. Copy it?". It waits
    /// for an answer — shown even with arrival notices off — and goes after a minute, as codes expire.
    func code(_ sc: StoredClip) { present(.code(sc), hideAfter: 60, always: true) }

    /// The image shown arriving changed; nil when none is arriving any more.
    func transfer(_ t: IncomingTransfer?) {
        if let t {
            guard t.id != dismissedTransfer else { return }
            present(.transfer(t), hideAfter: nil)
        } else if case .transfer = shown {
            hide()
        }
    }

    private func present(_ s: Shown, hideAfter: TimeInterval?, always: Bool = false) {
        guard always || model.settings.showToasts else { return }
        // A code waiting for an answer is not pushed away by a notice (a newer code replaces it).
        if case .code = shown, panel?.isVisible == true, !always { return }
        shown = s
        token += 1
        let p = panel ?? makePanel()
        panel = p
        if !p.isVisible { epoch += 1 }
        let view = makeView(s)
        if let host {
            host.rootView = view
        } else {
            let h = FirstClickHostingView(rootView: view)
            host = h
            p.contentView = HistoryPanelController.surface(for: h, cornerRadius: 16)
        }
        // Measured off-screen: the hosted view is pinned to the panel, which still has the old size.
        let size = NSHostingView(rootView: view).fittingSize
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        p.setFrame(NSRect(x: vf.maxX - size.width - 14, y: vf.maxY - size.height - 10, width: size.width, height: size.height),
                   display: true)
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }
        hideWork?.cancel()
        hideWork = nil
        if let hideAfter { scheduleHide(after: hideAfter) }
    }

    private func makeView(_ s: Shown) -> ToastView {
        ToastView(content: content(s), epoch: epoch, onClick: { [weak self] in self?.clicked() },
                  onCopy: { [weak self] in self?.copyShownCode() }, onDismiss: { [weak self] in self?.hide() })
    }

    private func content(_ s: Shown) -> ToastContent {
        switch s {
        case .copied(let sc):
            return clipContent(sc, title: String(localized: "Copied from \(model.sourceName(sc))"), detail: preview(sc))
        case .received(let sc):
            return clipContent(sc, title: String(localized: "Image from \(model.sourceName(sc))"),
                               detail: String(localized: "Saved to history"))
        case .transfer(let t):
            let name = model.deviceName(t.from)
            return ToastContent(
                id: t.id, symbol: model.deviceSymbol(t.from), tint: Brand.iris,
                title: String(localized: "Receiving an image from \(name)…"),
                detail: t.total > 0 ? ToastContent.progressText(t.received, of: t.total) : String(localized: "Preparing…"),
                progress: t.fraction.map { .value($0) } ?? .indeterminate, image: true)
        case .failed(let t):
            return ToastContent(
                id: t.id, symbol: "exclamationmark", tint: Brand.warning,
                title: String(localized: "Couldn't receive the image"),
                detail: String(localized: "Copy it again on \(model.deviceName(t.from))."), progress: .none, image: false)
        case .code(let sc):
            return ToastContent(
                id: sc.id, symbol: model.sourceSymbol(sc), tint: Brand.iris,
                title: String(localized: "A verification code arrived from \(model.sourceName(sc)). Copy it?"),
                detail: "", progress: .none, image: false, code: sc.clip.text)
        }
    }

    private func clipContent(_ sc: StoredClip, title: String, detail: String) -> ToastContent {
        let image = sc.clip.isImage
        // Made off the main thread and filled in when ready, so "Copied from …" shows the moment the image is in.
        let thumbnail = image ? Thumbnails.shared.cached(id: sc.id) : nil
        if image, thumbnail == nil { loadThumbnail(sc) }
        return ToastContent(id: sc.id, symbol: model.sourceSymbol(sc), tint: Brand.iris, title: title, detail: detail,
                            progress: .none, image: image, thumbnail: thumbnail)
    }

    private func loadThumbnail(_ sc: StoredClip) {
        let url = model.node.blobURL(for: sc.id)
        Task { [weak self] in
            guard await Thumbnails.shared.load(id: sc.id, url: url) != nil, let self, let s = self.shown else { return }
            switch s {
            case .copied(let shownClip) where shownClip.id == sc.id, .received(let shownClip) where shownClip.id == sc.id:
                // Same size: the slot is already there.
                self.host?.rootView = self.makeView(s)
            default:
                break
            }
        }
    }

    private func preview(_ sc: StoredClip) -> String {
        if sc.clip.isImage {
            let w = sc.clip.w ?? 0, h = sc.clip.h ?? 0
            return w > 0 ? String(localized: "Image · \(w)×\(h)") : String(localized: "Image")
        }
        return Format.preview(sc.clip.text ?? "", maxLines: 1)
    }

    private func clicked() {
        // Clicking a code offer anywhere copies it, like its Copy button.
        if case .code = shown {
            copyShownCode()
            return
        }
        if case .transfer(let t) = shown { dismissedTransfer = t.id }
        hideWork?.cancel()
        token += 1
        shown = nil
        panel?.orderOut(nil)
        onClick?()
    }

    /// Copy on a code offer: the code goes to this Mac's clipboard, and the capsule says so.
    private func copyShownCode() {
        guard case .code(let sc) = shown else { return }
        model.copyCode(sc)
        shown = nil
        present(.copied(sc), hideAfter: 1.8, always: true)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideIfIdle() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hideIfIdle() {
        guard let p = panel else { return }
        if NSMouseInRect(NSEvent.mouseLocation, p.frame, false) {
            scheduleHide(after: 1)
            return
        }
        hide()
    }

    private func hide() {
        hideWork?.cancel()
        hideWork = nil
        shown = nil
        guard let p = panel, p.isVisible else { return }
        token += 1
        let t = token
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard self?.token == t else { return }
                p.orderOut(nil)
            }
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

struct ToastContent: Equatable {
    enum Progress: Equatable {
        case none
        /// Size not known yet: the other device is still encoding the image.
        case indeterminate
        case value(Double)
    }

    var id: String
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    var progress: Progress
    /// Keeps a thumbnail slot, so the capsule keeps its size when "Receiving…" turns into "Copied from…".
    var image: Bool
    var thumbnail: NSImage? = nil
    /// A verification code offered with Copy and Not Now.
    var code: String? = nil

    /// "3.1 / 8.4 MB": both in the unit of the total, so the numbers don't jump between units.
    static func progressText(_ received: Int, of total: Int) -> String {
        if total >= 1_000_000 {
            return String(format: "%.1f / %.1f MB", Double(received) / 1_000_000, Double(total) / 1_000_000)
        }
        return String(format: "%d / %d KB", received / 1000, max(1, total / 1000))
    }
}

struct ToastView: View {
    let content: ToastContent
    /// A new value starts over without animating from the previous content (the capsule just appeared).
    var epoch = 0
    var onClick: () -> Void = {}
    var onCopy: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        Group {
            if let code = content.code { codeOffer(code) } else { notice }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
        .animation(.snappy(duration: 0.25), value: content.title)
        .accessibilityElement(children: content.code == nil ? .combine : .contain)
        .accessibilityValue(content.accessibilityProgress)
        .id(epoch)
    }

    private var icon: some View {
        Image(systemName: content.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(content.tint))
            .contentTransition(.symbolEffect(.replace))
    }

    /// "A verification code arrived from Junseo's iPhone. Copy it?", the code in large digits, Copy and Not Now.
    private func codeOffer(_ code: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 7) {
                Text(verbatim: content.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: code)
                    .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                    .tracking(2.5)
                    .accessibilityLabel(Text(verbatim: code.map(String.init).joined(separator: " ")))
                HStack(spacing: 8) {
                    Button(action: onCopy) {
                        Label("Copy", systemImage: "doc.on.doc").labelStyle(.titleOnly)
                    }
                    .buttonStyle(ToastButtonStyle(prominent: true))
                    .accessibilityIdentifier("toast.code.copy")
                    Button("Not Now", action: onDismiss)
                        .buttonStyle(ToastButtonStyle(prominent: false))
                        .accessibilityIdentifier("toast.code.dismiss")
                }
                .padding(.top, 1)
            }
            .frame(width: 230, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    private var notice: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: content.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                if content.progress == .none {
                    Text(verbatim: content.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 8) {
                        ToastProgressBar(fraction: content.fraction)
                            .frame(height: 4)
                        Text(verbatim: content.detail)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(height: 15)
                }
            }
            .frame(width: content.image ? 230 : nil, alignment: .leading)
            .frame(maxWidth: 230, alignment: .leading)
            if content.image {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08))
                    if let thumbnail = content.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .animation(.easeOut(duration: 0.2), value: content.thumbnail != nil)
            }
        }
    }
}

/// Capsule buttons that keep their colour in the capsule, which never becomes the key window.
private struct ToastButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .frame(minWidth: 64)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(Capsule().fill(prominent ? AnyShapeStyle(Brand.iris) : AnyShapeStyle(Color.primary.opacity(0.1))))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Takes the first click: the capsule is a non-activating panel, and its buttons work without focusing it first.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private extension ToastContent {
    var fraction: Double? {
        if case .value(let f) = progress { return f }
        return nil
    }

    var accessibilityProgress: Text {
        guard let f = fraction else { return Text(verbatim: "") }
        return Text(f, format: .percent.precision(.fractionLength(0)))
    }
}

/// A thin capsule bar; without a fraction a short segment sweeps across (a still segment with Reduce Motion).
struct ToastProgressBar: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if let fraction {
                    Capsule()
                        .fill(Brand.iris)
                        .frame(width: max(4, g.size.width * fraction))
                        .animation(.easeOut(duration: 0.3), value: fraction)
                } else if reduceMotion {
                    Capsule().fill(Brand.iris.opacity(0.55)).frame(width: g.size.width * 0.3)
                } else {
                    TimelineView(.animation) { timeline in
                        let period = 1.3
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                        let w = g.size.width * 0.32
                        Capsule()
                            .fill(Brand.iris)
                            .frame(width: w)
                            .offset(x: -w + (g.size.width + w) * phase)
                    }
                }
            }
            .clipShape(Capsule())
        }
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
