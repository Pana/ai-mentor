package cn.littlebear.tutor.homework

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import androidx.compose.ui.geometry.Offset
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.time.Instant
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLog

/**
 * Renders the parent and child apps at phone and tablet sizes with Robolectric's native graphics and saves PNGs to
 * `app/build/screenshots/`. Data comes from a realistic cache (no network), so the screens are deterministic.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34])
class ScreenshotTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val outDir = File(System.getProperty("user.dir"), "build/screenshots").apply { mkdirs() }
    private val noNetwork = HttpTransport { throw java.io.IOException("offline in screenshots") }

    // ---------- fixture ----------

    private val today = Day.today("Asia/Shanghai", System.currentTimeMillis())
    private val yesterday = Day.add(today, -1)
    private val ming = RemoteChild("6f1c3a52-0000-4000-8000-000000000001", "小明", 2)
    private val hong = RemoteChild("6f1c3a52-0000-4000-8000-00000000000a", "小红", 3)

    private fun page(lines: List<String>, ink: Int = android.graphics.Color.rgb(40, 40, 40)): ByteArray {
        val bitmap = Bitmap.createBitmap(600, 800, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(android.graphics.Color.rgb(250, 248, 240))
        val rule = Paint().apply { color = android.graphics.Color.rgb(200, 215, 230); strokeWidth = 2f }
        for (y in 120 until 800 step 60) canvas.drawLine(30f, y.toFloat(), 570f, y.toFloat(), rule)
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = ink; textSize = 34f }
        lines.forEachIndexed { i, line -> canvas.drawText(line, 50f, 110f + i * 60, text) }
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
    }

    private fun seed(role: String, pickChild: Boolean = true): HomeworkStore {
        val dir = Files.createTempDirectory("shots-$role").toFile()
        val files = File(dir, "files").apply { mkdirs() }
        fun file(id: String, data: ByteArray) = File(files, id).writeBytes(data)

        val sheet = "a0000000-0000-4000-8000-000000000001"; file(sheet, page(listOf("口算练习册 第 12 页", "1. 36 + 27 =", "2. 58 - 19 =", "3. 45 + 38 =")))
        val p1 = "a0000000-0000-4000-8000-000000000002"; file(p1, page(listOf("36 + 27 = 63", "58 - 19 = 39", "45 + 38 = 73", "72 - 45 = 37")))
        val p2 = "a0000000-0000-4000-8000-000000000003"; file(p2, page(listOf("90 - 26 = 64", "17 + 48 = 65")))
        val marks = AnnotationModel().apply {
            aspect[0] = 0.75f; aspect[1] = 0.75f
            stamp(MarkTool.CHECK, Offset(0.62f, 0.13f), 0); stamp(MarkTool.CHECK, Offset(0.62f, 0.2f), 0)
            stamp(MarkTool.CIRCLE, Offset(0.3f, 0.28f), 0); stamp(MarkTool.CHECK, Offset(0.6f, 0.13f), 1)
        }
        val overlays = marks.overlays(2)
        val o1 = "a0000000-0000-4000-8000-000000000004"; file(o1, overlays[0])
        val o2 = "a0000000-0000-4000-8000-000000000005"; file(o2, overlays[1])
        val p3 = "a0000000-0000-4000-8000-000000000006"; file(p3, page(listOf("咏柳  贺知章", "碧玉妆成一树高，", "万条垂下绿丝绦。")))

        val iso = Instant.now().toString()
        fun hw(n: Int, subject: String, content: String, mode: String = "OFFLINE", kind: String? = null, status: String = "NOT_STARTED", date: String = today,
               submissions: List<Submission> = emptyList(), source: String = "PASTE", minutes: Int? = null, attachments: List<String> = emptyList(), due: String? = null) =
            RemoteHomework(id = "b0000000-0000-4000-8000-%012d".format(n), childId = ming.id, subject = subject, date = date, dueDate = due, content = content,
                rawText = if (source == "PASTE") "【二年级作业】$content 明早交[抱拳][抱拳]" else "", mode = mode, onlineKind = kind, durationMinutes = minutes,
                parentTodo = if (n == 1) "检查后签字" else "", status = status, source = source, attachmentIds = attachments, submissions = submissions)
        val homework = listOf(
            hw(1, "MATH", "口算练习册第 12 页，竖式写在本子上", attachments = listOf(sheet), due = Day.add(today, 1)),
            hw(2, "CHINESE", "背诵《咏柳》，录音交给家长", "ONLINE", "RECORDING", "SUBMITTED",
                submissions = listOf(Submission("c0000000-0000-4000-8000-000000000002", 1, listOf("a0000000-0000-4000-8000-0000000000aa"), submittedAt = iso, receivedAt = iso, onTime = true))),
            hw(3, "ENGLISH", "Unit 3 课文朗读", "ONLINE", "TIMER", "REVIEWED", minutes = 10,
                submissions = listOf(Submission("c0000000-0000-4000-8000-000000000003", 1, durationSeconds = 612, submittedAt = iso, receivedAt = iso, onTime = true))),
            hw(4, "MATH", "数学书第 35 页练一练 1–4 题", status = "NEEDS_CORRECTION", date = yesterday,
                submissions = listOf(Submission("c0000000-0000-4000-8000-000000000004", 1, listOf(p1, p2), submittedAt = iso, receivedAt = iso, onTime = true,
                    review = Review("d0000000-0000-4000-8000-000000000004", "FAIR", "第 3 题再算一遍，进位别忘了", true, listOf(o1, o2), iso)))),
            hw(5, "CHINESE", "生字本：第 8 课生字各写两遍", status = "SUBMITTED",
                submissions = listOf(Submission("c0000000-0000-4000-8000-000000000005", 1, listOf(p3), submittedAt = iso, receivedAt = iso, onTime = true))),
            hw(6, "ENGLISH", "英语朗读 5 分钟", "ONLINE", "TIMER", source = "ROUTINE", minutes = 5),
            hw(7, "MATH", "口算 10 道", source = "ROUTINE", status = "REVIEWED",
                submissions = listOf(Submission("c0000000-0000-4000-8000-000000000007", 1, listOf(p1), submittedAt = iso, receivedAt = iso, onTime = true))),
            hw(8, "OTHER", "科学：观察一片树叶并画下来", status = "REVIEWED", date = yesterday,
                submissions = listOf(Submission("c0000000-0000-4000-8000-000000000008", 1, listOf(p3), submittedAt = iso, receivedAt = iso, onTime = true,
                    review = Review("d0000000-0000-4000-8000-000000000008", "EXCELLENT", "画得很仔细", false, emptyList(), iso)))),
        )
        val routines = listOf(
            Routine("e0000000-0000-4000-8000-000000000001", ming.id, "英语朗读 5 分钟", "ENGLISH", "ONLINE", "TIMER", 5, null, (0..6).toList(), true, 0),
            Routine("e0000000-0000-4000-8000-000000000002", ming.id, "口算 10 道", "MATH", "OFFLINE", null, null, null, (1..5).toList(), true, 1),
            Routine("e0000000-0000-4000-8000-000000000003", ming.id, "课外阅读 20 分钟", "CHINESE", "ONLINE", "TIMER", 20, null, listOf(0, 6), false, 2),
        )
        val entries = listOf(
            RewardEntry("f1", 5, "ON_TIME", homework[1].id, today, iso), RewardEntry("f2", 3, "CHECKIN", homework[6].id, today, iso),
            RewardEntry("f3", 5, "GRADE", homework[7].id + ":1", yesterday, iso), RewardEntry("f4", -10, "SPEND", "x", yesterday, iso),
            RewardEntry("f5", 10, "STREAK7", "r:1", yesterday, iso), RewardEntry("f6", 1, "GRADE", homework[3].id + ":1", yesterday, iso),
        )
        val cache = Cache(cursor = 42, family = FamilyInfo("fam", "", "Asia/Shanghai", today), children = listOf(ming, hong), homework = homework,
            routines = routines, rules = RewardRules(), rewards = listOf(RewardSummary(ming.id, 38, 8, 0, entries), RewardSummary(hong.id, 12, 0, 0, emptyList())))
        File(dir, "cache.json").writeText(wireJson.encodeToString(Cache.serializer(), cache))
        context.getSharedPreferences("phase1.child", Context.MODE_PRIVATE).edit().apply { if (pickChild) putString("current", ming.id) else remove("current") }.commit()
        val session = DeviceSession("https://hw.example.cn", "dev", role, "fam", "t".repeat(64))
        return HomeworkStore(dir, MemorySessionStorage(session), transport = noNetwork, debug = false)
    }

    // ---------- capture ----------

    private fun shot(name: String) {
        // Let image decoding (IO dispatcher) and the follow-up recomposition finish.
        repeat(4) { compose.waitForIdle(); Thread.sleep(120) }
        val view = compose.activity.window.decorView
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        File(outDir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private fun show(store: HomeworkStore) {
        ShadowLog.stream = null
        compose.setContent { HomeworkApp(store) }
        compose.waitForIdle()
    }

    private fun tap(text: String) { compose.onAllNodesWithText(text, substring = true).onFirst().performClick(); compose.waitForIdle() }

    // ---------- phone ----------

    @Test @Config(qualifiers = "w411dp-h891dp-port-xhdpi")
    fun phoneParent() {
        show(seed("parent"))
        shot("phone-parent-1-homework")
        tap("等你批改"); shot("phone-parent-2-detail")
        tap("开始批改"); shot("phone-parent-3-review")
        tap("下一步：打分"); shot("phone-parent-4-grade")
    }

    @Test @Config(qualifiers = "w411dp-h891dp-port-xhdpi")
    fun phoneParentTabs() {
        show(seed("parent"))
        tap("录入"); shot("phone-parent-5-entry")
        tap("每天坚持"); shot("phone-parent-6-routines")
        tap("奖励"); shot("phone-parent-7-rewards")
    }

    @Test @Config(qualifiers = "w411dp-h891dp-port-xhdpi")
    fun phoneChild() {
        show(seed("child"))
        shot("phone-child-1-today")
        tap("全部作业"); shot("phone-child-2-all")
        tap("奖励时间"); shot("phone-child-3-reward")
        tap("今天"); tap("数学书第 35 页练一练 1–4 题"); shot("phone-child-4-feedback")
    }

    @Test @Config(qualifiers = "w411dp-h891dp-port-xhdpi")
    fun phoneOnboardingAndPicker() {
        show(HomeworkStore(Files.createTempDirectory("shots-new").toFile(), MemorySessionStorage(), transport = noNetwork))
        shot("phone-0-onboarding")
    }

    // ---------- tablet (landscape) ----------

    @Test @Config(qualifiers = "w1280dp-h800dp-land-mdpi")
    fun tabletParent() {
        show(seed("parent"))
        tap("生字本：第 8 课生字各写两遍"); shot("tablet-parent-1-list-detail")
        tap("开始批改"); shot("tablet-parent-2-review")
    }

    @Test @Config(qualifiers = "w1280dp-h800dp-land-mdpi")
    fun tabletChild() {
        show(seed("child", pickChild = false))
        shot("tablet-child-0-picker")
        tap("小明"); shot("tablet-child-1-today")
        tap("口算练习册第 12 页，竖式写在本子上"); shot("tablet-child-2-offline-task")
        tap("写完了，拍照交作业"); shot("tablet-child-3-submit")
        tap("回到作业"); tap("返回"); tap("数学书第 35 页练一练 1–4 题"); shot("tablet-child-4-feedback")
        tap("返回"); tap("奖励时间"); shot("tablet-child-5-reward")
    }
}
