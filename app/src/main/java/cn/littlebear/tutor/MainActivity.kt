package cn.littlebear.tutor

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.speech.tts.TextToSpeech
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { BearTheme { TutorApp() } }
    }
}

enum class Page { ENTRY, HOME, TASKS, PRACTICE, KNOWLEDGE, STUDY, PARENT }

@Composable fun TutorApp(store: FamilyStore = viewModel()) {
    val family by store.family.collectAsStateWithLifecycle()
    val ready by store.ready.collectAsStateWithLifecycle()
    val error by store.error.collectAsStateWithLifecycle()
    var page by rememberSaveable { mutableStateOf(Page.ENTRY) }
    var childID by rememberSaveable { mutableStateOf<String?>(null) }
    var taskID by rememberSaveable { mutableStateOf<String?>(null) }
    var previousStore by rememberSaveable { mutableStateOf(store.instanceID) }
    var parentUnlocked by remember { mutableStateOf(false) }
    var addTask by rememberSaveable { mutableStateOf(false) }
    var addChild by rememberSaveable { mutableStateOf(false) }
    var confirmReset by remember { mutableStateOf(false) }
    var externalActivity by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val child = family.children.find { it.id == childID }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(page, childID) { onDispose { store.cancelTutor() } }
    val gate = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) { parentUnlocked = true; page = Page.PARENT }
        else store.reportError("未完成家长验证，仍停留在当前页面。")
    }
    val openParent: () -> Unit = {
        if (family.demo) { parentUnlocked = true; page = Page.PARENT }
        else {
            val manager = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            if (manager.isDeviceSecure) {
                @Suppress("DEPRECATION")
                val intent = manager.createConfirmDeviceCredentialIntent("家长验证", "请使用设备锁屏凭据进入家长空间")
                if (intent != null) gate.launch(intent) else store.reportError("此设备暂不支持身份验证")
            } else store.reportError("请先在系统设置中设置锁屏密码，再建立家庭档案；也可以体验示例家庭。")
        }
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP && !externalActivity) {
                store.cancelTutor()
                parentUnlocked = false
                if (page == Page.PARENT) { page = Page.ENTRY; addTask = false; addChild = false; confirmReset = false }
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(ready, parentUnlocked) {
        if (page == Page.PARENT && !parentUnlocked) page = Page.ENTRY
    }
    LaunchedEffect(ready) {
        if (ready && previousStore != store.instanceID) {
            if (page == Page.STUDY) { page = Page.TASKS; taskID = null }
            previousStore = store.instanceID
        }
    }
    BackHandler(page != Page.ENTRY) {
        page = if (page == Page.STUDY) Page.TASKS else Page.ENTRY
        parentUnlocked = false
        addTask = false
        store.cancelTutor()
    }
    fun openTask(id: String) {
        val selected = child ?: return
        store.change({ state -> state.update(selected.id, id) {
            if (it.status == WorkStatus.READY) it.copy(status = WorkStatus.ACTIVE) else it
        } }) { taskID = id; page = Page.STUDY }
    }
    fun startPractice(subject: Subject, concept: String = "") {
        val selected = child ?: return
        if (!store.settings.value.consent) {
            page = Page.PRACTICE
            store.reportError("相似题需要先开启云端辅导，也可以先做本地基础练习。")
            return
        }
        store.requestTutor(selected, null, "practice", "请围绕${concept.ifBlank { subject.label + "基础知识" }}生成一道适合${selected.grade}年级的练习", subject = subject) { result ->
            val exercise = result.exercise?.copy(verified = false)
            if (exercise == null || exercise.subject != subject || exercise.hints.size != 3 || exercise.answer.isBlank()) store.reportError("这次练习生成不完整，请重试。")
            else {
                val work = Homework(childID = selected.id, subject = subject, title = exercise.concept, instructions = "AI 生成练习，答案供参考；疑问请向家长核对", generated = exercise, exerciseID = exercise.id, practice = true)
                store.change({ it.addTask(work) }) { openTask(work.id) }
            }
        }
    }
    Surface(Modifier.fillMaxSize(), color = Paper) {
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            if (family.demo) Row(Modifier.fillMaxWidth().background(Color(0xFFF0E5CD)).padding(horizontal = 24.dp, vertical = 7.dp),
                horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text("示例家庭 · 可体验本地练习与学习流程", fontSize = 12.sp, color = Ochre)
                Text("仅在本机保存", fontSize = 12.sp, color = Ochre)
            }
            if (!ready) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            else if (page == Page.ENTRY || (child == null && page != Page.PARENT)) {
                Entry(family, onSelect = { childID = it; page = Page.HOME }, onParent = openParent,
                    onDemo = { store.change({ check(it.children.isEmpty()); demoFamily() }) }, onReset = { openParent() })
            } else if (page == Page.PARENT && parentUnlocked) {
                ParentSpace(family, childID, store, onSelect = { childID = it },
                    onBack = { parentUnlocked = false; page = Page.ENTRY }, onAddChild = { addChild = true },
                    onAddTask = { addTask = true }, onReset = { confirmReset = true })
            } else if (child != null) {
                BoxWithConstraints(Modifier.weight(1f)) {
                    val wide = maxWidth >= 900.dp
                    Row(Modifier.fillMaxSize()) {
                        if (wide && page != Page.STUDY) Sidebar(child, page, onPage = { page = it }, onSwitch = {
                            page = Page.ENTRY; taskID = null; parentUnlocked = false
                        }, onParent = openParent)
                        Column(Modifier.weight(1f).fillMaxHeight().padding(if (wide) 28.dp else 16.dp)) {
                            if (!wide && page != Page.STUDY) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                TextButton(onClick = { page = Page.ENTRY }) { Text("${child.name} · 切换孩子") }
                                TextButton(onClick = openParent) { Text("家长空间") }
                            }
                            when (page) {
                                Page.HOME -> ChildHome(child, family, onTask = ::openTask, onTasks = { page = Page.TASKS }, onPractice = { page = Page.PRACTICE })
                                Page.TASKS -> TaskList(child, family, onTask = ::openTask, onAdd = { addTask = true })
                                Page.PRACTICE -> Practice(child, family, store, onCloud = ::startPractice, onStart = { subject ->
                                    val existing = family.tasksFor(child.id).find { it.practice && it.subject == subject && it.exercise()?.verified != false && it.status != WorkStatus.DONE }
                                    if (existing != null) openTask(existing.id)
                                    else {
                                        val completed = family.tasksFor(child.id).filter { it.status == WorkStatus.DONE }.mapNotNull { it.exerciseID }.toSet()
                                        val exercise = Exercises.practice(subject, completed)
                                        run {
                                            val task = Homework(childID = child.id, subject = subject, title = "${subject.label} · 小练习",
                                                instructions = "本地基础练习，未对应学校教材", exerciseID = exercise.id, generated = exercise, practice = true)
                                            store.change({ it.addTask(task) }) { openTask(task.id) }
                                        }
                                    }
                                })
                                Page.KNOWLEDGE -> KnowledgeList(child, family, ::startPractice)
                                Page.STUDY -> {
                                    val task = family.tasksFor(child.id).find { it.id == taskID }
                                    if (task == null) Text("任务不存在，请返回作业列表。")
                                    else key(task.id) { Study(child, task, store, onBack = { page = Page.TASKS }, onPractice = { page = Page.PRACTICE }) }
                                }
                                else -> Unit
                            }
                            if (!wide && page != Page.STUDY) {
                                Spacer(Modifier.height(8.dp))
                                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                                    listOf(Page.HOME to "首页", Page.TASKS to "作业", Page.PRACTICE to "练习", Page.KNOWLEDGE to "进步").forEach { (p, label) ->
                                        TextButton(onClick = { page = p }) { Text(label, fontWeight = if (page == p) FontWeight.Bold else FontWeight.Normal) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if (addChild && parentUnlocked) ChildDialog(onDismiss = { addChild = false }, onSave = { name, grade ->
        store.change({ it.addChild(name, grade) }) { childID = store.family.value.children.last().id; addChild = false }
    })
    if (addTask && child != null) TaskDialog(child, store, onExternalActivity = { externalActivity = it }, onDismiss = { addTask = false }, onSave = { task ->
        store.change({ it.addTask(task) }) { addTask = false }
    })
    if (confirmReset && parentUnlocked) AlertDialog(onDismissRequest = { confirmReset = false }, title = { Text("删除这个家庭的本地记录？") },
        text = { Text("所有孩子的档案、作业、图片和学习记录将从本机删除。当前没有云端备份，此操作不可撤销。") },
        confirmButton = { TextButton(onClick = { store.reset { confirmReset = false; childID = null; page = Page.ENTRY; parentUnlocked = false } }) { Text("确认删除") } },
        dismissButton = { TextButton(onClick = { confirmReset = false }) { Text("保留记录") } })
    if (error != null) AlertDialog(onDismissRequest = store::clearError, title = { Text("小提示") }, text = { Text(error!!) },
        confirmButton = { TextButton(onClick = store::clearError) { Text("知道了") } })
}

@Composable private fun Entry(family: Family, onSelect: (String) -> Unit, onParent: () -> Unit, onDemo: () -> Unit, onReset: () -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(40.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Text("小 熊 伴 学", color = Forest, fontWeight = FontWeight.Bold, letterSpacing = 5.sp)
        Bear(Modifier.size(180.dp, 196.dp))
        Text(if (family.children.isEmpty()) "每一步，都有小熊陪你。" else "今天，和谁一起学习？", fontSize = 32.sp, fontWeight = FontWeight.Bold)
        Text("写作业 · 学会思考 · 看见进步", color = Muted)
        family.children.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) { row.forEach { child ->
                Card(onClick = { onSelect(child.id) }, colors = CardDefaults.cardColors(containerColor = Color.White), modifier = Modifier.width(180.dp)) {
                    Column(Modifier.padding(26.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(if (child.grade == 2) "🌱" else "🌻", fontSize = 38.sp)
                        Spacer(Modifier.height(12.dp))
                        Text(child.name, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                        Text("${child.grade} 年级", color = Muted)
                    }
                }
            } }
        }
        if (family.children.isEmpty()) {
            Button(onClick = onParent, contentPadding = PaddingValues(22.dp, 14.dp)) { Text("家长建立家庭档案") }
            OutlinedButton(onClick = onDemo) { Text("先体验示例家庭") }
        } else TextButton(onClick = onReset) { Icon(Icons.Default.Lock, null, Modifier.size(16.dp)); Text(" 进入家长空间") }
        Text("学习记录在本机 · 云端辅导需家长开启", color = Muted, fontSize = 12.sp)
    }
}

@Composable private fun Sidebar(child: Child, page: Page, onPage: (Page) -> Unit, onSwitch: () -> Unit, onParent: () -> Unit) {
    Column(Modifier.width(208.dp).fillMaxHeight().background(Color(0xFFEEF0E8)).padding(22.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("小熊伴学", fontWeight = FontWeight.Bold, fontSize = 22.sp, color = Forest)
        Text("一点一点，学会更多", color = Muted, fontSize = 12.sp)
        Spacer(Modifier.height(22.dp))
        Text("🌱  ${child.name}", fontSize = 23.sp, fontWeight = FontWeight.Bold)
        Text("石家庄 · ${child.grade} 年级", color = Muted, fontSize = 13.sp)
        Spacer(Modifier.height(18.dp))
        NavItem("学习首页", Icons.Default.Home, page == Page.HOME) { onPage(Page.HOME) }
        NavItem("我的作业", Icons.AutoMirrored.Filled.List, page == Page.TASKS) { onPage(Page.TASKS) }
        NavItem("练一练", Icons.Default.PlayArrow, page == Page.PRACTICE) { onPage(Page.PRACTICE) }
        NavItem("我的进步", Icons.Default.Star, page == Page.KNOWLEDGE) { onPage(Page.KNOWLEDGE) }
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onSwitch) { Text("切换孩子") }
        TextButton(onClick = onParent) { Icon(Icons.Default.Lock, null, Modifier.size(16.dp)); Text(" 家长空间") }
        Text("学习记录只在这台设备", fontSize = 11.sp, color = Muted)
    }
}

@Composable private fun NavItem(label: String, icon: ImageVector, selected: Boolean, onClick: () -> Unit) {
    Surface(onClick = onClick, color = if (selected) Forest else Color.Transparent, shape = RoundedCornerShape(14.dp)) {
        Row(Modifier.fillMaxWidth().padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(icon, null, tint = if (selected) Color.White else Muted, modifier = Modifier.size(20.dp))
            Text(label, color = if (selected) Color.White else Ink, fontSize = 14.sp)
        }
    }
}

@Composable private fun ColumnScope.ChildHome(child: Child, family: Family, onTask: (String) -> Unit, onTasks: () -> Unit, onPractice: () -> Unit) {
    val tasks = family.tasksFor(child.id).filterNot { it.practice }
    val done = tasks.count { it.status == WorkStatus.DONE }
    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(22.dp)) {
        SectionTitle("${child.name}，准备好一起探索了吗？", "今天也按自己的节奏，一件一件来。")
        Panel(color = Sage, modifier = Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Tag("小熊在这里陪你")
                    Text("遇到不会的，\n我们一起想办法。", fontSize = 30.sp, fontWeight = FontWeight.Bold, lineHeight = 42.sp)
                    Text("先试一试，再说说你的想法。", color = Muted)
                    Button(onClick = onTasks, contentPadding = PaddingValues(22.dp, 14.dp)) { Text("开始写作业  →") }
                }
                Bear(Modifier.size(170.dp, 190.dp))
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Text("我的作业", fontWeight = FontWeight.Bold, fontSize = 21.sp)
            Text("已完成 $done / ${tasks.size}", color = Muted)
        }
        if (tasks.isEmpty()) Panel(Modifier.fillMaxWidth()) { Text("今天还没有添加作业。可以请家长添加，也可以自己补充。") }
        tasks.filter { it.status != WorkStatus.DONE }.take(3).forEach { TaskCard(it) { onTask(it.id) } }
        StudySummary(child, family)
        OutlinedButton(onClick = onPractice) { Text("还有精力？来做一个小练习") }
    }
}

@Composable private fun TaskCard(task: Homework, onClick: () -> Unit) {
    Surface(onClick = onClick, color = Color.White, shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Box(Modifier.size(50.dp).background(task.subject.tint().copy(alpha = .1f), RoundedCornerShape(15.dp)), contentAlignment = Alignment.Center) {
                Text(when (task.subject) { Subject.MATH -> "＋"; Subject.CHINESE -> "文"; Subject.ENGLISH -> "Aa" }, color = task.subject.tint(), fontSize = 24.sp, fontWeight = FontWeight.Bold)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(task.title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                Text(task.instructions.ifEmpty { task.subject.label }, color = Muted, fontSize = 12.sp, maxLines = 2)
            }
            Tag(task.status.label, if (task.status == WorkStatus.CORRECTION) Ochre else Forest)
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = "打开作业", tint = Muted)
        }
    }
}

@Composable private fun ColumnScope.TaskList(child: Child, family: Family, onTask: (String) -> Unit, onAdd: () -> Unit) {
    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            SectionTitle("我的作业", "做完一项，就离今天的小目标近一步。")
            OutlinedButton(onClick = onAdd) { Text("＋ 补充作业") }
        }
        val tasks = family.tasksFor(child.id).filterNot { it.practice }
        if (tasks.isEmpty()) Text("还没有作业，点击“补充作业”添加。", color = Muted)
        tasks.forEach { TaskCard(it) { onTask(it.id) } }
    }
}

@Composable private fun ColumnScope.Practice(child: Child, family: Family, store: FamilyStore, onCloud: (Subject, String) -> Unit, onStart: (Subject) -> Unit) {
    val busy by store.busy.collectAsStateWithLifecycle()
    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        SectionTitle("练一练，再前进一步", "本地基础练习随时可用；开启云端辅导后可以生成相似题。")
        ReviewList(child, family, onCloud)
        if (busy) { LinearProgressIndicator(Modifier.fillMaxWidth()); TextButton(onClick = store::cancelTutor) { Text("停止生成") } }
        Subject.entries.forEach { subject ->
            Panel(Modifier.fillMaxWidth()) {
                Tag(subject.label, subject.tint())
                Text(when(subject) { Subject.MATH -> "换个问题，试试自己的方法"; Subject.CHINESE -> "读一小段，找到关键信息"; Subject.ENGLISH -> "想一想，拼出水果单词" }, fontSize = 21.sp, fontWeight = FontWeight.Bold)
                Text("已经记录 ${family.evidenceFor(child.id).count { family.tasksFor(child.id).find { work -> work.id == it.taskID }?.subject == subject }} 次作答", color = Muted)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { onStart(subject) }, enabled = !busy) { Text("本地基础练习") }
                    OutlinedButton(onClick = { onCloud(subject, "") }, enabled = !busy) { Text("生成新题") }
                }
            }
        }
    }
}

