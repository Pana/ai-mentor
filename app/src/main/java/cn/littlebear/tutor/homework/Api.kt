package cn.littlebear.tutor.homework

import java.io.IOException
import java.net.URI
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.serializer
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

// Wire types for the phase-1 homework API (`server/src/api.mjs`), matching the iOS client.
// Enumerations stay as strings on the wire so a newer server value never breaks decoding; views use the helpers.

@Serializable data class RemoteChild(val id: String, val name: String, val grade: Int, val avatar: String = "")

@Serializable data class Review(
    val id: String, val grade: String, val comment: String = "", val requireCorrection: Boolean = false,
    val annotationFileIds: List<String> = emptyList(), val reviewedAt: String = "",
)

@Serializable data class Submission(
    val id: String, val attempt: Int, val fileIds: List<String> = emptyList(), val durationSeconds: Int? = null,
    val submittedAt: String = "", val receivedAt: String = "", val onTime: Boolean = false, val review: Review? = null,
)

@Serializable data class RemoteHomework(
    val id: String, val childId: String, val subject: String, val date: String, val dueDate: String? = null,
    val content: String, val rawText: String = "", val mode: String, val onlineKind: String? = null,
    val durationMinutes: Int? = null, val parentTodo: String = "", val status: String, val source: String = "MANUAL",
    val routineId: String? = null, val attachmentIds: List<String> = emptyList(), val version: Int = 0,
    val submissions: List<Submission> = emptyList(),
) {
    val latest: Submission? get() = submissions.lastOrNull()
    val latestReview: Review? get() = submissions.lastOrNull { it.review != null }?.review
    val isOffline: Boolean get() = mode == "OFFLINE"
    val isTimer: Boolean get() = onlineKind == "TIMER"
    val isRecording: Boolean get() = onlineKind == "RECORDING"
    val isRoutine: Boolean get() = source == "ROUTINE"
    val needsWork: Boolean get() = status == "NOT_STARTED" || status == "NEEDS_CORRECTION"
    val awaitingReview: Boolean get() = status == "SUBMITTED"
}

@Serializable data class Routine(
    val id: String, val childId: String, val title: String, val subject: String, val mode: String,
    val onlineKind: String? = null, val durationMinutes: Int? = null, val quantity: Int? = null,
    val weekdays: List<Int> = emptyList(), val active: Boolean = true, val sortOrder: Int = 0,
)

@Serializable data class RewardRules(
    val finishTime: String = "19:30", val onTime: Int = 5, val gradeExcellent: Int = 5, val gradeGood: Int = 3,
    val gradeFair: Int = 1, val checkin: Int = 3, val streak7: Int = 10, val dailyCap: Int = 30,
    val windowStart: String = "19:00", val windowEnd: String = "20:30", val requireAllSubmitted: Boolean = true,
) {
    fun points(grade: String): Int = when (grade) { "EXCELLENT" -> gradeExcellent; "GOOD" -> gradeGood; "FAIR" -> gradeFair; else -> 0 }
}

@Serializable data class RewardEntry(val id: String, val minutes: Int, val reason: String, val refId: String = "", val date: String = "", val createdAt: String = "")

@Serializable data class RewardSummary(val childId: String, val balance: Int = 0, val earnedToday: Int = 0, val usedToday: Int = 0, val entries: List<RewardEntry> = emptyList())

@Serializable data class FamilyInfo(val id: String, val name: String = "", val timezone: String = "Asia/Shanghai", val today: String = "")
@Serializable data class DeviceInfo(val id: String, val role: String, val name: String = "")
@Serializable data class MeResponse(val cursor: Int, val device: DeviceInfo, val family: FamilyInfo, val children: List<RemoteChild> = emptyList(), val rules: RewardRules = RewardRules())
@Serializable data class Change(val seq: Int, val entity: String, val id: String, val op: String)
@Serializable data class ChangeFeed(val changes: List<Change> = emptyList(), val next: Int, val hasMore: Boolean = false)
@Serializable data class DeviceGrant(val deviceId: String, val deviceToken: String, val role: String, val familyId: String)
@Serializable data class PairingCode(val code: String, val expiresAt: String)
@Serializable data class DeviceRecord(val id: String, val role: String, val name: String = "", val createdAt: String = "", val lastSeenAt: String? = null, @SerialName("self") val isSelf: Boolean = false)
@Serializable data class ParsedItem(val subject: String, val content: String, val mode: String = "OFFLINE", val dueText: String = "", val dueDate: String? = null, val parentTodo: String = "")
@Serializable data class ParseResult(val items: List<ParsedItem> = emptyList(), val message: String = "")
@Serializable data class RewardSession(val id: String, val minutes: Int, val endsAt: String)

/** Fields for a new homework item (`POST /v1/homework`). */
@Serializable data class NewHomework(
    val id: String = newId(), val childId: String, val subject: String, val date: String, val dueDate: String? = null,
    val content: String, val rawText: String = "", val mode: String, val onlineKind: String? = null,
    val durationMinutes: Int? = null, val parentTodo: String = "", val attachmentIds: List<String> = emptyList(),
)

