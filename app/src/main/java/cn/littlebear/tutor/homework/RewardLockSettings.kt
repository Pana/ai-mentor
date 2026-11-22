package cn.littlebear.tutor.homework

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.graphics.drawable.toBitmap
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Bumps whenever the screen comes back to the front, so status read from system settings stays current. */
@Composable private fun resumeCount(): Int {
    var count by remember { mutableIntStateOf(0) }
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_RESUME) count++ }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    return count
}

private fun Context.open(intent: Intent) = try { startActivity(intent) } catch (_: ActivityNotFoundException) {
    Toast(this, "这台设备打不开这个设置页，请在系统设置里手动找。")
}

@Suppress("FunctionName") private fun Toast(context: Context, text: String) = android.widget.Toast.makeText(context, text, android.widget.Toast.LENGTH_LONG).show()

/** The 奖励时间锁定 part of the child tablet's 家长设置. Only shown after the parent passed the lock-screen check. */
@Composable fun RewardLockSection() {
    val context = LocalContext.current
    val resumed = resumeCount()
    val serviceOn = remember(resumed) { RewardLock.isServiceEnabled(context) }
    val adminOn = remember(resumed) { RewardLock.isAdminActive(context) }
    val stalled = remember(resumed) { RewardLock.recentlyStalled(context) }
    var apps by remember { mutableStateOf(RewardLock.lockedApps(context)) }
    var picking by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxWidth().background(Palette.paper, RoundedCornerShape(16.dp)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("奖励时间锁定", fontWeight = FontWeight.Bold, fontSize = 16.sp)
        Text(when {
            !serviceOn -> "还没开启：现在只记账和倒计时，不会锁住其他 App。"
            apps.isEmpty() -> "已开启，但还没选要锁住的 App。"
            else -> "已开启：锁住 ${apps.size} 个 App，孩子用奖励时间才能打开。"
        }, fontSize = 13.sp, color = if (serviceOn && apps.isNotEmpty()) Palette.pine else Palette.warn)

        StepRow("1. 开启无障碍服务", serviceOn, if (serviceOn) "已开启" else "去开启") {
            context.open(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }
        if (!serviceOn) Text("在无障碍里找到“小熊伴学 · 奖励时间锁定”，打开开关。小米平板在“已下载的应用”或“更多已下载的服务”里。", fontSize = 12.sp, color = Palette.ink3)
        StepRow("2. 选择要锁住的 App", apps.isNotEmpty(), if (apps.isEmpty()) "去选择" else "已选 ${apps.size} 个") { picking = true }
        StepRow("3. 防止卸载", adminOn, if (adminOn) "已开启" else "去开启") {
            if (!adminOn) context.open(RewardLock.adminIntent(context))
        }
        StepRow("4. 省电策略选“无限制”", null, "去设置") {
            RewardLock.clearStall(context)
            context.open(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)))
        }
        if (stalled) Text("⚠ 系统最近暂停过锁定，那段时间孩子能打开被锁的 App。请在应用信息 → 省电策略里选“无限制”。", fontSize = 13.sp,
            fontWeight = FontWeight.Medium, color = Palette.warn, modifier = Modifier.fillMaxWidth().background(Palette.warnSoft, RoundedCornerShape(10.dp)).padding(10.dp))
        else Text("小米平板必须做这一步：在应用信息 → 省电策略里选“无限制”，并打开“自启动”。默认的“智能限制”会在孩子打开别的 App 时暂停锁定。", fontSize = 12.sp, color = Palette.ink3)
        Text("家长验证后、关闭这个窗口前（最多 10 分钟），平板不锁任何 App，方便您改系统设置。", fontSize = 12.sp, color = Palette.ink3)
    }

    if (picking) LockedAppsDialog(apps, onDismiss = { picking = false }) { chosen ->
        RewardLock.setLockedApps(context, chosen); apps = chosen; picking = false
    }
}

@Composable private fun StepRow(title: String, done: Boolean?, action: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(if (done == true) "✓" else "·", color = if (done == true) Palette.pine else Palette.ink3, fontWeight = FontWeight.Bold, modifier = Modifier.width(18.dp))
        Text(title, Modifier.weight(1f), fontSize = 14.sp)
        TextButton(onClick) { Text(action, color = if (done == true) Palette.ink3 else Palette.pine) }
    }
}

@Composable private fun LockedAppsDialog(initial: Set<String>, onDismiss: () -> Unit, onSave: (Set<String>) -> Unit) {
    val context = LocalContext.current
    var all by remember { mutableStateOf<List<LaunchableApp>?>(null) }
    var icons by remember { mutableStateOf<Map<String, ImageBitmap>>(emptyMap()) }
    val chosen = remember { mutableStateListOf<String>().apply { addAll(initial) } }
    LaunchedEffect(Unit) {
        val list = withContext(Dispatchers.IO) { RewardLock.launchableApps(context) }
        // Apps already locked first, so the parent sees them without scrolling.
        all = list.sortedBy { it.pkg !in initial }
        icons = withContext(Dispatchers.IO) {
            list.mapNotNull { app -> runCatching { app.pkg to context.packageManager.getApplicationIcon(app.pkg).toBitmap(96, 96).asImageBitmap() }.getOrNull() }.toMap()
        }
    }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("锁住哪些 App") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("选动画、视频和游戏 App。选中的平时打不开，孩子用奖励时间时才能用。", fontSize = 13.sp, color = Palette.ink2)
            val list = all
            if (list == null) Box(Modifier.fillMaxWidth().height(120.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            else LazyColumn(Modifier.fillMaxWidth().heightIn(max = 420.dp)) {
                items(list, key = { it.pkg }) { app ->
                    val on = app.pkg in chosen
                    Row(Modifier.fillMaxWidth().clickable { if (on) chosen.remove(app.pkg) else chosen.add(app.pkg) }.padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        val icon = icons[app.pkg]
                        if (icon != null) Image(icon, null, Modifier.size(36.dp)) else Spacer(Modifier.size(36.dp))
                        Text(app.label, Modifier.weight(1f), fontSize = 16.sp)
                        Checkbox(on, { if (it) chosen.add(app.pkg) else chosen.remove(app.pkg) })
                    }
                }
            }
        }
    }, confirmButton = { TextButton({ onSave(chosen.toSet()) }) { Text("保存（${chosen.size}）") } },
        dismissButton = { TextButton(onDismiss) { Text("取消") } })
}
