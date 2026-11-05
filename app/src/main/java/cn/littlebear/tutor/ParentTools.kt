package cn.littlebear.tutor

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable fun EditChildDialog(child: Child, onDismiss: () -> Unit, onSave: (Child) -> Unit) {
    var name by remember { mutableStateOf(child.name) }
    var textbook by remember { mutableStateOf(child.textbook) }
    var grade by remember { mutableIntStateOf(child.grade) }
    var minutes by remember { mutableFloatStateOf(child.studyMinutes.toFloat()) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("档案与学习安排") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(name, { name = it.take(20) }, label = { Text("昵称") }, singleLine = true)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { (2..3).forEach { n ->
                FilterChip(grade == n, { grade = n }, label = { Text("$n 年级") })
            } }
            OutlinedTextField(textbook, { textbook = it.take(300) }, label = { Text("各科教材、上下册与单元") }, minLines = 2)
            Text("请按学校实际情况填写；不确定的教材可以留空。", color = Muted)
            Text("连续学习 ${minutes.toInt()} 分钟后提醒休息")
            Slider(minutes, { minutes = it }, valueRange = 5f..60f, steps = 10)
        }
    }, confirmButton = { Button(onClick = { onSave(child.copy(name = name, grade = grade, textbook = textbook, studyMinutes = minutes.toInt())) }, enabled = name.isNotBlank()) { Text("保存") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } })
}

@Composable fun EditTaskDialog(task: Homework, onDismiss: () -> Unit, onSave: (Subject, String, String) -> Unit) {
    var title by remember { mutableStateOf(task.title) }
    var instructions by remember { mutableStateOf(task.instructions) }
    var subject by remember { mutableStateOf(task.subject) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("修改作业") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { Subject.entries.forEach { s ->
                FilterChip(subject == s, { subject = s }, label = { Text(s.label) })
            } }
            OutlinedTextField(title, { title = it.take(100) }, label = { Text("作业名称") })
            OutlinedTextField(instructions, { instructions = it.take(2000) }, label = { Text("题目与完成要求") }, minLines = 3)
            Text("修改题意后恢复待开始，清除旧辅导对话；保留原图和孩子草稿，请一并核对。", color = Muted)
        }
    }, confirmButton = { Button(onClick = { onSave(subject, title, instructions) }, enabled = title.isNotBlank()) { Text("保存修改") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } })
}

@Composable fun ParentReviewDialog(task: Homework, onDismiss: () -> Unit, onReview: (Boolean, String, String, Boolean) -> Unit) {
    var note by remember { mutableStateOf(task.reviewNote) }
    var concept by remember { mutableStateOf("") }
    var independent by remember { mutableStateOf(false) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("检查：${task.title}") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("孩子的记录：${task.draft.ifBlank { "请查看纸面作业" }}")
            OutlinedTextField(note, { note = it.take(1000) }, label = { Text("检查依据 / 订正建议") }, minLines = 3)
            OutlinedTextField(concept, { concept = it.take(100) }, label = { Text("知识点（可选，例如两位数进位加法）") })
            Row { Checkbox(independent, { independent = it }); Text("我观察到孩子独立完成并能解释思路") }
            Text("填写知识点与具体依据后，作为家长确认的学习证据保存。单次完成不等于掌握。", color = Muted)
        }
    }, confirmButton = { Button(onClick = { onReview(true, note, concept, independent) }) { Text("确认完成") } },
        dismissButton = { Row { TextButton(onClick = { onReview(false, note, concept, false) }) { Text("需要订正") }; TextButton(onClick = onDismiss) { Text("取消") } } })
}

@Composable fun ServiceSettingsPanel(store: FamilyStore, demo: Boolean) {
    val config by store.settings.collectAsStateWithLifecycle()
    var show by remember { mutableStateOf(false) }
    Panel(Modifier.fillMaxWidth()) {
        Text("云端辅导", fontWeight = FontWeight.Bold)
        Text(if (config.consent) "已开启：求助或识别时发送当前题目、相关图片和最近对话。" else "未开启：仍可管理作业和使用本地练习。", color = Muted)
        if (demo) Text("配置服务前请清空示例家庭，并通过系统锁屏验证建立实际家庭。", color = Muted)
        else OutlinedButton(onClick = { show = true }) { Text("设置辅导服务") }
    }
    if (show) {
        var url by remember { mutableStateOf(config.url) }
        var token by remember { mutableStateOf(config.token) }
        var consent by remember { mutableStateOf(config.consent) }
        AlertDialog(onDismissRequest = { show = false }, title = { Text("辅导服务设置") }, text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(url, { url = it.take(500) }, label = { Text("服务地址") }, singleLine = true)
                OutlinedTextField(token, { token = it.take(512) }, label = { Text("设备访问凭证") }, singleLine = true, visualTransformation = PasswordVisualTransformation())
                Text("请填写部署人员提供的地址与设备凭证。模型供应商密钥保存在服务端。", color = Muted)
                Row { Checkbox(consent, { consent = it }); Text("允许将当前辅导所需的题目、图片、语音识别文字和上下文发给配置的服务。") }
                Text("学习记录保存在本机。网关不保存学习内容；模型供应商的数据处理政策需由服务提供方说明。关闭后停止云端辅导。", color = Muted)
            }
        }, confirmButton = { Button(onClick = { store.saveSettings(ServiceSettings(url.trim(), token.trim(), consent)) { show = false } }) { Text("保存") } },
            dismissButton = { TextButton(onClick = { show = false }) { Text("取消") } })
    }
}
