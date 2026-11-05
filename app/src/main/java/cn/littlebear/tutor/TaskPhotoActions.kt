package cn.littlebear.tutor

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import java.io.File

@Composable fun TaskPhotoActions(child: Child, task: Homework, store: FamilyStore, enabled: Boolean) {
    val context = LocalContext.current
    var importing by remember { mutableStateOf(false) }
    var active by remember { mutableStateOf(true) }
    var cameraName by rememberSaveable { mutableStateOf<String?>(null) }
    val current by rememberUpdatedState(task)
    DisposableEffect(task.id) { onDispose { active = false } }
    fun import(uri: Uri) {
        importing = true
        store.importPhoto(uri, onFinished = {
            importing = false
            cameraName?.let { File(context.cacheDir, "capture/$it").delete() }
            cameraName = null
        }) { name ->
            if (!active) store.discardPhoto(name)
            else {
                val old = current.photo
                store.cancelTutor()
                store.change({ state -> state.update(child.id, task.id) {
                    require(it.status != WorkStatus.DONE)
                    it.copy(photo = name, revision = it.revision + 1, aiAssessment = "UNKNOWN")
                } }) { store.discardPhoto(old) }
            }
        }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { it?.let(::import) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { success ->
        cameraName?.let { name ->
            val file = File(context.cacheDir, "capture/$name")
            if (success) import(FileProvider.getUriForFile(context, "${context.packageName}.files", file))
            else { file.delete(); cameraName = null }
        }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(enabled = enabled && !importing, onClick = {
            try {
                val dir = File(context.cacheDir, "capture").apply { mkdirs() }
                val name = "${newID()}.jpg"
                cameraName = name
                camera.launch(FileProvider.getUriForFile(context, "${context.packageName}.files", File(dir, name)))
            } catch (_: Exception) { store.reportError("无法打开相机，请从相册选择图片。") }
        }) { Text("拍摄当前题目") }
        OutlinedButton(enabled = enabled && !importing, onClick = {
            try { picker.launch("image/*") } catch (_: Exception) { store.reportError("没有可用的相册应用。") }
        }) { Text("选择题目图片") }
    }
    if (importing) LinearProgressIndicator(Modifier.fillMaxWidth())
    Text("拍完整题目与步骤，尽量避开姓名和其他个人信息。新图会替换当前作业图片。", color = Muted)
}
