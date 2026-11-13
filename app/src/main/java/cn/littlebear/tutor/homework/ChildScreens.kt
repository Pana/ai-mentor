@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package cn.littlebear.tutor.homework

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.io.File
import java.time.Instant
import java.time.LocalTime
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private fun prefs(context: Context) = context.getSharedPreferences("phase1.child", Context.MODE_PRIVATE)

sealed interface ChildRoute {
    data class Homework(val id: String) : ChildRoute
    data class Submit(val id: String) : ChildRoute
}

enum class ChildTab(val label: String) { TODAY("今天"), ALL("全部作业"), REWARD("奖励时间") }

/** Child app (tablet or phone): pick yourself, then 今天 · 全部作业 · 奖励时间. */
@Composable fun ChildApp() {
    val context = LocalContext.current
    val state by LocalStore.current.state.collectAsStateWithLifecycle()
    var childId by remember { mutableStateOf(prefs(context).getString("current", null)) }
    fun choose(id: String?) { childId = id; prefs(context).edit().putString("current", id).apply() }
    val child = state.child(childId)
    if (child != null) ChildShell(child) { choose(null) } else ProfilePicker { choose(it.id) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun ProfilePicker(choose: (RemoteChild) -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var settings by remember { mutableStateOf(false) }
    val today = store.today
    PullToRefreshBox(state.syncing, { scope.launch { store.sync() } }, Modifier.fillMaxSize().systemBarsPadding()) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(24.dp)) {
            Row(Modifier.fillMaxWidth()) { Spacer(Modifier.weight(1f)); ParentLockButton { settings = true } }
            BearView(120.dp)
            Text(if (state.children.isEmpty()) "等家长添加孩子" else "今天谁来学习？", fontSize = 36.sp, fontWeight = FontWeight.Black, color = Palette.ink, textAlign = TextAlign.Center)
            if (state.children.isEmpty()) {
                Text("家长在手机上“作业 → 设置”里添加孩子后，这里会出现头像。", fontSize = 18.sp, color = Palette.ink2, textAlign = TextAlign.Center)
            } else {
                Text("点一下你的头像", fontSize = 18.sp, color = Palette.ink2)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterHorizontally), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                    state.children.forEach { c ->
                        val open = state.items(c.id).count { it.date <= today && it.needsWork }
                        Surface(onClick = { choose(c) }, shape = RoundedCornerShape(32.dp), color = Palette.card, modifier = Modifier.size(210.dp, 240.dp)) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically)) {
                                Avatar(c, 100.dp)
                                Text(c.name, fontSize = 26.sp, fontWeight = FontWeight.Bold)
                                Text(if (open == 0) "${c.grade} 年级 · 作业都完成啦" else "${c.grade} 年级 · 还有 $open 项作业", fontSize = 14.sp, color = Palette.ink2)
                            }
                        }
                    }
                }
            }
            Text("学习记录保存在家里的服务器上", fontSize = 13.sp, color = Palette.ink3)
        }
    }
    if (settings) ChildSettings { settings = false }
}

@Composable private fun ParentLockButton(onClick: () -> Unit) {
    OutlinedButton(onClick, shape = CircleShape, border = BorderStroke(1.dp, Palette.line), colors = ButtonDefaults.outlinedButtonColors(containerColor = Palette.card, contentColor = Palette.ink2)) {
        Icon(Icons.Filled.Lock, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)); Text("家长")
    }
}

@Composable private fun ChildShell(child: RemoteChild, switchChild: () -> Unit) {
    var tab by rememberSaveable { mutableStateOf(ChildTab.TODAY) }
    val stack = remember { mutableStateListOf<ChildRoute>() }
    var settings by remember { mutableStateOf(false) }
    BackHandler(stack.isNotEmpty()) { stack.removeAt(stack.lastIndex) }
    BackHandler(stack.isEmpty() && tab != ChildTab.TODAY) { tab = ChildTab.TODAY }
    val open: (String) -> Unit = { stack.add(ChildRoute.Homework(it)) }
    Box(Modifier.fillMaxSize().background(Palette.paper).systemBarsPadding()) {
        when (val route = stack.lastOrNull()) {
            is ChildRoute.Homework -> ChildHomeworkView(route.id, back = { stack.removeAt(stack.lastIndex) }, submit = { stack.add(ChildRoute.Submit(route.id)) })
            is ChildRoute.Submit -> SubmitPhotosView(route.id, back = { stack.removeAt(stack.lastIndex) }) { stack.clear(); stack.add(ChildRoute.Homework(route.id)) }
            null -> Column(Modifier.fillMaxSize()) {
                TopBar(child, tab, { tab = it }, switchChild) { settings = true }
                Box(Modifier.weight(1f)) {
                    when (tab) {
                        ChildTab.TODAY -> TodayView(child, open) { tab = ChildTab.REWARD }
                        ChildTab.ALL -> AllHomeworkView(child, open)
                        ChildTab.REWARD -> RewardView(child)
                    }
                }
            }
        }
    }
    if (settings) ChildSettings { settings = false }
}

