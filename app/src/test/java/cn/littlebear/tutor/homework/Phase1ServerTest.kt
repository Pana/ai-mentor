package cn.littlebear.tutor.homework

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The whole phase-1 loop through the Android data layer against a real server
 * (start one with `scripts/android-phase1-e2e.sh`, which sets E2E_SERVER and E2E_PARENT_SECRET).
 * Skipped when no server is configured, so plain `testDebugUnitTest` stays offline.
 */
class Phase1ServerTest {
    private val server = System.getenv("E2E_SERVER")
    private val secret = System.getenv("E2E_PARENT_SECRET")

    /** Real network, with a switch to simulate the child's tablet losing Wi-Fi. */
    private class Switchable(private val real: HttpTransport = OkHttpTransport()) : HttpTransport {
        @Volatile var offline = false
        override suspend fun execute(request: Request): Pair<Int, ByteArray> {
            if (offline) throw java.io.IOException("offline")
            return real.execute(request)
        }
    }

    private fun tempDir(name: String): File = Files.createTempDirectory("hw-$name").toFile()

    /** The server checks file signatures only; real photos come from the camera. `shade` keeps pages distinct. */
    private fun jpeg(shade: Int): ByteArray = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte()) +
        ByteArray(256) { shade.toByte() } + byteArrayOf(0xFF.toByte(), 0xD9.toByte())

    private fun png(): ByteArray = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + ByteArray(64) { 7 }

    /** The server only checks the MP4 `ftyp` box; real recordings come from MediaRecorder. */
    private fun m4a(): ByteArray = byteArrayOf(0, 0, 0, 0x18) + "ftypM4A ".toByteArray() + ByteArray(64)

    @Test fun childSeesParentsChangeWhileWaitingForChanges() = runBlocking {
        assumeTrue("set E2E_SERVER and E2E_PARENT_SECRET (scripts/android-phase1-e2e.sh)", server != null && secret != null)
        val parent = HomeworkStore(tempDir("lp-parent"), MemorySessionStorage(), debug = true)
        parent.connectParent(server!!, secret!!, "长轮询家长")
        parent.saveChild(name = "长轮询", grade = 1)
        val child = parent.state.value.children.single { it.name == "长轮询" }
        // The server has one family; this child is removed again so the full-loop test still sees only its own.
        try {
            val kid = HomeworkStore(tempDir("lp-child"), MemorySessionStorage(), debug = true)
            kid.pairChild(server, parent.pairingCode().code, "长轮询平板")
            kid.sync()

            // The child's request is held open; the parent's write answers it at once instead of after the 25 s wait.
            val started = System.currentTimeMillis()
            val waiting = async { kid.waitForChanges(); System.currentTimeMillis() - started }
            delay(500)
            parent.create(listOf(NewHomework(childId = child.id, subject = "MATH", date = parent.today, content = "长轮询测试", mode = "OFFLINE")))
            val waited = waiting.await()
            assertTrue("woken by the change, waited $waited ms", waited in 400..5_000)
            kid.sync()
            assertTrue(kid.state.value.items(child.id).any { it.content == "长轮询测试" })
        } finally {
            parent.deleteChild(child.id)
        }
    }

    /** A video is handed in from a file (as `video/mp4`), streamed back with a Range request, and graded like a recording. */
    @Test fun childHandsInAVideoAndTheParentGradesIt() = runBlocking {
        assumeTrue("set E2E_SERVER and E2E_PARENT_SECRET (scripts/android-phase1-e2e.sh)", server != null && secret != null)
        val parent = HomeworkStore(tempDir("video-parent"), MemorySessionStorage(), debug = true)
        parent.connectParent(server!!, secret!!, "录像家长")
        parent.saveChild(name = "录像", grade = 2)
        val child = parent.state.value.children.single { it.name == "录像" }
        // Removed again at the end so the full-loop test still sees only its own child.
        try {
            val net = Switchable()
            val kid = HomeworkStore(tempDir("video-child"), MemorySessionStorage(), transport = net, debug = true)
            kid.pairChild(server, parent.pairingCode().code, "录像平板")
            parent.create(listOf(NewHomework(childId = child.id, subject = "OTHER", date = parent.today, content = "跳绳 1 分钟录像", mode = "ONLINE", onlineKind = "VIDEO")))
            kid.sync()
            val item = kid.state.value.items(child.id).single()
            assertTrue(item.isVideo)

            // The server refuses a video hand-in without the video.
            val missing = runCatching { kid.submit(item) }
            assertTrue(missing.isSuccess)
            assertEquals("要先录一段视频。", kid.error.value)
            kid.error.value = null
            kid.sync()

            // Offline first: it waits in the outbox as a file, then goes up when the network is back.
            val video = File(tempDir("video-src"), "v.mp4").apply { writeBytes(byteArrayOf(0, 0, 0, 0x18) + "ftypisom".toByteArray() + ByteArray(2_000_000) { (it % 253).toByte() }) }
            val size = video.length()
            net.offline = true
            kid.submit(kid.state.value.homework.getValue(item.id), video = video)
            assertTrue("moved into the outbox", !video.exists())
            assertEquals(1, kid.state.value.outbox.size)
            net.offline = false
            kid.sync()
            assertTrue(kid.state.value.outbox.isEmpty())
            val handedIn = kid.state.value.homework.getValue(item.id)
            assertEquals("SUBMITTED", handedIn.status)
            val fileId = handedIn.latest!!.fileIds.single()

            // What the player does: stream with the device credential, a byte range at a time.
            val api = parent.client!!
            val ranged = OkHttpTransport.defaultClient.newCall(Request.Builder().url(api.fileUrl(fileId))
                .header("Authorization", "Bearer ${api.token}").header("Range", "bytes=0-15").build()).execute()
            ranged.use {
                assertEquals(206, it.code)
                assertEquals("video/mp4", it.header("Content-Type"))
                assertEquals("bytes 0-15/$size", it.header("Content-Range"))
                assertEquals("ftypisom", it.body!!.bytes().copyOfRange(4, 12).decodeToString())
            }

            parent.sync()
            val waiting = parent.state.value.homework.getValue(item.id)
            parent.review(waiting.latest!!, waiting, "GOOD", "跳得很有节奏", requireCorrection = false, overlays = emptyList())
            kid.sync()
            val graded = kid.state.value.homework.getValue(item.id)
            assertEquals("REVIEWED", graded.status)
            assertEquals("跳得很有节奏", graded.latestReview!!.comment)
        } finally {
            parent.deleteChild(child.id)
        }
    }

    @Test fun parentAndChildRunThePhase1LoopThroughTheServer() = runBlocking {
        assumeTrue("set E2E_SERVER and E2E_PARENT_SECRET (scripts/android-phase1-e2e.sh)", server != null && secret != null)

        // Parent phone connects and sets up the family.
        val parent = HomeworkStore(tempDir("parent"), MemorySessionStorage(), debug = true)
        parent.connectParent(server!!, secret!!, "测试家长手机")
        assertTrue(parent.state.value.session!!.isParent)
        parent.saveChild(name = "小明", grade = 2)
        val child = parent.state.value.children.single()
        // A window that is always open, so the test does not depend on the time of day.
        parent.saveRules(RewardRules(finishTime = "23:59", windowStart = "00:00", windowEnd = "23:59"))

        // Child tablet pairs with a code from the parent.
        val net = Switchable()
        val kidDir = tempDir("child")
        val kid = HomeworkStore(kidDir, MemorySessionStorage(), transport = net, debug = true)
        kid.pairChild(server, parent.pairingCode().code, "测试孩子平板")
        assertEquals("child", kid.state.value.session!!.role)
        kid.sync()
        assertEquals(listOf("小明"), kid.state.value.children.map { it.name })

        // Parent enters three kinds of homework for today.
        val today = parent.today
        val attachment = parent.uploadImages(listOf(jpeg(1))).single()
        parent.create(listOf(
            NewHomework(childId = child.id, subject = "MATH", date = today, dueDate = Day.add(today, 1), content = "口算本第 12 页",
                rawText = "数学：口算本第12页，明早交[抱拳]", mode = "OFFLINE", parentTodo = "检查后签字", attachmentIds = listOf(attachment)),
            NewHomework(childId = child.id, subject = "ENGLISH", date = today, content = "英语朗读 1 分钟", mode = "ONLINE", onlineKind = "TIMER", durationMinutes = 1),
            NewHomework(childId = child.id, subject = "CHINESE", date = today, content = "背诵《咏柳》", mode = "ONLINE", onlineKind = "RECORDING"),
        ))
        kid.sync()
        val items = kid.state.value.items(child.id).associateBy { it.subject }
        assertEquals(setOf("MATH", "ENGLISH", "CHINESE"), items.keys)
        assertEquals("口算本第 12 页", items.getValue("MATH").content)
        // The teacher's picture reaches the child's device.
        assertTrue(kid.fileData(attachment).isNotEmpty())

        // Offline photo submission waits in the queue, then goes out when the network is back.
        net.offline = true
        kid.submit(items.getValue("MATH"), pages = listOf(jpeg(2), jpeg(3)))
        assertEquals(1, kid.state.value.outbox.size)
        assertEquals("SUBMITTED", kid.state.value.homework.getValue(items.getValue("MATH").id).status)
        net.offline = false
        kid.sync()
        assertTrue(kid.state.value.outbox.isEmpty())
        val math = kid.state.value.homework.getValue(items.getValue("MATH").id)
        assertEquals("SUBMITTED", math.status)
        assertEquals(2, math.latest!!.fileIds.size)
        assertTrue("submitted before the family's finish time", math.latest!!.onTime)

        // Timer completes itself; recording waits for the parent.
        kid.submit(items.getValue("ENGLISH"), durationSeconds = 60)
        kid.submit(items.getValue("CHINESE"), audio = m4a())
        assertEquals("REVIEWED", kid.state.value.homework.getValue(items.getValue("ENGLISH").id).status)
        assertEquals("SUBMITTED", kid.state.value.homework.getValue(items.getValue("CHINESE").id).status)

        // Parent grades: the photo needs a correction (with red-pen overlays), the recording is excellent.
        parent.sync()
        val waiting = parent.state.value.items(child.id).filter { it.awaitingReview }
        assertEquals(2, waiting.size)
        val photoItem = waiting.first { it.isOffline }
        parent.review(photoItem.latest!!, photoItem, "FAIR", "第 3 题再算一遍", requireCorrection = true, overlays = listOf(png(), png()))
        val audioItem = waiting.first { it.isRecording }
        parent.review(audioItem.latest!!, audioItem, "EXCELLENT", "背得很流利", requireCorrection = false, overlays = emptyList())

        // Child sees the red pen and corrects.
        kid.sync()
        val corrected = kid.state.value.homework.getValue(photoItem.id)
        assertEquals("NEEDS_CORRECTION", corrected.status)
        val review = corrected.latestReview!!
        assertEquals("第 3 题再算一遍", review.comment)
        assertEquals(2, review.annotationFileIds.size)
        assertNotNull(overlayFile(corrected.latest!!, 1))
        assertTrue(kid.fileData(review.annotationFileIds.first()).copyOfRange(1, 4).decodeToString() == "PNG")
        kid.submit(corrected, pages = listOf(jpeg(4)))
        parent.sync()
        val second = parent.state.value.homework.getValue(photoItem.id)
        assertEquals(2, second.latest!!.attempt)
        parent.review(second.latest!!, second, "EXCELLENT", "订正得很好", requireCorrection = false, overlays = emptyList())

        // Rewards: on time + grade (with the top-up after the correction) + timer on time + recording grade.
        kid.sync()
        val rewards = kid.state.value.rewards.getValue(child.id)
        val byReason = rewards.entries.groupBy { it.reason }.mapValues { (_, list) -> list.sumOf { it.minutes } }
        assertEquals(15, byReason["ON_TIME"])         // three homework items handed in on time, 5 each
        assertEquals(10, byReason["GRADE"])           // FAIR 1 + top-up 4 to EXCELLENT, recording EXCELLENT 5
        assertEquals(25, rewards.balance)

        // Spending reward time is checked and debited by the server.
        val session = kid.startReward(child.id, 5)
        assertEquals(5, session.minutes)
        assertEquals(20, kid.state.value.rewards.getValue(child.id).balance)
        val tooMuch = runCatching { kid.startReward(child.id, 30) }.exceptionOrNull()
        assertEquals("daily_cap", (tooMuch as ApiException.Conflict).code)

        // Routines: at most five active ones per child.
        repeat(5) { i ->
            parent.saveRoutine(newId(), RoutineInput(child.id, "坚持 $i", "ENGLISH", "ONLINE", "TIMER", 5, null, (0..6).toList(), true, i))
        }
        val sixth = runCatching { parent.saveRoutine(newId(), RoutineInput(child.id, "第六项", "MATH", "OFFLINE", null, null, null, listOf(1), true, 6)) }.exceptionOrNull()
        assertEquals("routine_limit", (sixth as ApiException.Conflict).code)
        kid.sync()
        assertEquals(5, kid.state.value.items(child.id).count { it.isRoutine && it.date == today })

        // A deleted homework item disappears from the child's device through the change feed.
        parent.delete(audioItem.id)
        kid.sync()
        assertTrue(audioItem.id !in kid.state.value.homework)

        // The cache survives a restart of the app: everything shows before the first sync.
        val reopened = HomeworkStore(kidDir, MemorySessionStorage(kid.state.value.session), transport = net, debug = true)
        assertEquals(kid.state.value.homework.keys, reopened.state.value.homework.keys)
        assertEquals(20, reopened.state.value.rewards.getValue(child.id).balance)

        // Revoking the tablet signs it out on its next sync.
        val tablet = parent.devices().first { it.role == "child" && it.name == "测试孩子平板" }
        parent.revoke(tablet.id)
        kid.sync()
        assertTrue(kid.state.value.signedOut)
    }
}
