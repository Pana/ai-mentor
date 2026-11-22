package cn.littlebear.tutor.homework

import android.accessibilityservice.AccessibilityService
import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.widget.TextView
import android.widget.Toast
import java.text.Collator
import java.util.Locale

// Reward-time locking on Android (PRD §6.3). The parent picks the cartoon and game apps on the child's tablet; an
// accessibility service sends the child back to the home screen whenever one of them comes to the front outside a
// reward session. While apps are locked, it also keeps the child out of the system screens that could turn the lock
// off (the accessibility page, 小熊伴学's app info, device admin, uninstall). A parent who passes the lock-screen check
// in 家长设置 gets a few minutes without any locking.

/** The lock decision, free of Android types so it runs in JVM unit tests. */
object LockPolicy {
    /** Shown on every screen that could turn the lock off: the accessibility list, app info, device admin, uninstall. */
    const val APP_MARK = "小熊伴学"

    /** System apps whose screens can disable the service or remove the app. Only screens that mention [APP_MARK] are guarded. */
    val guardedPackages = setOf(
        "com.android.settings", "com.miui.securitycenter", "com.miui.securitymanager", "com.xiaomi.misettings", "com.miui.greenguard",
        "com.android.packageinstaller", "com.google.android.packageinstaller", "com.miui.packageinstaller",
        "com.android.permissioncontroller", "com.google.android.permissioncontroller",
    )

    enum class Verdict { ALLOW, LOCKED_APP, GUARDED_SETTINGS }

    /** Time since boot plus the boot number. Unlike the wall clock, the child can't move it by changing the date. */
    data class Clock(val elapsed: Long, val boot: Int)

    /** Unlocked until [untilElapsed] on boot [boot]. A grant ends at restart, so rebooting with a changed date can't stretch it. */
    data class Grant(val untilElapsed: Long, val boot: Int) {
        fun remaining(now: Clock): Long = if (now.boot == boot) (untilElapsed - now.elapsed).coerceAtLeast(0) else 0
        fun active(now: Clock) = remaining(now) > 0

        companion object {
            fun start(now: Clock, millis: Long) = Grant(now.elapsed + millis, now.boot)
            /** A new session while one is still running adds on to it. */
            fun extend(current: Grant?, now: Clock, millis: Long) = Grant(now.elapsed + (current?.remaining(now) ?: 0) + millis, now.boot)
        }
    }

    /**
     * What to do with the app in front. [mentionsUs] is only asked for guarded system screens (reading window text is
     * an IPC). Nothing is locked until the parent picks at least one app.
     */
    fun verdict(pkg: String, own: String, locked: Set<String>, session: Grant?, parent: Grant?, now: Clock, mentionsUs: () -> Boolean): Verdict = when {
        pkg == own || locked.isEmpty() -> Verdict.ALLOW
        parent?.active(now) == true -> Verdict.ALLOW
        pkg in guardedPackages -> if (mentionsUs()) Verdict.GUARDED_SETTINGS else Verdict.ALLOW
        pkg in locked && session?.active(now) != true -> Verdict.LOCKED_APP
        else -> Verdict.ALLOW
    }
}

data class LaunchableApp(val pkg: String, val label: String)

/** The lock's settings and the running session, kept in one preferences file the service watches. */
object RewardLock {
    private const val PARENT_MINUTES = 10

    fun prefs(context: Context): SharedPreferences = context.getSharedPreferences("phase1.lock", Context.MODE_PRIVATE)

    fun clock(context: Context) = LockPolicy.Clock(SystemClock.elapsedRealtime(),
        Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1))

    fun lockedApps(context: Context): Set<String> = prefs(context).getStringSet("apps", emptySet()).orEmpty().toSet()
    fun setLockedApps(context: Context, apps: Set<String>) { prefs(context).edit().putStringSet("apps", apps.toSet()).apply() }

    private fun grant(context: Context, key: String): LockPolicy.Grant? = prefs(context).let { p ->
        if (!p.contains("$key.until")) null else LockPolicy.Grant(p.getLong("$key.until", 0), p.getInt("$key.boot", -1))
    }
    private fun save(context: Context, key: String, grant: LockPolicy.Grant?) {
        prefs(context).edit().apply {
            if (grant == null) { remove("$key.until"); remove("$key.boot") } else { putLong("$key.until", grant.untilElapsed); putInt("$key.boot", grant.boot) }
        }.apply()
    }

    fun session(context: Context) = grant(context, "session")
    fun parent(context: Context) = grant(context, "parent")

    /** Called after the server accepted the session and took the minutes off the balance. */
    fun startSession(context: Context, minutes: Int) { save(context, "session", LockPolicy.Grant.extend(session(context), clock(context), minutes * 60_000L)) }
    fun remainingMillis(context: Context): Long = session(context)?.remaining(clock(context)) ?: 0

    /** The parent passed the lock-screen check in 家长设置: no locking until they close it, or for [PARENT_MINUTES] at most. */
    fun allowParent(context: Context) { save(context, "parent", LockPolicy.Grant.start(clock(context), PARENT_MINUTES * 60_000L)) }
    fun endParent(context: Context) { save(context, "parent", null) }

    /** The system paused the lock (see RewardLockService's tick). Shown to the parent for a day, or until they open battery settings. */
    fun recordStall(context: Context) { prefs(context).edit().putLong("stall.at", System.currentTimeMillis()).apply() }
    fun clearStall(context: Context) { prefs(context).edit().remove("stall.at").apply() }
    fun recentlyStalled(context: Context) = System.currentTimeMillis() - prefs(context).getLong("stall.at", 0) < 24 * 3_600_000L

    fun isServiceEnabled(context: Context): Boolean {
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val me = ComponentName(context, RewardLockService::class.java)
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == me }
    }

    fun adminComponent(context: Context) = ComponentName(context, RewardLockAdmin::class.java)
    fun isAdminActive(context: Context) = (context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager).isAdminActive(adminComponent(context))
    fun adminIntent(context: Context) = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
        .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, adminComponent(context))
        .putExtra(DevicePolicyManager.EXTRA_ADD_EXPLANATION, "开启后，孩子不能直接卸载小熊伴学来绕过奖励时间锁定。")

    /** Apps on the home screen the parent can lock: not this app, launchers or system settings. */
    fun launchableApps(context: Context): List<LaunchableApp> {
        val pm = context.packageManager
        val homes = pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), 0).map { it.activityInfo.packageName }.toSet()
        val collator = Collator.getInstance(Locale.CHINA)
        return pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .map { LaunchableApp(it.activityInfo.packageName, it.loadLabel(pm).toString()) }
            .filter { it.pkg != context.packageName && it.pkg !in homes && it.pkg !in LockPolicy.guardedPackages }
            .distinctBy { it.pkg }
            .sortedWith { a, b -> collator.compare(a.label, b.label) }
    }
}