@Composable private fun TopBar(child: RemoteChild, tab: ChildTab, onTab: (ChildTab) -> Unit, switchChild: () -> Unit, openSettings: () -> Unit) {
    val wide = isWide()
    val who = @Composable {
        Surface(onClick = switchChild, shape = CircleShape, color = Palette.card, border = BorderStroke(1.dp, Palette.line)) {
            Row(Modifier.padding(start = 6.dp, end = 14.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Avatar(child, 36.dp); Text(child.name, fontSize = 17.sp, fontWeight = FontWeight.Medium); Icon(Icons.Filled.KeyboardArrowDown, "换人", tint = Palette.ink3)
            }
        }
    }
    val tabs = @Composable { modifier: Modifier ->
        Row(modifier.background(Color(0xFFEAE4D8), CircleShape).padding(4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            ChildTab.entries.forEach { t ->
                val on = tab == t
                Surface(onClick = { onTab(t) }, shape = CircleShape, color = if (on) Palette.card else Color.Transparent, modifier = if (wide) Modifier else Modifier.weight(1f)) {
                    Text(t.label, Modifier.padding(horizontal = if (wide) 24.dp else 6.dp, vertical = 12.dp), fontSize = if (wide) 18.sp else 15.sp,
                        fontWeight = if (on) FontWeight.Bold else FontWeight.Medium, color = if (on) Palette.ink else Palette.ink2, textAlign = TextAlign.Center, maxLines = 1)
                }
            }
        }
    }
    if (wide) Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        who(); Spacer(Modifier.weight(1f)); tabs(Modifier); Spacer(Modifier.weight(1f)); ParentLockButton(openSettings)
    } else Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) { who(); Spacer(Modifier.weight(1f)); ParentLockButton(openSettings) }
        tabs(Modifier.fillMaxWidth())
    }
}

// ---------- 今天 ----------

private fun rank(item: RemoteHomework) = when (item.status) { "NEEDS_CORRECTION" -> 0; "NOT_STARTED" -> 1; "SUBMITTED" -> 2; else -> 3 }

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun TodayView(child: RemoteChild, open: (String) -> Unit, showRewards: () -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val today = store.today
    val all = state.items(child.id)
    val homework = all.filter { !it.isRoutine && (it.date == today || (it.date < today && it.needsWork)) }
        .sortedWith(compareBy<RemoteHomework>({ rank(it) }, { it.date }, { it.subject }))
    val routines = all.filter { it.isRoutine && it.date == today }.sortedBy { it.content }
    val wide = isWide()
    PullToRefreshBox(state.syncing, { scope.launch { store.sync() } }, Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = if (wide) 24.dp else 16.dp).padding(bottom = 24.dp)) {
            val main = @Composable { modifier: Modifier ->
                Column(modifier, verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    val done = homework.count { !it.needsWork }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        BearView(if (wide) 72.dp else 56.dp)
                        Column {
                            Text("${child.name}，${greeting()}！", fontSize = if (wide) 30.sp else 24.sp, fontWeight = FontWeight.Black)
                            Text(when { homework.isEmpty() -> "今天还没有作业。"; done == homework.size -> "今天的作业都交啦，真棒！"; else -> "今天有 ${homework.size} 项作业，交了 $done 项。" },
                                fontSize = 17.sp, color = Palette.ink2)
                        }
                    }
                    if (homework.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        homework.indices.forEach { i -> Box(Modifier.weight(1f).height(10.dp).background(if (i < done) Palette.pine else Palette.line, CircleShape)) }
                    }
                    val firstOpen = homework.firstOrNull { it.needsWork }?.id
                    homework.forEach { item -> TodayCard(item, item.id == firstOpen, state.pending(item.id) != null, today) { open(item.id) } }
                    SyncFootnote()
                }
            }
            val aside = @Composable { modifier: Modifier ->
                Column(modifier, verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    if (routines.isNotEmpty()) HCard {
                        Row { Text("每天坚持", fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f)); Text("${routines.count { !it.needsWork }} / ${routines.size} 做完", color = Palette.ink3) }
                        routines.forEach { item ->
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                if (item.needsWork) Box(Modifier.size(30.dp).border(2.dp, Color(0xFFD5CCBC), CircleShape))
                                else Box(Modifier.size(30.dp).background(Palette.pine, CircleShape), contentAlignment = Alignment.Center) { Icon(Icons.Filled.Check, null, tint = Color.White, modifier = Modifier.size(18.dp)) }
                                Column(Modifier.weight(1f)) {
                                    Text(item.content, fontWeight = FontWeight.Bold, color = if (item.needsWork) Palette.ink else Palette.ink2)
                                    Text(modeLabel(item), fontSize = 12.sp, color = Palette.ink3)
                                }
                                if (item.needsWork) SecondaryButton("开始", height = 44.dp) { open(item.id) }
                            }
                        }
                    }
                    all.filter { it.latestReview != null && it.date >= Day.add(today, -2) }.maxByOrNull { it.latestReview?.reviewedAt ?: "" }?.let { latest ->
                        val review = latest.latestReview!!
                        HCard(background = Palette.honeySoft) {
                            Text("家长批改好了", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Palette.honeyInk)
                            Text("${SubjectStyle.label(latest.subject)} · ${GradeStyle.label(review.grade)}", fontSize = 20.sp, fontWeight = FontWeight.Bold)
                            Text(latest.content, maxLines = 1, overflow = TextOverflow.Ellipsis, color = Palette.ink2)
                            PrimaryButton("去看看", Modifier.fillMaxWidth(), color = Palette.ink, height = 48.dp) { open(latest.id) }
                        }
                    }
                    Surface(onClick = showRewards, shape = RoundedCornerShape(24.dp), color = Palette.ink) {
                        Row(Modifier.padding(horizontal = 20.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text("▶", color = Palette.honey, fontSize = 22.sp); Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text("我的奖励时间", fontSize = 12.sp, color = Palette.onNight)
                                Text("已攒 ${state.rewards[child.id]?.balance ?: 0} 分钟", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = Color.White)
                            }
                            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Color.White)
                        }
                    }
                }
            }
            if (wide) Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) { main(Modifier.weight(1f)); aside(Modifier.width(340.dp)) }
            else Column(verticalArrangement = Arrangement.spacedBy(20.dp)) { main(Modifier.fillMaxWidth()); aside(Modifier.fillMaxWidth()) }
        }
    }
}


