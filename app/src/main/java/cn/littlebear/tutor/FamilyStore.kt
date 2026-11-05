package cn.littlebear.tutor

import android.app.Application
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import android.util.AtomicFile
import android.util.Base64
import androidx.lifecycle.AndroidViewModel
import androidx.exifinterface.media.ExifInterface
import androidx.lifecycle.viewModelScope
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class FamilyStore(application: Application) : AndroidViewModel(application) {
    val instanceID = newID()
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }
    private val file = AtomicFile(File(application.noBackupFilesDir, "family-v1.json"))
    private val mutex = Mutex()
    private val _family = MutableStateFlow(Family())
    val family = _family.asStateFlow()
    private val _ready = MutableStateFlow(false)
    val ready = _ready.asStateFlow()
    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()
    private var readable = true
    private val service = TutorService()
    private val settingsFile = AtomicFile(File(application.noBackupFilesDir, "service-v1.json"))
    private val _settings = MutableStateFlow(ServiceSettings())
    val settings = _settings.asStateFlow()
    private val _busy = MutableStateFlow(false)
    val busy = _busy.asStateFlow()
    private var requestJob: Job? = null
    private var requestEpoch = 0L

    init {
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                try {
                    if (file.baseFile.exists() || File(file.baseFile.path + ".bak").exists()) {
                        val loaded = file.openRead().use { json.decodeFromString<Family>(it.readBytes().decodeToString()) }
                        require(loaded.schemaVersion == 1) { "不支持此版本的数据" }
                        _family.value = loaded
                    }
                } catch (e: Exception) {
                    readable = false
                    _error.value = "本地记录读取失败，已保留原文件并停止写入。请勿卸载应用。"
                }
                runCatching {
                    if (settingsFile.baseFile.exists()) _settings.value = settingsFile.openRead().use {
                        json.decodeFromString<ServiceSettings>(it.readBytes().decodeToString())
                    }
                }.onFailure { _error.value = "辅导服务设置读取失败，请家长重新配置。" }
            }
            _ready.value = true
        }
    }

    fun clearError() { _error.value = null }
    fun reportError(message: String) { _error.value = message }

    fun change(transform: (Family) -> Family, after: () -> Unit = {}) {
        viewModelScope.launch {
            mutex.withLock {
                if (!readable || !_ready.value) {
                    reportError("本地数据尚不可写入，请保留应用并检查存储状态。")
                    return@withLock
                }
                try {
                    val next = transform(_family.value)
                    withContext(Dispatchers.IO) {
                        val stream = file.startWrite()
                        try {
                            stream.write(json.encodeToString(next).toByteArray())
                            file.finishWrite(stream)
                        } catch (e: Exception) {
                            file.failWrite(stream)
                            throw e
                        }
                    }
                    _family.value = next
                    after()
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) {
                    reportError(e.message ?: "保存失败，请重试；之前的记录仍保留。")
                }
            }
        }
    }

    fun importPhoto(uri: Uri, onFinished: () -> Unit = {}, onSaved: (String) -> Unit) {
        viewModelScope.launch {
            try {
                val path = withContext(Dispatchers.IO) {
                    val resolver = getApplication<Application>().contentResolver
                    val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    resolver.openInputStream(uri).use { BitmapFactory.decodeStream(it, null, options) }
                    require(options.outWidth > 0 && options.outHeight > 0) { "图片无法读取，请重新选择" }
                    var sample = 1
                    while (maxOf(options.outWidth, options.outHeight) / sample > 2048) sample *= 2
                    val decoded = resolver.openInputStream(uri).use {
                        BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
                    } ?: error("图片无法读取")
                    val orientation = resolver.openInputStream(uri).use { input ->
                        input?.let { ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) }
                    }
                    val matrix = Matrix().apply {
                        when (orientation) {
                            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> setScale(-1f, 1f)
                            ExifInterface.ORIENTATION_ROTATE_180 -> setRotate(180f)
                            ExifInterface.ORIENTATION_FLIP_VERTICAL -> { setRotate(180f); postScale(-1f, 1f) }
                            ExifInterface.ORIENTATION_TRANSPOSE -> { setRotate(90f); postScale(-1f, 1f) }
                            ExifInterface.ORIENTATION_ROTATE_90 -> setRotate(90f)
                            ExifInterface.ORIENTATION_TRANSVERSE -> { setRotate(-90f); postScale(-1f, 1f) }
                            ExifInterface.ORIENTATION_ROTATE_270 -> setRotate(-90f)
                        }
                    }
                    val bitmap = if (matrix.isIdentity) decoded else Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true).also { decoded.recycle() }
                    val dir = File(getApplication<Application>().noBackupFilesDir, "photos").apply { mkdirs() }
                    val name = "${newID()}.jpg"
                    File(dir, name).outputStream().use { out ->
                        check(bitmap.compress(Bitmap.CompressFormat.JPEG, 88, out)) { "图片保存失败" }
                    }
                    bitmap.recycle()
                    name
                }
                onSaved(path)
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { reportError(e.message ?: "导入图片失败") }
            finally { onFinished() }
        }
    }

    fun photoFile(name: String): File {
        require(name.matches(Regex("[a-fA-F0-9-]+\\.jpg")))
        return File(getApplication<Application>().noBackupFilesDir, "photos/$name")
    }

    fun discardPhoto(name: String?) {
        if (name == null) return
        viewModelScope.launch(Dispatchers.IO) {
            mutex.withLock {
                if (_family.value.tasks.none { it.photo == name }) runCatching { photoFile(name).delete() }
            }
        }
    }

    fun deleteChild(id: String) {
        cancelTutor()
        val names = _family.value.tasksFor(id).mapNotNull { it.photo }
        change({ it.deleteChild(id) }) { names.forEach(::discardPhoto) }
    }

    fun reset(after: () -> Unit) {
        cancelTutor()
        val names = _family.value.tasks.mapNotNull { it.photo }
        saveSettings(ServiceSettings()) {
            change({ Family() }) {
                names.forEach(::discardPhoto)
                after()
            }
        }
    }

    fun deleteTask(childID: String, taskID: String) {
        cancelTutor()
        val photo = _family.value.task(childID, taskID).photo
        change({ it.deleteTask(childID, taskID) }) { discardPhoto(photo) }
    }

    fun saveSettings(value: ServiceSettings, after: () -> Unit) {
        viewModelScope.launch {
            try {
                val config = if (value.url.isBlank() && !value.consent) ServiceSettings() else value.validated(BuildConfig.DEBUG)
                cancelTutor()
                withContext(Dispatchers.IO) {
                    val output = settingsFile.startWrite()
                    try { output.write(json.encodeToString(config).toByteArray()); settingsFile.finishWrite(output) }
                    catch (e: Exception) { settingsFile.failWrite(output); throw e }
                }
                _settings.value = config
                after()
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { reportError(e.message ?: "服务设置保存失败") }
        }
    }

    fun cancelTutor() { requestEpoch++; requestJob?.cancel(); requestJob = null; _busy.value = false }

    fun requestTutor(child: Child, task: Homework?, mode: String, message: String = "", photo: String? = task?.photo,
        subject: Subject = task?.subject ?: Subject.MATH, onResult: (TutorResponse) -> Unit = {}) {
        if (_busy.value) return
        val snapshot = task
        val config = _settings.value
        val epoch = ++requestEpoch
        _busy.value = true
        requestJob = viewModelScope.launch(start = CoroutineStart.LAZY) {
            try {
                require(config.consent) { "请家长先在家长空间开启云端辅导。" }
                val image = withContext(Dispatchers.IO) {
                    photo?.let {
                        val file = photoFile(it)
                        require(file.length() <= 2_000_000) { "图片过大，请拍摄更小的题目区域后重试。" }
                        Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)
                    }
                }
                val response = service.request(config, TutorRequest(mode, child.grade, subject.name, child.textbook,
                    snapshot?.title ?: "", snapshot?.instructions ?: "", snapshot?.draft ?: "", message, image,
                    snapshot?.conversation?.takeLast(8) ?: emptyList()))
                if (snapshot != null) {
                    change({ state -> if (requestEpoch != epoch) state else state.applyTutor(child.id, snapshot.id, snapshot.revision,
                        TutorTurn(message.ifBlank { if (mode == "check") "帮我检查这份作业" else "给我一点提示" },
                            response.message, mode, response.assessment)) }) { if (requestEpoch == epoch) onResult(response) }
                } else if (_family.value.children.any { it.id == child.id }) onResult(response)
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { reportError(e.message ?: "辅导暂不可用，已有记录已保留，请稍后重试。") }
            finally { if (requestJob == coroutineContext[Job]) { _busy.value = false; requestJob = null } }
        }
        requestJob?.start()
    }
}
