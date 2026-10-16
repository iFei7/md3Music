package com.gracemusic.feature.login

import android.graphics.BitmapFactory
import android.util.Base64
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gracemusic.core.theme.Md3MusicTheme

/** 登录页根节点测试标签（androidTest 断言用）。 */
const val LoginScreenTestTag = "login_page"

/** 二维码区域测试标签。 */
const val LoginQrAreaTestTag = "login_qr_area"

/**
 * 登录页（T-P4-11 / F-ACC-001）。
 *
 * 对位 lite `lib/modules/login/login_page.dart`（607 行）：
 * - 3 tab：扫码（酷狗 App 扫 native 二维码）/ 手机验证码 / 微信扫码；
 * - 扫码与微信 tab 由 [LoginViewModel] 2s 轮询；
 * - 手机 tab 有验证码重发倒计时；
 * - 登录成功后 [onLoggedIn] 回调由调用方关闭页面（对位 lite 800ms 后 `Navigator.pop()`）。
 *
 * ## 未完成（登记）
 * 多账号选择 UI（`LoginResult.NeedAccountChoice`）本阶段只提示，未做选择列表（lite 侧由
 * login_page 的 info_list 弹窗承担，见 `phase-6-auth.md` §7）。
 *
 * @param onLoggedIn 登录成功（调用方关闭页面并刷新登录态）。
 * @param onClose 用户主动关闭（右上角关闭按钮）。
 */
