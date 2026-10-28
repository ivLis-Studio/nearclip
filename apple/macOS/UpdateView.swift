import SwiftUI

struct UpdateView: View {
    @State private var message = ""
    @State private var newer: String?
    @State private var checking = false
    var body: some View {
        VStack(spacing: 8) {
            if let newer {
                Link(String(localized: "Download version \(newer)"), destination: URL(string: "https://github.com/ivLis-Studio/nearclip/releases/latest")!)
            } else {
                Button("Check for updates") { Task { await check() } }.disabled(checking)
            }
            if !message.isEmpty { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
        }
        .task {
            let defaults = UserDefaults.standard
            if let cached = defaults.string(forKey: "updateAvailableVersion"),
               cached.compare(MacSystem.appVersion, options: .numeric) == .orderedDescending { newer = cached }
            let last = defaults.double(forKey: "updateCheckAt")
            if defaults.string(forKey: "updateCheckAppVersion") != MacSystem.appVersion || Date().timeIntervalSince1970 - last > 86_400 {
                await check()
            } else if newer == nil { message = String(localized: "You’re up to date") }
        }
    }
    private func check() async {
        guard !checking else { return }; checking = true
        defer { checking = false }
        struct Release: Decodable { var tag_name: String; var draft: Bool; var prerelease: Bool }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/ivLis-Studio/nearclip/releases/latest")!)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            guard !release.draft, !release.prerelease, version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { throw URLError(.cannotParseResponse) }
            newer = version.compare(MacSystem.appVersion, options: .numeric) == .orderedDescending ? version : nil
            message = newer == nil ? String(localized: "You’re up to date") : ""
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "updateCheckAt")
            UserDefaults.standard.set(MacSystem.appVersion, forKey: "updateCheckAppVersion")
            UserDefaults.standard.set(newer, forKey: "updateAvailableVersion")
        } catch { message = String(localized: "Couldn’t check for updates. Try again later.") }
    }
}
