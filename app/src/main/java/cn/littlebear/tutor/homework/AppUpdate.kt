package cn.littlebear.tutor.homework

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.FileProvider
import cn.littlebear.tutor.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

private val updateHttp = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).build()
private const val MAX_APK = 200L * 1024 * 1024

@Suppress("DEPRECATION")
private suspend fun downloadUpdate(context: Context, server: String): File? = withContext(Dispatchers.IO) {
    val base = server.trimEnd('/') + "/android-updates/"
    fun request(name: String) = updateHttp.newCall(Request.Builder().url(base + name).build()).execute()
    val manifest = request("latest.json").use { response ->
        check(response.code != 404) { "服务器还没有发布更新包。" }
        check(response.isSuccessful) { "检查更新失败（HTTP ${response.code}）。" }
        val source = response.body!!.source()
        check(!source.request(8193)) { "更新信息过大。" }
        JSONObject(source.readUtf8())
    }
    val code = manifest.getLong("versionCode")
    if (code <= BuildConfig.VERSION_CODE) return@withContext null
    val hash = manifest.getString("sha256")
    val size = manifest.getLong("size")
    check(hash.matches(Regex("[a-f0-9]{64}")) && size in 1..MAX_APK) { "更新信息无效。" }
    val directory = File(context.cacheDir, "updates").apply { mkdirs() }
    // Keep only the current release after a successful installation. Android may reclaim cache at any time.
    directory.listFiles()?.filter { it.name.endsWith(".apk") && it.name != "$hash.apk" }?.forEach { it.delete() }
    val tmp = File.createTempFile("download-", ".apk", context.cacheDir)
    try {
        val digest = MessageDigest.getInstance("SHA-256")
        request("$hash.apk").use { response ->
            check(response.isSuccessful) { "下载失败（HTTP ${response.code}）。" }
            val stream = response.body!!.byteStream()
            tmp.outputStream().use { out ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = stream.read(buffer)
                    if (count < 0) break
                    total += count
                    check(total <= size) { "更新包大小有误。" }
                    out.write(buffer, 0, count)
                    digest.update(buffer, 0, count)
                }
                check(total == size) { "下载不完整，请重试。" }
            }
        }
        check(digest.digest().joinToString("") { "%02x".format(it) } == hash) { "下载校验失败，请重试。" }
        val pm = context.packageManager
        val archive = pm.getPackageArchiveInfo(tmp.path, PackageManager.GET_SIGNATURES)
        val installed = pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNATURES)
        check(archive != null && archive.packageName == context.packageName && archive.versionCode.toLong() == code) { "更新包的应用或版本不匹配。" }
        val signers = installed.signatures
        check(!signers.isNullOrEmpty() && archive.signatures?.toSet() == signers.toSet()) { "更新包与本机安装版本签名不同，请联系发布者。" }
        File(directory, "$hash.apk").also { check(tmp.renameTo(it)) { "保存更新包失败。" } }
    } finally {
        tmp.delete()
    }
}

@Composable internal fun AppUpdateButton(server: String) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf("") }
    var pending by androidx.compose.runtime.saveable.rememberSaveable(server) { mutableStateOf<String?>(null) }
    fun install() {
        val apk = pending?.let(::File) ?: return
        try {
            check(apk.isFile) { "更新包已清理，请重新检查更新。" }
            val uri = FileProvider.getUriForFile(context, context.packageName + ".files", apk)
            context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
            message = "请在系统安装界面确认更新。"
        } catch (e: Exception) {
            message = e.localizedMessage ?: "无法打开系统安装程序。"
        }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        if (context.packageManager.canRequestPackageInstalls()) install()
        else message = "需要允许小熊伴学安装应用才能更新。"
    }
    TextButton(enabled = !busy, onClick = {
        busy = true
        message = "正在检查并下载更新…"
        scope.launch {
            try {
                val apk = downloadUpdate(context, server)
                pending = apk?.path
                if (apk == null) message = "已经是最新版本。"
                else if (context.packageManager.canRequestPackageInstalls()) install()
                else {
                    message = "请开启“允许来自此来源的应用”，然后返回继续安装。"
                    permission.launch(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + context.packageName)))
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                message = "更新失败：${e.localizedMessage ?: "请检查网络后重试"}"
            } finally {
                busy = false
            }
        }
    }) { Text("检查更新 · ${BuildConfig.VERSION_NAME}") }
    if (message.isNotEmpty()) Text(message)
}
