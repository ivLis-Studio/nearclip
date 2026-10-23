import AppKit
import NearclipKit
import SwiftUI

struct HistoryView: View {
    let model: AppModel
    @Bindable var state: PanelState
    let actions: PanelActions
    @FocusState private var searchFocused: Bool

    var body: some View {
        let sections = state.sections(model)
        let flat = sections.flatMap(\.items)
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            searchField
                .padding(.horizontal, 12)
            filterBar
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)
            PanelBanners(model: model, openToken: state.openToken, settings: actions.settings)
            Divider().opacity(0.5)
            if flat.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(sections, flat: flat)
            }
            Divider().opacity(0.5)
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: HistoryPanelController.size.width, height: HistoryPanelController.size.height)
        .onChange(of: state.focusToken) { _, _ in searchFocused = true }
        .onChange(of: state.query) { _, _ in state.selection = state.flat(model).first?.id }
        .onChange(of: state.filter) { _, _ in state.selection = state.flat(model).first?.id }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            Image("BrandMark")
                .resizable()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            Text(verbatim: "Nearclip")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            DeviceStack(model: model)
                .onTapGesture { actions.settings(.devices) }
                .help(Text(model.statusLine))
            Menu {
                Button("Add Device…", systemImage: "plus") { actions.addDevice() }
                Button(model.settings.paused ? "Resume Syncing" : "Pause Syncing",
                       systemImage: model.settings.paused ? "play.circle" : "pause.circle") {
                    model.setPaused(!model.settings.paused)
                }
                Divider()
                Button("Settings…", systemImage: "gearshape") { actions.settings(.general) }
                Button("Quit Nearclip", systemImage: "power") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("More"))
        }
    }

    // MARK: Search & filters

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search history", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(searchFocused ? 0.12 : 0.05)))
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(HistoryFilter.allCases) { f in
                let on = state.filter == f
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { state.filter = f }
                } label: {
                    Text(f.title)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(on ? Brand.iris : Color.secondary)
                        .background(Capsule().fill(on ? Brand.iris.opacity(0.14) : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: List

    private func list(_ sections: [PanelState.Section], flat: [ClipItem]) -> some View {
        let index = Dictionary(uniqueKeysWithValues: flat.enumerated().map { ($1.id, $0) })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 10)
                            .padding(.top, section.id == sections.first?.id ? 4 : 12)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.items) { item in
                            ClipRow(model: model, item: item, index: index[item.id] ?? 99,
                                    selected: state.selection == item.id,
                                    onCopy: { actions.copy(item) })
                                .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
            .onChange(of: state.selection) { _, sel in
                guard let sel else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(sel) }
            }
        }
    }

    private var emptyState: some View {
        let filtered = !state.query.isEmpty || state.filter != .all
        return VStack(spacing: 8) {
            Image(systemName: filtered ? "magnifyingglass" : "doc.on.clipboard")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(filtered ? "No matches" : "Nothing here yet")
                .font(.system(size: 14, weight: .semibold))
            Text(filtered ? "Try a different search or filter." : "Copy something on any of your devices.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !filtered && model.otherMembers.isEmpty {
                Button {
                    actions.addDevice()
                } label: {
                    Label("Add Device", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.iris)
                .padding(.top, 8)
            }
        }
        .padding(30)
    }

    // MARK: Footer

    private var footer: some View {
        let paused = model.settings.paused
        let color: Color = paused ? Brand.warning : (model.connectedCount > 0 ? Brand.online : Color.secondary.opacity(0.6))
        return HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(model.statusLine)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                actions.addDevice()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(Text("Add Device…"))
            .accessibilityLabel(Text("Add Device"))
            Button {
                model.setPaused(!paused)
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(paused ? Text("Resume Syncing") : Text("Pause Syncing"))
            .accessibilityLabel(paused ? Text("Resume Syncing") : Text("Pause Syncing"))
        }
        .foregroundStyle(.secondary)
    }
}

/// Small overlapping avatars of the other devices; online ones carry a green dot.
struct DeviceStack: View {
    let model: AppModel

    var body: some View {
        let others = model.otherMembers.sorted { (model.isOnline($0.id) ? 0 : 1, $0.addedAt) < (model.isOnline($1.id) ? 0 : 1, $1.addedAt) }
        HStack(spacing: -6) {
            ForEach(others.prefix(4)) { m in
                let on = model.isOnline(m.id)
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(on ? Brand.iris.opacity(0.22) : Color.primary.opacity(0.08))
                        .background(Circle().fill(.thinMaterial))
                        .overlay(Image(systemName: DeviceStyle.symbol(platform: m.platform, model: m.model))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(on ? Brand.iris : Color.secondary))
                        .frame(width: 24, height: 24)
                    if on {
                        Circle().fill(Brand.online)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 1, y: 1)
                    }
                }
                .help(Text(verbatim: m.name))
            }
            if others.count > 4 {
                Text(verbatim: "+\(others.count - 4)")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(model.statusLine))
    }
}

