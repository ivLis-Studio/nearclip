import Foundation

enum Wire {
    static let maxFrame = 17_825_792
    static let chunkSize = 1_048_576
    static let maxText = 4 * 1_048_576
    static let maxImage = 32 * 1_048_576
    static let maxCatchUpImage = 16 * 1_048_576
    static let typeJSON: UInt8 = 0x01
    static let typeChunk: UInt8 = 0x02
    static let serviceType = "_nearclip._tcp"
    static let defaultPort: UInt16 = 45821

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    static let decoder = JSONDecoder()

    static func jsonBytes(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    static func type(of json: Data) -> String? {
        struct T: Decodable { let t: String }
        return try? decoder.decode(T.self, from: json).t
    }
}

struct IdTs: Codable, Hashable { var id: String; var ts: Int64 }
struct GroupWire: Codable { var id: String; var key: String }

struct WelcomeMsg: Codable { var t = "welcome"; var device: MemberRecord; var members: [MemberRecord]?; var addrs: [Endpoint]? }
struct ByeMsg: Codable { var t = "bye"; var reason: String? }
struct ErrorMsg: Codable { var t = "error"; var code: String?; var msg: String? }
struct ClipMsg: Codable { var t = "clip"; var live: Bool?; var clip: Clip }
struct InvMsg: Codable { var t = "inv"; var clips: [IdTs]?; var dels: [IdTs]? }
struct WantMsg: Codable { var t = "want"; var ids: [String]? }
struct DelMsg: Codable { var t = "del"; var items: [IdTs]? }
struct MembersMsg: Codable { var t = "members"; var members: [MemberRecord]? }
struct PairRequestMsg: Codable { var t = "pair_request"; var device: MemberRecord }
struct PairAcceptMsg: Codable { var t = "pair_accept"; var group: GroupWire; var device: MemberRecord; var members: [MemberRecord]? }
struct SimpleMsg: Codable { var t: String }

