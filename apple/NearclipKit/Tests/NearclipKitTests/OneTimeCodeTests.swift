import XCTest
@testable import NearclipKit

/// Every case in spec/otp-vectors.json (the Android app checks the same file).
final class OneTimeCodeTests: XCTestCase {
    func testVectors() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spec/otp-vectors.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 40)
        var failures: [String] = []
        for c in cases {
            let text = c["text"] as! String
            let want = c["code"] as? String
            let got = OneTimeCode.find(in: text)
            if got != want { failures.append("\(c["note"] ?? ""): want \(want ?? "nil"), got \(got ?? "nil")") }
        }
        XCTAssertEqual(failures, [])
    }
}
