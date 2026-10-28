import UIKit

/// Simulator-only host for the real system share sheet. Never embedded in Nearclip or a release archive.
@main
final class ShareHarnessApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ShareHost()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class ShareHost: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView()
        stack.axis = .vertical; stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        for kind in ["url", "text", "image"] {
            let button = UIButton(type: .system)
            button.setTitle("Share " + kind, for: .normal)
            button.accessibilityIdentifier = "host.share." + kind
            button.addAction(UIAction { [weak self] _ in self?.share(kind, sender: button) }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
    }
    private func share(_ kind: String, sender: UIButton) {
        let environment = ProcessInfo.processInfo.environment
        let item: Any
        switch kind {
        case "url": item = URL(string: environment["NC_SHARE_URL"]!)!
        case "text": item = environment["NC_SHARE_TEXT"]!
        default:
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            item = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
                UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
        }
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = sender
        controller.popoverPresentationController?.sourceRect = sender.bounds
        present(controller, animated: true)
    }
}
