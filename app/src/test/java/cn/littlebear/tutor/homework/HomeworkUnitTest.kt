package cn.littlebear.tutor.homework

import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import okhttp3.Request
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
}