private fun greeting(): String { val h = LocalTime.now().hour; return if (h < 12) "早上好" else if (h < 18) "下午好" else "晚上好" }

@Composable private fun TodayCard(item: RemoteHomework, highlighted: Boolean, pending: Boolean, today: String, onClick: () -> Unit) {
    val wide = isWide()
    Surface(onClick = onClick, shape = RoundedCornerShape(24.dp), color = Palette.card, border = if (highlighted) BorderStroke(2.dp, Palette.pine) else null) {
        val action = @Composable {
            if (item.needsWork) {
                val strong = highlighted
                Box(Modifier.heightIn(min = 52.dp).background(if (strong) Palette.pine else Palette.card, CircleShape).border(if (strong) 0.dp else 2.dp, Palette.pine, CircleShape)
                    .padding(horizontal = 24.dp, vertical = 12.dp), contentAlignment = Alignment.Center) {
                    Text(if (item.status == "NEEDS_CORRECTION" || highlighted) "继续" else "开始", color = if (strong) Color.White else Palette.pine, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                }
            }
        }
        val body = @Composable { modifier: Modifier ->
            Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SubjectTag(item.subject); StatusChip(item, pending = pending); Chip(modeLabel(item))
                    if (item.date < today) Chip("${Day.short(item.date)} 的作业", Palette.warn, Palette.warnSoft)
                }
                Text(item.content, fontSize = 21.sp, fontWeight = FontWeight.Bold, color = if (item.needsWork) Palette.ink else Palette.ink2, maxLines = 3, overflow = TextOverflow.Ellipsis)
                val comment = item.latestReview?.comment
                if (item.status == "NEEDS_CORRECTION" && !comment.isNullOrEmpty()) Text("家长说：$comment", fontSize = 16.sp, color = Palette.honeyInk,
                    modifier = Modifier.background(Palette.honeySoft, RoundedCornerShape(12.dp)).padding(horizontal = 14.dp, vertical = 8.dp))
            }
        }
        if (wide) Row(Modifier.padding(22.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(20.dp)) { body(Modifier.weight(1f)); action() }
        else Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) { body(Modifier.fillMaxWidth()); Row { Spacer(Modifier.weight(1f)); action() } }
    }
}

// ---------- 全部作业 (grouped by date) ----------

private enum class Filter(val label: String) { ALL("全部"), OPEN("还没做完"), WAITING("等家长批改"), MARKED("有批注") }

private fun Filter.matches(item: RemoteHomework) = when (this) {
    Filter.ALL -> true
    Filter.OPEN -> item.needsWork
    Filter.WAITING -> item.awaitingReview
    Filter.MARKED -> item.latestReview?.let { it.comment.isNotEmpty() || it.annotationFileIds.isNotEmpty() } ?: false
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun AllHomeworkView(child: RemoteChild, open: (String) -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var filter by rememberSaveable { mutableStateOf(Filter.ALL) }
    val today = store.today
    val wide = isWide()
    PullToRefreshBox(state.syncing, { scope.launch { store.sync() } }, Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = if (wide) 24.dp else 16.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Filter.entries.forEach { f ->
                    val count = if (f == Filter.ALL) null else state.items(child.id).count { f.matches(it) }
                    Pill(count?.let { "${f.label} $it" } ?: f.label, filter == f) { filter = f }
                }
            }
            val groups = state.grouped(child.id) { filter.matches(it) }.filter { it.first <= Day.add(today, 7) }
            if (groups.isEmpty()) Text("这里还没有作业。", fontSize = 18.sp, color = Palette.ink2, modifier = Modifier.fillMaxWidth().padding(top = 40.dp), textAlign = TextAlign.Center)
            groups.forEach { (day, items) ->
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(Day.label(day, today), fontSize = 19.sp, fontWeight = FontWeight.Bold)
                    Column(Modifier.fillMaxWidth().background(Palette.card, RoundedCornerShape(22.dp))) {
                        items.forEachIndexed { i, item ->
                            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).clickable { open(item.id) }.padding(horizontal = 18.dp, vertical = 14.dp),
                                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                SubjectTag(item.subject)
                                Column(Modifier.weight(1f)) {
                                    Text(item.content, fontSize = 18.sp, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                    item.latestReview?.comment?.takeIf { it.isNotEmpty() }?.let { Text("家长的批注：$it", fontSize = 14.sp, color = Palette.honeyInk, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                                }
                                if (wide) Text(if (item.isOffline) "本子上写" else "在线完成", fontSize = 14.sp, color = Palette.ink3)
                                StatusChip(item, pending = state.pending(item.id) != null)
                            }
                            if (i < items.lastIndex) HorizontalDivider(Modifier.padding(start = 18.dp), color = Palette.line)
                        }
                    }
                }
            }
        }
    }
}

