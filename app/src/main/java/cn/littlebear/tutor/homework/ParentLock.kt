package cn.littlebear.tutor.homework

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

// The parent's view of each child tablet's reward-time lock, from the tablet's heartbeat (RewardLock on Android).

/** "11/22 15:39" in the family's time zone; empty when the server sent no time. */
fun lockTime(iso: String, zone: String): String = try {
    DateTimeFormatter.ofPattern("M/d HH:mm").withZone(ZoneId.of(zone)).format(Instant.parse(iso))
} catch (_: Exception) { "" }

/** One line about a tablet's lock: a warning when [LockStatus.problem] is set, otherwise that it is working. */
fun lockMessage(lock: LockStatus, zone: String): String {
    val name = lock.name.ifBlank { "孩子的平板" }
    val at = lockTime(lock.reportedAt, zone)
    return when (lock.problem) {
        "off" -> "$name 的奖励时间锁定已关闭，被锁的动画和游戏现在随时能打开。请在平板上点“家长 → 奖励时间锁定”重新开启。"
        "paused" -> "$name 的锁定最近被系统暂停过，那段时间被锁的 App 能打开。请在平板的应用信息里把省电策略改成“无限制”。"
        "silent" -> "$name 超过一天没有报告锁定状态（最后一次 $at）。平板可能关机或断网，也可能锁定被关掉了。"
        else -> "$name：锁定正常，锁住 ${lock.lockedApps} 个 App" + (if (at.isNotEmpty()) "，$at 报告" else "") +
            (if (!lock.adminActive) "。没开“防止卸载”" else "")
    }
}

/** Shown above every parent tab while any tablet's lock needs attention. */
@Composable fun LockAlertBanner(locks: List<LockStatus>, zone: String, onClick: () -> Unit) {
    val problems = locks.filter { it.problem != null }
    if (problems.isEmpty()) return
    Surface(onClick = onClick, color = Palette.warnSoft, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            problems.forEach { Text("⚠ " + lockMessage(it, zone), color = Palette.warn, fontSize = 14.sp, fontWeight = FontWeight.Medium) }
        }
    }
}

/** The 奖励 tab's section listing every tablet that reports a lock. */
@Composable fun LockStatusSection(locks: List<LockStatus>, zone: String) {
    Column(Modifier.fillMaxWidth().background(Palette.card, RoundedCornerShape(18.dp)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("孩子平板的锁定", fontWeight = FontWeight.Bold, fontSize = 16.sp)
        if (locks.isEmpty()) Text("还没有平板开启锁定。安卓平板可以锁住动画和游戏 App，平时打不开，用奖励时间才放开：在孩子平板上点“家长 → 奖励时间锁定”设置。",
            fontSize = 13.sp, color = Palette.ink3)
        locks.forEach { lock ->
            Text((if (lock.problem != null) "⚠ " else "✓ ") + lockMessage(lock, zone), fontSize = 14.sp,
                color = if (lock.problem != null) Palette.warn else Palette.pine)
        }
    }
}
