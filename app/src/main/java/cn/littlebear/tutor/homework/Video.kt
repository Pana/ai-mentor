package cn.littlebear.tutor.homework

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.activity.result.contract.ActivityResultContract
import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.Presentation
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import androidx.media3.ui.PlayerView
import java.io.File
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// ---------- Video homework: the child records or picks a video (≤ 30 min), it is compressed to 480p, saved to the
// gallery (the class teacher also wants it in DingTalk, which has no API) and handed in like a recording. ----------

/** The rules for a video hand-in, free of Android so they are unit-tested. */
object VideoRules {
    const val MAX_SECONDS = 30 * 60
    const val SHORT_SIDE = 480
    const val VIDEO_BITRATE = 800_000
    const val AUDIO_BITRATE = 64_000
    const val MAX_FRAME_RATE = 30f
    const val GALLERY_FOLDER = "小熊伴学"

    /**
     * The output size as the video is shown (after its rotation tag), scaled so the short side is [SHORT_SIDE] with the
     * aspect kept; a smaller video keeps its size. Both sides even, as H.264 encoders want.
     */
    fun targetSize(width: Int, height: Int, rotation: Int = 0): Pair<Int, Int> {
        val (w, h) = if (rotation % 180 != 0) height to width else width to height
        if (w <= 0 || h <= 0) return 854 to SHORT_SIDE
        val scale = minOf(1.0, SHORT_SIDE.toDouble() / minOf(w, h))
        fun even(v: Double) = maxOf(2, Math.round(v / 2).toInt() * 2)
        return even(w * scale) to even(h * scale)
    }

    /** Why a video cannot be handed in (in the child's words), or null when it is fine. Camera apps may ignore the 30-minute limit. */
    fun lengthProblem(durationMs: Long?): String? = when {
        durationMs == null || durationMs <= 0 -> "这个视频读不出来，换一个试试吧。"
        durationMs < 1_000 -> "视频太短了，再录一次吧。"
        // A camera stopped at the 30-minute limit may run a fraction of a second over.
        durationMs >= (MAX_SECONDS + 1) * 1000L -> "这个视频有 ${(durationMs + 59_999) / 60_000} 分钟，超过 30 分钟了。请录短一点再交。"
        else -> null
    }

    /** "3 分 25 秒" */
    fun lengthLabel(durationMs: Long): String {
        val s = (durationMs + 500) / 1000
        return if (s < 60) "$s 秒" else "${s / 60} 分 ${s % 60} 秒"
    }

    /** "小熊伴学_语文_20261121_193005.mp4": easy for the child to find when posting it in DingTalk. */
    fun galleryName(subject: String, millis: Long, timeZone: String): String =
        "小熊伴学_${SubjectStyle.label(subject)}_" + DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss").format(Instant.ofEpochMilli(millis).atZone(Day.zone(timeZone))) + ".mp4"
}

data class VideoInfo(val width: Int, val height: Int, val rotation: Int, val durationMs: Long?)

/** Camera capture with a 30-minute limit; returns the video's Uri (the camera's own if it ignored ours), or null when cancelled. */
class CaptureVideo : ActivityResultContract<Uri, Uri?>() {
    private var output: Uri? = null
    override fun createIntent(context: Context, input: Uri): Intent {
        output = input
        return Intent(MediaStore.ACTION_VIDEO_CAPTURE).putExtra(MediaStore.EXTRA_OUTPUT, input)
            .putExtra(MediaStore.EXTRA_DURATION_LIMIT, VideoRules.MAX_SECONDS)
            .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    override fun parseResult(resultCode: Int, intent: Intent?): Uri? =
        if (resultCode == android.app.Activity.RESULT_OK) intent?.data ?: output ?: Uri.EMPTY else null
}

object Videos {
    /** Where the camera writes; earlier unused captures (up to a few GB for 30 minutes of 1080p) are removed first. */
    fun captureFile(context: Context, keep: String? = null): File {
        val dir = File(context.cacheDir, "capture").apply { mkdirs() }
        val busy = VideoPrep.busyFiles + listOfNotNull(keep)
        dir.listFiles { f -> f.extension == "mp4" && f.absolutePath !in busy }?.forEach { it.delete() }
        return File(dir, "${newId()}.mp4")
    }