@Composable
fun LoginScreen(
    onLoggedIn: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    viewModel: LoginViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()

    // 登录成功 → 回调调用方关闭页面（一次性：回调后靠导航出栈，不再回来）。
    if (state.loginSucceeded) {
        onLoggedIn()
    }

    LoginContent(
        state = state,
        onTabSelected = viewModel::onTabSelected,
        onRefreshQr = viewModel::onRefreshQr,
        onPhoneChange = viewModel::onPhoneChange,
        onCodeChange = viewModel::onCodeChange,
        onSendCode = viewModel::onSendCode,
        onLoginPhone = viewModel::onLoginPhone,
        onClose = onClose,
        modifier = modifier,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LoginContent(
    state: LoginUiState,
    onTabSelected: (Int) -> Unit,
    onRefreshQr: () -> Unit,
    onPhoneChange: (String) -> Unit,
    onCodeChange: (String) -> Unit,
    onSendCode: () -> Unit,
    onLoginPhone: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier.testTag(LoginScreenTestTag),
        topBar = {
            TopAppBar(
                title = { Text("登录") },
                navigationIcon = {
                    IconButton(onClick = onClose) {
                        Icon(imageVector = Icons.Filled.Close, contentDescription = "关闭")
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
        ) {
            TabRow(selectedTabIndex = state.tabIndex) {
                LoginTab.entries.forEachIndexed { index, tab ->
                    Tab(
                        selected = state.tabIndex == index,
                        onClick = { onTabSelected(index) },
                        text = { Text(tab.title) },
                    )
                }
            }
            Box(modifier = Modifier.fillMaxSize()) {
                when (state.tabIndex) {
                    0 -> QrTab(
                        qrImage = state.qrImage,
                        statusText = state.statusText,
                        isBusy = state.isBusy,
                        onRefresh = onRefreshQr,
                    )

                    1 -> PhoneTab(
                        state = state,
                        onPhoneChange = onPhoneChange,
                        onCodeChange = onCodeChange,
                        onSendCode = onSendCode,
                        onLogin = onLoginPhone,
                    )

                    else -> WxTab(
                        qrImage = state.wxImage,
                        statusText = state.statusText,
                        isBusy = state.isBusy,
                    )
                }
            }
        }
    }
}

/** 三个 tab（对位 lite `_tabIndex` 的 0/1/2）。 */
private enum class LoginTab(val title: String) {
    QR("扫码"),
    PHONE("手机"),
    WX("微信"),
}

/** 扫码 tab（对位 lite `_buildQrTab`：200x200 边框容器 + 二维码 + 刷新按钮）。 */
@Composable
private fun QrTab(
    qrImage: String?,
    statusText: String?,
    isBusy: Boolean,
    onRefresh: () -> Unit,
) {
    LoginTabLayout(statusText = statusText, isBusy = isBusy) {
        Box(
            modifier = Modifier
                .testTag(LoginQrAreaTestTag)
                .size(size = 200.dp)
                .border(
                    width = 2.dp,
                    color = MaterialTheme.colorScheme.outlineVariant,
                    shape = RoundedCornerShape(12.dp),
                )
                .background(
                    color = MaterialTheme.colorScheme.surface,
                    shape = RoundedCornerShape(12.dp),
                ),
            contentAlignment = Alignment.Center,
        ) {
            val bitmap = remember(qrImage) { decodeDataUrlToBitmap(qrImage) }
            if (bitmap != null) {
                Image(bitmap = bitmap, contentDescription = "登录二维码")
            } else {
                CircularProgressIndicator()
            }
        }
        Button(onClick = onRefresh) {
            Icon(imageVector = Icons.Filled.Refresh, contentDescription = null)
            Text(text = "刷新二维码", modifier = Modifier.padding(start = 8.dp))
        }
    }
}

/** 微信 tab（对位 lite `_buildWxTab`：与扫码 tab 同构，仅文案不同）。 */
@Composable
private fun WxTab(
    qrImage: String?,
    statusText: String?,
    isBusy: Boolean,
) {
    LoginTabLayout(statusText = statusText, isBusy = isBusy) {
        Box(
            modifier = Modifier
                .size(size = 200.dp)
                .border(
                    width = 2.dp,
                    color = MaterialTheme.colorScheme.outlineVariant,
                    shape = RoundedCornerShape(12.dp),
                )
                .background(
                    color = MaterialTheme.colorScheme.surface,
                    shape = RoundedCornerShape(12.dp),
                ),
            contentAlignment = Alignment.Center,
        ) {
            val bitmap = remember(qrImage) { decodeDataUrlToBitmap(qrImage) }
            if (bitmap != null) {
                Image(bitmap = bitmap, contentDescription = "微信登录二维码")
            } else {
                CircularProgressIndicator()
            }
        }
        Text(
            text = "请使用微信扫码登录",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** 手机验证码 tab（对位 lite `_buildPhoneTab`）。 */
@Composable
private fun PhoneTab(
    state: LoginUiState,
    onPhoneChange: (String) -> Unit,
    onCodeChange: (String) -> Unit,
    onSendCode: () -> Unit,
    onLogin: () -> Unit,
) {
    LoginTabLayout(statusText = state.statusText, isBusy = state.isBusy) {
        OutlinedTextField(
            value = state.phone,
            onValueChange = onPhoneChange,
            label = { Text("手机号") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Phone,
                imeAction = ImeAction.Next,
            ),
            modifier = Modifier.fillMaxWidth(),
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = state.code,
                onValueChange = onCodeChange,
                label = { Text("验证码") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Number,
                    imeAction = ImeAction.Done,
                ),
                modifier = Modifier.weight(weight = 1f),
            )
            FilledTonalButton(
                onClick = onSendCode,
                enabled = !state.isBusy && state.countdown == 0,
                modifier = Modifier.height(height = 56.dp),
            ) {
                Text(
                    text = if (state.countdown > 0) "${state.countdown}s" else "发送",
                )
            }
        }
        Button(
            onClick = onLogin,
            enabled = !state.isBusy,
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (state.isBusy) {
                CircularProgressIndicator(
                    modifier = Modifier.size(size = 16.dp),
                    strokeWidth = 2.dp,
                    color = MaterialTheme.colorScheme.onPrimary,
                )
            } else {
                Text("登录")
            }
        }
    }
}

/** 三个 tab 共用的滚动布局（状态文本 + 内容）。 */
@Composable
private fun LoginTabLayout(
    statusText: String?,
    isBusy: Boolean,
    content: ColumnScopeContent,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(all = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        if (!statusText.isNullOrBlank()) {
            Text(
                text = statusText,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        content()
    }
}

/** [LoginTabLayout] 的内容槽类型别名（保持签名可读）。 */
private typealias ColumnScopeContent = @Composable () -> Unit

/**
 * base64 data URL → [ImageBitmap]。
 *
 * 对位 lite `_decodeBase64Image`（`login_page.dart` 的同名工具）。失败（空串 /
 * 非法 base64 / 解码失败）一律返回 `null`，UI 侧回落为加载指示器——不得崩溃。
 */
private fun decodeDataUrlToBitmap(dataUrl: String?): ImageBitmap? {
    if (dataUrl.isNullOrBlank()) return null
    return try {
        val payload = dataUrl.substringAfter(delimiter = "base64,", missingDelimiterValue = "")
        if (payload.isBlank()) return null
        val bytes = Base64.decode(payload, Base64.DEFAULT)
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        bitmap?.asImageBitmap()
    } catch (t: Throwable) {
        null
    }
}

@Preview(name = "登录页 · 扫码", showBackground = true)
@Composable
private fun LoginScreenPreview() {
    Md3MusicTheme {
        Surface {
            LoginContent(
                state = LoginUiState(tabIndex = 0, statusText = "请使用酷狗音乐 App 扫码登录"),
                onTabSelected = {},
                onRefreshQr = {},
                onPhoneChange = {},
                onCodeChange = {},
                onSendCode = {},
                onLoginPhone = {},
                onClose = {},
            )
        }
    }
}
