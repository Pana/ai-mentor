package cn.littlebear.tutor

import java.io.IOException
import java.io.ByteArrayOutputStream
import java.net.URI
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

@Serializable data class ServiceSettings(val url: String = "", val token: String = "", val consent: Boolean = false) {
    fun validated(debug: Boolean): ServiceSettings {
        val uri = URI(url.trim().removeSuffix("/"))
        require(uri.host != null && uri.userInfo == null && uri.query == null && uri.fragment == null) { "请填写有效的服务地址" }
        require(uri.scheme == "https" || (debug && uri.scheme == "http" && uri.host in listOf("localhost", "127.0.0.1", "10.0.2.2"))) {
            "服务地址必须使用 HTTPS；调试版仅允许本机 HTTP"
        }
        require(token.length in 24..512 && token.none { it.isWhitespace() }) { "请填写有效的设备访问凭证（至少 24 字符）" }
        return copy(url = uri.toString(), token = token.trim())
    }
}
@Serializable data class TutorRequest(val mode: String, val grade: Int, val subject: String,
    val textbook: String = "", val title: String = "", val instructions: String = "", val answer: String = "",
    val message: String = "", val image: String? = null, val history: List<TutorTurn> = emptyList())
@Serializable data class TutorResponse(val message: String = "", val assessment: String = "UNKNOWN",
    val title: String = "", val instructions: String = "", val subject: String = "",
    val exercise: Exercise? = null)

class TutorService {
    private val json = Json { ignoreUnknownKeys = true }
    private val client = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(65, TimeUnit.SECONDS).callTimeout(75, TimeUnit.SECONDS)
        .followRedirects(false).followSslRedirects(false).build()

    suspend fun request(settings: ServiceSettings, input: TutorRequest): TutorResponse {
        require(settings.consent) { "请家长先开启云端辅导" }
        val config = settings.validated(BuildConfig.DEBUG)
        val request = Request.Builder().url(config.url + "/v1/tutor")
            .header("Authorization", "Bearer ${config.token}")
            .post(json.encodeToString(input).toRequestBody("application/json; charset=utf-8".toMediaType())).build()
        val raw = suspendCancellableCoroutine<String> { continuation ->
            val call = client.newCall(request)
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (!continuation.isCancelled) continuation.resumeWithException(IOException("无法连接辅导服务，请检查网络后重试。"))
                }
                override fun onResponse(call: Call, response: Response) {
                    response.use {
                        try {
                            if (!it.isSuccessful) error(when (it.code) {
                                401, 403 -> "访问凭证无效，请家长检查服务设置。"
                                422 -> "当前辅导服务不能看图。请不发送图片、用文字描述题目，或请家长配置支持图片的模型。"
                                429 -> "请求较多，请稍后再试。"
                                503 -> "模型服务尚未配置或暂不可用。"
                                else -> "辅导服务暂时无法处理，请稍后重试。"
                            })
                            val stream = it.body?.byteStream() ?: error("服务没有返回内容")
                            val buffer = ByteArray(4096)
                            val output = ByteArrayOutputStream()
                            while (true) {
                                val count = stream.read(buffer)
                                if (count < 0) break
                                require(output.size() + count <= 65_536) { "服务回复过长，请重试" }
                                output.write(buffer, 0, count)
                            }
                            val data = output.toByteArray()
                            if (!continuation.isCancelled) continuation.resume(data.toString(Charsets.UTF_8))
                        } catch (e: Exception) {
                            if (!continuation.isCancelled) continuation.resumeWithException(e)
                        }
                    }
                }
            })
        }
        return try {
            val result = json.decodeFromString<TutorResponse>(raw)
            require(result.message.isNotBlank() && result.message.length <= 8000)
            require(result.assessment in listOf("UNKNOWN", "CORRECT", "INCORRECT"))
            result
        } catch (_: Exception) { error("辅导回复格式无法识别，请重试或请家长检查服务设置。") }
    }
}