struct ClipRow: View {
    let model: AppModel
    let item: ClipItem
    let index: Int
    let selected: Bool
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        let sc = item.clip
        let content = ClipContent.of(sc.clip)
        HStack(spacing: 10) {
            leading(content, sc)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                title(content, sc)
                HStack(spacing: 4) {
                    Image(systemName: model.sourceSymbol(sc))
                        .font(.system(size: 9.5))
                    Text(verbatim: model.sourceName(sc))
                        .lineLimit(1)
                    Text(verbatim: "·")
                    Text(verbatim: Format.relative(sc.clip.ts))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if item.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Brand.iris)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Brand.iris.opacity(0.15) : (hovering ? Color.primary.opacity(0.05) : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onCopy)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc", action: onCopy)
            if case .link(let url) = content {
                Button("Open Link", systemImage: "safari") { NSWorkspace.shared.open(url) }
            }
            Button(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin") { model.togglePin(item) }
            Divider()
            Button("Delete from All Devices", systemImage: "trash", role: .destructive) { model.delete(item) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Copies to the clipboard"))
    }

    @ViewBuilder
    private func leading(_ content: ClipContent, _ sc: StoredClip) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        switch content {
        case .image:
            if let img = Thumbnails.shared.image(id: sc.id, url: model.node.blobURL(for: sc.id)) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
            } else {
                symbolTile("photo", tint: .secondary)
            }
        case .link:
            symbolTile("link", tint: Brand.iris)
        case .color(let hex):
            shape.fill(Format.colorFromHex(hex) ?? .gray)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.15)))
                .padding(4)
        case .text:
            symbolTile("text.alignleft", tint: .secondary)
        }
    }

    private func symbolTile(_ symbol: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint == Brand.iris ? Brand.iris.opacity(0.12) : Color.primary.opacity(0.06))
            .overlay(Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(tint))
    }

    @ViewBuilder
    private func title(_ content: ClipContent, _ sc: StoredClip) -> some View {
        switch content {
        case .text(let t):
            let preview = Format.preview(t, maxLines: 2)
            Text(verbatim: preview.isEmpty ? " " : preview)
                .font(looksLikeCode(t) ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .lineLimit(2)
                .truncationMode(.tail)
        case .link(let url):
            (Text(verbatim: url.host() ?? url.absoluteString).fontWeight(.semibold)
                + Text(verbatim: url.path().count > 1 ? url.path() : "").foregroundColor(.secondary))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
        case .color(let hex):
            Text(verbatim: hex.uppercased())
                .font(.system(size: 13, design: .monospaced))
        case .image:
            let dims = (sc.clip.w ?? 0) > 0 ? " · \(sc.clip.w!)×\(sc.clip.h ?? 0)" : ""
            (Text("Image") + Text(verbatim: dims + " · " + Format.bytes(sc.clip.size ?? 0)).foregroundColor(.secondary))
                .font(.system(size: 13))
                .lineLimit(1)
        }
    }

    private func looksLikeCode(_ t: String) -> Bool {
        let lines = t.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { return false }
        let codeish = lines.prefix(6).filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") || $0.hasSuffix("{") || $0.hasSuffix(";") || $0.hasSuffix(")") }
        return codeish.count >= 2
    }

    @ViewBuilder
    private var trailing: some View {
        if hovering {
            HStack(spacing: 2) {
                Button {
                    model.togglePin(item)
                } label: {
                    Image(systemName: item.pinned ? "pin.slash" : "pin")
                }
                .help(item.pinned ? Text("Unpin") : Text("Pin"))
                .accessibilityLabel(item.pinned ? Text("Unpin") : Text("Pin"))
                Button {
                    model.delete(item)
                } label: {
                    Image(systemName: "trash")
                }
                .help(Text("Delete from All Devices"))
                .accessibilityLabel(Text("Delete from All Devices"))
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        } else if index < 9 {
            Text(verbatim: "⌘\(index + 1)")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

/// Clipboard-permission and transient notices shown above the list.
struct PanelBanners: View {
    let model: AppModel
    let openToken: Int
    let settings: (SettingsPage) -> Void

    var body: some View {
        let access = MacSystem.clipboardAccess
        let _ = openToken
        VStack(spacing: 6) {
            if access == .denied || access == .ask {
                banner(symbol: "hand.raised.fill", tint: Brand.warning,
                       text: Text("Allow clipboard access so Nearclip can sync what you copy."),
                       action: Text("Fix…")) { MacSystem.openPrivacyPane("Privacy_Pasteboard") }
            }
            if let n = model.notice {
                banner(symbol: n.symbol, tint: n.tone == .warning ? Brand.warning : (n.tone == .success ? Brand.online : Brand.iris),
                       text: Text(verbatim: n.text), action: nil, perform: nil)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, (access == .denied || access == .ask || model.notice != nil) ? 8 : 0)
        .animation(.easeOut(duration: 0.2), value: model.notice)
    }

    private func banner(symbol: String, tint: Color, text: Text, action: Text?, perform: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            text.font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action, let perform {
                Button(action: perform) { action.font(.system(size: 11.5, weight: .semibold)) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)))
    }
}

