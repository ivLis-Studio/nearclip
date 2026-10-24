import NearclipKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Bindable var env: AppEnvironment

    var body: some View {
        HomeView(env: env)
            .fullScreenCover(isPresented: $env.showOnboarding) { OnboardingView(env: env) }
            .sheet(isPresented: $env.showAddDevice) { AddDeviceView(env: env) }
            .sheet(isPresented: $env.showSettings) { SettingsView(env: env) }
    }
}

struct HomeView: View {
    @Bindable var env: AppEnvironment
    @State private var query = ""
    @State private var filter: HistoryFilter = .all

    var body: some View {
        let model = env.model
        let items = model.items(filter: filter, query: query)
        NavigationStack(path: $env.path) {
            List {
                Section {
                    StatusCard(env: env)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
                Section {
                    FilterChips(filter: $filter)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                ForEach(sections(items), id: \.title) { section in
                    Section {
                        ForEach(section.items) { item in
                            ClipRowView(env: env, item: item)
                        }
                    } header: {
                        Text(section.title)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .navigationTitle("Nearclip")
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .devices: DevicesView(env: env, embedded: true)
                }
            }
            .searchable(text: $query, prompt: Text("Search history"))
            .refreshable { model.refresh() }
            .overlay {
                if items.isEmpty {
                    EmptyHistory(filtered: !query.isEmpty || filter != .all, hasDevices: !model.otherMembers.isEmpty) {
                        env.showAddDevice = true
                    }
                    .padding(.top, 180)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        env.showAddDevice = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("Add Device"))
                    .accessibilityIdentifier("home.addDevice")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        env.showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(Text("Settings"))
                    .accessibilityIdentifier("home.settings")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if env.toast == nil, let t = env.model.shownTransfer {
                        TransferOverlay(transfer: t, name: env.model.deviceName(t.from), symbol: env.model.deviceSymbol(t.from))
                    }
                    ToastOverlay(toast: env.toast)
                    SendBar(env: env)
                }
                .animation(.spring(duration: 0.35), value: env.model.shownTransfer?.id)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
    }

    private struct DaySection { var title: String; var items: [ClipItem] }

    private func sections(_ items: [ClipItem]) -> [DaySection] {
        if filter == .pinned || !query.isEmpty {
            return items.isEmpty ? [] : [DaySection(title: filter == .pinned ? String(localized: "Pinned") : String(localized: "Results"), items: items)]
        }
        var out: [DaySection] = []
        let pinned = items.filter(\.pinned)
        if !pinned.isEmpty { out.append(DaySection(title: String(localized: "Pinned"), items: pinned)) }
        for item in items where !item.pinned {
            let t = Format.daySection(item.clip.clip.ts)
            if out.last?.title == t, out.last?.title != String(localized: "Pinned") || pinned.isEmpty {
                out[out.count - 1].items.append(item)
            } else {
                out.append(DaySection(title: t, items: [item]))
            }
        }
        return out
    }
}

/// Connected devices at a glance; opens the Devices sheet.
struct StatusCard: View {
    let env: AppEnvironment

    var body: some View {
        let model = env.model
        let paused = model.settings.paused
        NavigationLink(value: AppRoute.devices) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill((paused ? Brand.warning : (model.connectedCount > 0 ? Brand.online : Color.secondary)).opacity(0.15))
                    Image(systemName: paused ? "pause.fill" : (model.connectedCount > 0 ? "dot.radiowaves.left.and.right" : "wifi"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(paused ? Brand.warning : (model.connectedCount > 0 ? Brand.online : Color.secondary))
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.statusLine)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(verbatim: subtitle(model))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                HStack(spacing: -8) {
                    ForEach(model.otherMembers.prefix(3)) { m in
                        Image(systemName: DeviceStyle.symbol(platform: m.platform, model: m.model))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.isOnline(m.id) ? Brand.iris : Color.secondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                            .background(Circle().fill(Brand.iris.opacity(model.isOnline(m.id) ? 0.18 : 0.06)).padding(-2))
                    }
                }
            }
        }
        .accessibilityHint(Text("Shows your devices"))
        .accessibilityIdentifier("home.devices")
    }

    private func subtitle(_ model: AppModel) -> String {
        if model.settings.paused { return String(localized: "Tap to manage your devices") }
        if model.otherMembers.isEmpty { return String(localized: "Add a computer or phone to start") }
        let names = model.connectedMembers.map(\.name)
        if names.isEmpty { return String(localized: "Make sure they're on the same Wi-Fi") }
        return ListFormatter.localizedString(byJoining: names)
    }
}

struct FilterChips: View {
    @Binding var filter: HistoryFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HistoryFilter.allCases) { f in
                    let on = filter == f
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { filter = f }
                    } label: {
                        Label(f.title, systemImage: f.symbol)
                            .font(.subheadline.weight(on ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .background(Capsule().fill(on ? Brand.iris : Color(.secondarySystemGroupedBackground)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .sensoryFeedback(.selection, trigger: filter)
    }
}

/// Bottom bar: send what's on the clipboard with the system Paste button (never triggers a permission prompt).
struct SendBar: View {
    let env: AppEnvironment

    var body: some View {
        let pending = env.pendingClipboard
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon(pending))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(pending != nil ? Color.white : Brand.iris)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(pending != nil ? Brand.iris : Brand.iris.opacity(0.14)))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(pending != nil ? title(pending!) : String(localized: "Send what you copied"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(pending != nil ? String(localized: "Tap Paste to send it to your devices") : String(localized: "Copy in any app, then tap Paste"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 4)
            PasteButton(supportedContentTypes: [.image, .url, .plainText]) { providers in
                Task { @MainActor in env.sendPasted(providers) }
            }
            .buttonBorderShape(.capsule)
            .labelStyle(.titleAndIcon)
            .tint(Brand.iris)
            .accessibilityIdentifier("send.paste")
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(pending != nil ? Brand.iris.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: pending != nil ? 1.5 : 1)
        }
        .animation(.snappy, value: pending)
    }

    private func icon(_ k: ClipboardKind?) -> String {
        switch k {
        case .image: return "photo"
        case .link: return "link"
        case .text: return "text.alignleft"
        case nil: return "paperplane.fill"
        }
    }

    private func title(_ k: ClipboardKind) -> String {
        switch k {
        case .image: return String(localized: "New image on your clipboard")
        case .link: return String(localized: "New link on your clipboard")
        case .text: return String(localized: "New text on your clipboard")
        }
    }
}

struct EmptyHistory: View {
    let filtered: Bool
    let hasDevices: Bool
    let addDevice: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: filtered ? "magnifyingglass" : "doc.on.clipboard")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(filtered ? "No matches" : "Nothing here yet")
                .font(.title3.weight(.semibold))
            Text(filtered ? "Try a different search or filter." : "Copy something on any of your devices.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !filtered && !hasDevices {
                Button(action: addDevice) {
                    Label("Add Device", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 40)
    }
}

struct ToastOverlay: View {
    let toast: Toast?

    var body: some View {
        if let t = toast {
            HStack(spacing: 8) {
                Image(systemName: t.symbol).foregroundStyle(t.tint)
                Text(verbatim: t.text)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Capsule().fill(.regularMaterial).shadow(color: .black.opacity(0.15), radius: 12, y: 4))
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("toast")
            .sensoryFeedback(.success, trigger: t.id)
        }
    }
}

/// "Receiving an image from MacBook Pro…" with a progress bar while a large image comes in (PROTOCOL.md §6.6). The
/// "Copied from MacBook Pro" toast takes its place when the image is in.
struct TransferOverlay: View {
    let transfer: IncomingTransfer
    let name: String
    let symbol: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Brand.iris))
            VStack(alignment: .leading, spacing: 6) {
                Text("Receiving an image from \(name)…")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    bar
                        .frame(height: 4)
                    Text(verbatim: detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial).shadow(color: .black.opacity(0.15), radius: 12, y: 4))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityValue(transfer.fraction.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text(verbatim: ""))
        .accessibilityIdentifier("transfer")
    }

    private var detail: String {
        guard transfer.total > 0 else { return String(localized: "Preparing…") }
        if transfer.total >= 1_000_000 {
            return String(format: "%.1f / %.1f MB", Double(transfer.received) / 1_000_000, Double(transfer.total) / 1_000_000)
        }
        return String(format: "%d / %d KB", transfer.received / 1000, max(1, transfer.total / 1000))
    }

    private var bar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if let f = transfer.fraction {
                    Capsule().fill(Brand.iris)
                        .frame(width: max(4, g.size.width * f))
                        .animation(.easeOut(duration: 0.3), value: f)
                } else if reduceMotion {
                    Capsule().fill(Brand.iris.opacity(0.55)).frame(width: g.size.width * 0.3)
                } else {
                    TimelineView(.animation) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
                        let w = g.size.width * 0.32
                        Capsule().fill(Brand.iris).frame(width: w).offset(x: -w + (g.size.width + w) * phase)
                    }
                }
            }
            .clipShape(Capsule())
        }
    }
}

