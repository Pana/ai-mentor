package cn.littlebear.tutor.homework

import android.graphics.Bitmap
import android.graphics.Paint
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChangeIgnoreConsumed
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.io.ByteArrayOutputStream
import kotlin.math.cos
import kotlin.math.sin

// ---------- Red-pen marks: strokes in page coordinates (0…1 of the photo's width and height) ----------

enum class MarkTool(val label: String) { PEN("红笔"), CHECK("打勾"), CIRCLE("圈出") }

/** Marks per page with an undo history; exported as one transparent PNG per page with the photo's aspect ratio. */
class AnnotationModel {
    val strokes = mutableStateMapOf<Int, List<List<Offset>>>()
    // Snapshot state, so the 撤销 button (which reads canUndo) turns on and off as marks are added and undone.
    private val history = mutableStateMapOf<Int, List<List<List<Offset>>>>()
    val aspect = mutableMapOf<Int, Float>()   // photo width / height

    fun add(page: Int, stroke: List<Offset>) {
        if (stroke.size < 2) return
        history[page] = history[page].orEmpty() + listOf(strokes[page] ?: emptyList())
        strokes[page] = (strokes[page] ?: emptyList()) + listOf(stroke)
    }

    /** ✓ or ○ around a point, sized relative to the page width like the iOS client. */
    fun stamp(tool: MarkTool, p: Offset, page: Int) {
        val ratio = aspect[page] ?: 0.75f
        val u = 1f / 300f                 // one iOS point on a 300-point-wide page
        val v = u * ratio                  // the same length measured against the page height
        val points = when (tool) {
            MarkTool.CHECK -> listOf(Offset(p.x - 16 * u, p.y), Offset(p.x - 5 * u, p.y + 13 * v), Offset(p.x + 20 * u, p.y - 18 * v))
            MarkTool.CIRCLE -> (0..36).map { i -> val a = i / 36.0 * 2 * Math.PI; Offset(p.x + 34 * u * cos(a).toFloat(), p.y + 24 * v * sin(a).toFloat()) }
            MarkTool.PEN -> return
        }
        add(page, points)
    }

    fun canUndo(page: Int) = history[page]?.isNotEmpty() == true
    fun undo(page: Int) {
        val past = history[page].orEmpty()
        if (past.isEmpty()) return
        strokes[page] = past.last()
        history[page] = past.dropLast(1)
    }
    val isEmpty get() = strokes.values.all { it.isEmpty() }

    /** One PNG per page (so overlays line up with pages by index), or none when nothing was marked. */
    fun overlays(pages: Int): List<ByteArray> {
        if (isEmpty) return emptyList()
        return (0 until pages).map { page ->
            val width = 900
            val height = (width / (aspect[page] ?: 0.75f)).toInt().coerceIn(300, 3000)
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = android.graphics.Canvas(bitmap)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = android.graphics.Color.rgb(0xD2, 0x3C, 0x2B); style = Paint.Style.STROKE
                strokeWidth = width * 5f / 300f; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
            }
            strokes[page].orEmpty().forEach { stroke ->
                val path = android.graphics.Path()
                stroke.forEachIndexed { i, o -> if (i == 0) path.moveTo(o.x * width, o.y * height) else path.lineTo(o.x * width, o.y * height) }
                canvas.drawPath(path, paint)
            }
            ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray().also { bitmap.recycle() }
        }
    }
}

/** How far one page is zoomed while marking it: 1…5×, moved by [offset] px from the centred position. */
class PageZoom {
    var scale by mutableFloatStateOf(1f); private set
    var offset by mutableStateOf(Offset.Zero); private set
    val zoomed get() = scale > 1.01f

    fun reset() { scale = 1f; offset = Offset.Zero }

    /** A pinch: zoom by [factor] around [centroid] and move by [pan] (all in the viewport's pixels). */
    fun pinch(centroid: Offset, factor: Float, pan: Offset, viewport: Size, page: Size) {
        val next = (scale * factor).coerceIn(1f, MAX_ZOOM)
        val c = centroid - Offset(viewport.width / 2, viewport.height / 2)
        // Keep the point under the fingers in place while zooming.
        offset = clamp(c - (c - offset) * (next / scale) + pan, next, viewport, page)
        scale = next
    }

