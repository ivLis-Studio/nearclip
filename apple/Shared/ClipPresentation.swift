import Foundation
import NearclipKit
import SwiftUI

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, text, links, images, pinned
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .links: return "Links"
        case .images: return "Images"
        case .pinned: return "Pinned"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.stack"
        case .text: return "text.alignleft"
        case .links: return "link"
        case .images: return "photo"
        case .pinned: return "pin"
        }
    }
}

/// What a clip looks like to a person.
enum ClipContent: Equatable {
    case text(String)
    case link(URL)
    case color(String)
    case image

    static func of(_ clip: Clip) -> ClipContent {
        guard clip.isText, let raw = clip.text else { return .image }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: "^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$", options: .regularExpression) != nil {
            return .color(t)
        }
        if t.count < 2048, !t.contains(where: { $0.isWhitespace }), let url = Self.link(t) { return .link(url) }
        return .text(raw)
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func link(_ s: String) -> URL? {
        if let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host != nil { return u }
        let ns = s as NSString
        guard let m = detector?.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.range.length == ns.length, let u = m.url, u.scheme?.hasPrefix("http") == true else { return nil }
        return u
    }

    var isLink: Bool { if case .link = self { return true } else { return false } }
}

struct ClipItem: Identifiable, Hashable {
    var clip: StoredClip
    /// Every history entry with the same content (newest first); deleting the item deletes them all.
    var ids: [String]
    var pinned: Bool
    var id: String { clip.id }
}

enum Brand {
    static let iris = Color("Iris")
    static let online = Color(red: 0x2F / 255, green: 0xBF / 255, blue: 0x71 / 255)
    static let warning = Color(red: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255)
}

enum DeviceStyle {
    static func symbol(platform: String, model: String?) -> String {
        switch platform {
        case "mac":
            if let m = model, m.hasPrefix("MacBook") { return "laptopcomputer" }
            return model == nil ? "laptopcomputer" : "desktopcomputer"
        case "win": return "pc"
        case "android": return "smartphone"
        case "ios": return (model ?? "").hasPrefix("iPad") ? "ipad" : "iphone"
        default: return "terminal"
        }
    }

    static func platformName(_ platform: String, model: String?) -> String {
        switch platform {
        case "mac": return "Mac"
        case "win": return "Windows PC"
        case "android": return "Android"
        case "ios": return (model ?? "").hasPrefix("iPad") ? "iPad" : "iPhone"
        default: return "Nearclip CLI"
        }
    }
}

enum Format {
    static func relative(_ ms: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let delta = now.timeIntervalSince(date)
        if delta < 45 { return String(localized: "Just now") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.dateTimeStyle = .named
        return f.localizedString(for: date, relativeTo: now)
    }

    static func lastSeen(_ ms: Int64?) -> String {
        guard let ms, ms > 0 else { return String(localized: "Not nearby") }
        return String(localized: "Last seen \(relative(ms))")
    }

    static func daySection(_ ms: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "Today") }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    /// First lines of a text, whitespace-trimmed, for a two-line preview.
    static func preview(_ text: String, maxLines: Int = 3) -> String {
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .prefix(maxLines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let joined = lines.joined(separator: "\n")
        return joined.count > 400 ? String(joined.prefix(400)) + "…" : joined
    }

    static func colorFromHex(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 6 {
            r = Double((v >> 16) & 0xff) / 255; g = Double((v >> 8) & 0xff) / 255; b = Double(v & 0xff) / 255; a = 1
        } else {
            r = Double((v >> 24) & 0xff) / 255; g = Double((v >> 16) & 0xff) / 255; b = Double((v >> 8) & 0xff) / 255; a = Double(v & 0xff) / 255
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    static func groupedCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }
}

