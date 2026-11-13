package cn.littlebear.tutor.homework

import android.app.KeyguardManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.compose.runtime.compositionLocalOf
import androidx.exifinterface.media.ExifInterface
import cn.littlebear.tutor.BuildConfig
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// ---------- Session: server and role in preferences, the device credential encrypted with an Android Keystore key ----------

class SecureSessionStorage(context: Context) : SessionStorage {
    private val prefs: SharedPreferences = context.getSharedPreferences("phase1.session", Context.MODE_PRIVATE)
    private val alias = "cn.littlebear.tutor.homework.device"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        return generator.generateKey()
    }

    override fun load(): DeviceSession? = try {
        val stored = prefs.getString("session", null)?.let { wireJson.decodeFromString(DeviceSession.serializer(), it) }
        val sealed = prefs.getString("token", null)
        if (stored == null || sealed == null) null else {
            val bytes = Base64.decode(sealed, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, 12))
            stored.copy(token = String(cipher.doFinal(bytes, 12, bytes.size - 12), Charsets.UTF_8))
        }
    } catch (_: Exception) { null }

    override fun save(session: DeviceSession) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(session.token.toByteArray(Charsets.UTF_8))
        check(prefs.edit().putString("session", wireJson.encodeToString(DeviceSession.serializer(), session.copy(token = "")))
            .putString("token", Base64.encodeToString(sealed, Base64.NO_WRAP)).commit()) { "保存登录信息失败" }
    }

    // Signing out must be on disk before the app can be killed, so this writes synchronously.
    @android.annotation.SuppressLint("ApplySharedPref")
    override fun clear() { prefs.edit().clear().commit() }
}

// ---------- One store per process ----------

object StoreHolder {
    @Volatile private var store: HomeworkStore? = null
    /** Store actions outlive the screen that started them (a submission keeps uploading after the child goes back). */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    fun get(context: Context): HomeworkStore = store ?: synchronized(this) {
        store ?: HomeworkStore(File(context.applicationContext.filesDir, "homework"), SecureSessionStorage(context.applicationContext),
            debug = BuildConfig.DEBUG).also { store = it }
    }
}

val LocalStore = compositionLocalOf<HomeworkStore> { error("no store") }

/** Runs a store action in the app scope; errors go to the store's message. */
fun HomeworkStore.launch(onDone: (Boolean) -> Unit = {}, action: suspend HomeworkStore.() -> Unit) {
    StoreHolder.scope.launch { onDone(perform { action() }) }
}

fun deviceName(context: Context): String =
    Settings.Global.getString(context.contentResolver, "device_name")?.takeIf { it.isNotBlank() } ?: "${Build.MANUFACTURER} ${Build.MODEL}".trim()

fun isTabletScreen(context: Context): Boolean = context.resources.configuration.smallestScreenWidthDp >= 600

fun parentAuthIntent(context: Context) = (context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).let { manager ->
    if (!manager.isDeviceSecure) null
    else @Suppress("DEPRECATION") manager.createConfirmDeviceCredentialIntent("家长验证", "用这台设备的锁屏密码验证家长身份")
}