@Serializable data class RoutineInput(
    val childId: String, val title: String, val subject: String, val mode: String, val onlineKind: String? = null,
    val durationMinutes: Int? = null, val quantity: Int? = null, val weekdays: List<Int>, val active: Boolean, val sortOrder: Int,
)

fun newId(): String = java.util.UUID.randomUUID().toString()

// ---------- Errors ----------

sealed class ApiException(val code: String? = null) : Exception() {
    class InvalidServer(private val debug: Boolean) : ApiException() {
        override val message get() = if (debug) "服务器地址需为 HTTPS（调试版也可用 http://10.0.2.2:8787、127.0.0.1 或局域网地址）。" else "服务器地址必须是 HTTPS。"
    }
    object Network : ApiException() { private fun readResolve(): Any = Network; override val message get() = "连不上服务器，请检查网络。已保存的内容不会丢。" }
    object Unauthorized : ApiException() { private fun readResolve(): Any = Unauthorized; override val message get() = "这台设备的登录已失效，请重新连接。" }
    object Forbidden : ApiException() { private fun readResolve(): Any = Forbidden; override val message get() = "这台设备没有权限做这件事。" }
    object NotFound : ApiException() { private fun readResolve(): Any = NotFound; override val message get() = "内容已经不存在了，可能被家长删除了。" }
    class Conflict(code: String) : ApiException(code) { override val message get() = messages[code] ?: "操作和当前状态冲突，刷新后再试。" }
    class Rejected(code: String) : ApiException(code) { override val message get() = messages[code] ?: "填写的内容不符合要求，请检查后再试。" }
    object Server : ApiException() { private fun readResolve(): Any = Server; override val message get() = "服务器暂时出错，请稍后再试。" }
    object InvalidResponse : ApiException() { private fun readResolve(): Any = InvalidResponse; override val message get() = "服务器返回的内容无法识别。" }

    companion object {
        fun from(status: Int, code: String): ApiException = when (status) {
            401 -> Unauthorized
            403 -> Forbidden
            404 -> NotFound
            409 -> Conflict(code)
            400, 413, 415, 422 -> Rejected(code)
            else -> Server
        }

        val messages = mapOf(
            "routine_limit" to "每天坚持最多 5 项。先暂停或删除一项再加。",
            "not_submittable" to "这项作业已经交过了，等家长批改。",
            "duration_not_met" to "时间还没到，再坚持一下。",
            "already_reviewed" to "这次提交已经批改过了。",
            "not_latest_submission" to "孩子已经重新提交，请批改最新一次。",
            "outside_window" to "现在不在可以使用奖励时间的时段。",
            "homework_pending" to "今天还有作业没交，交完就能用奖励时间。",
            "daily_cap" to "今天的奖励时间已经用到上限了。",
            "insufficient_balance" to "攒的时间还不够。",
            "photo_required" to "要先拍一张作业照片。",
            "recording_required" to "要先录一段音。",
            "invalid_code" to "配对码不对或已过期，请家长重新生成。",
            "model_not_configured" to "服务器还没有配置 AI 模型，可以先手动填写。",
            "invalid_model_reply" to "AI 这次没整理好，请再试一次或手动填写。",
            "invalid_due_date" to "交作业日期不能早于布置日期。",
            "invalid_window" to "开始时间要早于结束时间。",
            "unsupported_file_type" to "这种文件不能上传。",
            "invalid_file" to "文件已损坏，请重新拍摄。",
            "body_too_large" to "文件太大了。",
        )
    }
}

// ---------- Client ----------

/** Sends one request and returns status and body; swapped out in tests. */
fun interface HttpTransport {
    suspend fun execute(request: Request): Pair<Int, ByteArray>
}

/** OkHttp transport that refuses redirects, so a device credential is never forwarded to another host. */
class OkHttpTransport(private val client: OkHttpClient = defaultClient) : HttpTransport {
    override suspend fun execute(request: Request): Pair<Int, ByteArray> = suspendCancellableCoroutine { continuation ->
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (!continuation.isCancelled) continuation.resumeWithException(e)
            }
            override fun onResponse(call: Call, response: Response) {
                try {
                    val body = response.use { it.body?.bytes() ?: ByteArray(0) }
                    if (!continuation.isCancelled) continuation.resume(response.code to body)
                } catch (e: IOException) {
                    if (!continuation.isCancelled) continuation.resumeWithException(e)
                }
            }
        })
    }

    companion object {
        val defaultClient: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS).readTimeout(75, TimeUnit.SECONDS).callTimeout(90, TimeUnit.SECONDS)
            .followRedirects(false).followSslRedirects(false).build()
    }
}

val wireJson = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }

class ApiClient(val baseUrl: String, val token: String?, private val transport: HttpTransport) {