    fun pan(by: Offset, viewport: Size, page: Size) { offset = clamp(offset + by, scale, viewport, page) }

    /** A screen point in the viewport → a point on the page (0…1 of its width and height). */
    fun toPage(p: Offset, viewport: Size, page: Size): Offset {
        val local = (p - Offset(viewport.width / 2, viewport.height / 2) - offset) / scale + Offset(page.width / 2, page.height / 2)
        return Offset(local.x / page.width, local.y / page.height)
    }

    // The zoomed page may move until its edge reaches the viewport's edge, and stays centred along a side it doesn't fill.
    private fun clamp(o: Offset, scale: Float, viewport: Size, page: Size): Offset {
        val x = maxOf(0f, (page.width * scale - viewport.width) / 2)
        val y = maxOf(0f, (page.height * scale - viewport.height) / 2)
        return Offset(o.x.coerceIn(-x, x), o.y.coerceIn(-y, y))
    }

    companion object { const val MAX_ZOOM = 5f }
}

private enum class Touch { DRAW, TAP, PAN, PINCH, NONE }

/**
 * One submitted page fitted to the box, with the drawing layer exactly on top of the photo.
 * One finger draws (红笔) or stamps (打勾/圈出); two fingers zoom and move the page. When zoomed, one finger with a
 * stamp tool moves the page; when not zoomed, it is left to the pager to turn pages.
 */
@Composable private fun AnnotatePage(fileId: String, page: Int, model: AnnotationModel, tool: MarkTool, zoom: PageZoom) {
    val result by rememberRemoteBitmap(fileId)
    val bitmap = result?.getOrNull()
    BoxWithConstraints(Modifier.fillMaxSize().padding(12.dp), contentAlignment = Alignment.Center) {
        if (bitmap == null) { CircularProgressIndicator(color = Color.White); return@BoxWithConstraints }
        val ratio = bitmap.width.toFloat() / bitmap.height
        SideEffect { model.aspect[page] = ratio }
        val w = if (maxWidth / maxHeight > ratio) maxHeight * ratio else maxWidth
        val pageSize = with(LocalDensity.current) { Size(w.toPx(), (w / ratio).toPx()) }
        var live by remember { mutableStateOf<List<Offset>>(emptyList()) }
        Box(Modifier.fillMaxSize().clipToBounds().semantics { contentDescription = "在这一页上${tool.label}" }.pointerInput(tool, page, pageSize) {
            awaitEachGesture {
                val viewport = Size(size.width.toFloat(), size.height.toFloat())
                val down = awaitFirstDown(requireUnconsumed = false)
                var touch = if (tool == MarkTool.PEN) Touch.DRAW else Touch.TAP
                if (touch == Touch.DRAW) { live = listOf(zoom.toPage(down.position, viewport, pageSize)); down.consume() }
                var moved = Offset.Zero
                while (true) {
                    val event = awaitPointerEvent()
                    val pressed = event.changes.filter { it.pressed }
                    if (pressed.isEmpty()) break
                    if (pressed.size >= 2) {
                        // A second finger turns any stroke in progress into a pinch, and the gesture stays a pinch until all fingers lift.
                        touch = Touch.PINCH; live = emptyList()
                        zoom.pinch(event.calculateCentroid(), event.calculateZoom(), event.calculatePan(), viewport, pageSize)
                        event.changes.forEach { it.consume() }
                        continue
                    }
                    val change = pressed.first()
                    when (touch) {
                        Touch.DRAW -> { live = live + zoom.toPage(change.position, viewport, pageSize); change.consume() }
                        Touch.TAP -> {
                            moved += change.positionChangeIgnoreConsumed()
                            if (moved.getDistance() > viewConfiguration.touchSlop) touch = if (zoom.zoomed) Touch.PAN else Touch.NONE
                        }
                        Touch.PAN -> { zoom.pan(change.positionChangeIgnoreConsumed(), viewport, pageSize); change.consume() }
                        Touch.PINCH, Touch.NONE -> Unit
                    }
                }
                when (touch) {
                    Touch.DRAW -> model.add(page, live)
                    Touch.TAP -> model.stamp(tool, zoom.toPage(down.position, viewport, pageSize), page)
                    else -> Unit
                }
                live = emptyList()
            }
        }, contentAlignment = Alignment.Center) {
            Box(Modifier.size(w, w / ratio).graphicsLayer {
                scaleX = zoom.scale; scaleY = zoom.scale; translationX = zoom.offset.x; translationY = zoom.offset.y
            }) {
                Image(bitmap, "第 ${page + 1} 页", Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds)
                Canvas(Modifier.fillMaxSize()) {
                    val stroke = Stroke(size.width * 5f / 300f, cap = StrokeCap.Round, join = StrokeJoin.Round)
                    (model.strokes[page].orEmpty() + listOf(live)).forEach { points ->
                        if (points.size < 2) return@forEach
                        val path = Path().apply { points.forEachIndexed { i, o -> if (i == 0) moveTo(o.x * size.width, o.y * size.height) else lineTo(o.x * size.width, o.y * size.height) } }
                        drawPath(path, Palette.redPen, style = stroke)
                    }
                }
            }
        }
        if (zoom.zoomed) Surface(onClick = zoom::reset, Modifier.align(Alignment.TopEnd).padding(8.dp), shape = RoundedCornerShape(50), color = Color.Black.copy(alpha = 0.6f)) {
            Text("还原大小", color = Color.White, fontSize = 14.sp, modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp))
        }
    }
}