// ---------- One homework item: do it, wait for the parent, or read the feedback ----------

@Composable private fun BackPill(text: String, onClick: () -> Unit) {
    Surface(onClick = onClick, shape = CircleShape, color = Palette.card) {
        Row(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(text, fontSize = 17.sp, fontWeight = FontWeight.Medium)
        }
    }
}

@Composable private fun ChildHomeworkView(id: String, back: () -> Unit, submit: () -> Unit) {
    val state by LocalStore.current.state.collectAsStateWithLifecycle()
    val item = state.homework[id]
    val wide = isWide()
    Column(Modifier.fillMaxSize()) {
        if (item == null) {
            Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically)) {
                Text("这项作业已经删除了", fontSize = 22.sp, fontWeight = FontWeight.Bold); Text("可能是家长改了作业。", color = Palette.ink2)
                PrimaryButton("返回", onClick = back)
            }
            return
        }
        FlowRow(Modifier.padding(horizontal = if (wide) 24.dp else 16.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            BackPill("返回", back)
            Row(Modifier.align(Alignment.CenterVertically), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SubjectTag(item.subject); StatusChip(item, pending = state.pending(item.id) != null); Chip(modeLabel(item), bg = Palette.card)
            }
        }
        Box(Modifier.weight(1f).padding(horizontal = if (wide) 24.dp else 16.dp).padding(bottom = if (wide) 24.dp else 16.dp)) {
            when {
                state.pending(item.id) != null -> WaitingView(item, uploading = true)
                item.status == "REVIEWED" || item.status == "NEEDS_CORRECTION" -> FeedbackView(item, submit)
                item.status == "SUBMITTED" -> WaitingView(item, uploading = false)
                item.isOffline -> OfflineTaskView(item, submit)
                item.isTimer -> TimerTaskView(item)
                else -> RecordingTaskView(item)
            }
        }
    }
}

/** Homework content as numbered lines, plus the parent's note and the teacher's pictures. */
@Composable private fun HomeworkContent(item: RemoteHomework) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("作业 · ${Day.short(item.date)}${item.dueDate?.let { "，${Day.short(it)} 交" } ?: ""}", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Palette.ink3)
        val lines = item.content.split('\n', '；', ';').map { it.trim() }.filter { it.isNotEmpty() }
        lines.forEachIndexed { i, line ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (lines.size > 1) Text("${i + 1}.", color = Palette.ink3, fontSize = 21.sp)
                Text(line, fontSize = 21.sp, fontWeight = FontWeight.Medium)
            }
        }
        val comment = item.latestReview?.comment
        if (item.status == "NEEDS_CORRECTION" && !comment.isNullOrEmpty()) Text("家长说：$comment", fontSize = 17.sp, color = Palette.honeyInk,
            modifier = Modifier.background(Palette.honeySoft, RoundedCornerShape(14.dp)).padding(horizontal = 16.dp, vertical = 10.dp))
        if (item.attachmentIds.isNotEmpty()) {
            val pager = rememberPagerState { item.attachmentIds.size }
            HorizontalPager(pager, Modifier.fillMaxWidth().height(300.dp).background(Palette.cardSoft, RoundedCornerShape(18.dp))) { page ->
                RemoteImage(item.attachmentIds[page], Modifier.fillMaxSize().padding(8.dp))
            }
            if (item.attachmentIds.size > 1) Text("左右滑动看 ${item.attachmentIds.size} 张图", fontSize = 13.sp, color = Palette.ink3)
        }
    }
}

@Composable private fun OfflineTaskView(item: RemoteHomework, submit: () -> Unit) {
    Column(Modifier.fillMaxSize().background(Palette.card, RoundedCornerShape(28.dp)).padding(24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) { HomeworkContent(item) }
        Row { Spacer(Modifier.weight(1f)); PrimaryButton(if (item.status == "NEEDS_CORRECTION") "订正好了，拍照再交" else "写完了，拍照交作业", height = 60.dp, onClick = submit) }
    }
}

@Composable private fun WaitingView(item: RemoteHomework, uploading: Boolean) {
    Column(Modifier.fillMaxSize().background(Palette.card, RoundedCornerShape(28.dp)).verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp, Alignment.CenterVertically)) {
        BearView(96.dp)
        Text(if (uploading) "交上了，等网络好了就发给家长" else if (item.isTimer) "打卡完成！" else "交上了，等家长批改", fontSize = 28.sp, fontWeight = FontWeight.Black, textAlign = TextAlign.Center)
        Text(item.content, fontSize = 18.sp, color = Palette.ink2, textAlign = TextAlign.Center)
        val latest = item.latest
        if (latest != null && item.isOffline && !uploading) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            latest.fileIds.forEach { Thumb(Modifier.size(120.dp, 160.dp)) { RemoteImage(it, Modifier.fillMaxSize(), ContentScale.Crop, 500) } }
        }
    }
}

