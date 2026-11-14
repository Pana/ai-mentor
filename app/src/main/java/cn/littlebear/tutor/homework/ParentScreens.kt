package cn.littlebear.tutor.homework

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlinx.coroutines.launch

/** Screens that cover the tabs. */
sealed interface ParentRoute {
    data class Detail(val id: String) : ParentRoute
    data class Edit(val id: String) : ParentRoute
    data class Review(val homeworkId: String, val submissionId: String) : ParentRoute
    data object Settings : ParentRoute
    data class EntryResult(val drafts: List<DraftItem>, val message: String) : ParentRoute
    data class RoutineEdit(val draft: RoutineDraft) : ParentRoute
}

enum class ParentTab(val label: String, val icon: ImageVector) {
    HOMEWORK("作业", Icons.AutoMirrored.Filled.List), ENTRY("录入", Icons.Filled.AddCircle),
    ROUTINES("每天坚持", Icons.Filled.Refresh), REWARDS("奖励", Icons.Filled.Star)
}

/** Parent app: 作业 · 录入 · 每天坚持 · 奖励. Bottom tabs on a phone, a side rail and list + detail on a tablet. */
@Composable fun ParentApp() {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    var tab by rememberSaveable { mutableStateOf(ParentTab.HOMEWORK) }
    var childId by rememberSaveable { mutableStateOf<String?>(null) }
    val child = state.child(childId) ?: state.children.firstOrNull()
    val stack = remember { mutableStateListOf<ParentRoute>() }
    val entry = remember { EntryForm() }
    val push: (ParentRoute) -> Unit = { stack.add(it) }
    val pop: () -> Unit = { if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) }
    BackHandler(stack.isNotEmpty()) { pop() }
    BackHandler(stack.isEmpty() && tab != ParentTab.HOMEWORK) { tab = ParentTab.HOMEWORK }
    val wide = isWide()

    when (val route = stack.lastOrNull()) {
        is ParentRoute.Edit -> state.homework[route.id]?.let { EditHomeworkView(it, pop) } ?: SideEffect { pop() }
        is ParentRoute.Review -> {
            val item = state.homework[route.homeworkId]
            val submission = item?.submissions?.firstOrNull { it.id == route.submissionId }
            if (item != null && submission != null) ReviewFlow(item, submission, onClose = pop) else SideEffect { pop() }
        }
        ParentRoute.Settings -> ParentSettings(pop)
        is ParentRoute.EntryResult -> EntryResult(route.drafts, route.message, entry, onBack = pop) {
            stack.clear(); entry.reset(); tab = ParentTab.HOMEWORK
        }
        is ParentRoute.RoutineEdit -> RoutineEditor(route.draft, pop)
        is ParentRoute.Detail -> if (!wide) ParentHomeworkDetail(route.id, pop, push) else { SideEffect { pop() } }
        null -> {
            var selected by rememberSaveable { mutableStateOf<String?>(null) }
            val page: @Composable (Modifier) -> Unit = { modifier ->
                Box(modifier) {
                    when (tab) {
                        ParentTab.HOMEWORK -> if (wide) Row(Modifier.fillMaxSize()) {
                            ParentOverview(child, { childId = it }, Modifier.weight(1f), selected, { selected = it }, push)
                            VerticalDivider(color = Palette.line)
                            Box(Modifier.weight(1.15f)) {
                                val id = selected?.takeIf { it in state.homework }
                                if (id != null) ParentHomeworkDetail(id, null, push)
                                else Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                                    BearView(80.dp); Spacer(Modifier.height(12.dp)); Text("选一项作业查看详情", color = Palette.ink3)
                                }
                            }
                        } else ParentOverview(child, { childId = it }, Modifier.fillMaxSize(), null, { push(ParentRoute.Detail(it)) }, push)
                        ParentTab.ENTRY -> ParentEntry(entry, push)
                        ParentTab.ROUTINES -> ParentRoutines(child, { childId = it }, push)
                        ParentTab.REWARDS -> ParentRewards(child) { childId = it }
                    }
                }
            }
            if (wide) Row(Modifier.fillMaxSize().systemBarsPadding()) {
                NavigationRail(containerColor = Palette.card, header = { BearView(44.dp) }) {
                    Spacer(Modifier.height(12.dp))
                    ParentTab.entries.forEach { t ->
                        NavigationRailItem(tab == t, { tab = t }, icon = { Icon(t.icon, null) }, label = { Text(t.label) })
                    }
                }
                page(Modifier.weight(1f).fillMaxHeight())
            } else Scaffold(containerColor = Palette.paper, bottomBar = {
                NavigationBar(containerColor = Palette.card) {
                    ParentTab.entries.forEach { t -> NavigationBarItem(tab == t, { tab = t }, icon = { Icon(t.icon, null) }, label = { Text(t.label) }) }
                }
            }) { padding -> page(Modifier.padding(padding).fillMaxSize()) }
        }
    }
}

/** Child switcher for parent pages; hidden with a single child. */
@Composable fun ChildSwitcher(child: RemoteChild?, onChange: (String) -> Unit) {
    val state by LocalStore.current.state.collectAsStateWithLifecycle()
    if (state.children.size > 1) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        state.children.forEach { c -> FilterChip(c.id == child?.id, { onChange(c.id) }, label = { Text(c.name) }) }
    }
}

