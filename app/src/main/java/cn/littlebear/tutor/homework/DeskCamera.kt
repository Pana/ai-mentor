package cn.littlebear.tutor.homework

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbManager
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Size
import android.view.Surface
import android.view.TextureView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

// ---------- USB desk camera ----------
//
// A UVC camera on a stand points at the homework, so the child takes a photo with one tap on the screen instead of
// lifting the tablet. Android only offers such a camera to apps when the tablet's system ships the external camera
// HAL (Camera2 then lists it as LENS_FACING_EXTERNAL); many tablets do not. A USB video device that Camera2 does not
// list is reported as [DeskCameraAvailability.Unsupported], so the screen can say so instead of silently ignoring it.

sealed interface DeskCameraAvailability {
    data object None : DeskCameraAvailability
    data class Ready(val cameraId: String) : DeskCameraAvailability
    data object Unsupported : DeskCameraAvailability
}

object DeskCameras {
    private const val ROTATION = "external.rotation"
    private fun prefs(context: Context) = context.getSharedPreferences("phase1.camera", Context.MODE_PRIVATE)

    fun availability(context: Context): DeskCameraAvailability {
        externalCameraId(context)?.let { return DeskCameraAvailability.Ready(it) }
        return if (usbVideoAttached(context)) DeskCameraAvailability.Unsupported else DeskCameraAvailability.None
    }

    fun externalCameraId(context: Context): String? = try {
        val manager = context.getSystemService(CameraManager::class.java)
        manager?.cameraIdList?.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraMetadata.LENS_FACING_EXTERNAL }
    } catch (_: Exception) { null }

    /** A plugged-in USB device with a video interface (UVC cameras often report the composite class 0xEF). */
    fun usbVideoAttached(context: Context): Boolean = try {
        context.getSystemService(UsbManager::class.java)?.deviceList?.values?.any { device ->
            device.deviceClass == UsbConstants.USB_CLASS_VIDEO || (0 until device.interfaceCount).any { device.getInterface(it).interfaceClass == UsbConstants.USB_CLASS_VIDEO }
        } == true
    } catch (_: Exception) { false }

    /** Clockwise quarter turns, in degrees, that make the camera's picture upright on screen; the child sets it once. */
    fun rotation(context: Context): Int = normalized(prefs(context).getInt(ROTATION, 0))
    fun turn(context: Context): Int = normalized(rotation(context) + 90).also { prefs(context).edit().putInt(ROTATION, it).apply() }
    fun normalized(degrees: Int): Int = ((degrees / 90 % 4) + 4) % 4 * 90

    /** One size both the preview and the photo can use, so the camera decodes each frame once. Pages are kept at
     * 1400 px, so about 1080p is plenty; falls back to the smallest size when every size is larger. */
    fun chooseSize(preview: List<Size>, jpeg: List<Size>, maxSide: Int = 1920): Size? {
        val shared = preview.filter { p -> jpeg.any { it.width == p.width && it.height == p.height } }
        val pool = shared.ifEmpty { preview }
        return pool.filter { maxOf(it.width, it.height) <= maxSide }.maxByOrNull { it.width.toLong() * it.height }
            ?: pool.minByOrNull { it.width.toLong() * it.height }
    }

    /**
     * Matrix for a [TextureView] of [viewWidth]×[viewHeight] showing a [buffer] turned [degrees] clockwise, fitted
     * inside the view without stretching (the view stretches the buffer to its own size by default).
     */
    fun previewTransform(viewWidth: Float, viewHeight: Float, buffer: Size, degrees: Int): Matrix {
        val cx = viewWidth / 2; val cy = viewHeight / 2
        val turned = degrees % 180 != 0
        val contentW = if (turned) buffer.height.toFloat() else buffer.width.toFloat()
        val contentH = if (turned) buffer.width.toFloat() else buffer.height.toFloat()
        val scale = minOf(viewWidth / contentW, viewHeight / contentH)
        return Matrix().apply {
            setScale(buffer.width / viewWidth, buffer.height / viewHeight, cx, cy)
            postRotate(degrees.toFloat(), cx, cy)
            postScale(scale, scale, cx, cy)
        }
    }
}

