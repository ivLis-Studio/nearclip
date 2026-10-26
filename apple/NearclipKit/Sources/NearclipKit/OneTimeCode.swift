import Foundation

/// Finds the verification code (4–8 digits) in a message such as "[네이버] 인증번호 [123456]를 입력해주세요" (PROTOCOL.md §6.7).
///
/// A message needs a word that says it carries a code (인증, 코드, verification, OTP, …); the code is the 4–8 digit
/// number nearest to that word, preferring one set off by brackets, a colon or "is". Phone numbers, dates, times,
/// amounts and longer numbers are never taken for a code. spec/otp-vectors.json holds the cases the Apple and Android
/// apps agree on.
public enum OneTimeCode {
    private static let korean = ["인증", "확인번호", "확인 번호", "확인코드", "보안코드", "보안 코드", "일회용", "본인확인", "코드"]
    private static let english = ["code", "codes", "verification", "verify", "otp", "passcode", "one-time", "one time", "2fa",
                                  "pin", "authentication"]
    private static let units = Set("원년월일시분초개건명%".unicodeScalars)
    private static let currency = Set("₩$€£¥".unicodeScalars)
    private static let joiners = Set("-./:,".unicodeScalars)
    private static let open = Set("[(:<「".unicodeScalars)
    private static let close = Set("])>」".unicodeScalars)
    /// How far (in characters) a code may be from the word that announces it.
    private static let reach = 60

    private struct Candidate { var start: Int; var end: Int; var digits: String }

    public static func find(in message: String) -> String? {
        let text = Array(message.precomposedStringWithCompatibilityMapping.unicodeScalars)
        let lower = text.map { isUpper($0) ? Unicode.Scalar($0.value + 32)! : $0 }
        let keys = keywords(lower)
        guard !keys.isEmpty else { return nil }
        var best: Candidate?
        var bestScore = Int.max
        for c in candidates(text) {
            var distance = Int.max
            for (ks, ke) in keys {
                let d: Int
                if c.start >= ke { d = c.start - ke } else if c.end <= ks { d = ks - c.end + 12 } else { d = 0 }
                distance = min(distance, d)
            }
            guard distance <= reach else { continue }
            let score = framed(text, lower, c) ? distance - 25 : distance
            if score < bestScore {
                bestScore = score
                best = c
            }
        }
        return best?.digits
    }

    private static func occurrences(of word: String, in s: [Unicode.Scalar]) -> [Int] {
        let w = Array(word.unicodeScalars)
        guard !w.isEmpty, s.count >= w.count else { return [] }
        var out: [Int] = []
        for i in 0...(s.count - w.count) where s[i] == w[0] && Array(s[i..<(i + w.count)]) == w { out.append(i) }
        return out
    }

    private static func keywords(_ lower: [Unicode.Scalar]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for k in korean {
            let n = k.unicodeScalars.count
            for i in occurrences(of: k, in: lower) { out.append((i, i + n)) }
        }
        for k in english {
            let n = k.unicodeScalars.count
            for i in occurrences(of: k, in: lower) {
                let before: Unicode.Scalar = i > 0 ? lower[i - 1] : " "
                let after: Unicode.Scalar = i + n < lower.count ? lower[i + n] : " "
                if !isLetter(before), !isDigit(before), !isLetter(after) { out.append((i, i + n)) }
            }
        }
        return out
    }

    private static func candidates(_ t: [Unicode.Scalar]) -> [Candidate] {
        var runs: [(Int, Int)] = []
        var i = 0
        while i < t.count {
            guard isDigit(t[i]) else { i += 1; continue }
            var j = i
            while j < t.count, isDigit(t[j]) { j += 1 }
            runs.append((i, j))
            i = j
        }
        func digits(_ a: Int, _ b: Int) -> String { String(String.UnicodeScalarView(t[a..<b])) }
        var out: [Candidate] = []
        for (n, r) in runs.enumerated() {
            let length = r.1 - r.0
            if (4...8).contains(length), clearBefore(t, r.0), clearAfter(t, r.1) {
                out.append(Candidate(start: r.0, end: r.1, digits: digits(r.0, r.1)))
            }
            // "123 456" and "123-456" are one code.
            if length == 3, n + 1 < runs.count {
                let s = runs[n + 1]
                if s.1 - s.0 == 3, s.0 == r.1 + 1, t[r.1] == " " || t[r.1] == "-", clearBefore(t, r.0), clearAfter(t, s.1) {
                    out.append(Candidate(start: r.0, end: s.1, digits: digits(r.0, r.1) + digits(s.0, s.1)))
                }
            }
        }
        return out
    }

    /// Not the middle of a word, an amount, a phone number, a date or a time.
    private static func clearBefore(_ t: [Unicode.Scalar], _ start: Int) -> Bool {
        guard start > 0 else { return true }
        let c = t[start - 1]
        if isLetter(c) || currency.contains(c) { return false }
        return !(joiners.contains(c) && start >= 2 && isDigit(t[start - 2]))
    }

    private static func clearAfter(_ t: [Unicode.Scalar], _ end: Int) -> Bool {
        guard end < t.count else { return true }
        let c = t[end]
        if isLetter(c) || units.contains(c) { return false }
        return !(joiners.contains(c) && end + 1 < t.count && isDigit(t[end + 1]))
    }

    /// Set off as a code: "[123456]", "(1234)", "code: 1234", "is 1234".
    private static func framed(_ t: [Unicode.Scalar], _ lower: [Unicode.Scalar], _ c: Candidate) -> Bool {
        var i = c.start - 1
        while i >= 0, t[i] == " " { i -= 1 }
        if i >= 0, open.contains(t[i]) { return true }
        if i >= 1, lower[i] == "s", lower[i - 1] == "i", i < 2 || !isLetter(lower[i - 2]) { return true }
        var j = c.end
        while j < t.count, t[j] == " " { j += 1 }
        return j < t.count && close.contains(t[j])
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }
    private static func isUpper(_ c: Unicode.Scalar) -> Bool { c.value >= 65 && c.value <= 90 }
    private static func isLetter(_ c: Unicode.Scalar) -> Bool { isUpper(c) || (c.value >= 97 && c.value <= 122) }
}