@Composable fun ReviewFlow(item: RemoteHomework, submission: Submission, onClose: () -> Unit) {
    val marks = remember(submission.id) { AnnotationModel() }
    var grading by remember { mutableStateOf(!item.isOffline) }
    if (grading) {
        FormScaffold("打分与评语", onBack = { if (item.isOffline) grading = false else onClose() }) { GradeForm(item, submission, marks, onClose) }
        return
    }
    val pager = rememberPagerState { submission.fileIds.size }
    val zooms = remember(submission.id) { List(submission.fileIds.size) { PageZoom() } }
    var tool by remember { mutableStateOf(MarkTool.PEN) }
    Column(Modifier.fillMaxSize().background(Palette.night).systemBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClose) { Text("取消", color = Palette.onNight) }
            Text("${SubjectStyle.label(item.subject)} · 第 ${pager.currentPage + 1} / ${submission.fileIds.size} 页", color = Color.White,
                fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Spacer(Modifier.width(64.dp))
        }
        // Swiping pages only with the stamp tools on an unzoomed page; with the pen a drag draws, on a zoomed page it moves the page.
        HorizontalPager(pager, Modifier.weight(1f).fillMaxWidth(), userScrollEnabled = tool != MarkTool.PEN && zooms.getOrNull(pager.currentPage)?.zoomed != true) { page ->
            AnnotatePage(submission.fileIds[page], page, marks, tool, zooms[page])
        }
        Column(Modifier.fillMaxWidth().background(Palette.nightBar).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                MarkTool.entries.forEach { t ->
                    val on = tool == t
                    val tint = if (on) Color(0xFFE5584A) else Palette.onNight
                    TextButton({ tool = t }, Modifier.background(if (on) Color.White.copy(alpha = 0.18f) else Color.Transparent, RoundedCornerShape(12.dp))
                        .semantics { contentDescription = t.label }) {
                        Text(when (t) { MarkTool.PEN -> "✎"; MarkTool.CHECK -> "✓"; MarkTool.CIRCLE -> "○" }, color = tint, fontSize = 20.sp)
                        Spacer(Modifier.width(4.dp))
                        Text(t.label, color = tint)
                    }
                }
                TextButton({ marks.undo(pager.currentPage) }, enabled = marks.canUndo(pager.currentPage)) { Text("撤销", color = Palette.onNight) }
            }
            Text(if (submission.fileIds.size > 1 && tool == MarkTool.PEN) "两指张开放大看细节 · 用打勾或圈出工具时可以左右滑动翻页" else "两指张开放大看细节",
                color = Palette.onNight, fontSize = 12.sp)
            PrimaryButton("下一步：打分", Modifier.fillMaxWidth(), height = 50.dp) { grading = true }
        }
    }
}