@Composable private fun ColumnScope.KnowledgeList(child: Child, family: Family, onPractice: (Subject, String) -> Unit) {
    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        SectionTitle("每一点进步，都有迹可循", "做完作业不等于已经掌握。我们也会记下你获得了哪些帮助。")
        KnowledgeCards(child, family)
        ReviewList(child, family, onPractice)
    }
}

@Composable private fun KnowledgeCards(child: Child, family: Family) {
    val knowledge = family.knowledge(child.id)
    if (knowledge.isEmpty()) Panel(Modifier.fillMaxWidth()) {
        Text("还没有足够的学习证据", fontWeight = FontWeight.Bold)
        Text("完成一次示例练习后，这里会记录你的回答、提示次数和下一步建议。真实作业的 AI 检查建议单独保存，不直接变成掌握结论。", color = Muted)
    }
    knowledge.forEach { item ->
        Panel(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) { Text("${item.subject?.label.orEmpty()} · ${item.concept}", fontWeight = FontWeight.Bold, fontSize = 19.sp); Tag(item.state) }
            item.evidence.takeLast(5).reversed().forEach { record ->
                val date = SimpleDateFormat("MM-dd HH:mm", Locale.CHINA).format(Date(record.time))
                Text("$date · ${if (record.correct) "答对" else "需要订正"} · ${if (record.independent) "独立完成" else "提示 ${record.hints} 次 / 此前尝试 ${record.priorFailures} 次"}", color = Muted, fontSize = 13.sp)
                Text("回答：${record.answer}${if (!record.verifiedExercise) " · AI 生成题，答案待核验" else ""}", fontSize = 14.sp)
                if (record.origin == "parent") Text("家长确认：${record.note}", color = Forest, fontSize = 13.sp)
            }
            Text("下一步：${if (item.state == "初步掌握") "过几天再试一道新题，看看是否还记得。" else "尝试一道不同的题，并说说你的思路。"}", color = Forest, fontSize = 14.sp)
        }
    }
}

