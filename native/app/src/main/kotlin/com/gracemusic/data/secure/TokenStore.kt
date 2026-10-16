package com.gracemusic.data.secure

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.core.content.edit
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.IOException
import java.security.GeneralSecurityException
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 酷狗账号凭证（登录态的唯一载体）。
 *
 * @property userid 账号 id（**凭证的隔离键**：多账号时各存各的）。
 * @property token 登录令牌（敏感）。
 * @property vipToken VIP 令牌（敏感，可空）。
 */
data class KugouCredentials(
    val userid: String,
    val token: String,
    val vipToken: String? = null,
) {

    /**
     * 脱敏 `toString`（安全纪律，见类 KDoc §6）：token / vipToken 一律输出 `***`，
     * 仅 userid 明文（非机密，便于日志定位）。data class 自动生成的 `toString`
     * 会把 token 明文拼进字符串，误打印/误记录即泄露，故显式覆盖。
     */
    override fun toString(): String =
        "KugouCredentials(userid=$userid, token=***, vipToken=${vipToken?.let { "***" } ?: "null"})"
}

/**
 * 加密 token 存储端口（T-P2-04 / F-PERS-003）。
 *
 * 全部方法 `suspend`：磁盘 I/O 禁止在主线程执行（项目铁律）。
 * 实现方不得抛业务异常——读失败/解密失败一律返回 `null`（容错，见实现 KDoc）。
 */
interface TokenStore {

    /** 读取指定账号凭证；无记录 / 解密失败 / 键损坏 → `null`。 */
    suspend fun load(userid: String): KugouCredentials?

    /** 写入/覆盖指定账号凭证（加密落盘）。 */
    suspend fun save(credentials: KugouCredentials)

    /** 清除指定账号凭证（注销 / 踢下线）。 */
    suspend fun clear(userid: String)

    /** 当前登录账号 userid；未登录 → `null`。 */
    suspend fun currentUserid(): String?

    /** 设置/清除当前账号（退出登录传 `null`）。 */
    suspend fun setCurrentUserid(userid: String?)
}

/**
 * [TokenStore] 的 [androidx.security.crypto.EncryptedSharedPreferences] 实现
 * （T-P2-04 / F-PERS-003）。native 账号体系的第一环：按 userid 隔离的加密
 * token 存储。
 *
 * ## 两张 prefs 分立（安全边界）
 * - **加密**（[SECURE_PREFS_NAME]，security-crypto 的 `EncryptedSharedPreferences`）：
 *   `kugou_token_$uid` / `kugou_vip_token_$uid`——敏感凭证，Keystore 主密钥加密落盘；
 * - **普通**（[ACCOUNT_PREFS_NAME]，`MODE_PRIVATE`）：`kugou_current_userid`——
 *   非机密，仅定位用。
 *
 * 依据：lite `kugou_api_client.dart:650-651`（`setLoginCookies` 注释）「敏感凭证
 * （token/vip_token）写入加密存储（Keystore），userid/账号列表等非机密数据仍用
 * prefs（用于定位与展示）」。键名 `kugou_token_$uid` / `kugou_vip_token_$uid` /
 * `kugou_current_userid` 与 lite `:665-668` / `:662` 逐字一致。
 *
 * ## MasterKey 选用
 * `MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()`
 * ——security-crypto 1.1.0（本工程 `libs.versions.toml:27`）的新 API；旧写法
 * `MasterKeys.AES256_GCM_SPEC` 已 deprecated。别名走库常量
 * `MasterKey.DEFAULT_MASTER_KEY_ALIAS`，不在源码出现任何硬编码密钥。
 *
 * ## 绝不抛异常（容错）
 * `load` 的 `getString` / 解密失败（[GeneralSecurityException]、[IOException]，
 * 含 security-crypto 把解密失败包装出的 [SecurityException]）一律 catch →
 * 返回 `null` + `Log.w`。理由：凭证损坏不应阻塞冷启动——对位 lite
 * `_ensureInitialized`（`kugou_api_client.dart:538-604`）的容错思路：
 * 「凭证不完整则清除残留状态」，而非抛异常。
 *
 * ## 文件命名
 * 加密 prefs 用专用文件名 [SECURE_PREFS_NAME]，普通 prefs 用 [ACCOUNT_PREFS_NAME]，
 * 避免与 [com.gracemusic.data.source.LoudnessStorePrefs] /
 * [com.gracemusic.player.offline.ResolvedSourceMemory] 的文件混用。
 *
 * ## 并发
 * 磁盘访问一律 `withContext(Dispatchers.IO)`（项目铁律：I/O 不主线程）；
 * SharedPreferences 的 `apply()` 异步写盘。
 *
 * ## 安全纪律（§4.6 六项）
 * 1. token/vipToken 不写入任何日志/异常消息/UI 文案——全部 `Log.w` 仅含 userid；
 * 2. 无明文落盘——敏感值只经 EncryptedSharedPreferences 写入，普通 prefs 只存 userid；
 * 3. [KugouCredentials.toString] 显式脱敏，防误打印泄露；
 * 4. 无硬编码密钥——MasterKey 由 Keystore 生成，别名走库常量；
 * 5. 不吞异常后伪装成功——失败路径均 `Log.w` 留痕；
 * 6. 不主线程阻塞 I/O。
 */
