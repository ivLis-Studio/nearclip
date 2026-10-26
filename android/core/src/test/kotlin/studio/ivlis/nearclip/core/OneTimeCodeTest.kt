package studio.ivlis.nearclip.core

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import studio.ivlis.nearclip.core.model.OneTimeCode
import studio.ivlis.nearclip.core.proto.Wire
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Every case in spec/otp-vectors.json (the Apple app checks the same file). */
class OneTimeCodeTest {
    @Test
    fun vectors() {
        val path = System.getProperty("nearclip.otpVectors") ?: "../../spec/otp-vectors.json"
        val cases = Wire.parseObject("{\"cases\":" + File(path).readText() + "}")["cases"]!!.jsonArray
        assertTrue(cases.size >= 40)
        val failures = cases.mapNotNull { e ->
            val o = e as JsonObject
            val text = o["text"]!!.jsonPrimitive.content
            val want = o["code"].let { if (it == null || it is JsonNull) null else it.jsonPrimitive.content }
            val got = OneTimeCode.find(text)
            if (got == want) null else "${o["note"]!!.jsonPrimitive.content}: want $want, got $got"
        }
        assertEquals(emptyList(), failures)
    }
}
