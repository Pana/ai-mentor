package cn.littlebear.tutor.homework

import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import okhttp3.Request
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeworkUnitTest {
    @Test fun daysFollowTheServerFormat() {
        assertEquals("2026-11-10", Day.add("2026-11-09", 1))
        assertEquals("2026-02-28", Day.add("2026-03-01", -1))
        assertEquals(1, Day.weekday("2026-11-09")) // Monday
        assertEquals(0, Day.weekday("2026-11-15")) // Sunday
        assertEquals("今天 · 11 月 9 日 周一", Day.label("2026-11-09", today = "2026-11-09"))
        assertEquals("明天 · 11 月 10 日 周二", Day.label("2026-11-10", today = "2026-11-09"))
        assertEquals("11/9", Day.short("2026-11-09"))
        // 2026-11-09 16:30 UTC is already the 10th in Beijing.
        assertEquals("2026-11-10", Day.today("Asia/Shanghai", java.time.Instant.parse("2026-11-09T16:30:00Z").toEpochMilli()))
    }

    @Test fun serverAddressesAreHttpsOrLocalInDebug() {
        assertEquals("https://hw.example.cn", ApiClient.validate(" https://hw.example.cn/ ", debug = false))
        assertTrue(runCatching { ApiClient.validate("http://hw.example.cn", debug = false) }.isFailure)
        assertTrue(runCatching { ApiClient.validate("http://192.168.1.20:8787", debug = false) }.isFailure)
        assertEquals("http://192.168.1.20:8787", ApiClient.validate("http://192.168.1.20:8787", debug = true))
        assertEquals("http://10.0.2.2:8787", ApiClient.validate("http://10.0.2.2:8787", debug = true))
        assertTrue(runCatching { ApiClient.validate("http://8.8.8.8", debug = true) }.isFailure)
        assertTrue(runCatching { ApiClient.validate("https://user@hw.example.cn", debug = false) }.isFailure)
        assertTrue(runCatching { ApiClient.validate("https://hw.example.cn/api?x=1", debug = false) }.isFailure)
    }

    @Test fun errorCodesBecomeFriendlyMessages() {
        assertEquals("每天坚持最多 5 项。先暂停或删除一项再加。", ApiException.from(409, "routine_limit").message)
        assertTrue(ApiException.from(401, "unauthorized") is ApiException.Unauthorized)
        assertEquals("填写的内容不符合要求，请检查后再试。", ApiException.from(400, "something_new").message)
    }

    @Test fun wireTypesTolerateNewFieldsAndNulls() {
        val json = """{"id":"a","childId":"c","subject":"MATH","date":"2026-11-09","dueDate":null,"content":"口算","rawText":"",
            "mode":"OFFLINE","onlineKind":null,"durationMinutes":null,"parentTodo":"","status":"SUBMITTED","source":"PASTE",
            "routineId":null,"attachmentIds":[],"createdAt":"x","updatedAt":"y","version":2,"futureField":1,
            "submissions":[{"id":"s","attempt":1,"fileIds":["f"],"durationSeconds":null,"submittedAt":"t","receivedAt":"t","onTime":true,"review":null}]}"""
        val item = wireJson.decodeFromString(RemoteHomework.serializer(), json)
        assertTrue(item.awaitingReview)
        assertNull(item.latestReview)
        assertEquals(listOf("f"), item.latest!!.fileIds)
    }

    /** With no network, a submission is queued, shown as handed in, and kept across restarts. */
    @Test fun offlineSubmissionsAreQueuedAndCached() = runBlocking {
        val dir = Files.createTempDirectory("hw-offline").toFile()
        val session = DeviceSession("http://127.0.0.1:9", "d", "child", "f", "t".repeat(64))
        val offline = HttpTransport { _: Request -> throw java.io.IOException("offline") }
        val store = HomeworkStore(dir, MemorySessionStorage(session), transport = offline, debug = true)
        val item = RemoteHomework(id = newId(), childId = "c", subject = "MATH", date = "2026-11-09", content = "口算", mode = "OFFLINE", status = "NOT_STARTED")
        store.submit(item, pages = listOf(byteArrayOf(1, 2, 3)))
        assertEquals(1, store.state.value.outbox.size)
        assertEquals("SUBMITTED", store.state.value.homework.getValue(item.id).status)
        assertNull("offline is not an error worth an alert", store.error.value)
        val reopened = HomeworkStore(dir, MemorySessionStorage(session), transport = offline, debug = true)
        assertEquals(1, reopened.state.value.outbox.size)
        assertTrue(reopened.outboxFile(reopened.state.value.outbox.single().files.single()).exists())
        reopened.signOut()
        assertTrue(reopened.state.value.outbox.isEmpty())
        assertFalse(store.outboxFile(store.state.value.outbox.single().files.single()).exists())
    }

    @Test fun entryModeDefaultsToAiAndRemembersTheChoice() {
        assertEquals(EntryMode.AI, EntryMode.of(null))
        assertEquals(EntryMode.AI, EntryMode.of("SOMETHING_OLD"))
        assertEquals(EntryMode.MANUAL, EntryMode.of(EntryMode.MANUAL.name))
        assertEquals("粘贴老师发的作业，AI 拆成一项项，你核对后保存。", EntryMode.AI.hint)
        assertEquals("自己一项项填写，填完直接保存。", EntryMode.MANUAL.hint)
    }

    @Test fun picturesAddedWhileFillingInGoWithTheFirstItem() {
        val form = EntryForm()
        form.manualDrafts.addAll(listOf(DraftItem.blank("2026-11-16"), DraftItem.blank("2026-11-16")))
        form.addImage(byteArrayOf(1))
        assertEquals(listOf(true, false), form.manualDrafts.map { it.attachImages })
        // The parent's own choice wins after that.
        form.manualDrafts[0] = form.manualDrafts[0].copy(attachImages = false)
        form.addImage(byteArrayOf(2))
        assertEquals(listOf(false, false), form.manualDrafts.map { it.attachImages })
        repeat(6) { form.addImage(byteArrayOf(3)) }
        assertEquals(6, form.images.size)
        form.reset()
        assertTrue(form.images.isEmpty())
        assertEquals(2, form.manualDrafts.size)
    }

    @Test fun draftsBecomeOneHomeworkPerChildAndItem() {
        val ming = RemoteChild("c1", "小明", 2); val hong = RemoteChild("c2", "小红", 3); val other = RemoteChild("c3", "小刚", 1)
        val drafts = listOf(
            DraftItem.blank("2026-11-16", attach = true).copy(content = " 口算第 12 页 ", parentTodo = " 签字 "),
            DraftItem.blank("2026-11-16").copy(subject = "CHINESE", content = "朗读课文", kind = DoneBy.TIMER, minutes = 15, hasDue = true, dueDate = "2026-11-15"),
        )
        assertTrue(drafts.complete())
        assertFalse((drafts + DraftItem.blank("2026-11-16")).complete())
        assertFalse(emptyList<DraftItem>().complete())
        val items = newHomework(drafts, listOf(ming, hong, other), setOf("c1", "c2"), "", listOf("f1"))
        assertEquals(listOf("c1", "c1", "c2", "c2"), items.map { it.childId })
        assertEquals("口算第 12 页", items[0].content); assertEquals("签字", items[0].parentTodo)
        assertEquals(listOf("f1"), items[0].attachmentIds); assertTrue(items[1].attachmentIds.isEmpty())
        assertNull(items[0].dueDate); assertNull(items[0].durationMinutes); assertEquals("OFFLINE", items[0].mode)
        // A due date before the assigned day is moved up to it.
        assertEquals("2026-11-16", items[1].dueDate); assertEquals(15, items[1].durationMinutes); assertEquals("TIMER", items[1].onlineKind)
    }

    // ---------- Video homework ----------

    private fun homework(kind: String?, mode: String = "ONLINE") =
        RemoteHomework(id = newId(), childId = "c", subject = "OTHER", date = "2026-11-21", content = "跳绳", mode = mode, onlineKind = kind, status = "NOT_STARTED")

    @Test fun videoIsAKindNextToRecordingAndTimer() {
        assertEquals(listOf("本子上写，拍照交", "在线计时", "在线录音", "在线录像"), DoneBy.entries.map { it.label })
        assertEquals(DoneBy.VIDEO, DoneBy.of("ONLINE", "VIDEO"))
        assertEquals("ONLINE" to "VIDEO", DoneBy.VIDEO.mode to DoneBy.VIDEO.onlineKind)
        assertFalse(DoneBy.VIDEO.usesDuration)
        assertEquals(DoneBy.RECORDING, DoneBy.of("ONLINE", "SOMETHING_NEW"))
        assertEquals(DoneBy.PHOTO, DoneBy.of("OFFLINE", "VIDEO"))
        assertTrue(homework("VIDEO").isVideo); assertFalse(homework("RECORDING").isVideo)
        assertEquals("在线录像", modeLabel(homework("VIDEO")))
        assertEquals("在线录音", modeLabel(homework("RECORDING")))
        val routine = RoutineDraft(childId = "c", title = "跳绳", kind = DoneBy.VIDEO, weekdays = (1..5).toSet())
        assertEquals("周一到周五 · 在线录像", routine.summary)
        assertEquals("VIDEO", routine.input.onlineKind); assertNull(routine.input.durationMinutes)
        assertEquals(DoneBy.VIDEO, RoutineDraft.from(Routine("r", "c", "跳绳", "OTHER", "ONLINE", "VIDEO")).kind)
        val item = newHomework(listOf(DraftItem.blank("2026-11-21").copy(content = "跳绳", kind = DoneBy.VIDEO)), listOf(RemoteChild("c", "小明", 2)), setOf("c"), "", emptyList()).single()
        assertEquals("ONLINE" to "VIDEO", item.mode to item.onlineKind)
    }

    @Test fun aiReviewUsesTheParsedOnlineKind() {
        val json = """{"items":[{"subject":"OTHER","content":"跳绳 1 分钟录视频","mode":"ONLINE","onlineKind":"VIDEO"},
            {"subject":"CHINESE","content":"朗读","mode":"ONLINE","onlineKind":null},{"subject":"ENGLISH","content":"听读 10 分钟","mode":"ONLINE","onlineKind":"TIMER"},
            {"subject":"MATH","content":"口算","mode":"OFFLINE","onlineKind":null},{"subject":"CHINESE","content":"背诵","mode":"ONLINE"}],"message":""}"""
        val parsed = wireJson.decodeFromString(ParseResult.serializer(), json).items
        assertEquals("VIDEO", parsed[0].onlineKind)
        assertEquals(listOf(DoneBy.VIDEO, DoneBy.RECORDING, DoneBy.TIMER, DoneBy.PHOTO, DoneBy.RECORDING),
            parsed.map { DraftItem.from(it, "2026-11-21", attachImages = false).kind })
    }

    @Test fun videosAreScaledToA480ShortSideKeepingTheAspect() {
        assertEquals(854 to 480, VideoRules.targetSize(1920, 1080))
        assertEquals(480 to 854, VideoRules.targetSize(1920, 1080, rotation = 90))   // a phone held upright
        assertEquals(854 to 480, VideoRules.targetSize(1080, 1920, rotation = 270))
        assertEquals(480 to 854, VideoRules.targetSize(720, 1280))
        assertEquals(640 to 480, VideoRules.targetSize(1440, 1080))                  // 4:3 tablet camera
        assertEquals(480 to 640, VideoRules.targetSize(3024, 4032))
        assertEquals(640 to 480, VideoRules.targetSize(640, 480))                    // never scaled up
        assertEquals(320 to 240, VideoRules.targetSize(320, 240))
        assertEquals(322 to 242, VideoRules.targetSize(321, 241))                    // but always even
        assertEquals(854 to 480, VideoRules.targetSize(0, 0))
    }

    @Test fun videosLongerThanThirtyMinutesAreRefused() {
        assertNull(VideoRules.lengthProblem(65_000))
        assertNull(VideoRules.lengthProblem(1_800_000))
        assertNull("a camera stopped at the limit may run a little over", VideoRules.lengthProblem(1_800_700))
        assertEquals("这个视频有 31 分钟，超过 30 分钟了。请录短一点再交。", VideoRules.lengthProblem(1_801_000))
        assertEquals("这个视频有 45 分钟，超过 30 分钟了。请录短一点再交。", VideoRules.lengthProblem(45 * 60_000L))
        assertEquals("视频太短了，再录一次吧。", VideoRules.lengthProblem(400))
        assertEquals("这个视频读不出来，换一个试试吧。", VideoRules.lengthProblem(null))
        assertEquals("3 分 25 秒", VideoRules.lengthLabel(205_000))
        assertEquals("42 秒", VideoRules.lengthLabel(41_600))
        val at = java.time.Instant.parse("2026-11-21T11:30:05Z").toEpochMilli()
        assertEquals("小熊伴学_数学_20261121_193005.mp4", VideoRules.galleryName("MATH", at, "Asia/Shanghai"))
    }

    private fun mp4(dir: File, size: Int = 300_000): File =
        File(dir, "compressed.mp4").apply { writeBytes(byteArrayOf(0, 0, 0, 0x18) + "ftypisom".toByteArray() + ByteArray(size) { (it % 251).toByte() }) }

    /** The queue keeps a path to the video on disk: the compressed file is moved into the outbox, never read into memory. */
    @Test fun aQueuedVideoIsAFileInTheOutbox() = runBlocking {
        val dir = Files.createTempDirectory("hw-video").toFile()
        val session = DeviceSession("http://127.0.0.1:9", "d", "child", "f", "t".repeat(64))
        val offline = HttpTransport { _: Request -> throw java.io.IOException("offline") }
        val store = HomeworkStore(File(dir, "store"), MemorySessionStorage(session), transport = offline, debug = true)
        val video = mp4(dir)
        val bytes = video.readBytes()
        val item = homework("VIDEO")
        store.submit(item, video = video)
        assertFalse("moved, not copied", video.exists())
        val pending = store.state.value.outbox.single().files.single()
        assertTrue(pending.isVideo); assertEquals("video/mp4", pending.mime); assertTrue(pending.localName.endsWith(".mp4"))
        assertEquals("SUBMITTED", store.state.value.homework.getValue(item.id).status)
        assertTrue(store.uploads.value.isEmpty())
        val reopened = HomeworkStore(File(dir, "store"), MemorySessionStorage(session), transport = offline, debug = true)
        assertTrue(bytes.contentEquals(reopened.outboxFile(reopened.state.value.outbox.single().files.single()).readBytes()))
    }

    @Test fun videoUploadsStreamFromDiskAsMp4WithLongTimeouts() {
        val dir = Files.createTempDirectory("hw-upload").toFile()
        val video = mp4(dir)
        val api = ApiClient("https://hw.example.cn", "tok", HttpTransport { _: Request -> 200 to ByteArray(0) })
        val sent = mutableListOf<Long>()
        val request = api.uploadRequest("ABC-1", video, VIDEO_MIME) { done, total -> assertEquals(video.length(), total); sent += done }
        assertEquals("PUT", request.method)
        assertEquals("/v1/files/abc-1", request.url.encodedPath)
        assertEquals("Bearer tok", request.header("Authorization"))
        val body = request.body as FileBody
        assertEquals("video/mp4", body.contentType().toString())
        assertEquals(video.length(), body.contentLength())
        assertEquals(video, body.file)
        assertEquals(LongTransfer, request.tag(LongTransfer::class.java))
        val out = Buffer().also { body.writeTo(it) }
        assertTrue(video.readBytes().contentEquals(out.readByteArray()))
        assertEquals(video.length(), sent.last()); assertTrue(sent.size > 1)
        // Photos keep the normal timeouts.
        assertNull(api.uploadRequest("p", video, "image/jpeg").tag(LongTransfer::class.java))
        val slow = OkHttpTransport.longTransferClient()
        assertEquals(0, slow.callTimeoutMillis); assertEquals(TimeUnit.MINUTES.toMillis(2).toInt(), slow.writeTimeoutMillis)
        assertFalse("never forwards the credential", slow.followRedirects)
        assertEquals("https://hw.example.cn/v1/files/abc-1", api.fileUrl("ABC-1"))
    }

    /** Back online: the video goes up as `video/mp4` from the outbox file, then the submission names exactly that one file. */
    @Test fun aQueuedVideoIsUploadedThenSubmitted() = runBlocking {
        val dir = Files.createTempDirectory("hw-flush").toFile()
        val session = DeviceSession("http://127.0.0.1:9", "d", "child", "f", "t".repeat(64))
        val item = homework("VIDEO")
        var online = false
        val seen = mutableListOf<String>()
        var uploadedType: String? = null; var uploadedLength = -1L; var submitted = ""
        val server = HttpTransport { request: Request ->
            if (!online) throw java.io.IOException("offline")
            val path = request.url.encodedPath
            seen += "${request.method} $path"
            when {
                request.method == "PUT" -> { uploadedType = request.body?.contentType()?.toString(); uploadedLength = request.body!!.contentLength(); 200 to "{}".toByteArray() }
                path.endsWith("/submissions") -> {
                    submitted = Buffer().also { request.body!!.writeTo(it) }.readUtf8()
                    200 to wireJson.encodeToString(RemoteHomework.serializer(), item.copy(status = "SUBMITTED")).toByteArray()
                }
                path == "/v1/me" -> 200 to """{"cursor":1,"device":{"id":"d","role":"child"},"family":{"id":"f","timezone":"Asia/Shanghai"},"children":[]}""".toByteArray()
                path == "/v1/homework" -> 200 to """{"items":[]}""".toByteArray()
                path == "/v1/routines" -> 200 to """{"routines":[]}""".toByteArray()
                else -> 404 to "{}".toByteArray()
            }
        }
        val store = HomeworkStore(dir, MemorySessionStorage(session), transport = server, debug = true)
        val video = mp4(Files.createTempDirectory("hw-src").toFile(), 50_000)
        val length = video.length()
        store.submit(item, video = video)
        val outboxFile = store.outboxFile(store.state.value.outbox.single().files.single())
        online = true
        store.sync()
        assertTrue(store.state.value.outbox.isEmpty())
        assertEquals("video/mp4", uploadedType); assertEquals(length, uploadedLength)
        val fileId = seen.first { it.startsWith("PUT") }.substringAfterLast('/')
        assertTrue(submitted, submitted.contains("\"fileIds\":[\"$fileId\"]"))
        assertFalse("the outbox copy is gone once handed in", outboxFile.exists())
        assertFalse("a video is not kept in the file cache", store.cachedFile(fileId).exists())
        assertTrue(store.uploads.value.isEmpty())
        assertNull(store.error.value)
    }
}