@Composable private fun PageHeader(title: String, trailing: @Composable RowScope.() -> Unit = {}) {
    Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 12.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, fontSize = 30.sp, fontWeight = FontWeight.Black, color = Palette.ink, modifier = Modifier.weight(1f))
        trailing()
    }
}

// ---------- 作业: completion by date ----------

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun ParentOverview(child: RemoteChild?, onChild: (String) -> Unit, modifier: Modifier, selected: String?, open: (String) -> Unit, push: (ParentRoute) -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val today = store.today
    Column(modifier) {
        PageHeader("作业") {
            IconButton({ push(ParentRoute.Settings) }) { Icon(Icons.Filled.Settings, "设置", tint = Palette.ink2) }
        }
        Box(Modifier.padding(horizontal = 16.dp)) { ChildSwitcher(child, onChild) }
        PullToRefreshBox(state.syncing, { scope.launch { store.sync() } }, Modifier.fillMaxSize()) {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (state.children.isEmpty()) item {
                    HCard {
                        Text("先添加孩子", fontSize = 18.sp, fontWeight = FontWeight.Bold)
                        Text("在设置里添加孩子，再用配对码连接孩子的平板或手机。", color = Palette.ink2)
                        PrimaryButton("打开设置", height = 48.dp) { push(ParentRoute.Settings) }
                    }
                }
                if (child != null) {
                    val waiting = state.items(child.id).filter { it.awaitingReview }
                    waiting.lastOrNull()?.let { first ->
                        item {
                            Surface(onClick = { open(first.id) }, shape = RoundedCornerShape(20.dp), color = Palette.pine) {
                                Row(Modifier.padding(18.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Column(Modifier.weight(1f)) {
                                        Text("${waiting.size} 项作业等你批改", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                                        Text("${SubjectStyle.label(first.subject)} · ${first.content}", color = Color.White.copy(alpha = 0.85f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    }
                                    Text("去批改", color = Color.White, fontWeight = FontWeight.Bold)
                                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Color.White)
                                }
                            }
                        }
                    }
                    val groups = state.grouped(child.id) { it.date >= Day.add(today, -30) }
                    if (groups.isEmpty()) item { Text("还没有作业。到“录入”里粘贴老师发的作业。", color = Palette.ink2, modifier = Modifier.padding(8.dp)) }
                    groups.forEach { (day, items) ->
                        item(key = day) {
                            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                Row(Modifier.padding(horizontal = 8.dp)) {
                                    Text(Day.label(day, today), fontSize = 14.sp, color = Palette.ink3, modifier = Modifier.weight(1f))
                                    val regular = items.filter { !it.isRoutine }
                                    if (regular.isNotEmpty()) Text("交了 ${regular.count { !it.needsWork }} / ${regular.size}", fontSize = 14.sp, color = Palette.ink3)
                                }
                                Column(Modifier.fillMaxWidth().background(Palette.card, RoundedCornerShape(18.dp))) {
                                    items.forEachIndexed { i, item ->
                                        ParentRow(item, item.id == selected) { open(item.id) }
                                        if (i < items.lastIndex) HorizontalDivider(Modifier.padding(start = 16.dp), color = Palette.line)
                                    }
                                }
                            }
                        }
                    }
                }
                item { Box(Modifier.padding(8.dp)) { SyncFootnote() } }
            }
        }
    }
}

@Composable private fun ParentRow(item: RemoteHomework, selected: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(if (selected) Palette.pineSoft else Color.Transparent).clickable(onClick = onClick)
        .padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        SubjectTag(item.subject, 13.sp)
        Column(Modifier.weight(1f)) {
            Text(item.content, maxLines = 2, overflow = TextOverflow.Ellipsis, color = Palette.ink)
            if (item.isRoutine) Text("每天坚持", fontSize = 12.sp, color = Palette.honeyInk)
            else item.dueDate?.takeIf { it != item.date }?.let { Text("${Day.short(it)} 交", fontSize = 12.sp, color = Palette.ink3) }
        }
        when (item.status) {
            "SUBMITTED" -> Chip("待批改", Palette.waitInk, Palette.waitSoft, 13.sp)
            "NEEDS_CORRECTION" -> Chip("订正中", Palette.warn, Palette.warnSoft, 13.sp)
            "REVIEWED" -> item.latestReview?.let { GradeBadge(it.grade, 28.dp) } ?: Chip("已打卡", Palette.pine, Palette.pineSoft, 13.sp)
            else -> Text("未开始", fontSize = 13.sp, color = Palette.ink3)
        }
    }
}

// ---------- Homework detail (parent) ----------