    companion object {
        /** Accepts an HTTPS root URL, or loopback / emulator-host / home-network HTTP in debug builds. */
        fun validate(text: String, debug: Boolean): String {
            val trimmed = text.trim().removeSuffix("/")
            val uri = try { URI(trimmed) } catch (_: Exception) { throw ApiException.InvalidServer(debug) }
            val host = uri.host ?: throw ApiException.InvalidServer(debug)
            val okScheme = uri.scheme == "https" || (debug && uri.scheme == "http" && isLocalHost(host))
            if (!okScheme || uri.userInfo != null || uri.query != null || uri.fragment != null || (uri.path ?: "").isNotEmpty()) {
                throw ApiException.InvalidServer(debug)
            }
            return trimmed
        }

        fun isLocalHost(host: String): Boolean {
            if (host == "localhost" || host == "127.0.0.1" || host == "10.0.2.2" || host.endsWith(".local")) return true
            val parts = host.split(".").mapNotNull { it.toIntOrNull() }
            if (parts.size != 4) return false
            return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && parts[1] in 16..31)
        }

        private val jsonType = "application/json; charset=utf-8".toMediaType()
    }

    fun request(method: String, path: String, query: Map<String, String> = emptyMap(), body: RequestBody? = null): Request {
        val url = (baseUrl.trimEnd('/') + "/" + path).toHttpUrlOrNull()?.newBuilder()?.apply {
            query.forEach { (k, v) -> addQueryParameter(k, v) }
        }?.build() ?: throw ApiException.InvalidServer(true)
        return Request.Builder().url(url).apply {
            token?.let { header("Authorization", "Bearer $it") }
            method(method, body ?: if (method in listOf("POST", "PUT", "PATCH")) "{}".toRequestBody(jsonType) else null)
        }.build()
    }

    suspend fun raw(request: Request): ByteArray {
        val (status, data) = try { transport.execute(request) }
        catch (e: CancellationException) { throw e }
        catch (e: ApiException) { throw e }
        catch (_: Exception) { throw ApiException.Network }
        if (status !in 200..299) {
            val code = try { (wireJson.parseToJsonElement(data.decodeToString()) as? JsonObject)?.get("error")?.jsonPrimitive?.content } catch (_: Exception) { null }
            throw ApiException.from(status, code ?: "")
        }
        return data
    }

    suspend fun <T> send(method: String, path: String, out: KSerializer<T>, query: Map<String, String> = emptyMap(), json: String? = null): T {
        val data = raw(request(method, path, query, json?.toRequestBody(jsonType)))
        return try { wireJson.decodeFromString(out, data.decodeToString()) } catch (_: Exception) { throw ApiException.InvalidResponse }
    }

    suspend inline fun <reified T> get(path: String, query: Map<String, String> = emptyMap()): T = send("GET", path, serializer(), query)
    suspend inline fun <reified B, reified T> call(method: String, path: String, body: B): T =
        send(method, path, serializer<T>(), json = wireJson.encodeToString(serializer<B>(), body))

    // ---------- Endpoints ----------

    @Serializable private data class Bootstrap(val token: String, val deviceId: String, val name: String)
    @Serializable private data class PairBody(val code: String, val deviceId: String, val name: String)
    @Serializable private data class HomeworkPage(val items: List<RemoteHomework> = emptyList())
    @Serializable private data class ChildrenPage(val children: List<RemoteChild> = emptyList())
    @Serializable private data class RoutinesPage(val routines: List<Routine> = emptyList())

    suspend fun bootstrap(secret: String, deviceId: String, name: String): DeviceGrant =
        send("POST", "v1/devices/bootstrap", DeviceGrant.serializer(), json = wireJson.encodeToString(Bootstrap.serializer(), Bootstrap(secret, deviceId, name)))
    suspend fun pair(code: String, deviceId: String, name: String): DeviceGrant =
        send("POST", "v1/devices/pair", DeviceGrant.serializer(), json = wireJson.encodeToString(PairBody.serializer(), PairBody(code, deviceId, name)))
    suspend fun me(): MeResponse = send("GET", "v1/me", MeResponse.serializer())
    suspend fun changes(since: Int): ChangeFeed = send("GET", "v1/changes", ChangeFeed.serializer(), mapOf("since" to since.toString()))
    suspend fun homework(from: String, to: String): List<RemoteHomework> =
        send("GET", "v1/homework", HomeworkPage.serializer(), mapOf("from" to from, "to" to to)).items
    suspend fun homework(id: String): RemoteHomework = send("GET", "v1/homework/${id.lowercase()}", RemoteHomework.serializer())
    suspend fun children(): List<RemoteChild> = send("GET", "v1/children", ChildrenPage.serializer()).children
    suspend fun routines(): List<Routine> = send("GET", "v1/routines", RoutinesPage.serializer()).routines
    suspend fun rewards(childId: String): RewardSummary = send("GET", "v1/rewards", RewardSummary.serializer(), mapOf("childId" to childId.lowercase()))
    suspend fun upload(fileId: String, data: ByteArray, mime: String) {
        raw(request("PUT", "v1/files/${fileId.lowercase()}", body = data.toRequestBody(mime.toMediaType())))
    }
    suspend fun download(fileId: String): ByteArray = raw(request("GET", "v1/files/${fileId.lowercase()}"))
}
