package studio.ivlis.nearclip.core.model

import java.text.Normalizer

/**
 * Finds the verification code (4–8 digits) in a message such as "[네이버] 인증번호 [123456]를 입력해주세요" (PROTOCOL §6.7).
 *
 * A message needs a word that says it carries a code (인증, 코드, verification, OTP, …); the code is the 4–8 digit number
 * nearest to that word, preferring one set off by brackets, a colon or "is". Phone numbers, dates, times, amounts and
 * longer numbers are never taken for a code. spec/otp-vectors.json holds the cases the Android and Apple apps agree on.
 */
object OneTimeCode {
    private val KOREAN = listOf("인증", "확인번호", "확인 번호", "확인코드", "보안코드", "보안 코드", "일회용", "본인확인", "코드")
    private val ENGLISH = listOf(
        "code", "codes", "verification", "verify", "otp", "passcode", "one-time", "one time", "2fa", "pin", "authentication",
    )
    private const val UNITS = "원년월일시분초개건명%"
    private const val CURRENCY = "₩$€£¥"
    private const val JOINERS = "-./:,"
    private const val OPEN = "[(:<「"
    private const val CLOSE = "])>」"

    /** How far (in characters) a code may be from the word that announces it. */
    private const val REACH = 60

    private class Candidate(val start: Int, val end: Int, val digits: String)

    fun find(message: String): String? {
        val text = Normalizer.normalize(message, Normalizer.Form.NFKC)
        val lower = buildString(text.length) { for (c in text) append(if (c in 'A'..'Z') c + 32 else c) }
        val keys = keywords(lower)
        if (keys.isEmpty()) return null
        var best: Candidate? = null
        var bestScore = Int.MAX_VALUE
        for (c in candidates(text)) {
            var distance = Int.MAX_VALUE
            for ((ks, ke) in keys) {
                val d = when {
                    c.start >= ke -> c.start - ke
                    c.end <= ks -> ks - c.end + 12
                    else -> 0
                }
                if (d < distance) distance = d
            }
            if (distance > REACH) continue
            val score = if (framed(text, lower, c)) distance - 25 else distance
            if (score < bestScore) {
                bestScore = score
                best = c
            }
        }
        return best?.digits
    }

    private fun keywords(lower: String): List<Pair<Int, Int>> {
        val out = ArrayList<Pair<Int, Int>>()
        for (k in KOREAN) {
            var i = lower.indexOf(k)
            while (i >= 0) {
                out.add(i to i + k.length)
                i = lower.indexOf(k, i + 1)
            }
        }
        for (k in ENGLISH) {
            var i = lower.indexOf(k)
            while (i >= 0) {
                val before = if (i > 0) lower[i - 1] else ' '
                val after = if (i + k.length < lower.length) lower[i + k.length] else ' '
                if (!before.isAsciiLetter() && !before.isAsciiDigit() && !after.isAsciiLetter()) out.add(i to i + k.length)
                i = lower.indexOf(k, i + 1)
            }
        }
        return out
    }

    private fun candidates(text: String): List<Candidate> {
        val runs = ArrayList<IntArray>()
        var i = 0
        while (i < text.length) {
            if (!text[i].isAsciiDigit()) {
                i++
                continue
            }
            var j = i
            while (j < text.length && text[j].isAsciiDigit()) j++
            runs.add(intArrayOf(i, j))
            i = j
        }
        val out = ArrayList<Candidate>()
        for ((n, r) in runs.withIndex()) {
            val length = r[1] - r[0]
            if (length in 4..8 && clearBefore(text, r[0]) && clearAfter(text, r[1])) {
                out.add(Candidate(r[0], r[1], text.substring(r[0], r[1])))
            }
            // "123 456" and "123-456" are one code.
            if (length == 3 && n + 1 < runs.size) {
                val s = runs[n + 1]
                if (s[1] - s[0] == 3 && s[0] == r[1] + 1 && (text[r[1]] == ' ' || text[r[1]] == '-') &&
                    clearBefore(text, r[0]) && clearAfter(text, s[1])
                ) {
                    out.add(Candidate(r[0], s[1], text.substring(r[0], r[1]) + text.substring(s[0], s[1])))
                }
            }
        }
        return out
    }

    /** Not the middle of a word, an amount, a phone number, a date or a time. */
    private fun clearBefore(t: String, start: Int): Boolean {
        if (start == 0) return true
        val c = t[start - 1]
        if (c.isAsciiLetter() || c in CURRENCY) return false
        return !(c in JOINERS && start >= 2 && t[start - 2].isAsciiDigit())
    }

    private fun clearAfter(t: String, end: Int): Boolean {
        if (end >= t.length) return true
        val c = t[end]
        if (c.isAsciiLetter() || c in UNITS) return false
        return !(c in JOINERS && end + 1 < t.length && t[end + 1].isAsciiDigit())
    }

    /** Set off as a code: "[123456]", "(1234)", "code: 1234", "is 1234". */
    private fun framed(text: String, lower: String, c: Candidate): Boolean {
        var i = c.start - 1
        while (i >= 0 && text[i] == ' ') i--
        if (i >= 0 && text[i] in OPEN) return true
        if (i >= 1 && lower[i] == 's' && lower[i - 1] == 'i' && (i < 2 || !lower[i - 2].isAsciiLetter())) return true
        var j = c.end
        while (j < text.length && text[j] == ' ') j++
        return j < text.length && text[j] in CLOSE
    }

    private fun Char.isAsciiDigit() = this in '0'..'9'

    private fun Char.isAsciiLetter() = this in 'a'..'z' || this in 'A'..'Z'
}