// ---------- Feedback ----------

@Composable private fun FeedbackView(item: RemoteHomework, redo: () -> Unit) {
    val state by LocalStore.current.state.collectAsStateWithLifecycle()
    val wide = isWide()
    val submission = item.submissions.lastOrNull { it.review != null } ?: item.latest
    val work = @Composable { modifier: Modifier ->
        Box(modifier.background(Color(0xFFEDE8DD), RoundedCornerShape(28.dp)), contentAlignment = Alignment.Center) {
            when {
                submission != null && item.isOffline && submission.fileIds.isNotEmpty() -> {
                    val pager = rememberPagerState { submission.fileIds.size }
                    HorizontalPager(pager, Modifier.fillMaxSize()) { i -> AnnotatedPage(submission.fileIds[i], overlayFile(submission, i), Modifier.fillMaxSize().padding(16.dp)) }
                }
                item.isRecording && submission?.fileIds?.firstOrNull() != null -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    BearView(90.dp); Text(item.content, fontSize = 22.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center); AudioPlayerButton(submission.fileIds.first())
                }
                else -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    BearView(90.dp); Text(item.content, fontSize = 22.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                    submission?.durationSeconds?.let { Text("坚持了 ${it / 60} 分钟", fontSize = 18.sp, color = Palette.ink2) }
                }
            }
        }
    }
    val side = @Composable { modifier: Modifier ->
        Column(modifier, verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item.latestReview?.let { review ->
                HCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        GradeBadge(review.grade, 72.dp)
                        Column { Text("家长的评分", fontSize = 14.sp, color = Palette.ink3); Text(if (review.requireCorrection) "订正好再交一次" else "批改完成", fontSize = 20.sp, fontWeight = FontWeight.Bold) }
                    }
                    if (review.comment.isNotEmpty()) Text(review.comment, fontSize = 18.sp, modifier = Modifier.fillMaxWidth().background(Palette.cardSoft, RoundedCornerShape(14.dp)).padding(14.dp))
                }
            }
            val earned = state.rewards[item.childId]?.entries.orEmpty().filter { it.refId.startsWith(item.id.lowercase()) && it.minutes > 0 }
            if (earned.isNotEmpty()) Column(Modifier.fillMaxWidth().background(Palette.ink, RoundedCornerShape(24.dp)).padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("这项作业的奖励", fontSize = 14.sp, color = Palette.onNight)
                earned.forEach { e -> Row { Text(mapOf("ON_TIME" to "按时交", "GRADE" to "评分", "CHECKIN" to "打卡")[e.reason] ?: "奖励", color = Color.White, modifier = Modifier.weight(1f)); Text("+${e.minutes} 分钟", color = Palette.honey, fontWeight = FontWeight.Bold) } }
            }
            if (item.status == "NEEDS_CORRECTION") {
                if (item.isOffline) PrimaryButton("订正好了，拍照再交", Modifier.fillMaxWidth(), height = 60.dp, onClick = redo)
                else if (item.isTimer) Box(Modifier.height(380.dp)) { TimerTaskView(item) } else Box(Modifier.height(320.dp)) { RecordingTaskView(item) }
            }
        }
    }
    if (wide) Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(20.dp)) { work(Modifier.weight(1f).fillMaxHeight()); side(Modifier.width(380.dp).verticalScroll(rememberScrollState())) }
    else Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) { work(Modifier.fillMaxWidth().height(420.dp)); side(Modifier.fillMaxWidth()) }
}

// ---------- Photo submission (several pages) ----------

