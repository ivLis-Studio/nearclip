package studio.ivlis.nearclip.core

import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.core.model.ClipKind
import studio.ivlis.nearclip.core.model.ContentKey
import java.text.Normalizer
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The same thing copied again is recognised as the same thing (DESIGN §4.3). */
class ContentKeyTest {
    @Test
    fun textIgnoresLineEndingsCompositionAndTrailingWhitespace() {
        val key = ContentKey.text("첫 줄\n둘째 줄")
        assertEquals(key, ContentKey.text("첫 줄\r\n둘째 줄"))
        assertEquals(key, ContentKey.text("첫 줄\r둘째 줄"))
        assertEquals(key, ContentKey.text("첫 줄\n둘째 줄\r\n"))
        assertEquals(key, ContentKey.text("첫 줄\n둘째 줄 \t "))
        // Decomposed Hangul (as macOS file names carry it) is the same text.
        assertEquals(key, ContentKey.text(Normalizer.normalize("첫 줄\n둘째 줄", Normalizer.Form.NFD)))
        assertTrue(key.startsWith("t:"))
    }

    @Test
    fun differentTextStaysDifferent() {
        assertNotEquals(ContentKey.text("hello"), ContentKey.text("Hello"))
        assertNotEquals(ContentKey.text("hello"), ContentKey.text(" hello"))
        assertNotEquals(ContentKey.text("a\nb"), ContentKey.text("a\n\nb"))
        assertNotEquals(ContentKey.text("1234"), ContentKey.text("12345"))
    }

    /** The same keys as the Apple and Windows apps compute (not required, but easy to keep). */
    @Test
    fun sameKeysAsTheOtherApps() {
        assertEquals("t:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", ContentKey.text("hello\r\n"))
        assertEquals("f:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", ContentKey.file("abc".toByteArray()))
    }

    @Test
    fun clipsFromHistory() {
        val text = Clip(id = "id", ts = 1, src = "src", kind = ClipKind.TEXT, text = "a\r\nb", groupId = "g")
        assertEquals(ContentKey.text("a\nb"), ContentKey.of(text))
        val image = Clip(id = "id", ts = 1, src = "src", kind = ClipKind.IMAGE, mime = "image/png", size = 3, sha = "ABCDEF", groupId = "g")
        assertEquals("f:abcdef", ContentKey.of(image))
        assertNull(ContentKey.of(image.copy(sha = null)))
    }
}
