package cn.littlebear.tutor

import android.Manifest
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay

@Composable fun StudyClock(child: Child, task: Homework, store: FamilyStore, paused: Boolean, onPause: () -> Unit) {
    val id = remember(task.id) { newID() }
    val startedAt = remember(task.id) { System.currentTimeMillis() }
    var seconds by remember(task.id) { mutableLongStateOf(0) }
    var breakAt by remember(task.id) { mutableLongStateOf(child.studyMinutes * 60L) }
    var reminder by remember { mutableStateOf(false) }
    val pauseNow by rememberUpdatedState(onPause)
    fun save() { if (seconds > 0) store.change({ state ->
        if (state.tasksFor(child.id).any { it.id == task.id }) state.recordStudy(StudySession(id, child.id, task.id, seconds, startedAt)) else state
    }) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(task.id, lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) { pauseNow(); save() } }
        lifecycle.addObserver(observer)
        onDispose { save(); lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(paused, task.status) {
        if (paused || task.status == WorkStatus.DONE) { save(); return@LaunchedEffect }
        var tick = SystemClock.elapsedRealtime()
        while (true) {
            delay(1000)
            val now = SystemClock.elapsedRealtime()
            seconds += (now - tick) / 1000
            tick = now
            if (seconds % 30L == 0L) save()
            if (seconds >= breakAt) { reminder = true; pauseNow(); break }
        }
    }
    Text("本次学习 ${seconds / 60} 分 ${seconds % 60} 秒 · ${if (paused) "已暂停" else "到时间会提醒休息"}", color = Muted)
    if (reminder) AlertDialog(onDismissRequest = { reminder = false; breakAt = seconds + child.studyMinutes * 60L },
        title = { Text("伸个懒腰，休息一下吧") }, text = { Text("已经学习了一会儿，可以看看远处、喝口水。回来后点击“继续学习”。") },
        confirmButton = { TextButton(onClick = { reminder = false; breakAt = seconds + child.studyMinutes * 60L }) { Text("好，休息一下") } })
}

@Composable fun VoiceInputButton(enabled: Boolean, onStart: () -> Unit, onText: (String) -> Unit, onError: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val textNow by rememberUpdatedState(onText)
    val errorNow by rememberUpdatedState(onError)
    val startNow by rememberUpdatedState(onStart)
    val enabledNow by rememberUpdatedState(enabled)
    var listening by remember { mutableStateOf(false) }
    var consent by rememberSaveable { mutableStateOf(false) }
    var showConsent by remember { mutableStateOf(false) }
    val recognizer = remember { if (SpeechRecognizer.isRecognitionAvailable(context)) SpeechRecognizer.createSpeechRecognizer(context) else null }
    fun start() {
        if (recognizer == null) { errorNow("此设备未安装可用的语音识别服务，请使用键盘输入。"); return }
        startNow()
        try {
            recognizer.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            })
            listening = true
        } catch (_: Exception) { listening = false; errorNow("无法启动语音输入，请使用键盘或检查系统语音服务。") }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        if (it && enabled) start() else if (!it) errorNow("麦克风未授权，可以继续使用键盘输入。")
    }
    DisposableEffect(recognizer, lifecycle) {
        recognizer?.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) = Unit
            override fun onBeginningOfSpeech() = Unit
            override fun onRmsChanged(rmsdB: Float) = Unit
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() = Unit
            override fun onError(error: Int) {
                val wasListening = listening; listening = false
                if (wasListening) errorNow("这次没有听清或语音服务不可用，请再试一次，也可以打字。")
            }
            override fun onResults(results: Bundle?) {
                val accept = listening && enabledNow && lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
                listening = false
                if (accept) results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.let { textNow(it.take(2000)) }
            }
            override fun onPartialResults(partialResults: Bundle?) = Unit
            override fun onEvent(eventType: Int, params: Bundle?) = Unit
        })
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) { listening = false; recognizer?.cancel() } }
        lifecycle.addObserver(observer)
        onDispose { listening = false; recognizer?.destroy(); lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(enabled) { if (!enabled) { listening = false; recognizer?.cancel() } }
    OutlinedButton(enabled = enabled, onClick = {
        if (listening) { listening = false; recognizer?.cancel() }
        else if (!consent) showConsent = true
        else permission.launch(Manifest.permission.RECORD_AUDIO)
    }) { Text(if (listening) "正在识别 · 点击停止" else "说出问题") }
    if (showConsent) AlertDialog(onDismissRequest = { showConsent = false }, title = { Text("使用语音输入") },
        text = { Text("说话时使用麦克风，系统语音服务可能联网处理录音。识别出的文字先显示供你修改，点击发送后才交给辅导服务。也可以继续打字。") },
        confirmButton = { TextButton(onClick = { consent = true; showConsent = false; permission.launch(Manifest.permission.RECORD_AUDIO) }) { Text("继续") } },
        dismissButton = { TextButton(onClick = { showConsent = false }) { Text("使用键盘") } })
}