/** Whether a USB desk camera is plugged in, kept current while the screen shows (plugging in or out updates it). */
@Composable fun rememberDeskCamera(): DeskCameraAvailability {
    val context = LocalContext.current
    var state by remember { mutableStateOf(DeskCameras.availability(context)) }
    DisposableEffect(Unit) {
        val main = Handler(Looper.getMainLooper())
        val refresh = Runnable { state = DeskCameras.availability(context) }
        val manager = context.getSystemService(CameraManager::class.java)
        // Fires for cameras appearing and leaving, and also when a camera is opened or closed: the list is reread.
        val callback = object : CameraManager.AvailabilityCallback() {
            override fun onCameraAvailable(cameraId: String) = refresh.run()
            override fun onCameraUnavailable(cameraId: String) = refresh.run()
        }
        manager?.registerAvailabilityCallback(callback, main)
        // The camera service needs a moment after the USB device appears, so check again shortly after.
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) { refresh.run(); main.postDelayed(refresh, 1500) }
        }
        val filter = IntentFilter().apply { addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED); addAction(UsbManager.ACTION_USB_DEVICE_DETACHED) }
        ContextCompat.registerReceiver(context, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        onDispose {
            manager?.unregisterAvailabilityCallback(callback)
            context.unregisterReceiver(receiver)
            main.removeCallbacks(refresh)
        }
    }
    return state
}

/**
 * Declaring CAMERA (for the desk camera) means the system camera app may only be opened once CAMERA is granted, or
 * ACTION_IMAGE_CAPTURE / ACTION_VIDEO_CAPTURE throw. Returns a function that asks first when needed, then runs [action].
 */
@Composable fun rememberCameraGate(onDenied: () -> Unit): (action: () -> Unit) -> Unit {
    val context = LocalContext.current
    var pending by remember { mutableStateOf<(() -> Unit)?>(null) }
    val denied by rememberUpdatedState(onDenied)
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val action = pending
        pending = null
        if (granted) action?.invoke() else denied()
    }
    return { action ->
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) action()
        else { pending = action; launcher.launch(Manifest.permission.CAMERA) }
    }
}

private enum class DeskStatus { STARTING, RUNNING, FAILED }

/** One open USB camera: preview into a TextureView, still JPEGs on request. All camera work runs on its own thread. */
@SuppressLint("MissingPermission")
private class DeskCameraSession(context: Context, private val cameraId: String, private val onStatus: (DeskStatus) -> Unit) {
    private val manager = context.getSystemService(CameraManager::class.java)
    private val thread = HandlerThread("desk-camera").apply { start() }
    private val handler = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var surface: Surface? = null
    private var pending: ((ByteArray?) -> Unit)? = null
    private var closed = false
    val size: Size?

    init {
        size = try {
            val map = manager.getCameraCharacteristics(cameraId).get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            DeskCameras.chooseSize(map?.getOutputSizes(SurfaceTexture::class.java)?.toList().orEmpty(), map?.getOutputSizes(ImageFormat.JPEG)?.toList().orEmpty())
        } catch (_: Exception) { null }
    }

    private fun post(status: DeskStatus) = main.post { if (!closed) onStatus(status) }