@Composable private fun SubmitPhotosView(id: String, back: () -> Unit, done: () -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val pages = remember { mutableStateListOf<ByteArray>() }
    var sending by remember { mutableStateOf(false) }
    var cameraFile by rememberSaveable { mutableStateOf<String?>(null) }
    val item = state.homework[id]
    val wide = isWide()
    fun add(uri: Uri, cleanup: File? = null) = scope.launch {
        Photos.prepare(context, uri)?.let { if (pages.size < 6) pages.add(it) } ?: store.reportError("这张照片读不出来，再拍一次吧。")
        cleanup?.delete()
    }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        cameraFile?.let { path -> val f = File(path); if (ok) add(Uri.fromFile(f), f) else f.delete() }
        cameraFile = null
    }
    val gallery = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(6)) { uris -> uris.take(6 - pages.size).forEach { add(it) } }
    val takePhoto = {
        val f = Photos.captureFile(context); cameraFile = f.absolutePath
        try { camera.launch(FileProvider.getUriForFile(context, "${context.packageName}.files", f)) } catch (_: Exception) { store.reportError("无法打开相机，可以从相册选。") }
    }
    Column(Modifier.fillMaxSize()) {
        FlowRow(Modifier.padding(horizontal = if (wide) 24.dp else 16.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            BackPill("回到作业", back)
            Text("拍照交作业", fontSize = 24.sp, fontWeight = FontWeight.Black, modifier = Modifier.align(Alignment.CenterVertically))
            item?.let { Row(Modifier.align(Alignment.CenterVertically), horizontalArrangement = Arrangement.spacedBy(8.dp)) { SubjectTag(it.subject); Text(it.content, maxLines = 1, overflow = TextOverflow.Ellipsis, color = Palette.ink2) } }
        }
        val photos = @Composable { modifier: Modifier ->
            Column(modifier.background(Palette.card, RoundedCornerShape(28.dp)).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                if (pages.isEmpty()) {
                    Spacer(Modifier.weight(1f))
                    Text("📄", fontSize = 64.sp)
                    Text("把写好的这一页放平，拍完整就行", fontSize = 20.sp, color = Palette.ink2, textAlign = TextAlign.Center)
                    Spacer(Modifier.weight(1f))
                } else LazyVerticalGrid(GridCells.Adaptive(160.dp), Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    itemsIndexed(pages) { i, data ->
                        Box {
                            val bitmap = remember(data) { decodeBitmap(data, 600) }
                            Thumb(Modifier.fillMaxWidth().height(220.dp)) { bitmap?.let { Image(it, "第 ${i + 1} 页", Modifier.fillMaxSize()) } }
                            IconButton({ pages.removeAt(i) }, Modifier.align(Alignment.TopEnd).padding(6.dp).size(36.dp).background(Color.Black.copy(alpha = 0.55f), CircleShape)) {
                                Icon(Icons.Filled.Close, "删除第 ${i + 1} 页", tint = Color.White)
                            }
                            Text("第 ${i + 1} 页", fontSize = 14.sp, fontWeight = FontWeight.Bold, modifier = Modifier.align(Alignment.BottomStart).padding(8.dp).background(Color.White, CircleShape).padding(horizontal = 10.dp, vertical = 4.dp))
                        }
                    }
                }
                if (pages.size < 6) Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    PrimaryButton(if (pages.isEmpty()) "拍第 1 页" else "再拍一页", height = 52.dp, onClick = takePhoto)
                    SecondaryButton("从相册选", height = 52.dp) { gallery.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
                }
            }
        }
        val side = @Composable { modifier: Modifier ->
            Column(modifier.background(Palette.card, RoundedCornerShape(28.dp)).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text(if (pages.isEmpty()) "还没拍" else "已经拍了 ${pages.size} 页", fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Text("最多 6 页", color = Palette.ink3)
                val dark = remember(pages.size) { pages.indexOfFirst { Photos.isDark(it) } }
                if (dark >= 0) Row(Modifier.background(Palette.honeySoft, RoundedCornerShape(16.dp)).padding(14.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    BearView(40.dp); Text("第 ${dark + 1} 页有点暗，靠近台灯再拍一次会更清楚。", fontSize = 16.sp)
                }
                if (wide) Spacer(Modifier.weight(1f))
                PrimaryButton(if (sending) "正在交…" else "交给家长批改", Modifier.fillMaxWidth(), height = 60.dp, busy = sending, enabled = pages.isNotEmpty() && item != null) {
                    sending = true
                    val list = pages.toList()
                    StoreHolder.scope.launch { item?.let { store.submit(it, pages = list) }; sending = false; done() }
                }
            }
        }
        if (wide) Row(Modifier.weight(1f).padding(horizontal = 24.dp).padding(bottom = 24.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            photos(Modifier.weight(1f).fillMaxHeight()); side(Modifier.width(340.dp).fillMaxHeight())
        } else Column(Modifier.weight(1f).padding(horizontal = 16.dp).padding(bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            photos(Modifier.weight(1f).fillMaxWidth()); side(Modifier.fillMaxWidth())
        }
    }
}

// ---------- Online: timer ----------

@Composable private fun TimerTaskView(item: RemoteHomework) {
    val store = LocalStore.current
    val context = LocalContext.current
    val key = "timer.${item.id}"
    var elapsed by remember { mutableIntStateOf(prefs(context).getInt(key, 0)) }
    var running by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }
    val goal = maxOf(1, item.durationMinutes ?: 5) * 60
    fun save() = prefs(context).edit().putInt(key, elapsed).apply()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_STOP) { running = false; save() } }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); save() }
    }
    LaunchedEffect(running) { while (running) { delay(1000); elapsed++; if (elapsed % 10 == 0) save() } }
    Column(Modifier.fillMaxSize().background(Palette.card, RoundedCornerShape(28.dp)).verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(22.dp, Alignment.CenterVertically)) {
        Text(item.content, fontSize = 21.sp, fontWeight = FontWeight.Medium, color = Palette.ink2, textAlign = TextAlign.Center)
        Box(Modifier.size(240.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize()) {
                val w = 20.dp.toPx()
                drawArc(Palette.chip, 0f, 360f, false, Offset(w / 2, w / 2), Size(size.width - w, size.height - w), style = Stroke(w))
                drawArc(Palette.pine, -90f, 360f * minOf(1f, elapsed.toFloat() / goal), false, Offset(w / 2, w / 2), Size(size.width - w, size.height - w), style = Stroke(w, cap = StrokeCap.Round))
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text("%d:%02d".format(elapsed / 60, elapsed % 60), fontSize = 52.sp, fontWeight = FontWeight.Black)
                Text(if (elapsed >= goal) "时间到啦！" else "还差 ${(goal - elapsed) / 60} 分 ${(goal - elapsed) % 60} 秒", fontSize = 16.sp, color = Palette.ink2)
            }
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterHorizontally), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            SecondaryButton(if (running) "暂停" else if (elapsed == 0) "开始" else "继续", height = 58.dp) { running = !running }
            PrimaryButton(if (elapsed >= goal) (if (sending) "正在打卡…" else "完成打卡") else "满 ${goal / 60} 分钟就能打卡",
                color = if (elapsed >= goal) Palette.pine else Color(0xFF8FB5A6), height = 58.dp, enabled = elapsed >= goal, busy = sending) {
                sending = true; running = false
                val seconds = elapsed
                StoreHolder.scope.launch { store.submit(item, durationSeconds = seconds); prefs(context).edit().remove(key).apply(); sending = false }
            }
        }
    }
}

