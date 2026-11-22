package cn.littlebear.tutor.homework

import java.io.File
import java.nio.file.Files
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import okhttp3.Request
import okio.Buffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Thumbnails in the outbox, thumbnail-first previews with a fallback for older photos, and the parent's prefetch. */
class PhotoCacheTest {
    private val childSession = DeviceSession("http://127.0.0.1:9", "d", "child", "f", "t".repeat(64))
    private val parentSession = DeviceSession("http://127.0.0.1:9", "p", "parent", "f", "t".repeat(64))
    private fun dir(name: String): File = Files.createTempDirectory("hw-$name").toFile()

    private fun jpeg(shade: Int, size: Int = 256): ByteArray = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte()) +
        ByteArray(size) { shade.toByte() } + byteArrayOf(0xFF.toByte(), 0xD9.toByte())

    private fun body(request: Request): ByteArray = Buffer().also { request.body!!.writeTo(it) }.readByteArray()

    /** A fake server: answers by method and path, records every request, and can simulate being offline. */
    private class FakeServer(val answer: suspend (Request) -> Pair<Int, ByteArray>) : HttpTransport {
        @Volatile var offline = false
        val seen: MutableList<String> = Collections.synchronizedList(mutableListOf())
        val inFlight = AtomicInteger(); val maxInFlight = AtomicInteger()
        override suspend fun execute(request: Request): Pair<Int, ByteArray> {
            if (offline) throw java.io.IOException("offline")
            seen += "${request.method} ${request.url.encodedPath}"
            val now = inFlight.incrementAndGet()
            maxInFlight.accumulateAndGet(now, ::maxOf)
            try { return answer(request) } finally { inFlight.decrementAndGet() }
        }
    }

    private val ok = """{"id":"x","bytes":1}""".toByteArray()
    private fun notFound(code: String) = 404 to """{"error":"$code"}""".toByteArray()

    private fun item(id: String = newId(), status: String = "NOT_STARTED", date: String = "2026-11-22", mode: String = "OFFLINE", kind: String? = null,
                     files: List<String> = emptyList(), attachments: List<String> = emptyList()) =
        RemoteHomework(id = id, childId = "c", subject = "MATH", date = date, content = "口算", mode = mode, onlineKind = kind, status = status,
            attachmentIds = attachments, submissions = if (files.isEmpty()) emptyList() else listOf(Submission(newId(), 1, files)))

    // ---------- Outbox ----------

    /** Offline, a page waits in the outbox with its thumbnail as a file; back online, the thumbnail goes up right after its photo. */
    @Test fun theOutboxCarriesAThumbnailAndSendsItAfterItsPhoto() = runBlocking {
        val home = dir("thumb-outbox")
        val homework = item()
        var thumbType: String? = null; var thumbBody = ByteArray(0); var submitted = ""
        val server = FakeServer { request ->
            val path = request.url.encodedPath
            when {
                request.method == "PUT" && path.endsWith("/thumb") -> { thumbType = request.body?.contentType()?.toString(); thumbBody = body(request); 200 to ok }
                request.method == "PUT" -> 200 to ok
                path.endsWith("/submissions") -> { submitted = body(request).decodeToString(); 200 to wireJson.encodeToString(RemoteHomework.serializer(), homework.copy(status = "SUBMITTED")).toByteArray() }
                path == "/v1/me" -> 200 to """{"cursor":1,"device":{"id":"d","role":"child"},"family":{"id":"f"},"children":[]}""".toByteArray()
                path == "/v1/homework" -> 200 to """{"items":[]}""".toByteArray()
                path == "/v1/routines" -> 200 to """{"routines":[]}""".toByteArray()
                else -> 404 to "{}".toByteArray()
            }
        }
        server.offline = true
        val store = HomeworkStore(home, MemorySessionStorage(childSession), transport = server, debug = true)
        val page1 = PreparedPhoto(jpeg(1, 5_000), jpeg(11)); val page2 = PreparedPhoto(jpeg(2, 5_000), null)
        store.submit(homework, pages = listOf(page1, page2))
        val queued = store.state.value.outbox.single().files
        assertEquals(listOf(true, false), queued.map { it.thumbName != null })
        assertArrayEquals(page1.thumb, store.outboxThumb(queued[0])!!.readBytes())
        assertTrue("the queue stores names only", wireJson.encodeToString(PendingSubmission.serializer(), store.state.value.outbox.single()).contains("\"thumbName\":\"${queued[0].fileId}.thumb.jpg\""))

        // Survives a restart of the app.
        val reopened = HomeworkStore(home, MemorySessionStorage(childSession), transport = server, debug = true)
        assertEquals(queued, reopened.state.value.outbox.single().files)
        server.offline = false
        reopened.sync()
        assertTrue(reopened.state.value.outbox.isEmpty())
        val first = queued[0].fileId; val second = queued[1].fileId
        val sends = server.seen.filter { it.startsWith("PUT") || it.endsWith("/submissions") }
        assertEquals(listOf("PUT /v1/files/$first", "PUT /v1/files/$first/thumb", "PUT /v1/files/$second"), sends.take(3))
        assertTrue(sends[3].endsWith("/submissions"))
        assertEquals("image/jpeg", thumbType)
        assertArrayEquals(page1.thumb, thumbBody)
        assertTrue(submitted.contains("\"fileIds\":[\"$first\",\"$second\"]"))
        // The child's own pages show from the device: photo and thumbnail are cached, the outbox copies are gone.
        assertArrayEquals(page1.thumb, reopened.cachedThumb(first).readBytes())
        assertArrayEquals(page1.data, reopened.cachedFile(first).readBytes())
        assertFalse(reopened.outboxThumb(queued[0])!!.exists())
        assertFalse(reopened.outboxFile(queued[0]).exists())
        assertNull(reopened.error.value)
    }

    /** A thumbnail the server refuses or that times out never holds up the hand-in. */
    @Test fun aFailedThumbnailNeverBlocksTheSubmission() = runBlocking {
        val homework = item()
        for (failure in listOf<suspend () -> Pair<Int, ByteArray>>({ 500 to "{}".toByteArray() }, { throw java.io.IOException("reset") }, { 413 to """{"error":"body_too_large"}""".toByteArray() })) {
            val server = FakeServer { request ->
                val path = request.url.encodedPath
                when {
                    request.method == "PUT" && path.endsWith("/thumb") -> failure()
                    request.method == "PUT" -> 200 to ok
                    path.endsWith("/submissions") -> 200 to wireJson.encodeToString(RemoteHomework.serializer(), homework.copy(status = "SUBMITTED")).toByteArray()
                    path == "/v1/me" -> 200 to """{"cursor":1,"device":{"id":"d","role":"child"},"family":{"id":"f"},"children":[]}""".toByteArray()
                    path == "/v1/homework" -> 200 to """{"items":[]}""".toByteArray()
                    path == "/v1/routines" -> 200 to """{"routines":[]}""".toByteArray()
                    else -> 404 to "{}".toByteArray()
                }
            }
            val store = HomeworkStore(dir("thumb-fail"), MemorySessionStorage(childSession), transport = server, debug = true)
            store.submit(homework, pages = listOf(PreparedPhoto(jpeg(1), jpeg(2))))
            assertTrue(store.state.value.outbox.isEmpty())
            assertTrue(server.seen.any { it.endsWith("/thumb") })
            assertTrue(server.seen.any { it.endsWith("/submissions") })
            assertNull(store.error.value)
        }
    }

    /** A queue saved by the previous version (no thumbnails) still decodes and sends. */
    @Test fun anOutboxFromBeforeThumbnailsStillDecodes() {
        val old = """{"id":"s","homeworkId":"h","files":[{"fileId":"a","localName":"a.jpg","mime":"image/jpeg"}],"submittedAt":"t"}"""
        val pending = wireJson.decodeFromString(PendingSubmission.serializer(), old)
        assertNull(pending.files.single().thumbName)
    }

    /** The parent's homework pictures: each photo, then its thumbnail; a refused thumbnail does not stop saving. */
    @Test fun parentAttachmentsUploadTheirThumbnailsToo() = runBlocking {
        val server = FakeServer { request -> if (request.url.encodedPath.endsWith("/thumb")) 500 to "{}".toByteArray() else 200 to ok }
        val store = HomeworkStore(dir("attach"), MemorySessionStorage(parentSession), transport = server, debug = true)
        val photo = PreparedPhoto(jpeg(1), jpeg(2))
        val ids = store.uploadImages(listOf(photo, PreparedPhoto(jpeg(3), null)))
        assertEquals(listOf("PUT /v1/files/${ids[0]}", "PUT /v1/files/${ids[0]}/thumb", "PUT /v1/files/${ids[1]}"), server.seen)
        assertArrayEquals(photo.thumb, store.cachedThumb(ids[0]).readBytes())
        assertFalse(store.cachedThumb(ids[1]).exists())
    }

    // ---------- Thumbnail first ----------

    @Test fun previewsLoadTheThumbnailAndFallBackToThePhotoOn404() = runBlocking {
        val withThumb = newId().uppercase(); val older = newId()
        val server = FakeServer { request ->
            when (request.url.encodedPath) {
                "/v1/files/${withThumb.lowercase()}/thumb" -> 200 to jpeg(1)
                "/v1/files/$older/thumb" -> notFound("thumb_not_found")
                "/v1/files/$older" -> 200 to jpeg(9, 4_000)
                else -> notFound("file_not_found")
            }
        }
        val store = HomeworkStore(dir("thumb-first"), MemorySessionStorage(parentSession), transport = server, debug = true)
        assertArrayEquals(jpeg(1), store.thumbData(withThumb))
        assertTrue("cached apart from the photo", store.cachedThumb(withThumb).exists())
        assertFalse(store.cachedFile(withThumb).exists())
        assertEquals(listOf("GET /v1/files/${withThumb.lowercase()}/thumb"), server.seen)

        // A photo from an older app: 404 on the thumbnail, then the photo itself.
        assertArrayEquals(jpeg(9, 4_000), store.thumbData(older))
        assertEquals(listOf("GET /v1/files/$older/thumb", "GET /v1/files/$older"), server.seen.drop(1))
        assertFalse(store.cachedThumb(older).exists())
        assertTrue(store.cachedFile(older).exists())

        // Both now show from the device without asking the server again.
        server.seen.clear()
        assertArrayEquals(jpeg(1), store.thumbData(withThumb))
        assertArrayEquals(jpeg(9, 4_000), store.thumbData(older))
        assertTrue(server.seen.isEmpty())
        // Full-screen review keeps the full photo.
        server.seen.clear()
        val full = runCatching { store.fileData(withThumb) }
        assertTrue(full.exceptionOrNull() is ApiException.NotFound)
        assertEquals(listOf("GET /v1/files/${withThumb.lowercase()}"), server.seen)
    }

    @Test fun aMissingThumbnailIsAskedForOnlyOnce() = runBlocking {
        val id = newId()
        val server = FakeServer { request -> if (request.url.encodedPath.endsWith("/thumb")) notFound("thumb_not_found") else 200 to jpeg(4) }
        val store = HomeworkStore(dir("thumb-once"), MemorySessionStorage(parentSession), transport = server, debug = true)
        store.thumbData(id)
        store.cachedFile(id).delete()
        store.thumbData(id)
        assertEquals(listOf("GET /v1/files/$id/thumb", "GET /v1/files/$id", "GET /v1/files/$id"), server.seen)
    }

    @Test fun offlinePreviewsFailWithoutFallingBack() = runBlocking {
        val server = FakeServer { 200 to jpeg(1) }.apply { offline = true }
        val store = HomeworkStore(dir("thumb-offline"), MemorySessionStorage(parentSession), transport = server, debug = true)
        assertTrue(runCatching { store.thumbData(newId()) }.exceptionOrNull() is ApiException.Network)
    }

    // ---------- Prefetch ----------

    @Test fun prefetchChoosesPagesWaitingForReviewAndRecentPictures() {
        val today = "2026-11-22"
        val homework = listOf(
            item(status = "SUBMITTED", date = "2026-11-01", files = listOf("P1", "p2")),        // waiting, however old
            item(status = "REVIEWED", files = listOf("done")),                                // already graded
            item(status = "SUBMITTED", mode = "ONLINE", kind = "RECORDING", files = listOf("audio")),
            item(status = "SUBMITTED", mode = "ONLINE", kind = "VIDEO", files = listOf("video")),
            item(date = "2026-11-20", attachments = listOf("a1", "A2")),
            item(date = "2026-11-21", attachments = listOf("a2")),                            // shared by two children
            item(date = "2026-11-10", attachments = listOf("old")),                           // older than a week
        )
        val plan = prefetchPlan(homework, today)
        val ids = listOf("p1", "p2", "a2", "a1")
        assertEquals(ids.map { Prefetch(it, true) } + ids.map { Prefetch(it, false) }, plan)
    }

    private fun parentStore(name: String, server: HttpTransport, homework: List<RemoteHomework>, session: DeviceSession? = parentSession): HomeworkStore {
        val home = dir(name)
        // Seed the cache as a previous sync left it.
        File(home, "cache.json").writeText(wireJson.encodeToString(Cache.serializer(), Cache(cursor = 1, homework = homework)))
        return HomeworkStore(home, MemorySessionStorage(session), transport = server, debug = true, now = { java.time.Instant.parse("2026-11-22T10:00:00Z").toEpochMilli() })
    }

    @Test fun prefetchDownloadsWhatIsMissingTwoAtATime() = runBlocking {
        val ids = (1..5).map { newId() }
        val server = FakeServer { request -> delay(30); if (request.url.encodedPath.endsWith("/thumb")) 200 to jpeg(1) else 200 to jpeg(2, 2_000) }
        val homework = listOf(item(status = "SUBMITTED", files = ids.take(3)), item(attachments = ids.drop(3)))
        val store = parentStore("prefetch", server, homework)
        // Already on the device: one photo (so its thumbnail is not needed either) and one thumbnail.
        store.cachedFile(ids[0]).writeBytes(jpeg(5))
        store.cachedThumb(ids[1]).writeBytes(jpeg(6))
        store.prefetch()
        val expected = ids.drop(2).map { "GET /v1/files/$it/thumb" } + ids.drop(1).map { "GET /v1/files/$it" }
        assertEquals(expected.toSet(), server.seen.toSet())
        assertEquals(expected.size, server.seen.size)
        assertEquals("two downloads at a time, never more", 2, server.maxInFlight.get())
        ids.drop(2).forEach { assertTrue(store.cachedThumb(it).exists()) }
        ids.forEach { assertTrue(store.cachedFile(it).exists()) }
        assertArrayEquals("the cached photo is left alone", jpeg(5), store.cachedFile(ids[0]).readBytes())

        // Everything is local now: the next sync's prefetch asks for nothing.
        server.seen.clear()
        store.prefetch()
        assertTrue(server.seen.isEmpty())
    }

    @Test fun prefetchDoesNotRetryAFailedFileButRetriesAfterNoNetwork() = runBlocking {
        val gone = newId(); val fine = newId()
        val server = FakeServer { request ->
            val path = request.url.encodedPath
            when {
                path.contains(gone) -> notFound("file_not_found")
                path.endsWith("/thumb") -> 200 to jpeg(1)
                else -> 200 to jpeg(2)
            }
        }
        val store = parentStore("prefetch-fail", server, listOf(item(status = "SUBMITTED", files = listOf(gone, fine))))
        server.offline = true
        store.prefetch()
        assertTrue(server.seen.isEmpty())
        server.offline = false
        store.prefetch()
        assertTrue(server.seen.contains("GET /v1/files/$gone/thumb"))
        assertTrue(store.cachedFile(fine).exists())
        server.seen.clear()
        store.prefetch()
        assertTrue("a file that failed is not asked for again: ${server.seen}", server.seen.isEmpty())
    }

    @Test fun onlyAParentDeviceWithASessionPrefetches() = runBlocking {
        val server = FakeServer { 200 to jpeg(1) }
        val homework = listOf(item(status = "SUBMITTED", files = listOf(newId())), item(attachments = listOf(newId())))
        parentStore("prefetch-child", server, homework, childSession).prefetch()
        parentStore("prefetch-none", server, homework, session = null).prefetch()
        assertTrue(server.seen.isEmpty())
        val parent = parentStore("prefetch-parent", server, homework)
        assertNotNull(parent.client)
        parent.prefetch()
        assertEquals(4, server.seen.size)
    }
}
