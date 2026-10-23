package studio.ivlis.nearclip.ui.pairing

import android.Manifest
import android.content.pm.PackageManager
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size as GSize
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import kotlinx.coroutines.delay
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.pairing.PairingUri
import studio.ivlis.nearclip.ui.components.Sym
import java.util.concurrent.Executors

/** Full-screen QR scanner (CameraX preview + ZXing on the luminance plane). */
@Composable
fun ScanScreen(onBack: () -> Unit, onScanned: (PairingUri) -> Unit) {
    val context = LocalContext.current
    var granted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    var asked by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        granted = it
        asked = true
    }
    LaunchedEffect(Unit) { if (!granted) launcher.launch(Manifest.permission.CAMERA) }
    var torch by remember { mutableStateOf(false) }
    var camera by remember { mutableStateOf<Camera?>(null) }
    var notNearclip by remember { mutableStateOf(false) }
    var done by remember { mutableStateOf(false) }
    val haptic = LocalHapticFeedback.current
    LaunchedEffect(notNearclip) {
        if (notNearclip) {
            delay(2_500)
            notNearclip = false
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        if (granted) {
            CameraPreview(
                onCamera = { camera = it },
                onText = { text ->
                    if (done) return@CameraPreview
                    val uri = PairingUri.parse(text)
                    if (uri != null) {
                        done = true
                        haptic.performHapticFeedback(HapticFeedbackType.Confirm)
                        onScanned(uri)
                    } else {
                        notNearclip = true
                    }
                },
            )
            Viewfinder()
        } else {
            Column(
                Modifier
                    .align(Alignment.Center)
                    .padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Sym(R.drawable.ic_photo_camera, null, Modifier.size(48.dp), tint = Color.White)
                Spacer(Modifier.height(16.dp))
                Text(stringResource(R.string.camera_permission_title), style = MaterialTheme.typography.titleLarge, color = Color.White)
                Spacer(Modifier.height(8.dp))
                Text(
                    stringResource(R.string.camera_permission_body),
                    style = MaterialTheme.typography.bodyMedium,
                    color = Color.White.copy(alpha = 0.8f),
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(20.dp))
                Button(onClick = {
                    if (asked) {
                        context.startActivity(
                            android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(android.net.Uri.fromParts("package", context.packageName, null)),
                        )
                    } else {
                        launcher.launch(Manifest.permission.CAMERA)
                    }
                }) { Text(stringResource(R.string.camera_permission_button)) }
            }
        }

        Row(
            Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            IconButton(
                onClick = onBack,
                colors = IconButtonDefaults.iconButtonColors(containerColor = Color.Black.copy(alpha = 0.35f), contentColor = Color.White),
            ) { Sym(R.drawable.ic_arrow_back, stringResource(R.string.back)) }
            if (granted && camera?.cameraInfo?.hasFlashUnit() == true) {
                IconButton(
                    onClick = {
                        torch = !torch
                        camera?.cameraControl?.enableTorch(torch)
                    },
                    colors = IconButtonDefaults.iconButtonColors(containerColor = Color.Black.copy(alpha = 0.35f), contentColor = Color.White),
                ) {
                    Sym(
                        if (torch) R.drawable.ic_flashlight_off else R.drawable.ic_flashlight_on,
                        stringResource(if (torch) R.string.torch_off else R.string.torch_on),
                    )
                }
            }
        }

        Column(
            Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(start = 32.dp, end = 32.dp, bottom = 40.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(stringResource(R.string.scan_title), style = MaterialTheme.typography.titleLarge, color = Color.White)
            Spacer(Modifier.height(6.dp))
            Text(
                stringResource(R.string.scan_hint),
                style = MaterialTheme.typography.bodyMedium,
                color = Color.White.copy(alpha = 0.85f),
                textAlign = TextAlign.Center,
            )
            if (notNearclip) {
                Spacer(Modifier.height(16.dp))
                Surface(color = MaterialTheme.colorScheme.inverseSurface, shape = CircleShape) {
                    Text(
                        stringResource(R.string.scan_not_nearclip),
                        color = MaterialTheme.colorScheme.inverseOnSurface,
                        style = MaterialTheme.typography.labelLarge,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun Viewfinder() {
    Canvas(
        Modifier
            .fillMaxSize()
            .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen),
    ) {
        val side = minOf(size.width, size.height) * 0.68f
        val left = (size.width - side) / 2
        val top = (size.height - side) / 2.3f
        val r = 28.dp.toPx()
        drawRect(Color.Black.copy(alpha = 0.55f))
        drawRoundRect(Color.Transparent, Offset(left, top), GSize(side, side), CornerRadius(r), blendMode = BlendMode.Clear)
        val stroke = Stroke(width = 4.dp.toPx(), cap = StrokeCap.Round)
        val arm = side * 0.16f
        val corners = listOf(Offset(left, top), Offset(left + side, top), Offset(left, top + side), Offset(left + side, top + side))
        for ((i, c) in corners.withIndex()) {
            val sx = if (i % 2 == 0) 1f else -1f
            val sy = if (i < 2) 1f else -1f
            val path = androidx.compose.ui.graphics.Path().apply {
                moveTo(c.x, c.y + sy * arm)
                lineTo(c.x, c.y + sy * r)
                quadraticTo(c.x, c.y, c.x + sx * r, c.y)
                lineTo(c.x + sx * arm, c.y)
            }
            drawPath(path, Color.White, style = stroke)
        }
    }
}

@Composable
private fun CameraPreview(onCamera: (Camera) -> Unit, onText: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val previewView = remember { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } }
    val main = remember { ContextCompat.getMainExecutor(context) }
    DisposableEffect(lifecycleOwner) {
        val executor = Executors.newSingleThreadExecutor()
        val future = ProcessCameraProvider.getInstance(context)
        var provider: ProcessCameraProvider? = null
        future.addListener({
            val p = try { future.get() } catch (_: Exception) { return@addListener }
            provider = p
            val preview = Preview.Builder().build()
            preview.setSurfaceProvider(previewView.surfaceProvider)
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setResolutionSelector(
                    ResolutionSelector.Builder()
                        .setResolutionStrategy(ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER))
                        .build(),
                )
                .build()
            analysis.setAnalyzer(executor, QrAnalyzer { text -> main.execute { onText(text) } })
            val selector = when {
                p.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA) -> CameraSelector.DEFAULT_BACK_CAMERA
                p.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA) -> CameraSelector.DEFAULT_FRONT_CAMERA
                else -> return@addListener
            }
            try {
                p.unbindAll()
                onCamera(p.bindToLifecycle(lifecycleOwner, selector, preview, analysis))
            } catch (_: Exception) {
            }
        }, main)
        onDispose {
            provider?.unbindAll()
            executor.shutdown()
        }
    }
    AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
}

private class QrAnalyzer(private val onText: (String) -> Unit) : ImageAnalysis.Analyzer {
    private val reader = QRCodeReader()
    private val hints = mapOf(
        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
        DecodeHintType.TRY_HARDER to true,
    )
    private var lastText: String? = null
    private var lastAt = 0L

    override fun analyze(image: ImageProxy) {
        try {
            val plane = image.planes[0]
            val buffer = plane.buffer
            val rowStride = plane.rowStride
            val height = image.height
            val width = image.width
            val data = ByteArray(maxOf(buffer.remaining(), rowStride * height))
            buffer.get(data, 0, buffer.remaining())
            val source = PlanarYUVLuminanceSource(data, rowStride, height, 0, 0, width, height, false)
            val text = try {
                reader.decode(BinaryBitmap(HybridBinarizer(source)), hints).text
            } catch (_: Exception) {
                null
            } finally {
                reader.reset()
            }
            if (text != null) {
                val now = System.currentTimeMillis()
                if (text != lastText || now - lastAt > 1_500) {
                    lastText = text
                    lastAt = now
                    onText(text)
                }
            }
        } finally {
            image.close()
        }
    }
}