// ---------- Online: recording (reading aloud, recitation) ----------

@Composable private fun RecordingTaskView(item: RemoteHomework) {
    val store = LocalStore.current
    val context = LocalContext.current
    val recorder = remember { AudioRecorder(context) }
    val player = remember { AudioPlayer(context) }
    var recording by remember { mutableStateOf(false) }
    var seconds by remember { mutableIntStateOf(0) }
    var file by remember { mutableStateOf<File?>(null) }
    var playing by remember { mutableStateOf(false) }
    var denied by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }
    DisposableEffect(Unit) { player.onFinished = { playing = false }; onDispose { recorder.stop(); player.stop() } }
    LaunchedEffect(recording) { seconds = 0; while (recording) { delay(1000); seconds++ } }
    fun start() { player.stop(); playing = false; if (recorder.start()) { file = null; recording = true } else store.reportError("麦克风打不开，请稍后再试。") }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted -> denied = !granted; if (granted) start() }
    Column(Modifier.fillMaxSize().background(Palette.card, RoundedCornerShape(28.dp)).verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterVertically)) {
        Text(item.content, fontSize = 23.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
        when {
            recording -> Row(Modifier.background(Palette.warnSoft, CircleShape).padding(horizontal = 18.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(12.dp).background(Color(0xFFD9572B), CircleShape)); Spacer(Modifier.width(8.dp))
                Text("正在录音 %d:%02d".format(seconds / 60, seconds % 60), fontSize = 18.sp, color = Palette.warn)
            }
            file != null -> Text("录好了，可以先听一遍", fontSize = 18.sp, color = Palette.ink2)
            else -> Text("准备好就点“开始录音”，大声读出来", fontSize = 18.sp, color = Palette.ink2, textAlign = TextAlign.Center)
        }
        if (denied) Text("需要允许使用麦克风：请家长到 系统设置 → 应用 → 小熊伴学 → 权限 打开麦克风。", color = Palette.warn, textAlign = TextAlign.Center)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterHorizontally), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (recording) PrimaryButton("■ 录好了", color = Color(0xFFD9572B), height = 58.dp) { file = recorder.stop(); recording = false; if (file == null) store.reportError("录得太短了，再录一次吧。") }
            else {
                SecondaryButton(if (file == null) "● 开始录音" else "重新录", height = 58.dp) {
                    if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) start()
                    else permission.launch(Manifest.permission.RECORD_AUDIO)
                }
                file?.let { f ->
                    SecondaryButton(if (playing) "■ 停止" else "▶ 听一遍", height = 58.dp) { if (playing) { player.stop(); playing = false } else playing = player.play(f) }
                    PrimaryButton(if (sending) "正在交…" else "交给家长听", height = 58.dp, busy = sending) {
                        sending = true; player.stop(); playing = false
                        StoreHolder.scope.launch { store.submit(item, audio = f.readBytes()); f.delete(); sending = false }
                    }
                }
            }
        }
    }
}

// ---------- 奖励时间 ----------