@Composable fun ParentHomeworkDetail(id: String, onBack: (() -> Unit)?, push: (ParentRoute) -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val item = state.homework[id]
    var confirmDelete by remember { mutableStateOf(false) }
    val today = store.today
    if (item == null) { Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("作业已删除", color = Palette.ink3) }; return }
    FormScaffold(SubjectStyle.label(item.subject), onBack) {
        FormSection {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { SubjectTag(item.subject, 13.sp); Chip(modeLabel(item), size = 13.sp) }
            Text(item.content, fontSize = 20.sp, color = Palette.ink)
            LabeledRow("布置日期", Day.label(item.date, today))
            item.dueDate?.let { LabeledRow("老师要求", "${Day.label(it, today)} 交") }
            if (item.parentTodo.isNotEmpty()) Text("家长要做：${item.parentTodo}", color = Palette.honeyInk)
            if (item.rawText.isNotEmpty()) {
                var open by remember { mutableStateOf(false) }
                Text(if (open) "收起老师原话" else "查看老师原话", color = Palette.pine, modifier = Modifier.clickable { open = !open })
                if (open) Text(item.rawText, fontSize = 13.sp, color = Palette.ink2)
            }
        }
        if (item.attachmentIds.isNotEmpty()) FormSection("附带图片") {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                item.attachmentIds.forEach { Thumb(Modifier.size(96.dp)) { RemoteImage(it, Modifier.fillMaxSize(), ContentScale.Crop, 400) } }
            }
        }
        item.submissions.reversed().forEach { submission ->
            FormSection(if (submission.attempt == 1) "提交" else "第 ${submission.attempt} 次提交（订正）") {
                SubmissionSummary(item, submission, state.timeZone)
                if (submission.id == item.latest?.id && item.awaitingReview) {
                    PrimaryButton("开始批改", Modifier.fillMaxWidth(), height = 50.dp) { push(ParentRoute.Review(item.id, submission.id)) }
                }
            }
        }
        if (item.submissions.isEmpty()) FormSection { Text("孩子还没有提交。", color = Palette.ink2) }
        FormSection {
            TextButton({ push(ParentRoute.Edit(item.id)) }) { Text("修改作业") }
            TextButton({ confirmDelete = true }) { Text("删除作业", color = Palette.redPen) }
        }
    }
    if (confirmDelete) AlertDialog(onDismissRequest = { confirmDelete = false }, title = { Text("删除这项作业？") },
        text = { Text("会同时删除孩子提交的照片、录音和批改，奖励记录保留。") },
        confirmButton = { TextButton({ confirmDelete = false; store.launch({ if (it) onBack?.invoke() }) { delete(id) } }) { Text("删除", color = Palette.redPen) } },
        dismissButton = { TextButton({ confirmDelete = false }) { Text("取消") } })
}

@Composable fun LabeledRow(label: String, value: String) {
    Row { Text(label, color = Palette.ink2, modifier = Modifier.weight(1f)); Text(value, color = Palette.ink) }
}

@Composable private fun SubmissionSummary(item: RemoteHomework, submission: Submission, zone: String) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(submitTime(submission, zone), fontSize = 15.sp)
            if (!item.isRoutine) {
                if (submission.onTime) Chip("按时", Palette.pine, Palette.pineSoft, 12.sp) else Chip("晚交", Palette.warn, Palette.warnSoft, 12.sp)
            }
        }
        submission.durationSeconds?.let { Text("计时 ${it / 60} 分 ${it % 60} 秒", color = Palette.ink2) }
        if (item.isRecording) submission.fileIds.firstOrNull()?.let { AudioPlayerButton(it) }
        if (item.isOffline) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            submission.fileIds.forEachIndexed { i, file -> Thumb(Modifier.size(120.dp, 160.dp)) { AnnotatedPage(file, overlayFile(submission, i), Modifier.fillMaxSize()) } }
        }
        submission.review?.let { review ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                GradeBadge(review.grade, 34.dp)
                Column {
                    if (review.comment.isNotEmpty()) Text(review.comment)
                    if (review.requireCorrection) Text("要求订正后再交", fontSize = 13.sp, color = Palette.warn)
                }
            }
        }
    }
}

// ---------- Drafts shared by 录入 and 修改 ----------

/** How a homework item gets done. */
enum class DoneBy(val label: String, val mode: String, val onlineKind: String?) {
    PHOTO("本子上写，拍照交", "OFFLINE", null), TIMER("在线计时", "ONLINE", "TIMER"), RECORDING("在线录音", "ONLINE", "RECORDING");
    val usesDuration get() = this == TIMER
    companion object { fun of(mode: String, onlineKind: String?) = if (mode == "OFFLINE") PHOTO else if (onlineKind == "TIMER") TIMER else RECORDING }
}

data class DraftItem(
    val key: String = newId(), val subject: String = "MATH", val content: String = "", val date: String = "",
    val hasDue: Boolean = false, val dueDate: String = "", val kind: DoneBy = DoneBy.PHOTO, val minutes: Int = 10,
    val parentTodo: String = "", val attachImages: Boolean = false,
) {
    companion object {
        fun from(parsed: ParsedItem, date: String, attachImages: Boolean) = DraftItem(subject = parsed.subject, content = parsed.content, date = date,
            hasDue = parsed.dueDate != null, dueDate = parsed.dueDate ?: Day.add(date, 1), kind = if (parsed.mode == "OFFLINE") DoneBy.PHOTO else DoneBy.RECORDING,
            parentTodo = parsed.parentTodo, attachImages = attachImages)
        fun from(item: RemoteHomework) = DraftItem(subject = item.subject, content = item.content, date = item.date, hasDue = item.dueDate != null,
            dueDate = item.dueDate ?: Day.add(item.date, 1), kind = DoneBy.of(item.mode, item.onlineKind), minutes = item.durationMinutes ?: 10, parentTodo = item.parentTodo)
        fun blank(today: String, attach: Boolean = false) = DraftItem(date = today, dueDate = Day.add(today, 1), attachImages = attach)
    }
}

