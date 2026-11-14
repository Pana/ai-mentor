package cn.littlebear.tutor.homework

import android.graphics.BitmapFactory
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// ---------- Palette (matches the design canvas and the iOS client) ----------

object Palette {
    val paper = Color(0xFFF5F1E8)
    val card = Color.White
    val cardSoft = Color(0xFFFBF8F2)
    val line = Color(0xFFE6DFD2)
    val ink = Color(0xFF23201C)
    val ink2 = Color(0xFF5E574E)
    val ink3 = Color(0xFF7A7268)
    val pine = Color(0xFF1E6F55)
    val pineSoft = Color(0xFFE3F1EA)
    val honey = Color(0xFFF0A531)
    val honeySoft = Color(0xFFFDF0D8)
    val honeyInk = Color(0xFF8A5300)
    val chip = Color(0xFFF0EBE1)
    val redPen = Color(0xFFD23C2B)
    val warn = Color(0xFFA04A06)
    val warnSoft = Color(0xFFFDEBDC)
    val waitInk = Color(0xFF34557A)
    val waitSoft = Color(0xFFE8EEF6)
    val night = Color(0xFF1B1A18)
    val nightBar = Color(0xFF26241F)
    val onNight = Color(0xFFD9D2C5)
}

@Composable fun HomeworkTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = Palette.pine, onPrimary = Color.White, primaryContainer = Palette.pineSoft, onPrimaryContainer = Palette.pine,
            secondaryContainer = Palette.pineSoft, onSecondaryContainer = Palette.pine,
            background = Palette.paper, onBackground = Palette.ink, surface = Palette.paper, onSurface = Palette.ink,
            surfaceVariant = Palette.chip, onSurfaceVariant = Palette.ink2, surfaceContainer = Palette.card,
            surfaceContainerLow = Palette.card, surfaceContainerHigh = Palette.card, outline = Palette.line, error = Palette.redPen,
        ),
        content = content,
    )
}

/** Tablet-style layout from 600dp wide (Android's "medium" width class). */
@Composable fun isWide(): Boolean = LocalConfiguration.current.screenWidthDp >= 600

object SubjectStyle {
    val all = listOf("CHINESE", "MATH", "ENGLISH", "OTHER")
    fun label(subject: String) = when (subject) { "CHINESE" -> "语文"; "MATH" -> "数学"; "ENGLISH" -> "英语"; else -> "其他" }
    fun colors(subject: String): Pair<Color, Color> = when (subject) {
        "CHINESE" -> Color(0xFFA63A16) to Color(0xFFFCE8E0)
        "MATH" -> Color(0xFF1F55B0) to Color(0xFFE4EEFB)
        "ENGLISH" -> Color(0xFF5B3FB0) to Color(0xFFEEE8FB)
        else -> Color(0xFF4C5A3A) to Color(0xFFE9EEDF)
    }
}

object GradeStyle {
    val all = listOf("EXCELLENT", "GOOD", "FAIR", "TRY_AGAIN")
    fun label(grade: String) = when (grade) { "EXCELLENT" -> "优"; "GOOD" -> "良"; "FAIR" -> "中"; "TRY_AGAIN" -> "再努力"; else -> grade }
    fun color(grade: String) = when (grade) {
        "EXCELLENT" -> Palette.pine; "GOOD" -> Color(0xFF4E9A7E); "FAIR" -> Color(0xFF8A7A3A); else -> Palette.warn
    }
}

/** How a homework item is done, in the child's words. Device-neutral: the child may use a phone or a tablet. */
fun modeLabel(item: RemoteHomework): String = when {
    item.isOffline -> "本子上写 · 拍照交"
    item.isRecording -> "在线录音"
    item.durationMinutes != null -> "在线计时 ${item.durationMinutes} 分钟"
    else -> "在线完成"
}

// ---------- Small pieces ----------

@Composable fun SubjectTag(subject: String, size: TextUnit = 15.sp) {
    val (fg, bg) = SubjectStyle.colors(subject)
    Text(SubjectStyle.label(subject), color = fg, fontSize = size, fontWeight = FontWeight.Bold, maxLines = 1,
        modifier = Modifier.background(bg, RoundedCornerShape((size.value * 0.65f).dp)).padding(horizontal = (size.value * 0.7f).dp, vertical = (size.value * 0.2f).dp))
}

@Composable fun Chip(text: String, fg: Color = Palette.ink2, bg: Color = Palette.chip, size: TextUnit = 15.sp) {
    Text(text, color = fg, fontSize = size, fontWeight = FontWeight.SemiBold, maxLines = 1,
        modifier = Modifier.background(bg, RoundedCornerShape((size.value * 0.65f).dp)).padding(horizontal = (size.value * 0.7f).dp, vertical = (size.value * 0.25f).dp))
}