    fun open(texture: SurfaceTexture) = handler.post {
        val size = size ?: run { post(DeskStatus.FAILED); return@post }
        texture.setDefaultBufferSize(size.width, size.height)
        val preview = Surface(texture).also { surface = it }
        val jpeg = ImageReader.newInstance(size.width, size.height, ImageFormat.JPEG, 2).also { reader = it }
        jpeg.setOnImageAvailableListener({ r ->
            val bytes = try { r.acquireLatestImage()?.use { image -> val buffer = image.planes[0].buffer; ByteArray(buffer.remaining()).also { buffer.get(it) } } } catch (_: Exception) { null }
            val done = pending; pending = null
            main.post { done?.invoke(bytes) }
        }, handler)
        try {
            manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    if (closed) { camera.close(); return }
                    device = camera
                    start(camera, preview, jpeg)
                }
                override fun onDisconnected(camera: CameraDevice) { camera.close(); device = null; post(DeskStatus.FAILED) }
                override fun onError(camera: CameraDevice, error: Int) { camera.close(); device = null; post(DeskStatus.FAILED) }
            }, handler)
        } catch (_: Exception) { post(DeskStatus.FAILED) }
    }

    @Suppress("DEPRECATION") // createCaptureSession(List) keeps API 26–27 working; SessionConfiguration needs 28.
    private fun start(camera: CameraDevice, preview: Surface, jpeg: ImageReader) {
        try {
            camera.createCaptureSession(listOf(preview, jpeg.surface), object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(s: CameraCaptureSession) {
                    if (closed) { s.close(); return }
                    session = s
                    try {
                        val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply { addTarget(preview) }.build()
                        s.setRepeatingRequest(request, null, handler)
                        post(DeskStatus.RUNNING)
                    } catch (_: Exception) { post(DeskStatus.FAILED) }
                }
                override fun onConfigureFailed(s: CameraCaptureSession) { post(DeskStatus.FAILED) }
            }, handler)
        } catch (_: Exception) { post(DeskStatus.FAILED) }
    }

    /** Takes one JPEG (no orientation applied); [done] runs on the main thread, with null when it failed. */
    fun capture(done: (ByteArray?) -> Unit) = handler.post {
        val camera = device; val s = session; val jpeg = reader
        if (camera == null || s == null || jpeg == null || pending != null) { main.post { done(null) }; return@post }
        pending = done
        try {
            val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                addTarget(jpeg.surface)
                surface?.let { addTarget(it) }
                set(CaptureRequest.JPEG_QUALITY, 92.toByte())
            }.build()
            s.capture(request, object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureFailed(session: CameraCaptureSession, request: CaptureRequest, failure: android.hardware.camera2.CaptureFailure) {
                    val d = pending; pending = null; main.post { d?.invoke(null) }
                }
            }, handler)
        } catch (_: Exception) { pending = null; main.post { done(null) } }
    }

    fun close() {
        closed = true
        handler.post {
            pending?.let { d -> main.post { d(null) } }
            pending = null
            runCatching { session?.close() }; runCatching { device?.close() }; runCatching { reader?.close() }; runCatching { surface?.release() }
            session = null; device = null; reader = null; surface = null
            thread.quitSafely()
        }
    }
}

/**
 * Live picture from the USB desk camera inside the page. A tap anywhere on it (or on the big button) takes the photo,
 * so the tablet can stay on its stand. [onPhoto] gets the JPEG and the clockwise turn that makes it upright.
 */
