package cn.littlebear.tutor.homework

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/**
 * 小熊老师 on Android: the server's web teacher (`/teacher/`) in a WebView. The page gets this device's credential
 * and the child from [TeacherHost] instead of pairing again, and calls `close()` when the child says goodbye.
 * Like any browser, the WebView only opens the microphone on an HTTPS server: on a plain-HTTP dev server the
 * child types (the teacher still talks).
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable fun TeacherScreen(child: RemoteChild, close: () -> Unit) {
    val context = LocalContext.current
    val state by LocalStore.current.state.collectAsStateWithLifecycle()
    val session = state.session ?: run { LaunchedEffect(Unit) { close() }; return }
    val origin = remember(session.server) { Uri.parse(session.server.trimEnd('/')) }
    var micAsked by remember { mutableStateOf(false) }
    var micGranted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { micGranted = it; micAsked = true }
    LaunchedEffect(Unit) { if (!micGranted) permission.launch(Manifest.permission.RECORD_AUDIO) else micAsked = true }
    var webView by remember { mutableStateOf<WebView?>(null) }
    var unreachable by remember { mutableStateOf(false) }
    BackHandler { close() }
    if (unreachable) {
        Column(Modifier.fillMaxSize().background(Palette.paper).padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterVertically)) {
            BearView(120.dp)
            Text("连不上小熊老师", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Palette.ink)
            Text("请检查网络，或者让家长看看服务器是不是开着。", fontSize = 18.sp, color = Palette.ink2, textAlign = TextAlign.Center)
            Button(onClick = close) { Text("返回", fontSize = 18.sp) }
        }
        return
    }
    DisposableEffect(Unit) { onDispose { webView?.apply { stopLoading(); loadUrl("about:blank"); destroy() } } }
    if (!micAsked) { Box(Modifier.fillMaxSize().background(Palette.paper)); return } // the page asks for the mic once it loads
    AndroidView(modifier = Modifier.fillMaxSize().background(Palette.paper), factory = { ctx ->
        WebView.setWebContentsDebuggingEnabled(cn.littlebear.tutor.BuildConfig.DEBUG) // chrome://inspect on debug builds only
        WebView(ctx).apply {
            // Fill the screen from the start: with the default wrap-content size the page's 100vh comes out as 0.
            layoutParams = android.view.ViewGroup.LayoutParams(android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.MATCH_PARENT)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.mediaPlaybackRequiresUserGesture = false
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            setBackgroundColor(android.graphics.Color.parseColor("#F5F1E8"))
            webViewClient = object : WebViewClient() {
                // Stay on the family's server: the bridge below must never be reachable from another site.
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = !sameOrigin(request.url, origin)
                override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if (request.isForMainFrame) unreachable = true // our own message instead of the browser's error page
                }
            }
            webChromeClient = object : WebChromeClient() {
                override fun onPermissionRequest(request: PermissionRequest) {
                    val audio = PermissionRequest.RESOURCE_AUDIO_CAPTURE
                    if (micGranted && sameOrigin(request.origin, origin) && audio in request.resources) request.grant(arrayOf(audio)) else request.deny()
                }
            }
            addJavascriptInterface(TeacherHost(session.token, child.id) { Handler(Looper.getMainLooper()).post(close) }, "LittleBearHost")
            loadUrl("${session.server.trimEnd('/')}/teacher/")
            webView = this
        }
    })
}

private fun sameOrigin(url: Uri?, origin: Uri) =
    url != null && url.scheme == origin.scheme && url.host == origin.host && (if (url.port == -1) defaultPort(url.scheme) else url.port) ==
        (if (origin.port == -1) defaultPort(origin.scheme) else origin.port)

private fun defaultPort(scheme: String?) = if (scheme == "https") 443 else 80

/** What the web teacher may ask the app: this device's credential, the child, and to close the screen. */
class TeacherHost(private val token: String, private val childId: String, private val onClose: () -> Unit) {
    @JavascriptInterface fun token(): String = token
    @JavascriptInterface fun childId(): String = childId
    @JavascriptInterface fun close() = onClose()
}