@Composable fun ChoiceRow(options: List<Pair<String, String>>, selected: String, onSelect: (String) -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        options.forEach { (value, label) -> FilterChip(value == selected, { onSelect(value) }, label = { Text(label) }) }
    }
}

@Composable fun Stepper(label: String, value: Int, range: IntRange, step: Int = 1, onChange: (Int) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        OutlinedIconButton({ onChange((value - step).coerceIn(range)) }, enabled = value > range.first) { Text("−", fontSize = 20.sp) }
        Spacer(Modifier.width(8.dp))
        OutlinedIconButton({ onChange((value + step).coerceIn(range)) }, enabled = value < range.last) { Icon(Icons.Filled.Add, "加") }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun DayField(label: String, day: String, minDay: String? = null, onChange: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clickable { open = true }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Text(Day.parse(day)?.let { "${it.monthValue} 月 ${it.dayOfMonth} 日 周${Day.weekdayNames[Day.weekday(day)]}" } ?: "选择日期", color = Palette.pine, fontWeight = FontWeight.SemiBold)
    }
    if (open) {
        val millis = Day.parse(day)?.atStartOfDay(ZoneOffset.UTC)?.toInstant()?.toEpochMilli()
        val min = minDay?.let(Day::parse)?.atStartOfDay(ZoneOffset.UTC)?.toInstant()?.toEpochMilli()
        val picker = rememberDatePickerState(millis, selectableDates = object : SelectableDates {
            override fun isSelectableDate(utcTimeMillis: Long) = min == null || utcTimeMillis >= min
        })
        DatePickerDialog(onDismissRequest = { open = false }, confirmButton = {
            TextButton({ picker.selectedDateMillis?.let { onChange(Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate().toString()) }; open = false }) { Text("好") }
        }, dismissButton = { TextButton({ open = false }) { Text("取消") } }) { DatePicker(picker) }
    }
}

@Composable fun DraftFields(draft: DraftItem, imageCount: Int, onChange: (DraftItem) -> Unit) {
    ChoiceRow(SubjectStyle.all.map { it to SubjectStyle.label(it) }, draft.subject) { onChange(draft.copy(subject = it)) }
    OutlinedTextField(draft.content, { onChange(draft.copy(content = it.take(2000))) }, Modifier.fillMaxWidth(), label = { Text("作业内容") }, minLines = 2, maxLines = 8)
    ChoiceRow(DoneBy.entries.map { it.name to it.label }, draft.kind.name) { onChange(draft.copy(kind = DoneBy.valueOf(it))) }
    if (draft.kind.usesDuration) Stepper("时长 ${draft.minutes} 分钟", draft.minutes, 1..120) { onChange(draft.copy(minutes = it)) }
    DayField("布置日期", draft.date) { onChange(draft.copy(date = it, dueDate = maxOf(draft.dueDate, it))) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("老师要求的交作业日期", Modifier.weight(1f)); Switch(draft.hasDue, { onChange(draft.copy(hasDue = it)) })
    }
    if (draft.hasDue) DayField("交作业日期", draft.dueDate, minDay = draft.date) { onChange(draft.copy(dueDate = it)) }
    OutlinedTextField(draft.parentTodo, { onChange(draft.copy(parentTodo = it.take(500))) }, Modifier.fillMaxWidth(), label = { Text("家长要做的事（例如签字）") }, singleLine = true)
    if (imageCount > 0) Row(verticalAlignment = Alignment.CenterVertically) {
        Text("附上 $imageCount 张图片", Modifier.weight(1f)); Switch(draft.attachImages, { onChange(draft.copy(attachImages = it)) })
    }
}

@Composable private fun EditHomeworkView(item: RemoteHomework, onDone: () -> Unit) {
    val store = LocalStore.current
    var draft by remember(item.id) { mutableStateOf(DraftItem.from(item)) }
    var saving by remember { mutableStateOf(false) }
    FormScaffold("修改作业", onDone) {
        FormSection { DraftFields(draft, 0) { draft = it } }
        PrimaryButton(if (saving) "正在保存…" else "保存", Modifier.fillMaxWidth(), busy = saving, enabled = draft.content.isNotBlank()) {
            saving = true
            store.launch({ saving = false; if (it) onDone() }) {
                update(item.id, HomeworkStore.HomeworkPatch(draft.content.trim(), draft.subject, draft.date, if (draft.hasDue) maxOf(draft.dueDate, draft.date) else null,
                    draft.kind.mode, draft.kind.onlineKind, if (draft.kind.usesDuration) draft.minutes else null, draft.parentTodo.trim()))
            }
        }
    }
}

// ---------- 录入: paste the teacher's message → AI clean-up → check → save ----------

/** Kept across tab switches, like the iOS form that keeps its rows until the next entry. */
class EntryForm {
    var text by mutableStateOf("")
    val images = mutableStateListOf<ByteArray>()
    var childIds by mutableStateOf(setOf<String>())
    fun reset() { text = ""; images.clear() }
}