@Composable fun DeskCameraPanel(cameraId: String, buttonTitle: String, hint: String, modifier: Modifier = Modifier, onPhoto: (ByteArray, Int) -> Unit) {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var asked by remember { mutableStateOf(false) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it; asked = true }
    LaunchedEffect(Unit) { if (!granted) permission.launch(Manifest.permission.CAMERA) }
    // The camera is released while the app is in the background and opened again on return.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var started by remember { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, _ -> started = lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED) }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    var rotation by remember { mutableIntStateOf(DeskCameras.rotation(context)) }
    var status by remember(cameraId) { mutableStateOf(DeskStatus.STARTING) }
    var busy by remember { mutableStateOf(false) }
    var shots by remember { mutableIntStateOf(0) }
    val flash = remember { Animatable(0f) }
    LaunchedEffect(shots) { if (shots > 0) { flash.snapTo(0.75f); flash.animateTo(0f, tween(350)) } }
    var camera by remember { mutableStateOf<DeskCameraSession?>(null) }

    fun shoot() {
        val session = camera ?: return
        if (status != DeskStatus.RUNNING || busy) return
        busy = true; shots++
        val turn = rotation
        session.capture { bytes -> busy = false; if (bytes != null) onPhoto(bytes, turn) }
    }

    Box(modifier.clip(RoundedCornerShape(18.dp)).background(Color.Black)) {
        when {
            !granted -> Note("没有相机权限", if (asked) "请家长在系统设置里允许小熊伴学使用相机。" else "允许使用相机后就能看到画面。")
            status == DeskStatus.FAILED -> Box(Modifier.fillMaxSize().clickable { status = DeskStatus.STARTING }) {
                Note("外接摄像头暂时用不了", "点这里再试一次；还不行就拔下来重新插一下，或者用下面的按钮从相册选。")
            }
            !started -> {}
            else -> key(cameraId) {
                val session = remember { DeskCameraSession(context, cameraId) { status = it } }
                DisposableEffect(session) { camera = session; onDispose { session.close(); if (camera === session) camera = null } }
                AndroidView(factory = { ctx ->
                    TextureView(ctx).apply {
                        surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                            override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) { session.open(texture); fit(this@apply, session.size) }
                            override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) = fit(this@apply, session.size)
                            override fun onSurfaceTextureDestroyed(texture: SurfaceTexture) = true
                            override fun onSurfaceTextureUpdated(texture: SurfaceTexture) {}
                        }
                    }
                }, update = { view -> view.tag = rotation; fit(view, session.size) }, modifier = Modifier.fillMaxSize())
                // Taps go to this layer: the TextureView underneath does not handle touches.
                Box(Modifier.fillMaxSize().background(Color.White.copy(alpha = flash.value))
                    .semantics { contentDescription = "外接摄像头画面，点一下拍照" }
                    .clickable(role = Role.Button, onClick = ::shoot))
                Column(Modifier.fillMaxSize().padding(14.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("外接摄像头", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold,
                            modifier = Modifier.background(Color.Black.copy(alpha = 0.5f), CircleShape).padding(horizontal = 12.dp, vertical = 6.dp))
                        Spacer(Modifier.weight(1f))
                        Box(Modifier.size(56.dp).background(Color.Black.copy(alpha = 0.5f), CircleShape)
                            .semantics { contentDescription = "画面转一下" }
                            .clickable(role = Role.Button) { rotation = DeskCameras.turn(context) }, contentAlignment = Alignment.Center) {
                            Text("↻", color = Color.White, fontSize = 28.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                    Spacer(Modifier.weight(1f))
                    Text(hint, color = Color.White, fontSize = 15.sp, textAlign = TextAlign.Center,
                        modifier = Modifier.background(Color.Black.copy(alpha = 0.5f), CircleShape).padding(horizontal = 12.dp, vertical = 6.dp))
                    Spacer(Modifier.height(12.dp))
                    Box(Modifier.height(64.dp).background(if (status == DeskStatus.RUNNING && !busy) Color.White else Color.White.copy(alpha = 0.6f), CircleShape)
                        .clickable(enabled = status == DeskStatus.RUNNING && !busy, role = Role.Button, onClick = ::shoot)
                        .padding(horizontal = 28.dp), contentAlignment = Alignment.Center) {
                        Text(if (busy) "正在拍…" else "📷  $buttonTitle", color = Color.Black, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
    }
}

/** Fits the preview in the view, turned by the rotation kept in the view's tag (set on every recomposition). */
private fun fit(view: TextureView, size: Size?) {
    if (size == null || view.width == 0 || view.height == 0) return
    view.setTransform(DeskCameras.previewTransform(view.width.toFloat(), view.height.toFloat(), size, view.tag as? Int ?: 0))
}

@Composable private fun BoxScope.Note(title: String, detail: String) {
    Column(Modifier.align(Alignment.Center).padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("📷", fontSize = 40.sp)
        Text(title, color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
        Text(detail, color = Color.White, fontSize = 16.sp, textAlign = TextAlign.Center)
    }
}