    suspend fun probe(context: Context, uri: Uri): VideoInfo? = withContext(Dispatchers.IO) {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(context, uri)
            fun int(key: Int) = retriever.extractMetadata(key)?.toIntOrNull() ?: 0
            if (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) != "yes") return@withContext null
            VideoInfo(int(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH), int(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT),
                int(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION), retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull())
        } catch (_: Exception) { null } finally { runCatching { retriever.release() } }
    }

    /** H.264 at 480p, about 0.8 Mbit/s, AAC audio, at most 30 fps: 30 minutes come to about 200 MB. Null when it failed. */
    @OptIn(UnstableApi::class)
    suspend fun compress(context: Context, uri: Uri, info: VideoInfo, onProgress: (Float) -> Unit): File? = withContext(Dispatchers.Main) {
        val out = File(File(context.cacheDir, "video").apply { mkdirs() }, "${newId()}.mp4")
        val (_, height) = VideoRules.targetSize(info.width, info.height, info.rotation)
        val done = CompletableDeferred<Boolean>()
        val transformer = try {
            val encoders = DefaultEncoderFactory.Builder(context)
                .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(VideoRules.VIDEO_BITRATE).build())
                .setRequestedAudioEncoderSettings(AudioEncoderSettings.Builder().setBitrate(VideoRules.AUDIO_BITRATE).build()).build()
            Transformer.Builder(context).setVideoMimeType(MimeTypes.VIDEO_H264).setAudioMimeType(MimeTypes.AUDIO_AAC).setEncoderFactory(encoders)
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) { done.complete(true) }
                    override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) { done.complete(false) }
                }).build()
        } catch (_: Exception) { return@withContext null }
        // Effects see the frame as displayed, so scaling by height keeps the aspect for portrait and landscape alike.
        val effects = Effects(emptyList(), listOf(FrameDropEffect.createDefaultFrameDropEffect(VideoRules.MAX_FRAME_RATE), Presentation.createForHeight(height)))
        val item = EditedMediaItem.Builder(MediaItem.fromUri(uri)).setEffects(effects).build()
        // The deprecated builder infers the tracks from the file, so a video without sound still works
        // (`withAudioAndVideoFrom` would insist on both).
        @Suppress("DEPRECATION") val sequence = EditedMediaItemSequence.Builder(item).build()
        val composition = Composition.Builder(sequence)
            .setHdrMode(if (Build.VERSION.SDK_INT >= 29) Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL else Composition.HDR_MODE_KEEP_HDR).build()
        val ticker = launch {
            val holder = ProgressHolder()
            while (true) {
                if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) onProgress(holder.progress / 100f)
                delay(500)
            }
        }
        try {
            transformer.start(composition, out.absolutePath)
            if (done.await() && out.length() > 0) out else { out.delete(); null }
        } catch (e: CancellationException) {
            transformer.cancel(); out.delete(); throw e
        } catch (_: Exception) {
            transformer.cancel(); out.delete(); null
        } finally { ticker.cancel() }
    }

    /** Android 8–9 need the storage permission to put a file in the gallery; 10 and later use MediaStore without it. */
    fun needsStoragePermission(context: Context): Boolean = Build.VERSION.SDK_INT <= 28 &&
        ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED

    /** Copies the compressed video to Movies/小熊伴学 in the gallery. */
    suspend fun saveToGallery(context: Context, file: File, name: String): Boolean = withContext(Dispatchers.IO) {
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                val resolver = context.contentResolver
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, VIDEO_MIME)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_MOVIES}/${VideoRules.GALLERY_FOLDER}")
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = resolver.insert(MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values) ?: return@withContext false
                try {
                    (resolver.openOutputStream(uri) ?: error("no output")).use { out -> file.inputStream().use { it.copyTo(out) } }
                    resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
                    true
                } catch (e: Exception) { resolver.delete(uri, null, null); false }
            } else {
                @Suppress("DEPRECATION") val movies = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
                val dir = File(movies, VideoRules.GALLERY_FOLDER)
                if (!dir.isDirectory && !dir.mkdirs()) return@withContext false
                val target = File(dir, name)
                file.copyTo(target, overwrite = true)
                MediaScannerConnection.scanFile(context, arrayOf(target.absolutePath), arrayOf(VIDEO_MIME), null)
                true
            }
        } catch (_: Exception) { false }
    }
}

/**
 * A video on its way into the outbox: compressed, saved to the gallery, then queued and sent. Runs in the app scope,
 * so going back or switching to DingTalk does not stop it; the screen shows the progress by homework id.
 */