@Composable private fun ParentEntry(form: EntryForm, push: (ParentRoute) -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var cameraFile by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(state.children) { if (form.childIds.isEmpty()) state.children.firstOrNull()?.let { form.childIds = setOf(it.id) } }
    fun add(uri: Uri) = scope.launch { if (form.images.size < 6) Photos.prepare(context, uri)?.let { form.images.add(it) } ?: store.reportError("这张图片读不出来，换一张试试。") }
    val gallery = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(6)) { uris -> uris.take(6 - form.images.size).forEach { add(it) } }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        cameraFile?.let { path -> val file = java.io.File(path); if (ok) scope.launch { Photos.prepare(context, Uri.fromFile(file))?.let { form.images.add(it) }; file.delete() } else file.delete() }
        cameraFile = null
    }
    Column(Modifier.fillMaxSize()) {
        PageHeader("录入作业")
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp).wrapContentWidth(Alignment.CenterHorizontally).widthIn(max = 640.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            FormSection {
                if (state.children.isEmpty()) Text("先在“作业 → 设置”里添加孩子。", color = Palette.ink2)
                Row(Modifier.horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("给", color = Palette.ink2)
                    state.children.forEach { c ->
                        val on = c.id in form.childIds
                        FilterChip(on, { form.childIds = if (on) form.childIds - c.id else form.childIds + c.id }, label = { Text(c.name) })
                    }
                }
            }
            FormSection("老师发的作业", "直接从班级群复制过来就行，口语和表情 AI 会整理掉。") {
                OutlinedTextField(form.text, { form.text = it.take(5000) }, Modifier.fillMaxWidth(), minLines = 6, placeholder = { Text("粘贴老师在群里发的作业") })
                TextButton({ clipboard.getText()?.text?.let { form.text = it.take(5000) } }) { Text("从剪贴板粘贴") }
            }
            FormSection("图片（选填）", "作业单、课本页。最多 6 张。") {
                if (form.images.isNotEmpty()) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    form.images.forEachIndexed { i, data ->
                        Box {
                            val bitmap = remember(data) { decodeBitmap(data, 300) }
                            Thumb(Modifier.size(76.dp)) { bitmap?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) } }
                            IconButton({ form.images.removeAt(i) }, Modifier.align(Alignment.TopEnd).size(28.dp).background(Color.Black.copy(alpha = 0.5f), CircleShape)) {
                                Icon(Icons.Filled.Close, "删除图片", tint = Color.White, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton({ gallery.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }, enabled = form.images.size < 6) { Text("从相册选图片") }
                    OutlinedButton({
                        val file = Photos.captureFile(context); cameraFile = file.absolutePath
                        try { camera.launch(FileProvider.getUriForFile(context, "${context.packageName}.files", file)) } catch (_: Exception) { store.reportError("无法打开相机，请从相册选择。") }
                    }, enabled = form.images.size < 6) { Text("拍作业单") }
                }
            }
            PrimaryButton(if (busy) "AI 正在整理…" else "让 AI 整理", Modifier.fillMaxWidth(), busy = busy, enabled = form.childIds.isNotEmpty() && form.text.isNotBlank()) {
                busy = true
                store.launch({ busy = false }) {
                    val result = parse(form.text)
                    val today = this.today
                    val drafts = result.items.mapIndexed { i, p -> DraftItem.from(p, today, i == 0 && form.images.isNotEmpty()) }
                    push(ParentRoute.EntryResult(drafts.ifEmpty { listOf(DraftItem.blank(today, form.images.isNotEmpty())) }, result.message))
                }
            }
            SecondaryButton("不用 AI，手动填写", Modifier.fillMaxWidth(), enabled = !busy && form.childIds.isNotEmpty()) {
                push(ParentRoute.EntryResult(listOf(DraftItem.blank(store.today, form.images.isNotEmpty())), ""))
            }
        }
    }
}

@Composable private fun EntryResult(initial: List<DraftItem>, message: String, form: EntryForm, onBack: () -> Unit, onSaved: () -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val drafts = remember(initial) { initial.toMutableStateList() }
    var saving by remember { mutableStateOf(false) }
    val names = state.children.filter { it.id in form.childIds }.joinToString("、") { it.name }
    val valid = drafts.none { it.content.isBlank() }
    FormScaffold("核对作业", onBack) {
        if (message.isNotEmpty()) Text("✨ $message", color = Palette.ink2)
        drafts.forEachIndexed { i, draft ->
            FormSection(SubjectStyle.label(draft.subject)) {
                DraftFields(draft, form.images.size) { drafts[i] = it }
                if (drafts.size > 1) TextButton({ drafts.removeAt(i) }) { Text("删除这一项", color = Palette.redPen) }
            }
        }
        TextButton({ drafts.add(DraftItem.blank(store.today)) }) { Icon(Icons.Filled.Add, null); Text("再加一项") }
        PrimaryButton(if (saving) "正在保存…" else "加入${names}的作业（${drafts.size} 项）", Modifier.fillMaxWidth(), busy = saving, enabled = valid) {
            saving = true
            val images = form.images.toList()
            store.launch({ saving = false; if (it) onSaved() }) {
                val attachments = if (drafts.any { it.attachImages }) uploadImages(images) else emptyList()
                val items = state.children.filter { it.id in form.childIds }.flatMap { child ->
                    drafts.map { d ->
                        NewHomework(childId = child.id, subject = d.subject, date = d.date, dueDate = if (d.hasDue) maxOf(d.dueDate, d.date) else null,
                            content = d.content.trim(), rawText = form.text.take(5000), mode = d.kind.mode, onlineKind = d.kind.onlineKind,
                            durationMinutes = if (d.kind.usesDuration) d.minutes else null, parentTodo = d.parentTodo.trim(), attachmentIds = if (d.attachImages) attachments else emptyList())
                    }
                }
                create(items)
            }
        }
        Text("加入后，孩子的设备下次同步就能看到。", fontSize = 13.sp, color = Palette.ink3)
    }
}

