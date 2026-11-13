package cn.littlebear.tutor.homework

import java.io.File
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable

// ---------- Device session (which server, which role, this device's credential) ----------

@Serializable data class DeviceSession(val server: String, val deviceId: String, val role: String, val familyId: String, val token: String) {
    val isParent: Boolean get() = role == "parent"
}

/** Where the session lives: the app keeps the token encrypted with the Android Keystore; tests keep it in memory. */
interface SessionStorage {
    fun load(): DeviceSession?
    fun save(session: DeviceSession)
    fun clear()
}

class MemorySessionStorage(private var session: DeviceSession? = null) : SessionStorage {
    override fun load() = session
    override fun save(session: DeviceSession) { this.session = session }
    override fun clear() { session = null }
}

// ---------- Dates as the server writes them ("yyyy-MM-dd" in the family's time zone) ----------

object Day {
    fun today(timeZone: String, nowMillis: Long): String =
        Instant.ofEpochMilli(nowMillis).atZone(zone(timeZone)).toLocalDate().toString()
    fun zone(timeZone: String): ZoneId = try { ZoneId.of(timeZone) } catch (_: Exception) { ZoneId.of("Asia/Shanghai") }
    fun parse(day: String): LocalDate? = try { LocalDate.parse(day) } catch (_: Exception) { null }
    fun add(day: String, days: Int): String = parse(day)?.plusDays(days.toLong())?.toString() ?: day
    /** 0 = Sunday, as the server stores routine weekdays. */
    fun weekday(day: String): Int = parse(day)?.dayOfWeek?.let { if (it == DayOfWeek.SUNDAY) 0 else it.value } ?: 0
    val weekdayNames = listOf("日", "一", "二", "三", "四", "五", "六")
    /** "今天 · 11 月 9 日 周一" */
    fun label(day: String, today: String): String {
        val date = parse(day) ?: return day
        val base = "${date.monthValue} 月 ${date.dayOfMonth} 日 周${weekdayNames[weekday(day)]}"
        return when (day) {
            today -> "今天 · $base"
            add(today, -1) -> "昨天 · $base"
            add(today, 1) -> "明天 · $base"
            else -> base
        }
    }
    fun short(day: String): String = parse(day)?.let { "${it.monthValue}/${it.dayOfMonth}" } ?: day
}

// ---------- Offline submission queue (child device) ----------

@Serializable data class PendingFile(val fileId: String, val localName: String, val mime: String)

@Serializable data class PendingSubmission(
    /** Submission id; the server treats a retry with the same id as the same submission. */
    val id: String,
    val homeworkId: String,
    val files: List<PendingFile>,
    val submittedAt: String,
    val durationSeconds: Int? = null,
)

/** Everything shown on screen, cached so the app opens instantly and works offline. */
@Serializable internal data class Cache(
    val cursor: Int = 0,
    val family: FamilyInfo? = null,
    val children: List<RemoteChild> = emptyList(),
    val homework: List<RemoteHomework> = emptyList(),
    val routines: List<Routine> = emptyList(),
    val rules: RewardRules = RewardRules(),
    val rewards: List<RewardSummary> = emptyList(),
    val outbox: List<PendingSubmission> = emptyList(),
)

data class HomeworkState(
    val session: DeviceSession? = null,
    val family: FamilyInfo? = null,
    val children: List<RemoteChild> = emptyList(),
    val homework: Map<String, RemoteHomework> = emptyMap(),
    val routines: List<Routine> = emptyList(),
    val rules: RewardRules = RewardRules(),
    val rewards: Map<String, RewardSummary> = emptyMap(),
    val outbox: List<PendingSubmission> = emptyList(),
    val syncing: Boolean = false,
    val lastSynced: Long? = null,
    /** Set when the server no longer accepts this device's credential. */
    val signedOut: Boolean = false,
) {
    val timeZone: String get() = family?.timezone ?: "Asia/Shanghai"

    fun child(id: String?): RemoteChild? = children.firstOrNull { it.id == id }
    fun pending(homeworkId: String): PendingSubmission? = outbox.firstOrNull { it.homeworkId == homeworkId }

    fun items(child: String?): List<RemoteHomework> = homework.values.filter { child == null || it.childId == child }
        .sortedWith(compareByDescending<RemoteHomework> { it.date }.thenByDescending { if (it.isRoutine) 1 else 0 }.thenByDescending { it.content })

    /** Dates newest first, items in a stable order within each day. */
    fun grouped(child: String?, filter: (RemoteHomework) -> Boolean = { true }): List<Pair<String, List<RemoteHomework>>> =
        homework.values.filter { (child == null || it.childId == child) && filter(it) }.groupBy { it.date }
            .toSortedMap(compareByDescending { it }).map { (day, list) ->
                day to list.sortedWith(compareBy<RemoteHomework> { if (it.isRoutine) 1 else 0 }.thenBy { it.subject }.thenBy { it.content })
            }
}

