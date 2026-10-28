import NearclipKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UITableViewController {
    private var seed: ShareSeed?
    private var node: NearclipNode?
    private var directory: URL?
    private var operation: Task<Void, Never>?
    private var text: String?
    private var image: Data?
    private var mime = "image/png"
    private var peers: [MemberRecord] = []
    private let status = UILabel()
    private var sending = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        status.numberOfLines = 0; status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .headline)
        status.text = NSLocalizedString("Preparing…", comment: "")
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 132))
        header.autoresizingMask = .flexibleWidth
        let cancel = UIButton(type: .system)
        cancel.setTitle(NSLocalizedString("Cancel", comment: ""), for: .normal)
        cancel.frame = CGRect(x: 16, y: 8, width: 80, height: 36)
        cancel.addAction(UIAction { [weak self] _ in self?.cancel() }, for: .touchUpInside)
        cancel.accessibilityIdentifier = "share.cancel"
        status.frame = CGRect(x: 16, y: 48, width: view.bounds.width - 32, height: 76)
        status.autoresizingMask = .flexibleWidth
        status.accessibilityIdentifier = "share.status"
        header.addSubview(cancel); header.addSubview(status)
        tableView.tableHeaderView = header
        navigationItem.title = "Nearclip"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel() })
        operation = Task { await prepare() }
    }
    private func loadData(_ provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)) }
            }
        }
    }
    private func loadItem(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: error ?? NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)) }
            }
        }
    }
    private func loadImage(_ provider: NSItemProvider) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, error in
                if let image = object as? UIImage { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)) }
            }
        }
    }
    private func isImage(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) || provider.canLoadObject(ofClass: UIImage.self)
    }
    private func say(_ text: String) { status.text = text }
    private func prepare() async {
        do {
            guard let data = KeychainSecretStore(service: "studio.ivlis.nearclip.share").load("context") else {
                say(NSLocalizedString("Open Nearclip and add a device first.", comment: "")); return
            }
            let seed = try JSONDecoder().decode(ShareSeed.self, from: data)
            guard !seed.paused else { say(NSLocalizedString("Syncing paused", comment: "")); return }
            self.seed = seed
            let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
            guard let provider = providers.first(where: isImage) ?? providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) else { say(NSLocalizedString("Nothing to send", comment: "")); return }
            #if DEBUG
            NSLog("Nearclip share provider types: %@", provider.registeredTypeIdentifiers.joined(separator: ", "))
            #endif
            if isImage(provider) {
                guard seed.images else { say(NSLocalizedString("Turn on image sync in Nearclip first.", comment: "")); return }
                // A UIImage can be offered as a UIKit object without an encoded public.image representation.
                // Prefer actual encoded types so ordinary large PNG/JPEG images do not need a bitmap decode.
                let supported = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
                let concrete = provider.registeredTypeIdentifiers.filter { supported.contains($0) }
                let encoded = concrete.first { $0 == UTType.png.identifier || $0 == UTType.jpeg.identifier } ?? concrete.first
                if encoded == nil, provider.canLoadObject(ofClass: UIImage.self) {
                    let object = try await loadImage(provider)
                    guard object.size.width > 0, object.size.height > 0 else { say(NSLocalizedString("This item is not supported", comment: "")); return }
                    let factor = min(object.scale, 4096 / max(object.size.width, object.size.height))
                    let size = CGSize(width: max(1, floor(object.size.width * factor)), height: max(1, floor(object.size.height * factor)))
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
                    image = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in object.draw(in: CGRect(origin: .zero, size: size)) }
                } else {
                    let data = try await loadData(provider, type: encoded ?? UTType.image.identifier)
                    guard data.count <= 32 * 1024 * 1024,
                          let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                        say(NSLocalizedString("Image is too large", comment: "")); return
                    }
                    let type = CGImageSourceGetType(source) as String?
                    if type == UTType.jpeg.identifier { image = data; mime = "image/jpeg" }
                    else if type == UTType.png.identifier { image = data }
                    else {
                        // Bound decoding memory inside the share extension (for HEIC and other formats).
                        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096]
                        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                            say(NSLocalizedString("This item is not supported", comment: "")); return
                        }
                        image = UIImage(cgImage: cg).jpegData(compressionQuality: 0.9); mime = "image/jpeg"
                    }
                }
                guard let image, image.count <= 32 * 1024 * 1024 else { say(NSLocalizedString("Image is too large", comment: "")); return }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                let item = try await loadItem(provider, type: UTType.url.identifier)
                if let url = item as? URL { text = url.absoluteString }
                else if let url = item as? String { text = url }
                else if let data = item as? Data { text = String(data: data, encoding: .utf8) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                let item = try await loadItem(provider, type: UTType.text.identifier)
                text = (item as? String) ?? (item as? NSAttributedString)?.string ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            }
            guard image != nil || text?.isEmpty == false else { say(NSLocalizedString("This item is not supported", comment: "")); return }
            guard (text?.utf8.count ?? 0) <= 4 * 1024 * 1024 else { say(NSLocalizedString("Text is too large", comment: "")); return }
            try Task.checkCancellation()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nearclip-share-" + UUID().uuidString)
            directory = dir
            let node = try NearclipNode.shareNode(seed: seed, directory: dir)
            self.node = node
            peers = seed.members.filter { node.policy(for: $0.id).send && (image == nil || node.policy(for: $0.id).images) }
            say(peers.isEmpty ? NSLocalizedString("Open Nearclip and add a device first.", comment: "") : NSLocalizedString("Send to…", comment: ""))
            tableView.reloadData()
        } catch { say(NSLocalizedString("Couldn’t prepare this item. Try again in Nearclip.", comment: "")) }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { peers.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let peer = peers[indexPath.row]
        cell.textLabel?.text = peer.name
        let platform: String
        switch peer.platform {
        case "mac": platform = "Mac"
        case "win": platform = "Windows PC"
        case "android": platform = "Android"
        case "ios": platform = peer.model?.hasPrefix("iPad") == true ? "iPad" : "iPhone"
        default: platform = NSLocalizedString("Paired device", comment: "")
        }
        cell.detailTextLabel?.text = platform
        cell.imageView?.image = UIImage(systemName: peer.platform == "win" || peer.platform == "mac" ? "desktopcomputer" : "iphone")
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !sending, let node else { return }
        sending = true
        let peer = peers[indexPath.row]
        for member in seed?.members ?? [] {
            var policy = node.policy(for: member.id)
            policy.send = member.id == peer.id; policy.receive = false
            node.setPolicy(policy, for: member.id)
        }
        say(NSLocalizedString("Connecting…", comment: ""))
        node.start()
        operation = Task {
            let deadline = Date().addingTimeInterval(20)
            while !Task.isCancelled, Date() < deadline, !node.snapshot().online.contains(peer.id) { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled else { return }
            guard node.snapshot().online.contains(peer.id) else { fail(); return }
            guard node.supportsTargeting(peer.id) else {
                say(NSLocalizedString("Update Nearclip on the other device first.", comment: "")); node.stop(); sending = false; return
            }
            say(NSLocalizedString("Sending…", comment: ""))
            if let image { node.sendImage(image, mime: mime) } else if let text { node.sendText(text) }
            while !Task.isCancelled, Date() < deadline, !node.outgoingIdle(to: peer.id) { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled else { return }
            guard node.outgoingIdle(to: peer.id) else { fail(); return }
            cleanup()
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
    private func fail() {
        say(NSLocalizedString("Couldn’t connect. Open Nearclip on the other device and try again.", comment: ""))
        node?.stop(); sending = false
    }
    private func cleanup() {
        node?.stop(); node = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    private func cancel() {
        operation?.cancel(); cleanup()
        extensionContext?.cancelRequest(withError: NSError(domain: "Nearclip", code: NSUserCancelledError))
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); operation?.cancel(); cleanup() }
}