// ---------- 每天坚持 ----------

data class RoutineDraft(
    val id: String = newId(), val isNew: Boolean = true, val childId: String = "", val title: String = "", val subject: String = "ENGLISH",
    val kind: DoneBy = DoneBy.TIMER, val minutes: Int = 5, val weekdays: Set<Int> = (0..6).toSet(), val active: Boolean = true, val sortOrder: Int = 0,
) {
    companion object {
        fun from(r: Routine) = RoutineDraft(r.id, false, r.childId, r.title, r.subject, DoneBy.of(r.mode, r.onlineKind), r.durationMinutes ?: 5, r.weekdays.toSet(), r.active, r.sortOrder)
    }
    val summary: String get() {
        val days = when (weekdays) { (0..6).toSet() -> "每天"; (1..5).toSet() -> "周一到周五"; else -> "每周" + weekdays.sorted().joinToString("、") { Day.weekdayNames[it] } }
        return "$days · ${if (kind == DoneBy.TIMER) "在线计时 $minutes 分钟" else kind.label}"
    }
    val input get() = RoutineInput(childId, title.trim(), subject, kind.mode, kind.onlineKind, if (kind.usesDuration) minutes else null, null, weekdays.sorted(), active, sortOrder)
}

@Composable private fun ParentRoutines(child: RemoteChild?, onChild: (String) -> Unit, push: (ParentRoute) -> Unit) {
    val state by LocalStore.current.state.collectAsStateWithLifecycle()
    val mine = state.routines.filter { it.childId == child?.id }
    val active = mine.count { it.active }
    var warn by remember { mutableStateOf<RoutineDraft?>(null) }
    Column(Modifier.fillMaxSize()) {
        PageHeader("每天坚持")
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp).wrapContentWidth(Alignment.CenterHorizontally).widthIn(max = 640.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            ChildSwitcher(child, onChild)
            FormSection {
                Row { Text("启用 $active 项", fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f)); Text("建议 3 项，最多 5 项", fontSize = 13.sp, color = Palette.ink3) }
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    repeat(5) { i -> Box(Modifier.weight(1f).height(8.dp).background(if (i < active) Palette.pine else Color(0xFFF0E2C4), CircleShape)) }
                }
            }
            FormSection(footer = if (active >= 5) "已满 5 项。先暂停或删除一项再加。" else "每天坚持会按设定的日子自动出现在孩子的“今天”里。") {
                mine.forEach { r ->
                    Row(Modifier.fillMaxWidth().clickable { push(ParentRoute.RoutineEdit(RoutineDraft.from(r))) }.padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        SubjectTag(r.subject, 13.sp)
                        Column(Modifier.weight(1f)) {
                            Text(r.title, fontWeight = FontWeight.Bold, color = if (r.active) Palette.ink else Palette.ink3)
                            Text(RoutineDraft.from(r).summary, fontSize = 13.sp, color = Palette.ink2)
                        }
                        if (!r.active) Text("已暂停", fontSize = 13.sp, color = Palette.ink3)
                    }
                }
                if (child != null) TextButton({
                    val draft = RoutineDraft(childId = child.id, sortOrder = mine.size)
                    if (active >= 3) warn = draft else push(ParentRoute.RoutineEdit(draft))
                }, enabled = active < 5) { Icon(Icons.Filled.Add, null); Text("添加一项") }
            }
        }
    }
    warn?.let { draft ->
        AlertDialog(onDismissRequest = { warn = null }, title = { Text("项目有点多了") }, text = { Text("每天坚持太多，孩子容易坚持不下来。建议保持 3 项以内。") },
            confirmButton = { TextButton({ warn = null; push(ParentRoute.RoutineEdit(draft)) }) { Text("仍然添加") } },
            dismissButton = { TextButton({ warn = null }) { Text("取消") } })
    }
}