@Composable private fun RewardView(child: RemoteChild) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var endsAt by remember { mutableLongStateOf(prefs(context).getLong("reward.endsAt.${child.id}", 0)) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { while (true) { now = System.currentTimeMillis(); delay(1000) } }
    val summary = state.rewards[child.id]
    val today = store.today
    val openToday = state.items(child.id).count { it.date == today && it.needsWork }
    val wide = isWide()
    val bank = @Composable { modifier: Modifier ->
        Column(modifier.background(Palette.ink, RoundedCornerShape(28.dp)).padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text("已经攒了", fontSize = 18.sp, color = Palette.onNight)
            Row(verticalAlignment = Alignment.Bottom) {
                Text("${summary?.balance ?: 0}", fontSize = 80.sp, fontWeight = FontWeight.Black, color = Palette.honey)
                Spacer(Modifier.width(8.dp)); Text("分钟", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Color.White, modifier = Modifier.padding(bottom = 16.dp))
            }
            Text("今天最多能用 ${state.rules.dailyCap} 分钟，已用 ${summary?.usedToday ?: 0} 分钟", color = Palette.onNight)
            HorizontalDivider(color = Color(0xFF3D3832))
            Text("最近怎么攒到的", fontWeight = FontWeight.Bold, color = Palette.onNight)
            summary?.entries.orEmpty().take(12).forEach { e ->
                Row { Text(rewardReason(e, state), color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text(if (e.minutes > 0) "+${e.minutes}" else "${e.minutes}", fontWeight = FontWeight.Bold, color = if (e.minutes > 0) Palette.honey else Palette.onNight) }
            }
        }
    }
    val use = @Composable { modifier: Modifier ->
        Column(modifier, verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (endsAt > now) {
                val left = ((endsAt - now) / 1000).toInt()
                Column(Modifier.fillMaxWidth().background(Palette.card, RoundedCornerShape(28.dp)).padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text("奖励时间进行中", fontSize = 28.sp, fontWeight = FontWeight.Bold)
                    Text("%d:%02d".format(left / 60, left % 60), fontSize = 76.sp, fontWeight = FontWeight.Black, color = Palette.pine)
                    Text("时间到了要放下设备休息哦。", color = Palette.ink2)
                }
            } else {
                if (state.rules.requireAllSubmitted && openToday > 0) Text("🔒 今天还有 $openToday 项作业没交，全部交完就能用奖励时间", fontSize = 17.sp, fontWeight = FontWeight.Medium, color = Palette.warn,
                    modifier = Modifier.fillMaxWidth().background(Palette.warnSoft, RoundedCornerShape(18.dp)).padding(16.dp))
                else Text("可以使用时段：${state.rules.windowStart}–${state.rules.windowEnd}", color = Palette.ink2)
                HCard(padding = 24.dp) {
                    Text("看动画、玩游戏", fontSize = 26.sp, fontWeight = FontWeight.Black)
                    Text("用攒到的时间，选好多久", color = Palette.ink2)
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        listOf(5, 10, 15).forEach { m ->
                            SecondaryButton("$m 分钟", Modifier.weight(1f), height = 58.dp, enabled = !busy && (summary?.balance ?: 0) >= m, compact = !wide) {
                                busy = true
                                store.launch({ busy = false }) {
                                    val session = startReward(child.id, m)
                                    val end = runCatching { Instant.parse(session.endsAt).toEpochMilli() }.getOrDefault(System.currentTimeMillis() + m * 60_000L)
                                    endsAt = end
                                    prefs(context).edit().putLong("reward.endsAt.${child.id}", end).apply()
                                }
                            }
                        }
                    }
                }
                Text("安卓版暂时不会锁住其他 App，时间到了要自觉放下设备哦。", fontSize = 13.sp, color = Palette.ink3, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            }
        }
    }
    if (wide) Row(Modifier.fillMaxSize().padding(horizontal = 24.dp).padding(bottom = 24.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
        bank(Modifier.width(400.dp).fillMaxHeight().verticalScroll(rememberScrollState())); use(Modifier.weight(1f))
    } else Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        use(Modifier.fillMaxWidth()); bank(Modifier.fillMaxWidth())
    }
}

// ---------- Device settings (parent only) ----------

@Composable private fun ChildSettings(onDismiss: () -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var unlocked by remember { mutableStateOf(false) }
    var confirmSignOut by remember { mutableStateOf(false) }
    val gate = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        if (r.resultCode == Activity.RESULT_OK) unlocked = true else store.reportError("没有通过家长验证。")
    }
    fun authenticate() {
        val intent = parentAuthIntent(context)
        if (intent != null) gate.launch(intent) else unlocked = true
    }
    LaunchedEffect(Unit) { authenticate() }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("家长设置") }, text = {
        if (unlocked) Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (!isDeviceSecure(context)) Text("这台设备没有设置锁屏密码，任何人都能打开家长设置。建议在系统设置里设一个。", color = Palette.warn, fontSize = 13.sp)
            LabeledRow("服务器", state.session?.server ?: "")
            LabeledRow("孩子", state.children.joinToString("、") { it.name })
            TextButton({ StoreHolder.scope.launch { store.sync() } }) { Text("立即同步") }
            Text("奖励时间：安卓版只记账和倒计时，暂不锁定其他 App。", fontSize = 13.sp, color = Palette.ink3)
            TextButton({ confirmSignOut = true }) { Text("断开这台设备", color = Palette.redPen) }
        } else Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Filled.Lock, null, tint = Palette.pine, modifier = Modifier.size(44.dp))
            Text("用这台设备的锁屏密码验证家长身份。", color = Palette.ink2, textAlign = TextAlign.Center)
            Button(::authenticate) { Text("验证家长身份") }
        }
    }, confirmButton = { TextButton(onDismiss) { Text("完成") } })
    if (confirmSignOut) AlertDialog(onDismissRequest = { confirmSignOut = false }, title = { Text("断开这台设备？") }, text = { Text("断开后需要家长重新生成配对码。") },
        confirmButton = { TextButton({ confirmSignOut = false; onDismiss(); store.launch { signOut() } }) { Text("断开", color = Palette.redPen) } },
        dismissButton = { TextButton({ confirmSignOut = false }) { Text("取消") } })
}