struct ClipRowView: View {
    let env: AppEnvironment
    let item: ClipItem

    var body: some View {
        let model = env.model
        let sc = item.clip
        let content = ClipContent.of(sc.clip)
        Button {
            env.copy(item)
        } label: {
            HStack(spacing: 12) {
                leading(content, sc)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    title(content, sc)
                    HStack(spacing: 4) {
                        Image(systemName: model.sourceSymbol(sc)).font(.caption2)
                        Text(verbatim: model.sourceName(sc)).lineLimit(1)
                        Text(verbatim: "·")
                        Text(verbatim: Format.relative(sc.clip.ts)).lineLimit(1).layoutPriority(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(Brand.iris)
                        .accessibilityLabel(Text("Pinned"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("clip.row")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.delete(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                model.togglePin(item)
            } label: {
                Label(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin")
            }
            .tint(Brand.iris)
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { env.copy(item) }
            share(content, sc)
            if case .link(let url) = content {
                Link(destination: url) { Label("Open Link", systemImage: "safari") }
            }
            Button(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin") { model.togglePin(item) }
            Button("Delete from All Devices", systemImage: "trash", role: .destructive) { model.delete(item) }
        } preview: {
            ClipPreview(env: env, item: item)
        }
        .accessibilityHint(Text("Copies to the clipboard"))
    }

    @ViewBuilder
    private func share(_ content: ClipContent, _ sc: StoredClip) -> some View {
        if sc.clip.isImage, let img = UIImage(contentsOfFile: env.model.node.blobURL(for: sc.id).path) {
            ShareLink(item: Image(uiImage: img), preview: SharePreview(Text("Image"), image: Image(uiImage: img))) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } else if let t = sc.clip.text {
            ShareLink(item: t) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }

    @ViewBuilder
    private func leading(_ content: ClipContent, _ sc: StoredClip) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        switch content {
        case .image:
            if let img = Thumbs.shared.image(id: sc.id, url: env.model.node.blobURL(for: sc.id)) {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
            } else {
                tile("photo", Color.secondary)
            }
        case .link: tile("link", Brand.iris)
        case .color(let hex):
            shape.fill(Format.colorFromHex(hex) ?? .gray)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
                .padding(5)
        case .text: tile("text.alignleft", Color.secondary)
        }
    }

    private func tile(_ symbol: String, _ tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint == Brand.iris ? Brand.iris.opacity(0.13) : Color(.tertiarySystemFill))
            .overlay(Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(tint))
    }

    @ViewBuilder
    private func title(_ content: ClipContent, _ sc: StoredClip) -> some View {
        switch content {
        case .text(let t):
            Text(verbatim: Format.preview(t, maxLines: 2))
                .font(.body)
                .lineLimit(2)
                .foregroundStyle(.primary)
        case .link(let url):
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: url.host() ?? url.absoluteString).font(.body.weight(.semibold)).lineLimit(1)
                if url.path().count > 1 {
                    Text(verbatim: url.path()).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        case .color(let hex):
            Text(verbatim: hex.uppercased()).font(.body.monospaced())
        case .image:
            let dims = (sc.clip.w ?? 0) > 0 ? "\(sc.clip.w!)×\(sc.clip.h ?? 0) · " : ""
            (Text("Image").font(.body) + Text(verbatim: "  " + dims + Format.bytes(sc.clip.size ?? 0)).font(.subheadline).foregroundColor(.secondary))
                .lineLimit(1)
        }
    }
}

struct ClipPreview: View {
    let env: AppEnvironment
    let item: ClipItem

    var body: some View {
        let sc = item.clip
        Group {
            if sc.clip.isImage, let img = UIImage(contentsOfFile: env.model.node.blobURL(for: sc.id).path) {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                ScrollView {
                    Text(verbatim: sc.clip.text ?? "")
                        .font(.body)
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 340)
        .frame(maxHeight: 420)
    }
}