/** Status in the child's words: 还没开始 / 要订正 / 等家长批改 / 已批改. */
@Composable fun StatusChip(item: RemoteHomework, size: TextUnit = 15.sp, pending: Boolean = false) {
    when {
        pending -> Chip("等网络上传", size = size)
        item.status == "NEEDS_CORRECTION" -> Chip("要订正", Palette.warn, Palette.warnSoft, size)
        item.status == "SUBMITTED" -> Chip("等家长批改", Palette.waitInk, Palette.waitSoft, size)
        item.status == "REVIEWED" -> item.latestReview?.grade?.let { GradeBadge(it, (size.value * 1.9f).dp) } ?: Chip("完成了", Palette.pine, Palette.pineSoft, size)
        else -> Chip("还没开始", size = size)
    }
}

@Composable fun GradeBadge(grade: String, size: Dp = 30.dp) {
    Box(Modifier.size(size).background(GradeStyle.color(grade), CircleShape).semantics { contentDescription = "评分 ${GradeStyle.label(grade)}" }, contentAlignment = Alignment.Center) {
        Text(GradeStyle.label(grade), color = Color.White, fontWeight = FontWeight.Black,
            fontSize = (size.value * if (grade == "TRY_AGAIN") 0.3f else 0.5f).sp, maxLines = 1)
    }
}

private val avatarPalette = listOf(Color(0xFFCDE7DA) to Palette.pine, Color(0xFFFCE3D2) to Color(0xFFA63A16),
    Color(0xFFE4EEFB) to Color(0xFF1F55B0), Color(0xFFEEE8FB) to Color(0xFF5B3FB0))

@Composable fun Avatar(child: RemoteChild, size: Dp = 40.dp) {
    val last = child.id.lastOrNull()?.digitToIntOrNull(16) ?: 0
    val (bg, fg) = avatarPalette[last % avatarPalette.size]
    Box(Modifier.size(size).background(bg, CircleShape), contentAlignment = Alignment.Center) {
        Text(child.name.take(1), color = fg, fontWeight = FontWeight.Black, fontSize = (size.value * 0.45f).sp)
    }
}

/** The little bear, drawn so it needs no image assets (same geometry as the iOS client). */
@Composable fun BearView(size: Dp = 64.dp) {
    Canvas(Modifier.size(size).semantics { contentDescription = "小熊" }) {
        val s = this.size.width / 64f
        fun circle(x: Float, y: Float, r: Float, color: Color) = drawCircle(color, r * s, Offset(x * s, y * s))
        val ear = Color(0xFFC9822B); val inner = Color(0xFFF6D7A7); val dark = Color(0xFF2A1E14)
        circle(16f, 16f, 10f, ear); circle(48f, 16f, 10f, ear); circle(16f, 16f, 5f, inner); circle(48f, 16f, 5f, inner)
        circle(32f, 35f, 24f, Color(0xFFE39A3B))
        drawOval(inner, Offset(21f * s, 35.5f * s), Size(22f * s, 17f * s))
        circle(23f, 31f, 3f, dark); circle(41f, 31f, 3f, dark)
        drawOval(dark, Offset(28.4f * s, 37.4f * s), Size(7.2f * s, 5.2f * s))
        drawPath(Path().apply { moveTo(28f * s, 46f * s); quadraticTo(32f * s, 49f * s, 36f * s, 46f * s) }, dark, style = Stroke(2f * s, cap = StrokeCap.Round))
    }
}

@Composable fun HCard(modifier: Modifier = Modifier, padding: Dp = 20.dp, background: Color = Palette.card, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth().background(background, RoundedCornerShape(24.dp)).padding(padding), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
}