/** Watches which app is in front and sends locked ones back to the home screen. */
class RewardLockService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private var lastKick = 0L
    private val check = Runnable { evaluate() }
    // A session can run out while the child stays inside a game, which sends no events; look again every few seconds.
    private var lastTick = 0L
    private val tick = object : Runnable {
        override fun run() {
            // Uptime stops in deep sleep but not while HyperOS freezes the process, so a long gap here means the
            // system paused the lock (省电策略 not set to 无限制; verified on a Xiaomi Pad 9 Pro, HyperOS 4).
            val up = SystemClock.uptimeMillis()
            if (lastTick != 0L && up - lastTick > 20_000) RewardLock.recordStall(this@RewardLockService)
            lastTick = up
            evaluate(); handler.postDelayed(this, 5_000)
        }
    }
    private val changed = SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> scheduleSessionEnd(); schedule(0) }

    override fun onServiceConnected() {
        RewardLock.prefs(this).registerOnSharedPreferenceChangeListener(changed)
        handler.post(tick)
        scheduleSessionEnd()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        // Settings pages switch inside one activity (content changes), so wait a moment for the new page and read it once.
        schedule(if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) 0 else 250)
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        RewardLock.prefs(this).unregisterOnSharedPreferenceChangeListener(changed)
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun schedule(delay: Long) { handler.removeCallbacks(check); handler.postDelayed(check, delay) }

    private val sessionEnd = Runnable { evaluate() }
    private fun scheduleSessionEnd() {
        handler.removeCallbacks(sessionEnd)
        val left = RewardLock.remainingMillis(this)
        if (left > 0) handler.postDelayed(sessionEnd, left + 300)
    }

    private fun evaluate() {
        val root = try { rootInActiveWindow } catch (_: Exception) { null } ?: return
        val pkg = root.packageName?.toString() ?: return
        val verdict = LockPolicy.verdict(pkg, packageName, RewardLock.lockedApps(this), RewardLock.session(this), RewardLock.parent(this), RewardLock.clock(this)) {
            root.findAccessibilityNodeInfosByText(LockPolicy.APP_MARK).isNotEmpty()
        }
        if (verdict != LockPolicy.Verdict.ALLOW) Log.i("RewardLock", "$verdict $pkg")
        when (verdict) {
            LockPolicy.Verdict.ALLOW -> {}
            LockPolicy.Verdict.LOCKED_APP -> kick("动画和游戏要用奖励时间才能打开。去小熊伴学交作业、攒时间吧！")
            LockPolicy.Verdict.GUARDED_SETTINGS -> kick("这项设置要家长先在小熊伴学的“家长”里验证。")
        }
    }

    private fun kick(message: String) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastKick < 1_500) return
        lastKick = now
        performGlobalAction(GLOBAL_ACTION_HOME)
        showNotice(message)
    }

    // A toast from the background is dropped when the app has no notification permission (Android 13+), so the
    // message is an accessibility overlay instead: it needs no permission and passes touches through.
    private var notice: View? = null
    private val hideNotice = Runnable { removeNotice() }

    private fun showNotice(message: String) {
        removeNotice()
        val density = resources.displayMetrics.density
        val view = TextView(this).apply {
            text = "🐻  $message"
            textSize = 20f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setPadding((28 * density).toInt(), (20 * density).toInt(), (28 * density).toInt(), (20 * density).toInt())
            background = GradientDrawable().apply { setColor(0xEE23201C.toInt()); cornerRadius = 24 * density }
            maxWidth = (520 * density).toInt()
        }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.CENTER }
        try {
            getSystemService(WindowManager::class.java).addView(view, params)
            notice = view
            handler.postDelayed(hideNotice, 4_000)
        } catch (_: Exception) {
            Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        }
    }

    private fun removeNotice() {
        handler.removeCallbacks(hideNotice)
        notice?.let { runCatching { getSystemService(WindowManager::class.java).removeView(it) } }
        notice = null
    }
}

/** Device admin with no policies: while it's active the app can't be uninstalled until a parent turns it off. */
class RewardLockAdmin : DeviceAdminReceiver() {
    override fun onDisableRequested(context: Context, intent: Intent): CharSequence = "关掉后孩子可以卸载小熊伴学，奖励时间锁定会失效。"
}
