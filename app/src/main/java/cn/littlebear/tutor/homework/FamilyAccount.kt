package cn.littlebear.tutor.homework

import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

// ---------- Settings: the family's parents and this phone's account ----------

/** "1234 5678" for an eight-digit invite code. */
fun spacedInvite(code: String): String = if (code.length == 8) "${code.take(4)} ${code.takeLast(4)}" else code

/** The family's parents (list, invite, remove). */
@Composable fun FamilyParentsSection() {
    val store = LocalStore.current
    val context = LocalContext.current
    val state by store.state.collectAsStateWithLifecycle()
    var parents by remember { mutableStateOf<FamilyParents?>(null) }
    var invite by remember { mutableStateOf<InviteCode?>(null) }
    var removing by remember { mutableStateOf<FamilyParent?>(null) }
    suspend fun reload() { parents = runCatching { store.parents() }.getOrNull() }
    LaunchedEffect(Unit) { reload() }
    FormSection("家长", footer = "另一位家长用手机号注册时填上邀请码，就能和你一起管理孩子的作业。") {
        parents?.parents?.forEach { p ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(if (p.isSelf) "${p.name}（我）" else p.name)
                    Text(p.phone, fontSize = 12.sp, color = Palette.ink3)
                }
                if (!p.isSelf) TextButton({ removing = p }) { Text("移出", color = Palette.redPen) }
            }
        }
        parents?.unboundDevices?.takeIf { it > 0 }?.let {
            Text("另有 $it 台家长手机用家长密钥连接，没有登录账号。", fontSize = 13.sp, color = Palette.ink2)
        }
        invite?.let {
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(spacedInvite(it.code), fontSize = 36.sp, fontWeight = FontWeight.Black, fontFamily = FontFamily.Monospace, letterSpacing = 3.sp)
                Text("24 小时内有效，只能用一次", fontSize = 13.sp, color = Palette.ink2)
                TextButton({
                    val text = "我在用小熊伴学管孩子的作业。注册时填邀请码 ${it.code}（24 小时内有效）就能加入我们家。服务器：${state.session?.server ?: ""}"
                    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
                    context.startActivity(Intent.createChooser(send, "发给家人"))
                }) { Text("发给家人") }
            }
        }
        TextButton({ store.launch { invite = inviteCode() } }) { Icon(Icons.Filled.Add, null); Text(if (invite == null) "邀请家长" else "重新生成邀请码") }
    }
    removing?.let { p ->
        AlertDialog(onDismissRequest = { removing = null }, title = { Text("把${p.name}移出家庭？") },
            text = { Text("对方的手机会退出登录，账号会被删除。孩子和作业不受影响。") },
            confirmButton = { TextButton({ removing = null; store.launch { removeParent(p.id); reload() } }) { Text("移出", color = Palette.redPen) } },
            dismissButton = { TextButton({ removing = null }) { Text("取消") } })
    }
}

/** The account signed in on this phone, or setting one up for a phone connected with the parent secret. */
@Composable fun AccountSection() {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    var binding by remember { mutableStateOf(false) }
    var changingPassword by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { runCatching { store.refreshMe() } }
    val account = state.account
    FormSection("我的账号", footer = if (account == null) "这台手机是用家长密钥连接的。设置手机号和密码后，换手机时直接登录。" else null) {
        if (account != null) {
            LabeledRow("手机号", account.phone)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("称呼", Modifier.weight(1f)); TextButton({ renaming = true }) { Text(account.name) }
            }
            TextButton({ changingPassword = true }) { Text("修改密码") }
        } else {
            TextButton({ binding = true }) { Text("设置手机号登录") }
        }
    }
    if (binding) BindAccountDialog { binding = false }
    if (changingPassword) ChangePasswordDialog { changingPassword = false }
    if (renaming) {
        var name by remember { mutableStateOf(account?.name ?: "") }
        AlertDialog(onDismissRequest = { renaming = false }, title = { Text("修改称呼") },
            text = { OutlinedTextField(name, { name = it.take(20) }, label = { Text("称呼") }, singleLine = true) },
            confirmButton = { TextButton({ store.launch({ if (it) renaming = false }) { renameAccount(name) } }, enabled = name.isNotBlank()) { Text("保存") } },
            dismissButton = { TextButton({ renaming = false }) { Text("取消") } })
    }
}

@Composable private fun PasswordField(value: String, label: String, isError: Boolean = false, onChange: (String) -> Unit) {
    OutlinedTextField(value, { onChange(it.take(64)) }, Modifier.fillMaxWidth(), label = { Text(label) }, singleLine = true, isError = isError,
        visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
}

@Composable private fun BindAccountDialog(onDone: () -> Unit) {
    val store = LocalStore.current
    var phone by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    val mismatch = confirm.isNotEmpty() && confirm != password
    AlertDialog(onDismissRequest = onDone, title = { Text("设置手机号登录") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(phone, { phone = it.filter(Char::isDigit).take(11) }, Modifier.fillMaxWidth(), label = { Text("手机号") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone))
            PasswordField(password, "密码") { password = it }
            PasswordField(confirm, "再输一次密码", mismatch) { confirm = it }
            OutlinedTextField(name, { name = it.take(20) }, Modifier.fillMaxWidth(), label = { Text("你的称呼（如 妈妈）") }, singleLine = true)
            Text(if (mismatch) "两次输入的密码不一样。" else "密码至少 8 位。这台手机和家里的数据都不变。", fontSize = 13.sp,
                color = if (mismatch) Palette.redPen else Palette.ink3)
        }
    }, confirmButton = {
        TextButton({ store.launch({ if (it) onDone() }) { bindAccount(phone, password, name) } },
            enabled = phone.length == 11 && password.length >= 8 && password == confirm && name.isNotBlank()) { Text("保存") }
    }, dismissButton = { TextButton(onDone) { Text("取消") } })
}

@Composable private fun ChangePasswordDialog(onDone: () -> Unit) {
    val store = LocalStore.current
    var old by remember { mutableStateOf("") }
    var new by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    val mismatch = confirm.isNotEmpty() && confirm != new
    AlertDialog(onDismissRequest = onDone, title = { Text("修改密码") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            PasswordField(old, "原密码") { old = it }
            PasswordField(new, "新密码") { new = it }
            PasswordField(confirm, "再输一次新密码", mismatch) { confirm = it }
            Text(if (mismatch) "两次输入的密码不一样。" else "新密码至少 8 位。改完后，用这个账号登录的其他手机要重新登录。", fontSize = 13.sp,
                color = if (mismatch) Palette.redPen else Palette.ink3)
        }
    }, confirmButton = {
        TextButton({ store.launch({ if (it) onDone() }) { changePassword(old, new) } }, enabled = old.isNotEmpty() && new.length >= 8 && new == confirm) { Text("保存") }
    }, dismissButton = { TextButton(onDone) { Text("取消") } })
}