@Composable private fun ParentSpace(family: Family, selectedID: String?, store: FamilyStore, onSelect: (String) -> Unit,
    onBack: () -> Unit, onAddChild: () -> Unit, onAddTask: () -> Unit, onReset: () -> Unit) {
    var deleteChild by remember { mutableStateOf<Child?>(null) }
    var editChild by remember { mutableStateOf<Child?>(null) }
    var editTask by remember { mutableStateOf<Homework?>(null) }
    var deleteTask by remember { mutableStateOf<Homework?>(null) }
    var reviewTask by remember { mutableStateOf<Homework?>(null) }
    val child = family.children.find { it.id == selectedID } ?: family.children.firstOrNull()
    LaunchedEffect(child?.id) { child?.let { onSelect(it.id) } }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(32.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            SectionTitle("家长空间", "了解学习过程，给孩子刚刚好的帮助。")
            TextButton(onClick = onBack) { Text("退出家长空间") }
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            family.children.forEach { c -> FilterChip(selected = child?.id == c.id, onClick = { onSelect(c.id) }, label = { Text("${c.name} · ${c.grade} 年级") }) }
            OutlinedButton(onClick = onAddChild) { Text("＋ 添加孩子") }
        }
        if (child != null) {
            Panel(Modifier.fillMaxWidth(), Sage) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("${child.name}的学习安排", fontWeight = FontWeight.Bold, fontSize = 24.sp)
                        Text("石家庄 · ${child.grade} 年级 · ${child.textbook}", color = Muted)
                    }
                    Button(onClick = onAddTask) { Text("＋ 添加作业") }
                }
                val tasks = family.tasksFor(child.id).filterNot { it.practice }
                Text("${tasks.count { it.status == WorkStatus.DONE }} 项已完成   /   ${tasks.count { it.status == WorkStatus.REVIEW }} 项待检查   /   ${tasks.size} 项作业", color = Forest)
            }
            TextButton(onClick = { editChild = child }) { Text("编辑档案、教材与休息时间") }
            StudySummary(child, family)
            Text("作业与订正", fontSize = 21.sp, fontWeight = FontWeight.Bold)
            family.tasksFor(child.id).filterNot { it.practice }.forEach { task ->
                Panel(Modifier.fillMaxWidth()) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) { Text(task.title, fontWeight = FontWeight.Bold); Tag(task.status.label) }
                    if (task.instructions.isNotBlank()) Text(task.instructions, color = Muted)
                    if (task.photo != null) LocalPhoto(store.photoFile(task.photo))
                    if (task.draft.isNotBlank()) Text("孩子的记录：${task.draft}")
                    if (task.reviewNote.isNotBlank()) Text("检查意见：${task.reviewNote}", color = Forest)
                    if (task.conversation.isNotEmpty()) {
                        Text("最近的辅导记录", fontWeight = FontWeight.Bold)
                        task.conversation.takeLast(3).forEach { Text("孩子：${it.question}\n小熊：${it.reply}", color = Muted) }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (task.status == WorkStatus.REVIEW) Button(onClick = { reviewTask = task }) { Text("检查并反馈") }
                        if (task.exercise() == null && task.status != WorkStatus.DONE) TextButton(onClick = { editTask = task }) { Text("修改") }
                        TextButton(onClick = { deleteTask = task }) { Text("删除") }
                    }
                }
            }
            Text("知识与学习依据", fontSize = 21.sp, fontWeight = FontWeight.Bold)
            KnowledgeCards(child, family)
            TextButton(onClick = { deleteChild = child }) { Text("删除${child.name}的档案与记录", color = Ochre) }
        } else Panel(Modifier.fillMaxWidth()) { Text("先添加一个孩子，开始安排学习。") }
        ServiceSettingsPanel(store, family.demo)
        Panel(Modifier.fillMaxWidth()) {
            Text("设备与数据", fontWeight = FontWeight.Bold, fontSize = 19.sp)
            Text("档案、照片和学习记录保存在应用私有目录。开启云端辅导后，仅在求助、识别或生成练习时发送所需内容。系统备份与设备迁移已禁用，卸载会丢失记录。", color = Muted)
            Text("支持系统相机、相册导入、云端识题、文字和语音输入。外接 USB 摄像头兼容性需要在目标平板验证；语音输入依赖系统识别服务。", color = Muted)
            if (family.demo) Text("示例家庭为公开演示入口，不启用家长身份验证。创建实际家庭前请先清空示例记录。", color = Ochre)
            OutlinedButton(onClick = onReset) { Text("清空本机家庭数据") }
        }
    }
    editChild?.let { c -> EditChildDialog(c, { editChild = null }) { revised ->
        store.change({ it.editChild(revised) }) { editChild = null }
    } }
    editTask?.let { task -> EditTaskDialog(task, { editTask = null }) { subject, title, instructions ->
        store.cancelTutor()
        store.change({ it.editTask(task.childID, task.id, subject, title, instructions) }) { editTask = null }
    } }
    reviewTask?.let { task -> ParentReviewDialog(task, { reviewTask = null }) { passed, note, concept, independent ->
        store.change({ it.parentReview(task.childID, task.id, passed, note, concept, independent) }) { reviewTask = null }
    } }
    deleteTask?.let { task -> AlertDialog(onDismissRequest = { deleteTask = null }, title = { Text("删除这项作业？") },
        text = { Text("会一并删除关联图片、辅导对话与学习证据。此操作不可撤销。") },
        confirmButton = { TextButton(onClick = { store.deleteTask(task.childID, task.id); deleteTask = null }) { Text("删除") } },
        dismissButton = { TextButton(onClick = { deleteTask = null }) { Text("取消") } }) }
    deleteChild?.let { c -> AlertDialog(onDismissRequest = { deleteChild = null }, title = { Text("删除${c.name}的档案？") },
        text = { Text("会删除这个孩子的所有作业、图片和学习记录，其他孩子不受影响。此操作不可撤销。") },
        confirmButton = { TextButton(onClick = { store.deleteChild(c.id); deleteChild = null }) { Text("确认删除") } },
        dismissButton = { TextButton(onClick = { deleteChild = null }) { Text("取消") } }) }
}