object VideoPrep {
    data class Job(val step: String, val progress: Float?, val source: String)

    val jobs = MutableStateFlow<Map<String, Job>>(emptyMap())
    val busyFiles: Set<String> get() = jobs.value.values.map { it.source }.toSet()

    private fun set(id: String, job: Job) = jobs.update { it + (id to job) }

    fun start(context: Context, store: HomeworkStore, item: RemoteHomework, source: Uri, info: VideoInfo, capture: File?) {
        if (item.id in jobs.value) return
        val app = context.applicationContext
        val key = capture?.absolutePath ?: source.toString()
        set(item.id, Job("正在压缩视频", 0f, key))
        StoreHolder.scope.launch {
            var out: File? = null
            try {
                out = Videos.compress(app, source, info) { p -> set(item.id, Job("正在压缩视频", p, key)) }
                if (out == null) { store.reportError("视频压缩没成功，再试一次吧。还不行的话，换一个视频。"); return@launch }
                set(item.id, Job("正在存到相册", null, key))
                val saved = Videos.saveToGallery(app, out, VideoRules.galleryName(item.subject, System.currentTimeMillis(), store.state.value.timeZone))
                store.queue(item, video = out)
                out = null
                capture?.delete()
                store.reportError(if (saved) "交上了！已存到相册，可以去钉钉打卡。" else "交上了，但没能存到相册。钉钉打卡需要另外录一段。")
            } catch (e: CancellationException) { throw e }
            catch (_: Exception) { store.reportError("视频没交上，再试一次吧。"); return@launch }
            finally {
                out?.delete()
                jobs.update { it - item.id }
            }
            store.sync()
        }
    }
}

// ---------- Playback: streamed from the server with the device credential (the server answers Range requests) ----------

/** No limit on the whole call (a 30-minute video streams for 30 minutes); redirects stay off so the credential stays put. */
private val streamClient by lazy { OkHttpTransport.defaultClient.newBuilder().callTimeout(0, TimeUnit.MILLISECONDS).readTimeout(30, TimeUnit.SECONDS).build() }

@OptIn(UnstableApi::class)
private fun videoPlayer(context: Context, store: HomeworkStore, fileId: String): ExoPlayer? {
    val local = store.cachedFile(fileId).takeIf { it.exists() }
    val api = store.client
    val (uri, sources) = when {
        local != null -> Uri.fromFile(local) to DefaultDataSource.Factory(context)
        api != null -> Uri.parse(api.fileUrl(fileId)) to OkHttpDataSource.Factory(streamClient)
            .setDefaultRequestProperties(api.token?.let { mapOf("Authorization" to "Bearer $it") } ?: emptyMap())
        else -> return null
    }
    return ExoPlayer.Builder(context).setMediaSourceFactory(DefaultMediaSourceFactory(sources)).build().apply {
        setMediaItem(MediaItem.fromUri(uri)); prepare(); playWhenReady = true
    }
}

/** A dark box with a play button; the player (and the download) only starts when tapped. */
@OptIn(UnstableApi::class)
@Composable fun VideoPlayerBox(fileId: String, modifier: Modifier = Modifier) {
    val store = LocalStore.current
    val context = LocalContext.current
    var started by remember(fileId) { mutableStateOf(false) }
    var failed by remember(fileId) { mutableStateOf(false) }
    Box(modifier.clip(RoundedCornerShape(18.dp)).background(Color.Black), contentAlignment = Alignment.Center) {
        if (!started || failed) Surface(onClick = { failed = false; started = true }, shape = CircleShape, color = Color.White.copy(alpha = 0.92f)) {
            Row(Modifier.padding(horizontal = 20.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Filled.PlayArrow, null, tint = Palette.ink)
                Text(if (failed) "没放出来，再试一次" else "播放视频", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Palette.ink, textAlign = TextAlign.Center)
            }
        } else {
            val player = remember(fileId) { videoPlayer(context, store, fileId) }
            DisposableEffect(player) {
                val listener = object : Player.Listener { override fun onPlayerError(error: PlaybackException) { failed = true } }
                player?.addListener(listener)
                onDispose { player?.removeListener(listener); player?.release() }
            }
            if (player == null) SideEffect { failed = true }
            else AndroidView({ PlayerView(it).apply { this.player = player; setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING) } }, Modifier.fillMaxSize())
        }
    }
}