// ---------- Store ----------

/**
 * Single source of truth on the device: a cache of the server's data, kept current through `/v1/changes`.
 * Mirrors `ipad/LittleBearTutor/Phase1/Store.swift` so both platforms behave the same.
 */
class HomeworkStore(
    private val directory: File,
    private val sessions: SessionStorage,
    private val transport: HttpTransport = OkHttpTransport(),
    private val debug: Boolean = false,
    private val now: () -> Long = System::currentTimeMillis,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val _state = MutableStateFlow(HomeworkState())
    val state: StateFlow<HomeworkState> = _state.asStateFlow()
    /** One message at a time, shown once by the UI. */
    val error = MutableStateFlow<String?>(null)

    private var cursor = 0
    private val syncLock = Mutex()
    @Volatile private var syncAgain = false
    private val outboxDir = File(directory, "outbox")
    private val filesDir = File(directory, "files")
    private val cacheFile = File(directory, "cache.json")

    init {
        outboxDir.mkdirs(); filesDir.mkdirs()
        _state.value = HomeworkState(session = sessions.load())
        loadCache()
    }

    private val current get() = _state.value

    val client: ApiClient? get() {
        val session = current.session ?: return null
        val url = try { ApiClient.validate(session.server, debug) } catch (_: ApiException) { return null }
        return ApiClient(url, session.token, transport)
    }

    val today: String get() = Day.today(current.timeZone, now())

    fun reportError(message: String) { error.value = message }

    // ---------- Session ----------

    suspend fun connectParent(server: String, secret: String, name: String) {
        val url = ApiClient.validate(server, debug)
        val grant = ApiClient(url, null, transport).bootstrap(secret.trim(), newId(), name)
        begin(DeviceSession(url, grant.deviceId, grant.role, grant.familyId, grant.deviceToken))
    }

    suspend fun pairChild(server: String, code: String, name: String) {
        val url = ApiClient.validate(server, debug)
        val grant = ApiClient(url, null, transport).pair(code, newId(), name)
        begin(DeviceSession(url, grant.deviceId, grant.role, grant.familyId, grant.deviceToken))
    }

    private suspend fun begin(session: DeviceSession) {
        sessions.save(session)
        resetData()
        _state.update { it.copy(session = session, signedOut = false) }
    }

    suspend fun signOut() {
        sessions.clear()
        resetData()
        _state.update { it.copy(session = null) }
    }

    private suspend fun resetData() {
        cursor = 0
        current.outbox.forEach(::removeLocalFiles)
        _state.update { HomeworkState(session = it.session, signedOut = it.signedOut) }
        saveCache()
    }

    // ---------- Sync ----------

    suspend fun sync() {
        val api = client ?: return
        if (current.signedOut) return
        if (!syncLock.tryLock()) { syncAgain = true; return }
        try {
            _state.update { it.copy(syncing = true) }
            do {
                syncAgain = false
                try {
                    flushOutbox(api)
                    if (cursor == 0) fullRefresh(api) else applyChanges(api)
                    // Asking for today also makes the server create today's routine items.
                    val todays = api.homework(today, today)
                    _state.update { s -> s.copy(homework = s.homework + todays.associateBy { it.id }, lastSynced = now()) }
                    saveCache()
                } catch (e: CancellationException) { throw e }
                catch (_: ApiException.Unauthorized) {
                    _state.update { it.copy(signedOut = true) }
                    error.value = ApiException.Unauthorized.message
                } catch (_: ApiException.Network) {
                    // Offline: keep showing the cache; the next sync retries.
                } catch (e: ApiException) {
                    error.value = e.message
                }
            } while (syncAgain)
        } finally {
            _state.update { it.copy(syncing = false) }
            syncLock.unlock()
        }
    }

    private suspend fun fullRefresh(api: ApiClient) {
        val me = api.me()
        apply(me)
        val day = Day.today(me.family.timezone, now())
        val window = api.homework(Day.add(day, -45), Day.add(day, 14))
        val routines = api.routines()
        val rewards = me.children.associate { it.id to api.rewards(it.id) }
        _state.update { it.copy(homework = window.associateBy { h -> h.id }, routines = routines, rewards = rewards) }
        cursor = me.cursor
    }

    private fun apply(me: MeResponse) {
        _state.update { it.copy(family = me.family, children = me.children, rules = me.rules) }
    }

    private suspend fun applyChanges(api: ApiClient) {
        var more = true
        while (more) {
            val feed = api.changes(cursor)
            more = feed.hasMore
            val upserts = linkedSetOf<String>(); val deletes = linkedSetOf<String>(); val rewardChildren = linkedSetOf<String>()
            var childrenChanged = false; var routinesChanged = false; var rulesChanged = false
            for (change in feed.changes) {
                when (change.entity) {
                    "homework" -> if (change.op == "DELETE") { deletes += change.id; upserts -= change.id } else { upserts += change.id; deletes -= change.id }
                    "child" -> childrenChanged = true
                    "routine" -> routinesChanged = true
                    "rules" -> rulesChanged = true
                    "reward" -> rewardChildren += change.id
                }
            }
            _state.update { it.copy(homework = it.homework - deletes) }
            if (upserts.size > 40) {
                val window = api.homework(Day.add(today, -45), Day.add(today, 14))
                _state.update { s -> s.copy(homework = s.homework + window.associateBy { it.id }) }
            } else {
                for (id in upserts) {
                    try {
                        val item = api.homework(id)
                        _state.update { it.copy(homework = it.homework + (id to item)) }
                    } catch (_: ApiException.NotFound) {
                        _state.update { it.copy(homework = it.homework - id) }
                    }
                }
            }
            if (childrenChanged || rulesChanged) {
                apply(api.me())
                val known = current.children.map { it.id }.toSet()
                _state.update { s -> s.copy(homework = s.homework.filterValues { it.childId in known }, rewards = s.rewards.filterKeys { it in known }) }
                current.children.filter { it.id !in current.rewards }.forEach { rewardChildren += it.id }
            }
            if (routinesChanged) { val routines = api.routines(); _state.update { it.copy(routines = routines) } }
            for (child in rewardChildren) {
                if (current.child(child) == null) continue
                val summary = api.rewards(child)
                _state.update { it.copy(rewards = it.rewards + (child to summary)) }
            }
            cursor = feed.next
        }
    }

    // ---------- Child: submissions (queued, so a submission made offline is sent later) ----------

    suspend fun submit(item: RemoteHomework, pages: List<ByteArray> = emptyList(), audio: ByteArray? = null, durationSeconds: Int? = null) {
        val files = mutableListOf<PendingFile>()
        withContext(io) {
            pages.forEach { files += storeOutboxFile(it, "image/jpeg", "jpg") }
            audio?.let { files += storeOutboxFile(it, "audio/mp4", "m4a") }
        }
        val pending = PendingSubmission(newId(), item.id, files, Instant.ofEpochMilli(now()).toString(), durationSeconds)
        // Shown as handed in right away; the server's answer replaces this on the next sync.
        val local = item.copy(status = if (item.isTimer) "REVIEWED" else "SUBMITTED")
        _state.update { it.copy(outbox = it.outbox + pending, homework = it.homework + (item.id to local)) }
        saveCache()
        sync()
    }

    private fun storeOutboxFile(data: ByteArray, mime: String, ext: String): PendingFile {
        val id = newId()
        val name = "$id.$ext"
        File(outboxDir, name).writeBytes(data)
        return PendingFile(id, name, mime)
    }

    private fun removeLocalFiles(item: PendingSubmission) {
        item.files.forEach { File(outboxDir, it.localName).delete() }
    }

    @Serializable private data class SubmissionBody(val id: String, val fileIds: List<String>, val submittedAt: String, val durationSeconds: Int? = null)

    private suspend fun flushOutbox(api: ApiClient) {
        for (item in current.outbox) {
            try {
                for (file in item.files) {
                    val local = File(outboxDir, file.localName)
                    val data = withContext(io) { if (local.exists()) local.readBytes() else null } ?: throw ApiException.Rejected("invalid_file")
                    api.upload(file.fileId, data, file.mime)
                    withContext(io) { local.copyTo(cachedFile(file.fileId), overwrite = true) }
                }
                val updated: RemoteHomework = api.call("POST", "v1/homework/${item.homeworkId.lowercase()}/submissions",
                    SubmissionBody(item.id, item.files.map { it.fileId }, item.submittedAt, item.durationSeconds))
                _state.update { it.copy(homework = it.homework + (updated.id to updated)) }
                finish(item)
            } catch (e: ApiException) {
                if (e is ApiException.Network || e is ApiException.Unauthorized || e is ApiException.Server) throw e
                // The server refused it for good (e.g. the homework was deleted); drop it and say why.
                finish(item)
                error.value = e.message
                val fresh = try { api.homework(item.homeworkId) } catch (e2: CancellationException) { throw e2 } catch (_: Exception) { null }
                _state.update { it.copy(homework = if (fresh != null) it.homework + (fresh.id to fresh) else it.homework - item.homeworkId) }
            }
        }
    }

    private suspend fun finish(item: PendingSubmission) {
        withContext(io) { removeLocalFiles(item) }
        _state.update { s -> s.copy(outbox = s.outbox.filterNot { it.id == item.id }) }
        saveCache()
    }

    @Serializable private data class RewardBody(val id: String, val childId: String, val minutes: Int)

    suspend fun startReward(child: String, minutes: Int): RewardSession {
        val api = client ?: throw ApiException.InvalidServer(debug)
        val session: RewardSession = api.call("POST", "v1/rewards/sessions", RewardBody(newId(), child, minutes))
        sync()
        return session
    }

    // ---------- Parent actions (online) ----------

    private fun api(): ApiClient = client ?: throw ApiException.InvalidServer(debug)
    @Serializable private class Ok

    @Serializable private data class ChildBody(val name: String, val grade: Int, val avatar: String = "")
    suspend fun saveChild(id: String = newId(), name: String, grade: Int) {
        api().call<ChildBody, RemoteChild>("PUT", "v1/children/${id.lowercase()}", ChildBody(name.trim(), grade))
        sync()
    }
    suspend fun deleteChild(id: String) {
        api().send("DELETE", "v1/children/${id.lowercase()}", Ok.serializer())
        sync()
    }
    @Serializable private class Empty
    suspend fun pairingCode(): PairingCode = api().call("POST", "v1/devices/pairing-codes", Empty())
    @Serializable private data class DevicesPage(val devices: List<DeviceRecord> = emptyList())
    suspend fun devices(): List<DeviceRecord> = api().send("GET", "v1/devices", DevicesPage.serializer()).devices
    suspend fun revoke(device: String) { api().send("DELETE", "v1/devices/${device.lowercase()}", Ok.serializer()) }

    @Serializable private data class ParseBody(val text: String, val date: String)
    suspend fun parse(text: String): ParseResult = api().call("POST", "v1/homework/parse", ParseBody(text, today))

    /** Uploads JPEG attachments and returns their file ids. */
    suspend fun uploadImages(images: List<ByteArray>): List<String> {
        val api = api()
        return images.map { image ->
            val id = newId()
            api.upload(id, image, "image/jpeg")
            withContext(io) { cachedFile(id).writeBytes(image) }
            id
        }
    }

    @Serializable private data class CreateBody(val items: List<NewHomework>)
    @Serializable private data class HomeworkPage(val items: List<RemoteHomework> = emptyList())
    suspend fun create(items: List<NewHomework>) {
        val page: HomeworkPage = api().call("POST", "v1/homework", CreateBody(items))
        _state.update { s -> s.copy(homework = s.homework + page.items.associateBy { it.id }) }
        saveCache()
        sync()
    }

    @Serializable data class HomeworkPatch(
        val content: String, val subject: String, val date: String, val dueDate: String?, val mode: String,
        val onlineKind: String?, val durationMinutes: Int?, val parentTodo: String,
    )
    suspend fun update(id: String, patch: HomeworkPatch) {
        // `explicitNulls = false` would drop a cleared due date, so send nulls explicitly for PATCH.
        val body = kotlinx.serialization.json.Json { encodeDefaults = true }.encodeToString(HomeworkPatch.serializer(), patch)
        val updated = api().send("PATCH", "v1/homework/${id.lowercase()}", RemoteHomework.serializer(), json = body)
        _state.update { it.copy(homework = it.homework + (id to updated)) }
        sync()
    }

    suspend fun delete(id: String) {
        api().send("DELETE", "v1/homework/${id.lowercase()}", Ok.serializer())
        _state.update { it.copy(homework = it.homework - id) }
        sync()
    }

    @Serializable private data class ReviewBody(val grade: String, val comment: String, val requireCorrection: Boolean, val annotationFileIds: List<String>)
    suspend fun review(submission: Submission, item: RemoteHomework, grade: String, comment: String, requireCorrection: Boolean, overlays: List<ByteArray>) {
        val api = api()
        val ids = overlays.map { png ->
            val id = newId()
            api.upload(id, png, "image/png")
            withContext(io) { cachedFile(id).writeBytes(png) }
            id
        }
        val updated: RemoteHomework = api.call("POST", "v1/submissions/${submission.id.lowercase()}/review", ReviewBody(grade, comment.trim(), requireCorrection, ids))
        _state.update { it.copy(homework = it.homework + (item.id to updated)) }
        sync()
    }

    suspend fun saveRoutine(id: String, input: RoutineInput) {
        api().call<RoutineInput, Routine>("PUT", "v1/routines/${id.lowercase()}", input)
        sync()
    }
    suspend fun deleteRoutine(id: String) {
        api().send("DELETE", "v1/routines/${id.lowercase()}", Ok.serializer())
        sync()
    }
    suspend fun saveRules(rules: RewardRules) {
        val saved: RewardRules = api().call("PUT", "v1/reward-rules", rules)
        _state.update { it.copy(rules = saved) }
        sync()
    }

    // ---------- Files ----------

    fun cachedFile(id: String): File = File(filesDir, id.lowercase())
    fun outboxFile(file: PendingFile): File = File(outboxDir, file.localName)

    suspend fun fileData(id: String): ByteArray {
        val local = cachedFile(id)
        withContext(io) { if (local.exists()) local.readBytes() else null }?.let { return it }
        val data = api().download(id)
        withContext(io) { local.writeBytes(data) }
        return data
    }

    // ---------- Cache ----------

    private fun loadCache() {
        if (current.session == null || !cacheFile.exists()) return
        val cache = try { wireJson.decodeFromString(Cache.serializer(), cacheFile.readText()) } catch (_: Exception) { return }
        cursor = cache.cursor
        _state.update {
            it.copy(family = cache.family, children = cache.children, homework = cache.homework.associateBy { h -> h.id },
                routines = cache.routines, rules = cache.rules, rewards = cache.rewards.associateBy { r -> r.childId }, outbox = cache.outbox)
        }
    }

    private suspend fun saveCache() {
        val s = current
        val cache = Cache(cursor, s.family, s.children, s.homework.values.toList(), s.routines, s.rules, s.rewards.values.toList(), s.outbox)
        val text = wireJson.encodeToString(Cache.serializer(), cache)
        withContext(io) {
            val tmp = File(directory, "cache.json.tmp")
            tmp.writeText(text)
            if (!tmp.renameTo(cacheFile)) { cacheFile.delete(); tmp.renameTo(cacheFile) }
        }
    }

    /** Debug/test hook: drops the cache and every queued submission. */
    suspend fun wipeLocal() { resetData(); cacheFile.delete() }
}

/** Runs an action and routes its error to the store's message. */
suspend fun HomeworkStore.perform(action: suspend () -> Unit): Boolean = try {
    action(); true
} catch (e: CancellationException) { throw e } catch (e: ApiException) {
    reportError(e.message ?: "出错了"); false
} catch (e: Exception) {
    reportError(e.message ?: "出错了"); false
}