@Composable private fun RoutineEditor(initial: RoutineDraft, onDone: () -> Unit) {
    val store = LocalStore.current
    var draft by remember(initial.id) { mutableStateOf(initial) }
    var saving by remember { mutableStateOf(false) }
    FormScaffold(if (draft.isNew) "添加每天坚持" else "修改每天坚持", onDone) {
        FormSection {
            OutlinedTextField(draft.title, { draft = draft.copy(title = it.take(40)) }, Modifier.fillMaxWidth(), label = { Text("名称，例如：英语朗读 5 分钟") }, singleLine = true)
            ChoiceRow(SubjectStyle.all.map { it to SubjectStyle.label(it) }, draft.subject) { draft = draft.copy(subject = it) }
            ChoiceRow(DoneBy.entries.map { it.name to it.label }, draft.kind.name) { draft = draft.copy(kind = DoneBy.valueOf(it)) }
            if (draft.kind.usesDuration) Stepper("时长 ${draft.minutes} 分钟", draft.minutes, 1..120) { draft = draft.copy(minutes = it) }
        }
        FormSection("哪些天") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AssistChip({ draft = draft.copy(weekdays = (0..6).toSet()) }, label = { Text("每天") })
                AssistChip({ draft = draft.copy(weekdays = (1..5).toSet()) }, label = { Text("周一到周五") })
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf(1, 2, 3, 4, 5, 6, 0).forEach { d ->
                    val on = d in draft.weekdays
                    Surface(onClick = { draft = draft.copy(weekdays = if (on) draft.weekdays - d else draft.weekdays + d) }, modifier = Modifier.weight(1f).aspectRatio(1f),
                        shape = CircleShape, color = if (on) Palette.pine else Palette.chip) {
                        Box(contentAlignment = Alignment.Center) { Text(Day.weekdayNames[d], color = if (on) Color.White else Palette.ink, fontWeight = FontWeight.Bold) }
                    }
                }
            }
        }
        FormSection { Row(verticalAlignment = Alignment.CenterVertically) { Text("启用", Modifier.weight(1f)); Switch(draft.active, { draft = draft.copy(active = it) }) } }
        PrimaryButton(if (saving) "正在保存…" else "保存", Modifier.fillMaxWidth(), busy = saving, enabled = draft.title.isNotBlank() && draft.weekdays.isNotEmpty()) {
            saving = true
            store.launch({ saving = false; if (it) onDone() }) { saveRoutine(draft.id, draft.input) }
        }
        if (!draft.isNew) TextButton({ store.launch({ if (it) onDone() }) { deleteRoutine(draft.id) } }) { Text("删除", color = Palette.redPen) }
    }
}

// ---------- 奖励 ----------

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun ClockField(label: String, value: String, onChange: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clickable { open = true }.padding(vertical = 4.dp)) {
        Text(label, Modifier.weight(1f)); Text(value, color = Palette.pine, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
    }
    if (open) {
        val parts = value.split(":").mapNotNull { it.toIntOrNull() }
        val picker = rememberTimePickerState(parts.getOrElse(0) { 19 }, parts.getOrElse(1) { 0 }, is24Hour = true)
        AlertDialog(onDismissRequest = { open = false }, text = { TimePicker(picker) },
            confirmButton = { TextButton({ onChange("%02d:%02d".format(picker.hour, picker.minute)); open = false }) { Text("好") } },
            dismissButton = { TextButton({ open = false }) { Text("取消") } })
    }
}

@Composable private fun ParentRewards(child: RemoteChild?, onChild: (String) -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    var rules by remember { mutableStateOf(state.rules) }
    var saving by remember { mutableStateOf(false) }
    LaunchedEffect(state.rules) { if (!saving) rules = state.rules }
    val summary = child?.let { state.rewards[it.id] }
    Column(Modifier.fillMaxSize()) {
        PageHeader("奖励")
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp).wrapContentWidth(Alignment.CenterHorizontally).widthIn(max = 640.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            ChildSwitcher(child, onChild)
            if (summary != null) Row(Modifier.fillMaxWidth().background(Palette.ink, RoundedCornerShape(18.dp)).padding(18.dp)) {
                listOf(Triple("今天攒了", summary.earnedToday, Palette.honey), Triple("今天用了", summary.usedToday, Color.White), Triple("余额", summary.balance, Color.White)).forEach { (t, v, c) ->
                    Column(Modifier.weight(1f)) { Text(t, fontSize = 12.sp, color = Palette.onNight); Text("$v 分钟", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = c) }
                }
            }
            FormSection("怎么攒", "订正后评分提高，会补上差额。") {
                Stepper("按时交（${rules.finishTime} 前）+${rules.onTime}", rules.onTime, 0..60) { rules = rules.copy(onTime = it) }
                ClockField("每天完成时间", rules.finishTime) { rules = rules.copy(finishTime = it) }
                Stepper("评分 优 +${rules.gradeExcellent}", rules.gradeExcellent, 0..60) { rules = rules.copy(gradeExcellent = it) }
                Stepper("评分 良 +${rules.gradeGood}", rules.gradeGood, 0..60) { rules = rules.copy(gradeGood = it) }
                Stepper("评分 中 +${rules.gradeFair}", rules.gradeFair, 0..60) { rules = rules.copy(gradeFair = it) }
                Stepper("每天坚持打卡一项 +${rules.checkin}", rules.checkin, 0..60) { rules = rules.copy(checkin = it) }
                Stepper("连续打卡 7 天 +${rules.streak7}", rules.streak7, 0..120) { rules = rules.copy(streak7 = it) }
            }
            FormSection("怎么用") {
                Row(verticalAlignment = Alignment.CenterVertically) { Text("当天作业全交了才能用", Modifier.weight(1f)); Switch(rules.requireAllSubmitted, { rules = rules.copy(requireAllSubmitted = it) }) }
                Stepper("每天最多用 ${rules.dailyCap} 分钟", rules.dailyCap, 0..240, 5) { rules = rules.copy(dailyCap = it) }
                ClockField("可以用的开始时间", rules.windowStart) { rules = rules.copy(windowStart = it) }
                ClockField("结束时间", rules.windowEnd) { rules = rules.copy(windowEnd = it) }
            }
            PrimaryButton(if (saving) "正在保存…" else "保存规则", Modifier.fillMaxWidth(), busy = saving, enabled = rules != state.rules) {
                saving = true
                store.launch({ saving = false }) { saveRules(rules) }
            }
            Text("安卓版暂不锁定其他 App：奖励时间照常记账和倒计时，到点提醒孩子休息。", fontSize = 13.sp, color = Palette.ink3)
            if (summary != null && summary.entries.isNotEmpty()) FormSection("最近明细") {
                summary.entries.take(20).forEach { e ->
                    Row { Text(rewardReason(e, state), Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(if (e.minutes > 0) "+${e.minutes}" else "${e.minutes}", fontWeight = FontWeight.Bold, color = if (e.minutes > 0) Palette.honeyInk else Palette.ink2) }
                }
            }
        }
    }
}