@Composable fun PrimaryButton(text: String, modifier: Modifier = Modifier, color: Color = Palette.pine, height: Dp = 56.dp, enabled: Boolean = true, busy: Boolean = false, onClick: () -> Unit) {
    Button(onClick, modifier.heightIn(min = height), enabled = enabled && !busy, shape = CircleShape,
        colors = ButtonDefaults.buttonColors(containerColor = color, contentColor = Color.White, disabledContainerColor = color.copy(alpha = 0.45f), disabledContentColor = Color.White),
        contentPadding = PaddingValues(horizontal = (height.value * 0.5f).dp)) {
        if (busy) { CircularProgressIndicator(Modifier.size(18.dp), color = Color.White, strokeWidth = 2.dp); Spacer(Modifier.width(10.dp)) }
        Text(text, fontSize = (height.value * 0.32f).sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
    }
}

/** `compact` trims the side padding for buttons that share a narrow row (e.g. three choices on a phone). */
@Composable fun SecondaryButton(text: String, modifier: Modifier = Modifier, height: Dp = 52.dp, enabled: Boolean = true, compact: Boolean = false, onClick: () -> Unit) {
    OutlinedButton(onClick, modifier.heightIn(min = height), enabled = enabled, shape = CircleShape, border = BorderStroke(2.dp, Palette.line),
        colors = ButtonDefaults.outlinedButtonColors(containerColor = Palette.card, contentColor = Palette.ink),
        contentPadding = PaddingValues(horizontal = if (compact) 8.dp else (height.value * 0.45f).dp)) {
        Text(text, fontSize = (height.value * 0.32f).sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center, maxLines = 1)
    }
}

// ---------- Images stored on the server ----------

/** Decodes at most ~[maxSide] pixels on the long side, so a phone never holds full-size photos for thumbnails. */
fun decodeBitmap(data: ByteArray, maxSide: Int = 1600): ImageBitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
    if (bounds.outWidth <= 0) return null
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
    return BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
}

@Composable fun rememberRemoteBitmap(fileId: String, maxSide: Int = 1600): State<Result<ImageBitmap>?> {
    val store = LocalStore.current
    val state = remember(fileId) { mutableStateOf<Result<ImageBitmap>?>(null) }
    LaunchedEffect(fileId) {
        state.value = runCatching {
            val data = store.fileData(fileId)
            withContext(Dispatchers.Default) { decodeBitmap(data, maxSide) } ?: error("bad image")
        }
    }
    return state
}

@Composable fun RemoteImage(fileId: String, modifier: Modifier = Modifier, contentScale: ContentScale = ContentScale.Fit, maxSide: Int = 1600) {
    val result by rememberRemoteBitmap(fileId, maxSide)
    Box(modifier, contentAlignment = Alignment.Center) {
        val r = result
        when {
            r == null -> CircularProgressIndicator(Modifier.size(28.dp), color = Palette.ink3, strokeWidth = 3.dp)
            r.isFailure -> Text("图片加载失败", color = Palette.ink3, fontSize = 13.sp)
            else -> Image(r.getOrThrow(), null, Modifier.fillMaxSize(), contentScale = contentScale)
        }
    }
}

/** A submitted page with the parent's red-pen overlay drawn on top at the same aspect-fit frame. */
@Composable fun AnnotatedPage(photo: String, overlay: String?, modifier: Modifier = Modifier) {
    Box(modifier) {
        RemoteImage(photo, Modifier.fillMaxSize())
        if (overlay != null) RemoteImage(overlay, Modifier.fillMaxSize())
    }
}

fun overlayFile(submission: Submission, index: Int): String? {
    val ids = submission.review?.annotationFileIds ?: return null
    return if (ids.size == submission.fileIds.size) ids[index] else null
}

fun submitTime(submission: Submission, zone: String): String = try {
    val t = Instant.parse(submission.submittedAt).atZone(ZoneId.of(zone))
    "${t.monthValue} 月 ${t.dayOfMonth} 日 ${DateTimeFormatter.ofPattern("HH:mm").format(t)} 交"
} catch (_: Exception) { "已提交" }

@Composable fun SyncFootnote() {
    val state by LocalStore.current.state.collectAsStateWithLifecycle()
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (state.syncing) CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = Palette.ink3)
        val text = when {
            state.outbox.isNotEmpty() -> "${state.outbox.size} 项等网络上传"
            state.lastSynced != null -> "已同步 " + DateTimeFormatter.ofPattern("HH:mm").format(Instant.ofEpochMilli(state.lastSynced!!).atZone(ZoneId.systemDefault()))
            else -> "还没有同步"
        }
        Text(text, fontSize = 13.sp, color = Palette.ink3)
    }
}

@Composable fun Pill(text: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Surface(onClick = onClick, modifier = modifier.heightIn(min = 40.dp), shape = CircleShape, color = if (selected) Palette.ink else Palette.card,
        border = if (selected) null else BorderStroke(1.dp, Palette.line)) {
        Box(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), contentAlignment = Alignment.Center) {
            Text(text, color = if (selected) Color.White else Palette.ink, fontSize = 15.sp, fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal, maxLines = 1)
        }
    }
}

@Composable fun Thumb(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    Box(modifier.clip(RoundedCornerShape(10.dp)).background(Palette.chip).border(1.dp, Palette.line, RoundedCornerShape(10.dp)), content = content)
}