@Composable fun TutorPanel(child: Child, task: Homework, store: FamilyStore, paused: Boolean, stopSpeaking: () -> Unit, speak: (String) -> Unit) {
    val busy by store.busy.collectAsStateWithLifecycle()
    val config by store.settings.collectAsStateWithLifecycle()
    var question by rememberSaveable(task.id) { mutableStateOf("") }
    var includePhoto by rememberSaveable(task.id) { mutableStateOf(false) }
    DisposableEffect(task.id) { onDispose { store.cancelTutor() } }
    LaunchedEffect(paused) { if (paused) store.cancelTutor() }
    val enabled = !paused && !busy && task.status != WorkStatus.DONE && config.consent
    Panel(Modifier.fillMaxWidth(), Sage) {
        Text("问问小熊", fontWeight = FontWeight.Bold)
        if (!config.consent) Text("请家长先在家长空间开启辅导服务。你仍然可以记录想法并交给家长检查。", color = Muted)
        task.conversation.takeLast(8).forEach { turn ->
            Text("我：${turn.question}", color = Muted)
            Text("小熊：${turn.reply}")
            TextButton(onClick = { speak(turn.reply) }, enabled = !paused) { Text("朗读这条提示") }
        }
        if (task.aiAssessment != "UNKNOWN") Text("AI 检查建议：${if (task.aiAssessment == "CORRECT") "目前看起来正确" else "需要再检查"}。最终完成状态由家长确认。", color = Ochre)
        OutlinedTextField(question, { question = it.take(2000) }, modifier = Modifier.fillMaxWidth(), minLines = 2,
            label = { Text("说说你卡在哪里，或写下你的思路") }, enabled = !paused && !busy)
        if (task.photo != null) Row {
            Checkbox(includePhoto, { includePhoto = it }, enabled = enabled)
            Text("这次发送作业图片（请确认图片中包含要问的题目）")
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(enabled = enabled && question.isNotBlank(), onClick = {
                stopSpeaking(); store.requestTutor(child, task, "help", question, if (includePhoto) task.photo else null) { question = "" }
            }) { Text("发送问题") }
            OutlinedButton(enabled = enabled && (task.draft.isNotBlank() || includePhoto), onClick = {
                stopSpeaking(); store.requestTutor(child, task, "check", "请检查我的答案和步骤", if (includePhoto) task.photo else null)
            }) { Text("帮我检查") }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            VoiceInputButton(enabled, stopSpeaking, { question = it }, store::reportError)
            TextButton(onClick = { stopSpeaking(); store.cancelTutor() }) { Text("停止") }
        }
        if (busy) { LinearProgressIndicator(Modifier.fillMaxWidth()); Text("小熊正在看这道题，可以点击停止。", color = Muted) }
        Text("仅发送当前题目和最近对话。识别不清时先补充材料；AI 回复可能出错，可请家长一起核对。", color = Muted)
    }
}

@Composable fun StudySummary(child: Child, family: Family) {
    val start = java.time.LocalDate.now().atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
    val seconds = family.sessions.filter { it.childID == child.id && it.startedAt >= start }.sumOf { it.seconds }
    val records = family.evidenceFor(child.id).filter { it.time >= start }
    Panel(Modifier.fillMaxWidth(), Sage) {
        Text("今天的学习回顾", fontWeight = FontWeight.Bold)
        Text("学习 ${seconds / 60} 分钟 · ${records.size} 次练习作答 · ${records.count { it.independent }} 次独立答对")
        Text("需要帮助和订正也是学习的一部分。完成作业后，可以向家长说说今天学到了什么。", color = Muted)
    }
}

@Composable fun ReviewList(child: Child, family: Family, onPractice: (Subject, String) -> Unit) {
    val now = System.currentTimeMillis()
    val reviews = family.reviews(child.id)
    if (reviews.isNotEmpty()) Panel(Modifier.fillMaxWidth()) {
        Text("复习安排", fontWeight = FontWeight.Bold)
        reviews.forEach { review ->
            val due = review.dueAt <= now
            Text("${review.concept} · ${if (due) "可以复习了" else java.text.SimpleDateFormat("MM-dd", java.util.Locale.CHINA).format(java.util.Date(review.dueAt))}")
            Text(review.reason, color = Muted)
            TextButton(onClick = { onPractice(review.subject, review.concept) }) { Text("试一道相似题") }
        }
    }
}