fun rewardReason(entry: RewardEntry, state: HomeworkState): String {
    val name = state.homework[entry.refId.take(36)]?.let { "${SubjectStyle.label(it.subject)} · ${it.content.take(12)}" }
    return when (entry.reason) {
        "ON_TIME" -> "${name ?: "作业"} · 按时交"
        "GRADE" -> "${name ?: "作业"} · 评分"
        "CHECKIN" -> "${name ?: "每天坚持"} · 打卡"
        "STREAK7" -> "连续打卡 7 天"
        "SPEND" -> "使用奖励时间"
        else -> entry.reason
    }
}

// ---------- Settings: children, pairing, devices ----------

@Composable private fun ParentSettings(onBack: () -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    var code by remember { mutableStateOf<PairingCode?>(null) }
    var devices by remember { mutableStateOf<List<DeviceRecord>>(emptyList()) }
    var editing by remember { mutableStateOf<RemoteChild?>(null) }
    var adding by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<RemoteChild?>(null) }
    var confirmSignOut by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { devices = runCatching { store.devices() }.getOrDefault(emptyList()) }
    FormScaffold("设置", onBack) {
        FormSection("孩子") {
            state.children.forEach { c ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.clickable { editing = c }) {
                    Avatar(c, 32.dp); Text(c.name, Modifier.weight(1f)); Text("${c.grade} 年级", color = Palette.ink2)
                    IconButton({ deleting = c }) { Icon(Icons.Filled.Close, "删除${c.name}", tint = Palette.ink3) }
                }
            }
            TextButton({ adding = true }) { Icon(Icons.Filled.Add, null); Text("添加孩子") }
        }
        FormSection("连接孩子的设备") {
            code?.let {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(it.code, fontSize = 44.sp, fontWeight = FontWeight.Black, fontFamily = FontFamily.Monospace, letterSpacing = 6.sp)
                    Text("在孩子的平板或手机上输入，10 分钟内有效", fontSize = 13.sp, color = Palette.ink2)
                }
            }
            TextButton({ store.launch { code = pairingCode() } }) { Text(if (code == null) "生成配对码" else "重新生成") }
        }
        FormSection("已连接的设备") {
            devices.forEach { d ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(d.name.ifEmpty { if (d.role == "parent") "家长手机" else "孩子设备" })
                        Text((if (d.role == "parent") "家长" else "孩子") + if (d.isSelf) " · 这台设备" else "", fontSize = 12.sp, color = Palette.ink3)
                    }
                    if (!d.isSelf) TextButton({ store.launch { revoke(d.id); devices = devices() } }) { Text("断开", color = Palette.redPen) }
                }
            }
        }
        FormSection {
            LabeledRow("服务器", state.session?.server ?: "")
            TextButton({ confirmSignOut = true }) { Text("退出这台设备", color = Palette.redPen) }
        }
    }
    if (adding || editing != null) ChildEditor(editing) { adding = false; editing = null }
    deleting?.let { c ->
        AlertDialog(onDismissRequest = { deleting = null }, title = { Text("删除${c.name}的全部数据？") }, text = { Text("会删除这个孩子的作业、照片、录音、批改和奖励，不能恢复。") },
            confirmButton = { TextButton({ deleting = null; store.launch { deleteChild(c.id) } }) { Text("删除", color = Palette.redPen) } },
            dismissButton = { TextButton({ deleting = null }) { Text("取消") } })
    }
    if (confirmSignOut) AlertDialog(onDismissRequest = { confirmSignOut = false }, title = { Text("退出这台设备？") }, text = { Text("退出后需要用家长密钥重新连接。") },
        confirmButton = { TextButton({ confirmSignOut = false; store.launch { signOut() } }) { Text("退出", color = Palette.redPen) } },
        dismissButton = { TextButton({ confirmSignOut = false }) { Text("取消") } })
}

@Composable private fun ChildEditor(child: RemoteChild?, onDone: () -> Unit) {
    val store = LocalStore.current
    var name by remember { mutableStateOf(child?.name ?: "") }
    var grade by remember { mutableIntStateOf(child?.grade ?: 2) }
    AlertDialog(onDismissRequest = onDone, title = { Text(if (child == null) "添加孩子" else "修改孩子") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(name, { name = it.take(20) }, label = { Text("昵称") }, singleLine = true)
            ChoiceRow((1..6).map { "$it" to "$it 年级" }, "$grade") { grade = it.toInt() }
        }
    }, confirmButton = {
        TextButton({ store.launch({ if (it) onDone() }) { saveChild(child?.id ?: newId(), name, grade) } }, enabled = name.isNotBlank()) { Text("保存") }
    }, dismissButton = { TextButton(onDone) { Text("取消") } })
}