fun isDeviceSecure(context: Context) = (context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isDeviceSecure

// ---------- Photos: upright JPEG within the server's 2 MB limit ----------

object Photos {
    private const val MAX_BYTES = 1_900_000

    /** Reads a picked or captured photo, applies EXIF rotation, scales to ≤ [maxSide] px and compresses to JPEG. */
    suspend fun prepare(context: Context, uri: Uri, maxSide: Int = 2000): ByteArray? = withContext(Dispatchers.IO) {
        try {
            val resolver = context.contentResolver
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            resolver.openInputStream(uri).use { BitmapFactory.decodeStream(it, null, bounds) }
            if (bounds.outWidth <= 0) return@withContext null
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
            val decoded = resolver.openInputStream(uri).use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) } ?: return@withContext null
            val orientation = resolver.openInputStream(uri).use { input -> input?.let { ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) } } ?: ExifInterface.ORIENTATION_NORMAL
            val matrix = Matrix().apply {
                when (orientation) {
                    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> setScale(-1f, 1f)
                    ExifInterface.ORIENTATION_ROTATE_180 -> setRotate(180f)
                    ExifInterface.ORIENTATION_FLIP_VERTICAL -> { setRotate(180f); postScale(-1f, 1f) }
                    ExifInterface.ORIENTATION_TRANSPOSE -> { setRotate(90f); postScale(-1f, 1f) }
                    ExifInterface.ORIENTATION_ROTATE_90 -> setRotate(90f)
                    ExifInterface.ORIENTATION_TRANSVERSE -> { setRotate(-90f); postScale(-1f, 1f) }
                    ExifInterface.ORIENTATION_ROTATE_270 -> setRotate(-90f)
                }
            }
            var bitmap = if (matrix.isIdentity) decoded else Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true).also { decoded.recycle() }
            val longest = maxOf(bitmap.width, bitmap.height)
            if (longest > maxSide) {
                val scale = maxSide.toFloat() / longest
                bitmap = Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).toInt(), (bitmap.height * scale).toInt(), true)
            }
            jpeg(bitmap)
        } catch (_: Exception) { null }
    }

    fun jpeg(bitmap: Bitmap): ByteArray? {
        var quality = 86
        var current = bitmap
        while (true) {
            val out = ByteArrayOutputStream()
            if (!current.compress(Bitmap.CompressFormat.JPEG, quality, out)) return null
            if (out.size() <= MAX_BYTES) return out.toByteArray()
            if (quality > 60) quality -= 10
            else current = Bitmap.createScaledBitmap(current, (current.width * 0.8f).toInt(), (current.height * 0.8f).toInt(), true)
        }
    }

    /** Average brightness of a tiny thumbnail; very dark photos are hard for a parent to read. */
    fun isDark(data: ByteArray): Boolean {
        val bitmap = BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = 32 }) ?: return false
        val small = Bitmap.createScaledBitmap(bitmap, 16, 16, true)
        var total = 0
        for (x in 0 until 16) for (y in 0 until 16) {
            val p = small.getPixel(x, y)
            total += (((p shr 16) and 0xFF) * 299 + ((p shr 8) and 0xFF) * 587 + (p and 0xFF) * 114) / 1000
        }
        return total / 256.0 < 70
    }

    fun captureFile(context: Context): File = File(File(context.cacheDir, "capture").apply { mkdirs() }, "${newId()}.jpg")
}

// ---------- Audio: AAC in MP4 (the server checks for an `ftyp` box) ----------

class AudioRecorder(private val context: Context) {
    private var recorder: MediaRecorder? = null
    var file: File? = null
        private set

    fun start(): Boolean {
        stop()
        val target = File(context.cacheDir, "recording-${newId()}.m4a")
        val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else @Suppress("DEPRECATION") MediaRecorder()
        return try {
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioSamplingRate(22_050)
            r.setAudioChannels(1)
            r.setAudioEncodingBitRate(48_000)
            r.setOutputFile(target.absolutePath)
            r.prepare(); r.start()
            recorder = r; file = null; pendingFile = target
            true
        } catch (_: Exception) { r.release(); target.delete(); false }
    }

    private var pendingFile: File? = null

    /** Stops recording; returns the finished file, or null when it was too short to be usable. */
    fun stop(): File? {
        val r = recorder ?: return file
        recorder = null
        val ok = try { r.stop(); true } catch (_: Exception) { false }
        r.release()
        file = if (ok) pendingFile else { pendingFile?.delete(); null }
        pendingFile = null
        return file
    }

    val isRecording get() = recorder != null
}

class AudioPlayer(private val context: Context) {
    private var player: MediaPlayer? = null
    var onFinished: () -> Unit = {}

    fun play(data: ByteArray): Boolean {
        stop()
        val file = File(context.cacheDir, "playback.m4a").apply { writeBytes(data) }
        return play(file)
    }

    fun play(file: File): Boolean {
        stop()
        return try {
            player = MediaPlayer().apply {
                setDataSource(file.absolutePath)
                setOnCompletionListener { stop(); onFinished() }
                prepare(); start()
            }
            true
        } catch (_: Exception) { stop(); false }
    }

    fun stop() { player?.let { runCatching { it.stop() }; it.release() }; player = null }
    val isPlaying get() = player?.isPlaying == true
}
