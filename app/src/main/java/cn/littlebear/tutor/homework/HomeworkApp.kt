package cn.littlebear.tutor.homework

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Face
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import cn.littlebear.tutor.BuildConfig
import kotlinx.coroutines.delay

/** App entry: role choice and pairing until this device is connected, then the parent or child app. */
@Composable fun HomeworkApp(store: HomeworkStore) {
    CompositionLocalProvider(LocalStore provides store) {
        HomeworkTheme {
            val state by store.state.collectAsStateWithLifecycle()
            val lifecycle = LocalLifecycleOwner.current.lifecycle
            // Foreground polling stands in for push notifications (FCM is unavailable on many devices in mainland China).
            LaunchedEffect(state.session?.deviceId) {
                if (state.session == null) return@LaunchedEffect
                lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
                    while (true) { store.sync(); delay(20_000) }
                }
            }
            Surface(Modifier.fillMaxSize(), color = Palette.paper) {
                val session = state.session
                when {
                    session == null -> OnboardingView()
                    session.isParent -> ParentApp()
                    else -> ChildApp()
                }
            }
            val message by store.error.collectAsStateWithLifecycle()
            message?.let { text ->
                AlertDialog(onDismissRequest = { store.error.value = null }, title = { Text("提示") }, text = { Text(text) },
                    confirmButton = { TextButton({ store.error.value = null }) { Text("知道了") } })
            }
        }
    }
}

private val defaultServer = if (BuildConfig.DEBUG) "http://10.0.2.2:8787" else "https://"

@Composable private fun OnboardingView() {
    var step by rememberSaveable { mutableStateOf("choose") }
    BackHandler(step != "choose") { step = "choose" }
    when (step) {
        "parent" -> ParentConnectView { step = "choose" }
        "child" -> ChildPairView { step = "choose" }
        else -> Column(Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(22.dp)) {
            Spacer(Modifier.height(24.dp))
            BearView(110.dp)
            Text("小熊伴学", fontSize = 36.sp, fontWeight = FontWeight.Black, color = Palette.ink)
            Text("家长用手机布置和批改作业，孩子用平板或手机完成作业。", fontSize = 18.sp, color = Palette.ink2, textAlign = TextAlign.Center)
            Column(Modifier.widthIn(max = 520.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                RoleButton("我是家长", "在这台设备上录入作业、批改、设置奖励", Icons.Filled.Person) { step = "parent" }
                RoleButton("这是孩子的设备", "用家长手机上生成的配对码连接", Icons.Filled.Face) { step = "child" }
            }
        }
    }
}

@Composable private fun RoleButton(title: String, detail: String, icon: ImageVector, onClick: () -> Unit) {
    Surface(onClick = onClick, shape = RoundedCornerShape(22.dp), color = Palette.card) {
        Row(Modifier.padding(18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Box(Modifier.size(52.dp).background(Palette.pineSoft, CircleShape), contentAlignment = Alignment.Center) { Icon(icon, null, tint = Palette.pine, modifier = Modifier.size(28.dp)) }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, fontSize = 20.sp, fontWeight = FontWeight.Bold, color = Palette.ink)
                Text(detail, fontSize = 14.sp, color = Palette.ink2)
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Palette.ink3)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun FormScaffold(title: String, onBack: (() -> Unit)?, actions: @Composable RowScope.() -> Unit = {}, content: @Composable ColumnScope.() -> Unit) {
    Scaffold(containerColor = Palette.paper, topBar = {
        TopAppBar(title = { Text(title, fontWeight = FontWeight.Bold) }, colors = TopAppBarDefaults.topAppBarColors(containerColor = Palette.paper),
            navigationIcon = { if (onBack != null) IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } }, actions = actions)
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp)
            .wrapContentWidth(Alignment.CenterHorizontally).widthIn(max = 640.dp), verticalArrangement = Arrangement.spacedBy(14.dp), content = content)
    }
}

/** A white rounded group of form rows, like an iOS form section. */
@Composable fun FormSection(header: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        header?.let { Text(it, fontSize = 14.sp, color = Palette.ink3, modifier = Modifier.padding(start = 8.dp)) }
        Column(Modifier.fillMaxWidth().background(Palette.card, RoundedCornerShape(18.dp)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
        footer?.let { Text(it, fontSize = 13.sp, color = Palette.ink3, modifier = Modifier.padding(horizontal = 8.dp)) }
    }
}

@Composable private fun ParentConnectView(back: () -> Unit) {
    val store = LocalStore.current
    val context = LocalContext.current
    var server by rememberSaveable { mutableStateOf(defaultServer) }
    var secret by rememberSaveable { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    FormScaffold("连接家长手机", back) {
        FormSection(footer = "家长密钥是服务器配置里的 PARENT_BOOTSTRAP_TOKEN，只在第一次连接时用，换取这台设备自己的登录凭证。") {
            OutlinedTextField(server, { server = it.trim() }, Modifier.fillMaxWidth(), label = { Text("服务器地址") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            OutlinedTextField(secret, { secret = it.trim() }, Modifier.fillMaxWidth(), label = { Text("家长密钥") }, singleLine = true,
                visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
        }
        PrimaryButton(if (busy) "正在连接…" else "连接", Modifier.fillMaxWidth(), busy = busy, enabled = secret.length >= 24) {
            busy = true
            store.launch({ busy = false }) { connectParent(server, secret, deviceName(context)) }
        }
    }
}

@Composable private fun ChildPairView(back: () -> Unit) {
    val store = LocalStore.current
    val context = LocalContext.current
    var server by rememberSaveable { mutableStateOf(defaultServer) }
    var code by rememberSaveable { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    FormScaffold("连接孩子的设备", back) {
        FormSection(footer = "在家长手机上打开“作业 → 设置 → 连接孩子的设备”，会显示配对码，10 分钟内有效。") {
            OutlinedTextField(server, { server = it.trim() }, Modifier.fillMaxWidth(), label = { Text("服务器地址") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            OutlinedTextField(code, { v -> code = v.filter(Char::isDigit).take(6) }, Modifier.fillMaxWidth(), label = { Text("6 位配对码") }, singleLine = true,
                textStyle = LocalTextStyle.current.copy(fontSize = 24.sp, fontFamily = FontFamily.Monospace), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword))
        }
        PrimaryButton(if (busy) "正在连接…" else "连接", Modifier.fillMaxWidth(), busy = busy, enabled = code.length == 6) {
            busy = true
            store.launch({ busy = false }) { pairChild(server, code, deviceName(context)) }
        }
    }
}