@Composable private fun ChildDialog(onDismiss: () -> Unit, onSave: (String, Int) -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    var grade by rememberSaveable { mutableIntStateOf(2) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("添加孩子") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            OutlinedTextField(name, { name = it.take(20) }, label = { Text("昵称") }, singleLine = true)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { (2..3).forEach { n -> FilterChip(grade == n, { grade = n }, label = { Text("$n 年级") }) } }
            Text("教材版本待学校确认后配置。每个孩子的记录独立保存。", color = Muted)
        }
    }, confirmButton = { Button(onClick = { onSave(name, grade) }, enabled = name.isNotBlank()) { Text("保存档案") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } })
}

@Composable private fun TaskDialog(child: Child, store: FamilyStore, onExternalActivity: (Boolean) -> Unit, onDismiss: () -> Unit, onSave: (Homework) -> Unit) {
    var title by rememberSaveable { mutableStateOf("") }
    var instructions by rememberSaveable { mutableStateOf("") }
    var subject by rememberSaveable { mutableStateOf(Subject.MATH) }
    var photo by rememberSaveable { mutableStateOf<String?>(null) }
    var importing by remember { mutableStateOf(false) }
    var cameraURI by rememberSaveable { mutableStateOf<String?>(null) }
    var active by remember { mutableStateOf(true) }
    val busy by store.busy.collectAsStateWithLifecycle()
    val serviceSettings by store.settings.collectAsStateWithLifecycle()
    var recognitionNote by remember { mutableStateOf("") }
    var recognized by remember { mutableStateOf(false) }
    var confirmed by remember { mutableStateOf(false) }
    val context = LocalContext.current
    DisposableEffect(Unit) { onDispose { active = false; store.cancelTutor(); store.discardPhoto(photo) } }
    fun importImage(uri: Uri) {
        importing = true
        store.importPhoto(uri, onFinished = {
            importing = false
            if (uri.toString() == cameraURI) File(context.cacheDir, "capture/capture.jpg").delete()
        }) { name ->
            if (!active) store.discardPhoto(name)
            else { store.discardPhoto(photo); photo = name; recognized = false; confirmed = false; recognitionNote = "" }
        }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        onExternalActivity(false)
        uri?.let { importImage(it) }
    }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { success ->
        onExternalActivity(false)
        if (success) cameraURI?.let { importImage(Uri.parse(it)) }
        else File(context.cacheDir, "capture/capture.jpg").delete()
    }
    AlertDialog(onDismissRequest = onDismiss, modifier = Modifier.widthIn(max = 680.dp), title = { Text("为${child.name}添加作业") }, text = {
        Column(Modifier.heightIn(max = 560.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { Subject.entries.forEach { s -> FilterChip(subject == s, { subject = s }, label = { Text(s.label) }) } }
            OutlinedTextField(title, { title = it.take(100) }, label = { Text("作业名称") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
            OutlinedTextField(instructions, { instructions = it.take(2000) }, label = { Text("页码、题号与完成要求") }, modifier = Modifier.fillMaxWidth(), minLines = 2)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(enabled = !importing, onClick = {
                    try { onExternalActivity(true); picker.launch("image/*") }
                    catch (e: Exception) { onExternalActivity(false); store.reportError("没有可用的图片选择应用。") }
                }) { Text("从相册选图") }
                OutlinedButton(enabled = !importing, onClick = {
                    try {
                        val dir = File(context.cacheDir, "capture").apply { mkdirs() }
                        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", File(dir, "capture.jpg"))
                        cameraURI = uri.toString(); onExternalActivity(true); camera.launch(uri)
                    } catch (e: Exception) { onExternalActivity(false); store.reportError("无法打开系统相机，请尝试从相册选择图片。") }
                }) { Text("拍照") }
            }
            if (photo != null) {
                LocalPhoto(store.photoFile(photo!!))
                Text("核对原图与任务要求，再确认加入作业。", color = Ochre, fontSize = 13.sp)
                if (serviceSettings.consent) OutlinedButton(enabled = !busy && !importing, onClick = {
                    store.requestTutor(child, null, "recognize", photo = photo, subject = subject) { result ->
                        if (active) {
                            title = result.title; instructions = result.instructions
                            subject = Subject.entries.find { it.name == result.subject } ?: subject
                            recognitionNote = result.message; recognized = true; confirmed = false
                        }
                    }
                }) { Text("识别作业要求（发送这张图片）") }
                if (recognitionNote.isNotBlank()) Text(recognitionNote, color = Forest)
                if (recognized) Row { Checkbox(confirmed, { confirmed = it }); Text("我已核对图片，并修正不清楚的内容") }
                TextButton(enabled = !busy, onClick = { store.discardPhoto(photo); photo = null; recognized = false; confirmed = false }) { Text("移除图片") }
            }
            if (importing || busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            Text("确认后才加入作业列表。识别需要发送本次图片，已有学习记录仍保存在本机。", color = Muted, fontSize = 12.sp)
        }
    }, confirmButton = { Button(enabled = title.isNotBlank() && !importing && !busy && (!recognized || confirmed), onClick = {
        onSave(Homework(childID = child.id, subject = subject, title = title.trim(), instructions = instructions.trim(), photo = photo))
    }) { Text("确认添加") } }, dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } })
}

@Composable private fun LocalPhoto(file: File) {
    var bitmap by remember(file.path) { mutableStateOf<android.graphics.Bitmap?>(null) }
    LaunchedEffect(file.path) {
        bitmap = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { BitmapFactory.decodeFile(file.path) }
    }
    bitmap?.let { Image(it.asImageBitmap(), "作业图片", Modifier.fillMaxWidth().heightIn(max = 260.dp), contentScale = ContentScale.Fit) }
}

@Composable private fun ColumnScope.Study(child: Child, task: Homework, store: FamilyStore, onBack: () -> Unit, onPractice: () -> Unit) {
    val exercise = task.exercise()
    var answer by rememberSaveable(task.id) { mutableStateOf(task.draft) }
    var paused by rememberSaveable(task.id) { mutableStateOf(false) }
    var ttsReady by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val tts = remember { TextToSpeech(context) { ttsReady = it == TextToSpeech.SUCCESS } }
    fun speakText(text: String) {
        if (!ttsReady) store.reportError("本机语音引擎尚未就绪，请检查系统文字转语音设置。")
        else {
            val voice = tts.voices?.firstOrNull { it.locale.language == "zh" && !it.isNetworkConnectionRequired }
            if (voice == null) store.reportError("没有可用的离线中文语音，请先安装离线中文语音包。")
            else { tts.voice = voice; tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, task.id) }
        }
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) { tts.stop(); paused = true } }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); tts.stop(); tts.shutdown() }
    }
    val message = when {
        paused -> "休息一下吧，我在这里等你。"
        task.status == WorkStatus.DONE -> exercise?.explanation ?: "家长已经确认完成。下次继续一起学习。"
        task.status == WorkStatus.REVIEW -> "已经记下啦，等待家长检查。"
        task.status == WorkStatus.CORRECTION -> "这次还需要再检查一下。可以看看提示，再试一次。"
        task.hints > 0 && exercise != null -> exercise.hints[(task.hints - 1).coerceAtMost(2)]
        else -> "先试着自己想一想。需要帮助时，我可以给你一点提示。"
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = { tts.stop(); onBack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, null); Text(" 返回作业") }
        Text("${child.name} · ${task.subject.label}", fontWeight = FontWeight.Bold)
        Tag(if (paused) "已暂停" else task.status.label)
    }
    StudyClock(child, task, store, paused) { paused = true; tts.stop() }
    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Panel(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(task.title, fontSize = 25.sp, fontWeight = FontWeight.Bold)
                Tag(if (exercise == null) "我的作业" else if (exercise.verified) "基础练习" else "AI 生成练习", task.subject.tint())
            }
            Text(exercise?.prompt ?: task.instructions.ifBlank { "按照作业要求在纸上完成，也可以在下方记录你的想法。" }, fontSize = 22.sp, lineHeight = 35.sp)
            if (task.photo != null) LocalPhoto(store.photoFile(task.photo))
            if (exercise == null && task.status != WorkStatus.DONE) TaskPhotoActions(child, task, store, !paused)
            if (exercise?.id in listOf("addition-42", "addition-53") && task.hints >= 2) {
                Text(if (exercise?.id == "addition-42") "24  +  10  +  8\n       34  +  8" else "36  +  10  +  7\n       46  +  7", fontSize = 30.sp, color = Forest, lineHeight = 42.sp)
            }
            OutlinedTextField(answer, {
                answer = it.take(2000)
                val draft = answer
                store.change({ state -> state.saveDraft(child.id, task.id, draft) })
            }, label = { Text(if (exercise != null) "写下你的答案" else "记录你的想法（可选）") },
                modifier = Modifier.fillMaxWidth(), enabled = !paused && task.status !in listOf(WorkStatus.DONE, WorkStatus.REVIEW))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(enabled = !paused && task.status !in listOf(WorkStatus.DONE, WorkStatus.REVIEW) && (exercise == null || answer.isNotBlank()), onClick = {
                    tts.stop()
                    store.change({ state -> if (exercise != null) state.check(child.id, task.id, answer)
                        else state.submit(child.id, task.id, answer) })
                }) { Text(if (exercise != null) "我写好了，检查一下" else "我写好了，请家长检查") }
                OutlinedButton(enabled = !paused && task.status != WorkStatus.DONE && exercise != null, onClick = {
                    tts.stop(); store.change({ it.hint(child.id, task.id) })
                }) { Text("给我一点提示") }
            }
            if (exercise == null) Text("可以请小熊给提示或检查建议，最终交给家长确认。", color = Muted, fontSize = 13.sp)
            if (exercise?.verified == false) Text("这是 AI 生成题，参考答案可能有误；结果不计入独立掌握证据。", color = Ochre)
            if (task.reviewNote.isNotBlank()) Text("家长的建议：${task.reviewNote}", color = Forest)
        }
        Panel(Modifier.fillMaxWidth(), Sage) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                Bear(Modifier.size(110.dp, 126.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("小熊陪你想一想", color = Forest, fontWeight = FontWeight.Bold)
                    Text(message, fontSize = 18.sp, lineHeight = 28.sp)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = {
                            if (!ttsReady) store.reportError("本机语音引擎尚未就绪，请检查系统文字转语音设置。")
                            else {
                                val voice = tts.voices?.firstOrNull { it.locale.language == "zh" && !it.isNetworkConnectionRequired }
                                if (voice == null) store.reportError("没有可用的离线中文语音，请先在系统中安装离线中文语音包。")
                                else { tts.voice = voice; tts.speak(message, TextToSpeech.QUEUE_FLUSH, null, task.id) }
                            }
                        }, enabled = !paused) { Text("朗读提示") }
                        TextButton(onClick = { tts.stop() }) { Text("停止朗读") }
                        TextButton(onClick = { tts.stop(); paused = !paused }) { Text(if (paused) "继续学习" else "休息一下") }
                    }
                }
            }
        }
        if (exercise == null) TutorPanel(child, task, store, paused, { tts.stop() }, { text -> speakText(text) })
        ScratchBoard(task.id, enabled = !paused)
        if (task.status == WorkStatus.DONE) Button(onClick = { tts.stop(); onPractice() }) { Text("再试一个小练习 →") }
        Text("相机仅在拍照时使用 · 语音输入可随时停止 · 离开页面暂停学习", color = Muted, fontSize = 12.sp)
    }
}

@Composable private fun ScratchBoard(taskID: String, enabled: Boolean) {
    val lines = remember(taskID) { mutableStateListOf<Pair<Offset, Offset>>() }
    Panel(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Text("草稿白板", fontWeight = FontWeight.Bold)
            TextButton(onClick = { lines.clear() }, enabled = enabled) { Text("清空") }
        }
        Canvas(Modifier.fillMaxWidth().height(160.dp).background(Paper, RoundedCornerShape(12.dp))
            .pointerInput(taskID, enabled) {
                if (enabled) detectDragGestures { change, drag ->
                    change.consume()
                    lines.add((change.position - drag) to change.position)
                }
            }) {
            for (x in 0..(size.width / 24).toInt()) for (y in 0..(size.height / 24).toInt()) drawCircle(Color(0xFFD8DFD3), 1f, Offset(x * 24f, y * 24f))
            lines.forEach { (a, b) -> drawLine(Forest, a, b, strokeWidth = 4f, cap = StrokeCap.Round) }
        }
        Text("可以用手指或触控笔画一画。草稿仅在当前页面保留，离开后清空。", fontSize = 12.sp, color = Muted)
    }
}
