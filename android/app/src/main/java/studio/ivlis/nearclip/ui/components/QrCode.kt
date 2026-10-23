package studio.ivlis.nearclip.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.vectorResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.google.zxing.qrcode.encoder.Encoder
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.ui.theme.Brand

/**
 * QR code as specified in DESIGN §4.2: Iris modules on white, rounded quiet zone, app glyph in the centre.
 * Error correction H keeps the code readable with the logo on top.
 */
@Composable
fun QrCode(content: String, description: String, modifier: Modifier = Modifier, moduleColor: Color = Brand.Iris) {
    val matrix = remember(content) {
        Encoder.encode(content, ErrorCorrectionLevel.H, mapOf(EncodeHintType.CHARACTER_SET to "UTF-8")).matrix
    }
    val glyph = rememberVectorPainter(ImageVector.vectorResource(R.drawable.ic_nearclip_glyph))
    Canvas(
        modifier
            .aspectRatio(1f)
            .semantics { contentDescription = description },
    ) {
        val n = matrix.width
        val quiet = 3
        val cell = size.width / (n + quiet * 2)
        drawRoundRect(Color.White, cornerRadius = CornerRadius(cell * 3.2f))
        val logoModules = (n * 0.24f).toInt().let { if (it % 2 == n % 2) it else it + 1 }
        val logoStart = (n - logoModules) / 2
        fun inFinder(x: Int, y: Int) = (x < 7 && y < 7) || (x >= n - 7 && y < 7) || (x < 7 && y >= n - 7)
        fun inLogo(x: Int, y: Int) = x >= logoStart - 1 && x < logoStart + logoModules + 1 && y >= logoStart - 1 && y < logoStart + logoModules + 1
        val inset = cell * 0.08f
        for (y in 0 until n) for (x in 0 until n) {
            if (matrix.get(x, y).toInt() != 1 || inFinder(x, y) || inLogo(x, y)) continue
            drawRoundRect(
                moduleColor,
                topLeft = Offset((x + quiet) * cell + inset, (y + quiet) * cell + inset),
                size = Size(cell - 2 * inset, cell - 2 * inset),
                cornerRadius = CornerRadius(cell * 0.32f),
            )
        }
        for ((fx, fy) in listOf(0 to 0, n - 7 to 0, 0 to n - 7)) {
            val ox = (fx + quiet) * cell
            val oy = (fy + quiet) * cell
            drawRoundRect(moduleColor, Offset(ox, oy), Size(7 * cell, 7 * cell), CornerRadius(cell * 2.2f))
            drawRoundRect(Color.White, Offset(ox + cell, oy + cell), Size(5 * cell, 5 * cell), CornerRadius(cell * 1.5f))
            drawRoundRect(moduleColor, Offset(ox + 2 * cell, oy + 2 * cell), Size(3 * cell, 3 * cell), CornerRadius(cell * 1.0f))
        }
        val logoSize = logoModules * cell
        val lx = (logoStart + quiet) * cell
        drawRoundRect(Brand.Iris, Offset(lx, lx), Size(logoSize, logoSize), CornerRadius(logoSize * 0.28f))
        translate(lx, lx) {
            with(glyph) { draw(Size(logoSize, logoSize)) }
        }
    }
}