class EncryptedSharedPreferencesTokenStore @Inject constructor(
    @ApplicationContext private val context: Context,
) : TokenStore {

    override suspend fun load(userid: String): KugouCredentials? = withContext(Dispatchers.IO) {
        try {
            val prefs = encryptedPrefs()
            if (prefs == null) return@withContext null
            val token = prefs.getString(TOKEN_KEY_PREFIX + userid, null)
            if (token.isNullOrEmpty()) return@withContext null
            val vipToken = prefs.getString(VIP_TOKEN_KEY_PREFIX + userid, null)
                ?.takeIf { it.isNotEmpty() }
            KugouCredentials(userid = userid, token = token, vipToken = vipToken)
        } catch (e: GeneralSecurityException) {
            Log.w(TAG, "凭证解密失败，按未登录处理（userid=$userid）", e)
            null
        } catch (e: IOException) {
            Log.w(TAG, "凭证读取 IO 失败，按未登录处理（userid=$userid）", e)
            null
        } catch (e: SecurityException) {
            // security-crypto 会把解密失败包装成 SecurityException（Runtime）。
            Log.w(TAG, "凭证解密失败（security-crypto 包装异常），按未登录处理（userid=$userid）", e)
            null
        }
    }

    override suspend fun save(credentials: KugouCredentials) {
        withContext(Dispatchers.IO) {
            try {
                val prefs = encryptedPrefs()
                if (prefs == null) {
                    Log.w(TAG, "加密存储不可用，凭证未写入（userid=${credentials.userid}）")
                    return@withContext
                }
                prefs.edit {
                    putString(TOKEN_KEY_PREFIX + credentials.userid, credentials.token)
                    if (credentials.vipToken.isNullOrEmpty()) {
                        // vipToken 为空 → 删除旧值（对位 lite kugou_api_client.dart:668-670）。
                        remove(VIP_TOKEN_KEY_PREFIX + credentials.userid)
                    } else {
                        putString(
                            VIP_TOKEN_KEY_PREFIX + credentials.userid,
                            credentials.vipToken,
                        )
                    }
                }
            } catch (e: GeneralSecurityException) {
                Log.w(TAG, "凭证加密写入失败（userid=${credentials.userid}）", e)
            } catch (e: IOException) {
                Log.w(TAG, "凭证写入 IO 失败（userid=${credentials.userid}）", e)
            } catch (e: SecurityException) {
                Log.w(TAG, "凭证写入失败（security-crypto 包装异常）（userid=${credentials.userid}）", e)
            }
        }
    }

    override suspend fun clear(userid: String) {
        withContext(Dispatchers.IO) {
            try {
                val prefs = encryptedPrefs()
                if (prefs == null) {
                    Log.w(TAG, "加密存储不可用，凭证清除未执行（userid=$userid）")
                    return@withContext
                }
                prefs.edit {
                    remove(TOKEN_KEY_PREFIX + userid)
                    remove(VIP_TOKEN_KEY_PREFIX + userid)
                }
            } catch (e: GeneralSecurityException) {
                Log.w(TAG, "凭证清除失败（userid=$userid）", e)
            } catch (e: IOException) {
                Log.w(TAG, "凭证清除 IO 失败（userid=$userid）", e)
            } catch (e: SecurityException) {
                Log.w(TAG, "凭证清除失败（security-crypto 包装异常）（userid=$userid）", e)
            }
        }
    }

    override suspend fun currentUserid(): String? = withContext(Dispatchers.IO) {
        try {
            accountPrefs().getString(CURRENT_USERID_KEY, null)?.takeIf { it.isNotEmpty() }
        } catch (e: IOException) {
            Log.w(TAG, "当前账号读取失败，按未登录处理", e)
            null
        }
    }

    override suspend fun setCurrentUserid(userid: String?) {
        withContext(Dispatchers.IO) {
            try {
                accountPrefs().edit {
                    if (userid.isNullOrEmpty()) {
                        remove(CURRENT_USERID_KEY)
                    } else {
                        putString(CURRENT_USERID_KEY, userid)
                    }
                }
            } catch (e: IOException) {
                Log.w(TAG, "当前账号写入失败", e)
            }
        }
    }

    /**
     * 获取（必要时创建）加密凭证 prefs。
     *
     * 每次调用重建实例：`EncryptedSharedPreferences.create` 内部仅做 keyset 解密与
     * SharedPreferences 包装（载体 prefs 本身有 ContextImpl 实例缓存），开销小；
     * 换来「初始化失败不传染」——Keystore 不可用只影响当次调用（返回 `null` 走容错），
     * 不会让整个存储类长期不可用（对位 lite `_ensureInitialized` 容错思路）。
     */
    private fun encryptedPrefs(): SharedPreferences? = try {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            SECURE_PREFS_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    } catch (e: GeneralSecurityException) {
        Log.w(TAG, "加密凭证存储初始化失败（Keystore/解密异常）", e)
        null
    } catch (e: IOException) {
        Log.w(TAG, "加密凭证存储初始化失败（IO 异常）", e)
        null
    }

    /** 非机密账号 prefs（当前 userid 定位用，对位 lite 的普通 prefs）。 */
    private fun accountPrefs(): SharedPreferences =
        context.getSharedPreferences(ACCOUNT_PREFS_NAME, Context.MODE_PRIVATE)

    companion object {
        private const val TAG: String = "TokenStore"

        /** 加密凭证 prefs 文件名（专用，避免与 LoudnessStorePrefs 等混用）。 */
        const val SECURE_PREFS_NAME: String = "gracemusic_secure_credentials"

        /** 非机密账号 prefs 文件名。 */
        const val ACCOUNT_PREFS_NAME: String = "gracemusic_account"

        /** 加密 prefs 内 token 键前缀（对位 lite `kugou_token_$uid`）。 */
        const val TOKEN_KEY_PREFIX: String = "kugou_token_"

        /** 加密 prefs 内 vipToken 键前缀（对位 lite `kugou_vip_token_$uid`）。 */
        const val VIP_TOKEN_KEY_PREFIX: String = "kugou_vip_token_"

        /** 普通 prefs 内当前账号键（对位 lite `kugou_current_userid`）。 */
        const val CURRENT_USERID_KEY: String = "kugou_current_userid"
    }
}