@Composable private fun GradeForm(item: RemoteHomework, submission: Submission, marks: AnnotationModel, onDone: () -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsState()
    var grade by remember { mutableStateOf("EXCELLENT") }
    var requireCorrection by remember { mutableStateOf(false) }
    var comment by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    val phrases = listOf("字很工整", "比昨天进步了", "再细心一点", "订正好就是优")
    val rules = state.rules
    val earlier = item.submissions.mapNotNull { it.review?.grade }.maxOfOrNull { rules.points(it) } ?: 0
    val topUp = maxOf(0, rules.points(grade) - earlier)

    FormSection {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) { SubjectTag(item.subject, 13.sp); Text(item.content, maxLines = 2) }
        if (!item.isRoutine) Text(if (submission.onTime) "按时交（${rules.finishTime} 前）" else "晚于 ${rules.finishTime} 交", fontSize = 13.sp, color = if (submission.onTime) Palette.pine else Palette.warn)
        if (item.isRecording) submission.fileIds.firstOrNull()?.let { AudioPlayerButton(it) }
        if (item.isVideo) submission.fileIds.firstOrNull()?.let { VideoPlayerBox(it, Modifier.fillMaxWidth().height(if (isWide()) 400.dp else 260.dp)) }
        if (item.isOffline) Text(if (marks.isEmpty) "没有批注" else "已批注", fontSize = 13.sp, color = Palette.ink3)
    }
    FormSection("评分") {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            GradeStyle.all.forEach { g ->
                val on = grade == g
                Surface(onClick = { grade = g }, modifier = Modifier.weight(1f).heightIn(min = 50.dp), shape = RoundedCornerShape(14.dp),
                    color = if (on) Palette.pineSoft else Palette.card, border = androidx.compose.foundation.BorderStroke(if (on) 2.dp else 1.dp, if (on) Palette.pine else Palette.line)) {
                    Box(contentAlignment = Alignment.Center) { Text(GradeStyle.label(g), fontSize = if (g == "TRY_AGAIN") 15.sp else 20.sp, fontWeight = FontWeight.Bold, color = if (on) Palette.pine else Palette.ink) }
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) { Text("要求订正后再交", Modifier.weight(1f)); Switch(requireCorrection, { requireCorrection = it }) }
    }
    FormSection("评语") {
        OutlinedTextField(comment, { comment = it.take(500) }, Modifier.fillMaxWidth(), placeholder = { Text("写给孩子的话") }, minLines = 2, maxLines = 5)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            phrases.forEach { p -> AssistChip({ comment = if (comment.isEmpty()) p else "$comment，$p" }, label = { Text(p) }) }
        }
    }
    Column(Modifier.fillMaxWidth().background(Palette.honeySoft, RoundedCornerShape(18.dp)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("这次的奖励", fontSize = 13.sp, color = Palette.honeyInk)
        if (!item.isRoutine && submission.onTime && submission.attempt == 1) Row { Text("按时交", Modifier.weight(1f)); Text("+${rules.onTime} 分钟", fontWeight = FontWeight.Bold) }
        Row { Text("评分 ${GradeStyle.label(grade)}", Modifier.weight(1f)); Text("+$topUp 分钟", fontWeight = FontWeight.Bold) }
        if (requireCorrection) Text("订正后评分提高，会补上差额。", fontSize = 13.sp, color = Palette.ink2)
    }
    PrimaryButton(if (saving) "正在发送…" else "完成批改，发给${state.child(item.childId)?.name ?: "孩子"}", Modifier.fillMaxWidth(), busy = saving) {
        saving = true
        val overlays = marks.overlays(submission.fileIds.size)
        store.launch({ saving = false; if (it) onDone() }) { review(submission, item, grade, comment, requireCorrection, overlays) }
    }
}

// ---------- Audio playback (recorded reading / recitation) ----------

@Composable fun AudioPlayerButton(fileId: String) {
    val store = LocalStore.current
    val context = LocalContext.current
    val player = remember { AudioPlayer(context) }
    var playing by remember { mutableStateOf(false) }
    var data by remember(fileId) { mutableStateOf<ByteArray?>(null) }
    LaunchedEffect(fileId) { data = runCatching { store.fileData(fileId) }.getOrNull() }
    DisposableEffect(player) { player.onFinished = { playing = false }; onDispose { player.stop() } }
    OutlinedButton({
        if (playing) { player.stop(); playing = false } else data?.let { playing = player.play(it); if (!playing) store.reportError("这段录音放不出来。") }
    }, enabled = data != null) {
        Text(when { data == null -> "正在加载录音…"; playing -> "■ 停止"; else -> "▶ 播放录音" })
    }
}
