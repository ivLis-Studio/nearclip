import Foundation

/// One component of the embedded Tailscale node and its license files, from THIRD_PARTY_NOTICES.txt
/// (tailnet/build.sh notices, bundled with the app). Shown under About › Open-source licenses.
struct OpenSourceNotice: Identifiable, Hashable {
    let id: String   // "tailscale.com v1.104.2"
    let text: String // the license files, as published

    var name: String { id.split(separator: " ").first.map(String.init) ?? id }

    /// The text with its hard-wrapped lines joined into paragraphs, for narrow screens; list items ("* ", "1. ",
    /// "(a) ") keep their own line and the file markers ("--- LICENSE") become plain headings.
    var reflowed: String {
        text.split(separator: /\n[ \t]*\n/).map { (para: Substring) -> String in
            var out = ""
            for raw in para.split(separator: "\n") {
                var line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line.hasPrefix("--- ") { line.removeFirst(4) }
                if !out.isEmpty { out += line.firstMatch(of: /^(\*|-|•|\d+\.|\([a-z0-9]{1,3}\))\s/) != nil ? "\n" : " " }
                out += line
            }
            return out
        }.joined(separator: "\n\n")
    }

    /// The main components; the notices list every module with its full license text.
    static let mainComponents: [(name: String, license: String, owner: String)] = [
        ("Tailscale (tsnet)", "BSD-3-Clause", "Tailscale Inc & contributors"),
        ("wireguard-go", "MIT", "WireGuard LLC"),
        ("gVisor", "Apache-2.0", "The gVisor Authors"),
        ("Go, golang.org/x", "BSD-3-Clause", "The Go Authors"),
    ]

    /// The file is a header, then per component a title between two "====" rules followed by its license files.
    static func load(bundle: Bundle = .main) -> [OpenSourceNotice] {
        guard let url = bundle.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var segments: [[Substring]] = [[]]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.count >= 20, line.allSatisfy({ $0 == "=" }) { segments.append([]) } else { segments[segments.count - 1].append(line) }
        }
        var out: [OpenSourceNotice] = []
        var i = 1
        while i + 1 < segments.count {
            let title = segments[i].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let body = segments[i + 1].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { out.append(OpenSourceNotice(id: title, text: body)) }
            i += 2
        }
        return out
    }
}
