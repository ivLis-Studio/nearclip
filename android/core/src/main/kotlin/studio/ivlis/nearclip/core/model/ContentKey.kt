package studio.ivlis.nearclip.core.model

import studio.ivlis.nearclip.core.crypto.Crypto
import studio.ivlis.nearclip.core.crypto.Hex
import java.text.Normalizer

/**
 * What a clip holds, so that the same thing put on the clipboard again is not taken for a new copy (DESIGN §4.3): Link to
 * Windows putting back the text Nearclip just wrote, an app setting the same clip twice. Text compares with line endings,
 * Unicode composition and trailing whitespace evened out; an image by its file's SHA-256. Keys are only compared on the
 * device that made them.
 */
object ContentKey {
    /** Line endings as `\n`, composed Unicode (NFC), no trailing spaces, tabs or line breaks. */
    fun normalizeText(text: String): String {
        var s = if (text.indexOf('\r') >= 0) text.replace("\r\n", "\n").replace('\r', '\n') else text
        if (!Normalizer.isNormalized(s, Normalizer.Form.NFC)) s = Normalizer.normalize(s, Normalizer.Form.NFC)
        var end = s.length
        while (end > 0 && s[end - 1].let { it == ' ' || it == '\t' || it == '\n' || it == '\u000B' || it == '\u000C' }) end--
        return s.substring(0, end)
    }

    fun text(text: String): String = "t:" + Hex.encode(Crypto.sha256(normalizeText(text).toByteArray(Charsets.UTF_8)))

    /** An image file, from its bytes. */
    fun file(bytes: ByteArray): String = "f:" + Hex.encode(Crypto.sha256(bytes))

    /** A clip in history: its text, or its image file's SHA-256 (null when neither is known). */
    fun of(clip: Clip): String? = when {
        clip.isText -> text(clip.text ?: "")
        !clip.sha.isNullOrEmpty() -> "f:" + clip.sha.lowercase()
        else -> null
    }
}
